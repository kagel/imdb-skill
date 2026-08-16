# imdb — a Claude Code skill for querying all of IMDb locally

Loads IMDb's official daily dumps into a single DuckDB file and lets Claude
Code answer film/TV questions with SQL instead of a web search. 12.7M titles,
15.6M people, 101M credits, ~3.5 GB on disk, no API key, no rate limit, no
network at query time.

**Licensing:** the data comes from IMDb's non-commercial datasets and is
licensed by IMDb for *personal and non-commercial use only*. Do not build
anything you charge money for on top of it.

## Requirements

- **DuckDB CLI** — `brew install duckdb` (macOS) or see duckdb.org/docs/installation
- **~8 GB free disk** during the build; 3.5 GB once it settles
- bash, curl (already on macOS and Linux)
- Claude Code

## Install

The directory must be named `imdb` — Claude Code takes the skill's name from
the folder, so `SKILL.md` has to land at `~/.claude/skills/imdb/SKILL.md`.

```bash
mkdir -p ~/.claude/skills
git clone https://github.com/kagel/imdb-skill.git ~/.claude/skills/imdb
chmod +x ~/.claude/skills/imdb/scripts/*.sh
```

Later updates are then just `git -C ~/.claude/skills/imdb pull`.

From a zip instead — note that GitHub's own "Download ZIP" unpacks as
`imdb-skill-main/`, which is the wrong name, so rename it:

```bash
mkdir -p ~/.claude/skills
unzip imdb-skill.zip -d ~/.claude/skills          # this repo's release zip: already named imdb/
# if you used GitHub's Download ZIP button instead:
#   unzip imdb-skill-main.zip -d ~/.claude/skills && mv ~/.claude/skills/imdb-skill-main ~/.claude/skills/imdb
chmod +x ~/.claude/skills/imdb/scripts/*.sh
```

Then build the database — one download of ~1.9 GB, about a minute in total:

```bash
~/.claude/skills/imdb/scripts/refresh.sh
```

Verify it:

```bash
~/.claude/skills/imdb/scripts/smoke.sh    # expect "32 passed, 0 failed"
```

Restart Claude Code (or start a new session) and it will pick the skill up.

## Use

In Claude Code, just ask — "what's the best-rated sci-fi of the last decade",
"which episodes of The Wire are weakest", "everything Tilda Swinton directed".
Typing `/imdb` invokes it explicitly.

Outside Claude Code, query it yourself:

```bash
S=~/.claude/skills/imdb/scripts
$S/q.sh "SELECT primaryTitle, averageRating FROM movies WHERE numVotes > 200000 ORDER BY averageRating DESC LIMIT 10"
$S/q.sh --csv "SELECT ..." > out.csv
$S/q.sh --info                # what's loaded and how fresh
```

## Optional: TMDb enrichment

The IMDb dumps carry no plots, posters, budgets or streaming availability.
`enrich.sh` fetches those from TMDb into a **separate** cache database, so a
`refresh.sh` rebuild never wipes them.

```bash
scripts/enrich.sh --dry-run --top 5000   # how many would be fetched
scripts/enrich.sh --top 500              # one request per title
scripts/enrich.sh --top 100 --providers  # + budgets, keywords, where to watch
scripts/enrich.sh --top 500 --lang ru-RU # Russian descriptions
```

### Getting and storing a TMDb token

Free and instant. Use a **desktop** browser — TMDb's API signup is not
mobile-friendly.

1. Sign up: <https://www.themoviedb.org/signup>
2. Go to <https://www.themoviedb.org/settings/api>
3. Request a key, accept the terms, choose **Personal / non-commercial**
   (approved immediately)
4. Copy the **API Read Access Token** — the long value starting with `ey…`

Store it outside this repository — a token committed here would be published:

```bash
echo '<your token>' > ~/.local/share/imdb/tmdb.token
chmod 600 ~/.local/share/imdb/tmdb.token
```

Alternatives: `export TMDB_TOKEN='<token>'` for a single session, or
`export TMDB_TOKEN_FILE=~/path/to/your/secrets/tmdb.token` to keep it wherever
you already keep credentials.

Also needs `python3` (standard library only — nothing to install). Re-running
fetches only what is missing or stale: 30-day TTL for descriptions, 7-day for
streaming providers, and titles TMDb does not have are cached as misses so they
are not re-requested.

Afterwards `q.sh` joins the two automatically:

```bash
scripts/q.sh "SELECT m.primaryTitle, t.overview FROM movies m JOIN tmdb.tmdb_titles t USING (tconst) LIMIT 5"
```

## Keeping it fresh

IMDb republishes the dumps daily, around 00:40 UTC.

```bash
scripts/refresh.sh            # rebuilds only if IMDb published something new
scripts/refresh.sh --check    # compare local vs remote, change nothing
scripts/refresh.sh --force    # rebuild regardless
scripts/refresh.sh --keep-raw # keep the .tsv.gz dumps around
```

The refresh downloads and builds in a staging directory, checks row counts and
NULL handling, and only then swaps the new database in and deletes the old
one. A failed refresh leaves the working database untouched. Raw dumps are
deleted after a successful build.

The database lives in `~/.local/share/imdb/` by default. Set `IMDB_DATA_DIR`
to put it elsewhere (an external drive, for instance).

## What's in the box

```
imdb/
  SKILL.md               what Claude reads: schema, caveats, query rules
  README.md              this file
  reference/recipes.md   20 worked query patterns
  scripts/refresh.sh     download → build → verify → swap → clean up
  scripts/build.sql      the TSV → DuckDB load
  scripts/q.sh           read-only SQL runner
  scripts/smoke.sh       32 assertions to run after each refresh
```

## Known limits of the data

The dumps do **not** contain plots, reviews, box office, budgets, images,
streaming availability, full cast, or any rating history — the ratings are a
daily snapshot. `SKILL.md` documents the traps in detail (multi-director
lists, name collisions, transliterated original titles, duplicate alias rows,
missing birth years). Worth skimming before writing your own SQL.

## Uninstall

```bash
rm -rf ~/.claude/skills/imdb ~/.local/share/imdb
```
