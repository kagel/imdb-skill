-- Build the IMDb DuckDB from the raw daily TSV dumps.
-- Run with cwd = staging dir (so raw/*.tsv.gz resolves), e.g.
--   cd "$STAGE" && duckdb imdb.duckdb < build.sql
--
-- Reader params that are NOT optional:
--   quote='' escape=''  -> IMDb TSVs contain bare " inside titles; with the
--                          default quote char whole rows get swallowed.
--   nullstr='\N'        -> IMDb's NULL marker, otherwise it lands as the
--                          literal two-char string "\N" in every text column.
-- Array separators differ per file: comma everywhere EXCEPT title.akas
-- types/attributes, which use the 0x02 control byte.

SET preserve_insertion_order = false;

CREATE OR REPLACE TABLE title_basics AS
SELECT
    tconst,
    titleType,
    primaryTitle,
    originalTitle,
    isAdult = '1'                                                            AS isAdult,
    TRY_CAST(startYear      AS SMALLINT)                                     AS startYear,
    TRY_CAST(endYear        AS SMALLINT)                                     AS endYear,
    TRY_CAST(runtimeMinutes AS INTEGER)                                      AS runtimeMinutes,
    CASE WHEN genres IS NULL THEN NULL ELSE string_split(genres, ',') END    AS genres
FROM read_csv('raw/title.basics.tsv.gz',
              delim='\t', header=true, quote='', escape='', nullstr='\N', all_varchar=true);

CREATE OR REPLACE TABLE title_ratings AS
SELECT
    tconst,
    TRY_CAST(averageRating AS DOUBLE)  AS averageRating,
    TRY_CAST(numVotes      AS INTEGER) AS numVotes
FROM read_csv('raw/title.ratings.tsv.gz',
              delim='\t', header=true, quote='', escape='', nullstr='\N', all_varchar=true);

CREATE OR REPLACE TABLE title_akas AS
SELECT
    titleId,
    TRY_CAST(ordering AS INTEGER) AS ordering,
    title,
    region,
    language,
    CASE WHEN types      IS NULL THEN NULL ELSE string_split(types,      chr(2)) END AS types,
    CASE WHEN attributes IS NULL THEN NULL ELSE string_split(attributes, chr(2)) END AS attributes,
    isOriginalTitle = '1' AS isOriginalTitle
FROM read_csv('raw/title.akas.tsv.gz',
              delim='\t', header=true, quote='', escape='', nullstr='\N', all_varchar=true);

CREATE OR REPLACE TABLE title_crew AS
SELECT
    tconst,
    CASE WHEN directors IS NULL THEN NULL ELSE string_split(directors, ',') END AS directors,
    CASE WHEN writers   IS NULL THEN NULL ELSE string_split(writers,   ',') END AS writers
FROM read_csv('raw/title.crew.tsv.gz',
              delim='\t', header=true, quote='', escape='', nullstr='\N', all_varchar=true);

CREATE OR REPLACE TABLE title_episode AS
SELECT
    tconst,
    parentTconst,
    TRY_CAST(seasonNumber  AS INTEGER) AS seasonNumber,
    TRY_CAST(episodeNumber AS INTEGER) AS episodeNumber
FROM read_csv('raw/title.episode.tsv.gz',
              delim='\t', header=true, quote='', escape='', nullstr='\N', all_varchar=true);

CREATE OR REPLACE TABLE title_principals AS
SELECT
    tconst,
    TRY_CAST(ordering AS INTEGER) AS ordering,
    nconst,
    category,
    job,
    json_extract_string(characters, '$[*]') AS characters
FROM read_csv('raw/title.principals.tsv.gz',
              delim='\t', header=true, quote='', escape='', nullstr='\N', all_varchar=true);

CREATE OR REPLACE TABLE name_basics AS
SELECT
    nconst,
    primaryName,
    TRY_CAST(birthYear AS SMALLINT) AS birthYear,
    TRY_CAST(deathYear AS SMALLINT) AS deathYear,
    CASE WHEN primaryProfession IS NULL THEN NULL ELSE string_split(primaryProfession, ',') END AS primaryProfession,
    CASE WHEN knownForTitles    IS NULL THEN NULL ELSE string_split(knownForTitles,    ',') END AS knownForTitles
FROM read_csv('raw/name.basics.tsv.gz',
              delim='\t', header=true, quote='', escape='', nullstr='\N', all_varchar=true);

-- No indexes on purpose. Measured on this dataset: ART indexes on the tconst /
-- nconst columns grow the database from 3.5 GB to 10.7 GB and the build from
-- 35 s to 2 m 22 s, while a person-filmography lookup takes 0.46 s either way.
-- DuckDB's zone maps and parallel hash joins already do the work.

-- Convenience views: the joins you would otherwise retype every session.

CREATE OR REPLACE VIEW titles AS
SELECT b.*, r.averageRating, r.numVotes
FROM title_basics b
LEFT JOIN title_ratings r USING (tconst);

CREATE OR REPLACE VIEW movies AS
SELECT * FROM titles WHERE titleType = 'movie';

CREATE OR REPLACE VIEW series AS
SELECT * FROM titles WHERE titleType IN ('tvSeries', 'tvMiniSeries');

CREATE OR REPLACE VIEW episodes AS
SELECT
    e.tconst,
    e.parentTconst,
    s.primaryTitle AS seriesTitle,
    e.seasonNumber,
    e.episodeNumber,
    b.primaryTitle AS episodeTitle,
    b.startYear,
    b.runtimeMinutes,
    r.averageRating,
    r.numVotes
FROM title_episode e
JOIN title_basics b       ON b.tconst = e.tconst
LEFT JOIN title_basics s  ON s.tconst = e.parentTconst
LEFT JOIN title_ratings r ON r.tconst = e.tconst;

-- One row per person per title: the table you want for "who was in what".
CREATE OR REPLACE VIEW credits AS
SELECT
    p.tconst,
    t.primaryTitle,
    t.titleType,
    t.startYear,
    p.nconst,
    n.primaryName,
    p.category,
    p.job,
    p.characters,
    p.ordering,
    t.averageRating,
    t.numVotes
FROM title_principals p
JOIN titles t      ON t.tconst = p.tconst
JOIN name_basics n ON n.nconst = p.nconst;
