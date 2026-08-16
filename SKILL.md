---
name: imdb
description: Query the full IMDb dataset locally with DuckDB — 12.7M titles, 15.6M people, 101M credits, refreshed from IMDb's official daily dumps. Use when the user says /imdb or asks anything about films, series, episodes, ratings, cast/crew, filmographies, genres, runtimes, or localized titles. Also handles refreshing the dataset and its housekeeping.
allowed-tools: Bash, Read
---

# imdb — the whole of IMDb, locally, in DuckDB

IMDb's official daily dumps (`datasets.imdbws.com`) loaded into one DuckDB
file. No API key, no rate limit, no network at query time. Licensed by IMDb
for **personal and non-commercial use only** — that is the whole basis on
which this exists, so nothing built here goes into a paid product.

Database: `~/.local/share/imdb/imdb.duckdb` (~3.5 GB, override with
`$IMDB_DATA_DIR`). Freshness manifest: `~/.local/share/imdb/RELEASE`.

## Querying

```bash
S=~/.claude/skills/imdb/scripts
$S/q.sh "SELECT primaryTitle, averageRating FROM movies ORDER BY numVotes DESC LIMIT 10"
$S/q.sh --csv "SELECT ..."      # also --json --markdown --line
$S/q.sh --info                  # what's loaded, how fresh
```

Multi-line SQL goes through a heredoc — never fight shell quoting:

```bash
$S/q.sh <<'SQL'
SELECT primaryTitle, startYear, averageRating
FROM movies
WHERE list_contains(genres, 'Film-Noir') AND numVotes > 20000
ORDER BY averageRating DESC LIMIT 10;
SQL
```

The database is opened `-readonly`, so no query can damage it. Answer the
user's question with SQL — don't hand them the SQL and stop.

More query patterns: `reference/recipes.md`.

## Refresh, housekeeping, smoke test

```bash
$S/refresh.sh           # rebuild only if IMDb published newer files
$S/refresh.sh --check   # compare local vs remote, change nothing
$S/refresh.sh --force   # rebuild regardless
$S/refresh.sh --keep-raw # keep the .tsv.gz dumps (default: delete them)
$S/smoke.sh             # 32 assertions; run after every refresh
```

Measured: ~62 s total (1.9 GB download + 35 s build). IMDb publishes around
00:40 UTC daily.

How it protects the working copy: downloads and builds in `.build/`, verifies
row counts and that `\N` was consumed as NULL, and only then swaps the new
file in and deletes the old one. A rejected build exits 1, clears staging, and
leaves the previous database byte-identical. Raw dumps are deleted after a
successful build, so the footprint stays at 3.5 GB, not 5.4 GB. Needs ~8 GB
free and refuses rather than filling the disk.

## Tables

Column names are IMDb's own camelCase, so IMDb's docs map 1:1. DuckDB
identifiers are case-insensitive, so `titletype` works too.

| Table | Rows | Columns |
|---|---|---|
| `title_basics` | 12.72M | tconst, titleType, primaryTitle, originalTitle, isAdult, startYear, endYear, runtimeMinutes, **genres[]** |
| `title_ratings` | 1.7M | tconst, averageRating, numVotes |
| `title_akas` | 59.0M | titleId, ordering, title, region, language, **types[]**, **attributes[]**, isOriginalTitle |
| `title_crew` | 12.7M | tconst, **directors[]**, **writers[]** (nconst lists) |
| `title_episode` | 9.8M | tconst, parentTconst, seasonNumber, episodeNumber |
| `title_principals` | 101.2M | tconst, ordering, nconst, category, job, **characters[]** |
| `name_basics` | 15.6M | nconst, primaryName, birthYear, deathYear, **primaryProfession[]**, **knownForTitles[]** |

## Views

- `titles` — `title_basics` + `averageRating`/`numVotes`. Start here.
- `movies` — `titles` where titleType = 'movie'.
- `series` — titleType in ('tvSeries','tvMiniSeries').
- `episodes` — episode + its series title + season/episode number + rating.
- `credits` — person × title, denormalized: primaryName, primaryTitle,
  category, characters, rating. The one you want for "who was in what".

## Rules that bite

All numbers below were measured on the 2026-08-16 build, not assumed.

### Ranking and ratings

