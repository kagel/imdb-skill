-- Cache database for TMDb enrichment. Separate file from imdb.duckdb on
-- purpose: refresh.sh rebuilds the IMDb database from scratch every time IMDb
-- publishes, and enrichment must survive that.

CREATE TABLE IF NOT EXISTS tmdb_titles (
    tconst              VARCHAR PRIMARY KEY,
    tmdb_id             BIGINT,
    lang                VARCHAR,
    title               VARCHAR,
    original_title      VARCHAR,
    tagline             VARCHAR,
    overview            VARCHAR,
    status              VARCHAR,
    release_date        DATE,
    runtime             INTEGER,
    budget              BIGINT,
    revenue             BIGINT,
    popularity          DOUBLE,
    vote_average        DOUBLE,
    vote_count          INTEGER,
    homepage            VARCHAR,
    poster_path         VARCHAR,
    backdrop_path       VARCHAR,
    original_language   VARCHAR,
    genres              VARCHAR[],
    production_countries VARCHAR[],
    spoken_languages    VARCHAR[],
    keywords            VARCHAR[],
    collection_id       BIGINT,
    collection_name     VARCHAR,
    full_fetch          BOOLEAN,   -- false = /find only (1 request, no budget/runtime/keywords)
    fetched_at          TIMESTAMP,
    -- Separate clock: watch providers rotate far faster than the rest of the
    -- record, so they expire on their own TTL. NULL = never fetched with
    -- --providers, which is not the same as "available nowhere".
    providers_fetched_at TIMESTAMP
);

-- Where to watch, per country. Volatile — its own timestamp and its own TTL.
CREATE TABLE IF NOT EXISTS tmdb_providers (
    tconst      VARCHAR,
    country     VARCHAR,
    kind        VARCHAR,   -- flatrate | rent | buy | free | ads
    provider    VARCHAR,
    fetched_at  TIMESTAMP
);

-- Negative cache. Without it every run re-requests the titles TMDb does not
-- have, and IMDb has millions of those.
CREATE TABLE IF NOT EXISTS tmdb_misses (
    tconst      VARCHAR PRIMARY KEY,
    reason      VARCHAR,
    fetched_at  TIMESTAMP
);

CREATE TABLE IF NOT EXISTS tmdb_meta (
    key     VARCHAR PRIMARY KEY,
    value   VARCHAR
);
