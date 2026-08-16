# imdb — query recipes

Run with `scripts/q.sh <<'SQL' ... SQL`. Every block here was executed against
the 2026-08-16 build. Read the "Rules that bite" section of SKILL.md first —
most of these recipes exist because the naive version is wrong.

## Finding a title

```sql
-- strip_accents is what makes "amelie" find "Amélie"; ILIKE alone does not
SELECT tconst, primaryTitle, originalTitle, titleType, startYear,
       averageRating, numVotes
FROM titles
WHERE strip_accents(primaryTitle) ILIKE strip_accents('amelie%')
ORDER BY numVotes DESC NULLS LAST
LIMIT 10;
```

When the user gives a title in its own language, `primaryTitle` will not have
it — native script lives only in `title_akas`, and it needs `DISTINCT`
because one title carries many identical aka rows:

```sql
SELECT DISTINCT t.tconst, a.title AS localTitle, t.primaryTitle, t.startYear,
       t.averageRating, t.numVotes
FROM title_akas a JOIN titles t ON t.tconst = a.titleId
WHERE a.title ILIKE 'начало'
ORDER BY t.numVotes DESC NULLS LAST LIMIT 10;
```

Search everything at once — international, original and localized:

```sql
SELECT DISTINCT t.tconst, t.primaryTitle, t.startYear, t.averageRating, t.numVotes
FROM titles t
LEFT JOIN title_akas a ON a.titleId = t.tconst
WHERE strip_accents(t.primaryTitle)  ILIKE strip_accents('%solaris%')
   OR strip_accents(t.originalTitle) ILIKE strip_accents('%solaris%')
   OR strip_accents(a.title)         ILIKE strip_accents('%solaris%')
ORDER BY t.numVotes DESC NULLS LAST LIMIT 10;
```

## Resolving a person — never `LIMIT 1` on a name

387 people are called John Williams. Show the candidates, then use the nconst:

```sql
WITH cand AS (
  SELECT nconst, primaryName, birthYear, deathYear, primaryProfession, knownForTitles
  FROM name_basics WHERE primaryName = 'John Williams'
),
known AS (   -- resolve knownForTitles ids to names; lambdas can't hold subqueries
  SELECT u.nconst, list(b.primaryTitle) AS knownFor
  FROM (SELECT nconst, unnest(knownForTitles) AS kt FROM cand) u
  JOIN title_basics b ON b.tconst = u.kt
  GROUP BY 1
),
vol AS (
  SELECT c.nconst, count(p.tconst) AS credits
  FROM cand c LEFT JOIN title_principals p USING (nconst) GROUP BY 1
)
SELECT c.nconst, c.primaryName, c.birthYear, c.deathYear,
       c.primaryProfession, k.knownFor, v.credits
FROM cand c LEFT JOIN known k USING (nconst) LEFT JOIN vol v USING (nconst)
ORDER BY v.credits DESC
LIMIT 10;
```

## Filmographies

```sql
-- acting/self credits, by nconst
SELECT primaryTitle, titleType, startYear, category, characters,
       averageRating, numVotes
FROM credits
WHERE nconst = 'nm0000138'
  AND titleType IN ('movie','tvSeries','tvMiniSeries')
ORDER BY startYear;
```

Directing credits must come from `title_crew` — `title_principals` only lists
a director when they are top-billed, and equality on the list silently drops
every co-directed film:

```sql
SELECT t.primaryTitle, t.startYear, t.averageRating, t.numVotes,
       len(c.directors) AS n_directors
FROM title_crew c JOIN titles t USING (tconst)
WHERE list_contains(c.directors, 'nm0001054')     -- Joel Coen
  AND t.titleType = 'movie'
ORDER BY t.startYear;
```

Co-directed films specifically:

```sql
WITH co AS (
  SELECT tconst, unnest(directors) AS nconst
  FROM title_crew WHERE len(directors) > 1
)
SELECT t.tconst, t.primaryTitle, t.startYear, t.averageRating,
       list(n.primaryName) AS directors
FROM co JOIN titles t USING (tconst) JOIN name_basics n USING (nconst)
WHERE t.titleType = 'movie' AND t.numVotes > 100000
GROUP BY 1, 2, 3, 4
ORDER BY t.averageRating DESC LIMIT 15;
```

## Ranking titles

```sql
SELECT primaryTitle, startYear, averageRating, numVotes
FROM movies
WHERE list_contains(genres, 'Horror')
  AND startYear BETWEEN 1980 AND 1989
  AND numVotes > 25000
  AND NOT isAdult                       -- 9k adult titles live in this view
ORDER BY averageRating DESC
LIMIT 20;
```

Hidden gems — rated well, enough votes to be real, few enough to be unknown:

```sql
SELECT primaryTitle, startYear, genres, averageRating, numVotes
FROM movies
WHERE numVotes BETWEEN 1000 AND 15000
  AND averageRating >= 7.8
  AND startYear BETWEEN 2000 AND year(current_date) - 1   -- exclude announcements
  AND NOT isAdult
ORDER BY averageRating DESC, numVotes DESC
LIMIT 30;
```

## Episodes