- **Ratings cover 1.7M of 12.7M titles.** Everything else has NULL
  `averageRating`. Always `numVotes > N` when ranking, or the top of every
  list is a 10.0 from 6 votes. 25k for "canonical", 5k for "known", 500 for
  "obscure but real".
- **`LIMIT` without `ORDER BY` returns arbitrary rows** — DuckDB reads in
  parallel, there is no natural order. This produces confidently wrong answers
  ("no such film") when the row existed but wasn't in the first N.
- **Adult titles are not filtered.** 414k titles are `isAdult`, 9,093 of them
  inside the `movies` view, 18 with 1000+ votes. Add `AND NOT isAdult` to
  anything user-facing.
- **Unreleased titles are in the data**: 201k dated 2026, 2,488 dated 2027,
  a handful out to 2033 — and 27k of the 2026 ones already carry ratings.
  A "newest films" query returns announcements unless bounded.

### People

- **Names collide, badly.** 15.58M rows, 11.86M distinct names, 1.24M names
  shared by 2+ people: `John Williams` is 387 different `nconst`,
  `Chris Evans` 143. **Never `WHERE primaryName = 'X' LIMIT 1`** — resolve
  the person first (show birthYear + knownForTitles), then query by nconst.
- **`birthYear` is NULL for 14.9M of 15.6M people (96%).** Any age or
  generation query silently drops almost everyone. Say so when answering.
- `title_principals` is *principal* credits: 8.8 rows per title on average
  (median 4 cast members, max 75). It is not the full cast, and it mixes cast
  with one row per key crew role — filter `category`.
- `characters` is NULL for every crew category (51.9M rows) and for 4.6M
  actor rows. It is also effectively single-valued: only 5 rows in 101M carry
  two names, and those are comma artifacts. The website's "Neo / Thomas A.
  Anderson" is not in the dumps.
- `job` is NULL on 81.7M of 101.2M rows.

### Crew

- **Directors and writers are lists.** 1.40M titles have 2+ directors, 3.28M
  have 2+ writers, the record is 558 directors / 1,483 writers on one
  tvSeries. `WHERE directors = ['nm0001054']` returns 3 Coen brothers titles;
  `list_contains(directors,'nm0001054')` returns 28. Always `list_contains`
  or `unnest` — never equality, never `LIKE`.
- **5.64M titles (44%) have no director at all** in `title_crew`.
- Directors live in two places: `title_crew.directors` (complete) and
  `title_principals` with `category='director'` (only when top-billed). Use
  `title_crew` for completeness, `title_principals` for billing order.

### Titles and languages

- **`primaryTitle` is the international/English title. `originalTitle` is
  transliterated Latin, not native script**: *Иди и смотри* is stored as
  `Idi i smotri`. Native-script titles exist only in `title_akas`.
- **`title_akas` is many rows per title, with duplicate strings.**
  Interstellar has 26 rows all reading "Interstellar"; 8.02M
  (titleId, title) groups are duplicated. **Any join to `title_akas` needs
  `DISTINCT`** or the result set multiplies ~20×.
- **Filter akas by `region`, not `language`.** `language` is NULL on 19.3M of
  59M rows, and often NULL exactly on the row you want: Inception's RU row
  has language NULL while its KZ row says `ru`.
- **`region` is not pure ISO-3166** and is NULL on 12.8M rows (21%). Historic
  codes matter: `SUHH` (USSR, 45k rows), `XWG` (West Germany), `DDDE` (East
  Germany), `XYU`/`YUCS` (Yugoslavia), `CSHH` (Czechoslovakia), `XWW`
  (worldwide), `XEU` (Europe). Soviet-era releases are under `SUHH`, not `RU`.
- **`ILIKE` folds Cyrillic correctly but not accents.** `ILIKE 'начало'`
  matches `Начало`; `ILIKE 'amelie'` finds 5 titles while `'amélie'` finds 13
  and `strip_accents(primaryTitle) ILIKE 'amelie'` finds 19. Use
  `strip_accents()` for any Latin-script search.
- The per-region display title is the aka row whose `types` contains
  `imdbDisplay`. Coverage is partial: of 12,528 movies with 10k+ votes, 10,593
  have a Russian `imdbDisplay` row.

### Episodes

- **`episodeNumber = 0` exists** (6,990 rows: unaired pilots, specials).
  Game of Thrones has 74 `title_episode` rows and 73 numbered episodes.