```sql
-- episodeNumber 0 is the unaired pilot / special, not episode one
SELECT seasonNumber, episodeNumber, episodeTitle, averageRating, numVotes
FROM episodes
WHERE parentTconst = 'tt0903747'                  -- Breaking Bad
  AND episodeNumber >= 1
ORDER BY seasonNumber, episodeNumber;
```

Season quality curve:

```sql
SELECT seasonNumber,
       count(*) AS eps,
       round(avg(averageRating), 2) AS avg_rating,
       min(averageRating) AS worst,
       max(averageRating) AS best
FROM episodes
WHERE parentTconst = 'tt0944947' AND seasonNumber IS NOT NULL
GROUP BY 1 ORDER BY 1;
```

Series ranked by episode quality:

```sql
SELECT s.primaryTitle, s.startYear,
       count(*) AS rated_eps,
       round(avg(e.averageRating), 2) AS avg_ep_rating
FROM episodes e JOIN titles s ON s.tconst = e.parentTconst
WHERE e.numVotes > 1000
GROUP BY 1, 2
HAVING count(*) >= 20
ORDER BY avg_ep_rating DESC
LIMIT 20;
```

## Who worked with whom

```sql
-- titles where both are credited (DiCaprio acting + Scorsese directing)
WITH a AS (SELECT tconst FROM title_principals WHERE nconst = 'nm0000138'),
     b AS (SELECT tconst FROM title_crew, unnest(directors) AS d(nconst)
           WHERE d.nconst = 'nm0000217')
SELECT t.primaryTitle, t.startYear, t.averageRating
FROM titles t
WHERE t.tconst IN (SELECT tconst FROM a INTERSECT SELECT tconst FROM b)
  AND t.startYear IS NOT NULL          -- drops the unreleased slate
ORDER BY t.startYear;
```

Frequent collaborators:

```sql
SELECT n.primaryName, p.category, count(*) AS shared
FROM title_principals p
JOIN title_principals me USING (tconst)
JOIN title_basics b      USING (tconst)
JOIN name_basics n ON n.nconst = p.nconst
WHERE me.nconst = 'nm0000233' AND p.nconst <> 'nm0000233'
  AND b.titleType = 'movie'            -- without this: making-of clips and TV
GROUP BY 1, 2 ORDER BY shared DESC LIMIT 20;
```

## Localization

```sql
-- how one film is titled per market; imdbDisplay is the official one
SELECT region, title, types, attributes
FROM title_akas
WHERE titleId = 'tt0816692'
  AND region IS NOT NULL
  AND list_contains(types, 'imdbDisplay')
ORDER BY region;
```

Soviet-era releases are `SUHH`, not `RU` — a Tarkovsky query filtering on
`region='RU'` finds only the modern re-releases:

```sql
SELECT a.region, a.title, t.primaryTitle, t.startYear
FROM title_akas a JOIN titles t ON t.tconst = a.titleId
WHERE a.titleId IN ('tt0069293','tt0079944')       -- Solaris, Stalker
  AND a.region IN ('RU','SUHH')
ORDER BY t.startYear, a.region;
```

## Aggregates

```sql
-- genre popularity over time
SELECT startYear, g AS genre, count(*) AS n, round(avg(averageRating), 2) AS avg_rating
FROM movies, unnest(genres) AS t(g)
WHERE startYear BETWEEN 2015 AND 2025 AND numVotes > 1000
GROUP BY 1, 2 ORDER BY 1, n DESC;
```

```sql
-- runtime vs rating; the bound is mandatory, the max runtime in the data is
-- 3,692,080 minutes
SELECT CASE
         WHEN runtimeMinutes < 90  THEN '<90'
         WHEN runtimeMinutes < 120 THEN '90-120'
         WHEN runtimeMinutes < 150 THEN '120-150'
         ELSE '150+' END AS bucket,
       count(*) AS n, round(avg(averageRating), 2) AS avg_rating
FROM movies
WHERE numVotes > 10000 AND runtimeMinutes BETWEEN 40 AND 300
GROUP BY 1 ORDER BY 2 DESC;
```

```sql
-- rating histogram
SELECT floor(averageRating) AS bucket, count(*) AS titles
FROM titles WHERE numVotes > 1000
GROUP BY 1 ORDER BY 1;
```

## People with dates

`birthYear` is present for only 4% of people, so anything age-based answers
for a small, non-random subset. Say so when reporting.

```sql
SELECT t.primaryTitle, t.startYear, n.primaryName,
       t.startYear - n.birthYear AS age_at_release
FROM credits c
JOIN titles t USING (tconst) JOIN name_basics n USING (nconst)
WHERE c.nconst = 'nm0000138' AND t.titleType = 'movie'
  AND n.birthYear IS NOT NULL AND t.startYear IS NOT NULL
ORDER BY t.startYear;
```

## Export

```bash
q.sh --csv "SELECT ..." > out.csv
q.sh "COPY (SELECT * FROM movies WHERE numVotes > 50000) TO '/tmp/top.parquet' (FORMAT parquet)"
```

`COPY … TO` writes a file even in read-only mode — verified; the database
itself stays untouched.