- `seasonNumber` and `episodeNumber` are both NULL on 2.06M rows (21%).
- 20 (parent, season, episode) triples are duplicated — IMDb's own errors.

### Missing and dirty values

- `runtimeMinutes` NULL on 8.16M titles (64%), with outliers up to 3,692,080
  minutes on a tvSeries. Bound it: `runtimeMinutes BETWEEN 40 AND 300`.
- `startYear` NULL on 1.48M (12%); `genres` NULL on 541k, and IMDb never
  stores more than 3 genres per title.

### The seven files are not one snapshot

They are published minutes to a day apart, and `refresh.sh` takes whatever is
current for each file. Measured both ways on 2026-08-16:

| | `title.basics` a day behind | all seven aligned |
|---|---:|---:|
| principals → basics dangling | 1,169 | **0** |
| principals → names dangling | 3,214 | 3,214 |
| rows dropped by `credits` | 13,771 | 7,000 |

So a stale file adds dangling ids, but ~3.2k nconsts referenced by
`title_principals` are missing from `name_basics` even within one aligned
release — that is IMDb's own inconsistency and never goes away. `credits` and
`episodes` are inner joins, so those rows silently vanish. `smoke.sh` fails
only above 50k, which would mean a genuinely broken download rather than
normal drift.

### DuckDB gotchas

- `cast` is a reserved word — `count(*) AS cast` is a syntax error. Alias it
  `n_cast`.
- **Lambdas cannot contain subqueries.** `list_transform(knownForTitles,
  x -> (SELECT primaryTitle ...))` fails with "subqueries in lambda
  expressions are not supported". Resolve id lists with `unnest` + join +
  `list()` instead — see the person-resolution recipe.

### What is not in the dataset at all

Plots/synopses, user reviews, box office, budgets, keywords, images, streaming
availability, popularity rank (MOVIEmeter), full cast, company credits,
rating history (the ratings are a daily snapshot, no time series). If the
question needs those, the dumps cannot answer it — say so instead of
approximating.

## Performance

Measured on this machine (10 cores, warm page cache, median of 3 runs). The
first query after a reboot pays reading up to 3.5 GB from SSD; everything
after that is RAM-speed.

| Query shape | Wall | CPU-s | Parallelism | Peak RSS |
|---|---:|---:|---:|---:|
| point lookup by tconst | 0.02 s | 0.03 | 1.5× | 38 MB |
| title prefix search (ILIKE, 12.7M) | 0.28 s | 2.04 | 7.8× | 316 MB |
| accent-insensitive search | 0.32 s | 2.63 | 8.2× | 283 MB |
| top movies by genre + vote floor | 0.11 s | 0.73 | 6.6× | 311 MB |
| person filmography (`credits`, 101M) | 0.43 s | 2.45 | 6.1× | 1.3 GB |
| director filmography (crew unnest) | 0.17 s | 0.86 | 5.1× | 522 MB |
| episodes of one series | 0.08 s | 0.39 | 4.9× | 189 MB |
| series ranked by avg episode rating | 0.68 s | 4.60 | 7.0× | 1.5 GB |
| genre × year aggregate (unnest) | 1.07 s | 3.82 | 3.6× | 365 MB |
| collaborators (self-join on 101M) | 0.97 s | 5.49 | 6.8× | 1.3 GB |
| localized title lookup (akas 59M) | 0.43 s | 2.84 | 7.3× | 1.1 GB |
| rating stats per decade | 0.11 s | 0.57 | 5.7× | 190 MB |
| full `credits` aggregate | 0.77 s | 4.82 | 6.8× | 1.4 GB |

Read: nothing takes longer than about a second, but a big join saturates 6–8
cores and can touch 1.5 GB of RAM for a second. Don't loop 500 of these in a
shell loop — write one SQL statement that does the whole job.

## Build details

`scripts/build.sql` holds the load. Two reader settings are not optional:
`quote='' escape=''` (IMDb titles contain bare `"`, which otherwise swallows
whole rows) and `nullstr='\N'`. Array separators are commas everywhere except
`title_akas.types`/`attributes`, which use the 0x02 control byte.

No indexes, deliberately: ART indexes on the tconst/nconst columns grew the
database from 3.5 GB to 10.7 GB and the build from 35 s to 2 m 22 s while a
person-filmography lookup ran 0.46 s either way.
