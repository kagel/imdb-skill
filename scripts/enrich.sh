#!/usr/bin/env bash
# Enrich IMDb titles with TMDb data (descriptions, posters, budgets, keywords,
# where-to-watch) into a SEPARATE cache database, fetching only what is missing
# or stale.
#
#   enrich.sh --top 500                    # 500 most-voted movies, 1 request each
#   enrich.sh --top 200 --full             # + runtime, budget, keywords, collection
#   enrich.sh --top 100 --providers        # + where to watch (implies --full)
#   enrich.sh --sql "SELECT tconst FROM imdb.movies WHERE startYear=2026 AND numVotes>10000"
#   enrich.sh --tconst tt1375666,tt0111161
#   enrich.sh --top 500 --lang ru-RU       # Russian overviews into a separate cache
#   enrich.sh --dry-run --top 5000         # how many would actually be fetched
#
# Cache: $IMDB_DATA_DIR/tmdb-<lang>.duckdb — a different file from imdb.duckdb,
# because refresh.sh replaces that one wholesale and enrichment must survive it.
#
# Freshness: a title is re-fetched only when its cached row is older than the
# TTL, or when a mode is requested that the cached row does not satisfy (asking
# for --full when only a /find record is cached). Misses are cached too.
#
# Token: $TMDB_TOKEN, or $IMDB_DATA_DIR/tmdb.token. A v4 read access token
# (starts with "ey") or a v3 API key both work.
set -euo pipefail

DATA_DIR="${IMDB_DATA_DIR:-$HOME/.local/share/imdb}"
DB="$DATA_DIR/imdb.duckdb"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LANG_TAG="en-US"; TOP=""; SEL_SQL=""; TCONSTS=""
FULL=0; PROVIDERS=0; DRY=0; REFRESH=0
TTL=30; PROV_TTL=7; MISS_TTL=30
WORKERS=12; RPS=30

while [[ $# -gt 0 ]]; do
  case "$1" in
    --top)           TOP="$2"; shift 2 ;;
    --sql)           SEL_SQL="$2"; shift 2 ;;
    --tconst)        TCONSTS="$2"; shift 2 ;;
    --lang)          LANG_TAG="$2"; shift 2 ;;
    --full)          FULL=1; shift ;;
    --providers)     PROVIDERS=1; FULL=1; shift ;;
    --ttl)           TTL="$2"; shift 2 ;;
    --providers-ttl) PROV_TTL="$2"; shift 2 ;;
    --miss-ttl)      MISS_TTL="$2"; shift 2 ;;
    --workers)       WORKERS="$2"; shift 2 ;;
    --rps)           RPS="$2"; shift 2 ;;
    --refresh)       REFRESH=1; shift ;;
    --dry-run)       DRY=1; shift ;;
    -h|--help)       sed -n '2,26p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1 (try --help)" >&2; exit 2 ;;
  esac
done

CACHE="$DATA_DIR/tmdb-${LANG_TAG}.duckdb"
[[ -f "$DB" ]] || { echo "no IMDb database at $DB — run refresh.sh first" >&2; exit 1; }
command -v duckdb >/dev/null || { echo "duckdb CLI not found" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 not found (stdlib only, no packages needed)" >&2; exit 1; }

# ---------- what to fetch ----------
if   [[ -n "$TCONSTS" ]]; then
  SELECTOR="SELECT unnest(string_split('$TCONSTS', ',')) AS tconst"
elif [[ -n "$SEL_SQL" ]]; then
  SELECTOR="$SEL_SQL"
elif [[ -n "$TOP" ]]; then
  SELECTOR="SELECT tconst FROM imdb.movies WHERE NOT isAdult AND numVotes IS NOT NULL
            ORDER BY numVotes DESC LIMIT $TOP"
else
  echo "pick a selection: --top N, --sql '<sql returning tconst>', or --tconst tt1,tt2" >&2
  exit 2
fi

# Token first, so a token-less run fails before creating any files. A dry run
# needs the cache to anti-join against, but never needs a token.
TOKEN="${TMDB_TOKEN:-}"
if [[ -z "$TOKEN" && -f "$DATA_DIR/tmdb.token" ]]; then TOKEN=$(tr -d '[:space:]' < "$DATA_DIR/tmdb.token"); fi
if [[ -z "$TOKEN" ]] && (( ! DRY )); then
  cat >&2 <<'EOF'
No TMDb token. Get one free (personal use, instant):
  themoviedb.org account -> Settings -> API -> request a key
Then either:
  export TMDB_TOKEN='<v4 read access token or v3 api key>'
  echo '<token>' > "$IMDB_DATA_DIR/tmdb.token"   # default ~/.local/share/imdb/tmdb.token
Or add --dry-run to see how many titles would be fetched without one.
EOF
  exit 1
fi

duckdb "$CACHE" < "$SCRIPT_DIR/tmdb-schema.sql" >/dev/null

WORK=$(mktemp); ND=$(mktemp); trap 'rm -f "$WORK" "$ND"' EXIT

# A row is fresh when: within TTL, and already carries the depth being asked
# for. Misses have their own TTL so absent titles are not re-requested daily.
FRESH_COND="fetched_at > now() - INTERVAL $TTL DAY"
(( FULL )) && FRESH_COND="$FRESH_COND AND full_fetch"
# Providers have their own, much shorter clock — streaming rights rotate.
(( PROVIDERS )) && FRESH_COND="$FRESH_COND AND providers_fetched_at > now() - INTERVAL $PROV_TTL DAY"
(( REFRESH )) && FRESH_COND="false"

duckdb -noheader -list "$CACHE" <<SQL > "$WORK"
ATTACH '$DB' AS imdb (READ_ONLY);
WITH cand AS ($SELECTOR),
     fresh AS (SELECT tconst FROM tmdb_titles WHERE $FRESH_COND),
     missed AS (SELECT tconst FROM tmdb_misses
                WHERE fetched_at > now() - INTERVAL $MISS_TTL DAY AND NOT $REFRESH)
SELECT tconst FROM cand ANTI JOIN fresh USING (tconst) ANTI JOIN missed USING (tconst);
SQL

TOTAL=$(duckdb -noheader -list "$CACHE" <<SQL
ATTACH '$DB' AS imdb (READ_ONLY);
SELECT count(*) FROM ($SELECTOR);
SQL
)
NEED=$(wc -l < "$WORK" | tr -d ' ')
REQ_PER=$(( FULL ? 2 : 1 ))
echo "selected $TOTAL titles; $NEED need fetching ($(( TOTAL - NEED )) already cached and fresh)"
echo "≈$(( NEED * REQ_PER )) requests at ${RPS}/s ≈ $(( NEED * REQ_PER / (RPS > 0 ? RPS : 1) ))s"

if (( DRY )); then echo "(dry run — nothing fetched)"; exit 0; fi
if (( NEED == 0 )); then echo "cache is current, nothing to do"; exit 0; fi

# ---------- fetch ----------
PYARGS=(--token "$TOKEN" --lang "$LANG_TAG" --workers "$WORKERS" --rps "$RPS")
(( FULL )) && PYARGS+=(--full)
(( PROVIDERS )) && PYARGS+=(--providers)
python3 "$SCRIPT_DIR/tmdb_fetch.py" "${PYARGS[@]}" < "$WORK" > "$ND"

# ---------- upsert ----------
# Columns are declared explicitly: with auto-detection a batch where some field
# is null in every row infers as NULL type and the insert fails.
duckdb "$CACHE" <<SQL
CREATE OR REPLACE TEMP TABLE inc AS
SELECT * FROM read_json('$ND', format='newline_delimited', columns={
  _kind:'VARCHAR', tconst:'VARCHAR', reason:'VARCHAR', tmdb_id:'BIGINT', lang:'VARCHAR',
  title:'VARCHAR', original_title:'VARCHAR', tagline:'VARCHAR', overview:'VARCHAR',
  status:'VARCHAR', release_date:'VARCHAR', runtime:'INTEGER', budget:'BIGINT',
  revenue:'BIGINT', popularity:'DOUBLE', vote_average:'DOUBLE', vote_count:'INTEGER',
  homepage:'VARCHAR', poster_path:'VARCHAR', backdrop_path:'VARCHAR',
  original_language:'VARCHAR', genres:'VARCHAR[]', production_countries:'VARCHAR[]',
  spoken_languages:'VARCHAR[]', keywords:'VARCHAR[]', collection_id:'BIGINT',
  collection_name:'VARCHAR', full_fetch:'BOOLEAN',
  providers:'STRUCT(country VARCHAR, kind VARCHAR, provider VARCHAR)[]'
});

INSERT OR REPLACE INTO tmdb_titles
SELECT tconst, tmdb_id, lang, title, original_title, tagline, overview, status,
       TRY_CAST(release_date AS DATE), runtime, budget, revenue, popularity,
       vote_average, vote_count, homepage, poster_path, backdrop_path,
       original_language, genres, production_countries, spoken_languages, keywords,
       collection_id, collection_name, coalesce(full_fetch, false), now(),
       CASE WHEN $PROVIDERS = 1 THEN now() ELSE NULL END
FROM inc WHERE _kind = 'hit';

DELETE FROM tmdb_providers WHERE tconst IN (SELECT tconst FROM inc WHERE _kind='hit');
INSERT INTO tmdb_providers
SELECT i.tconst, p.country, p.kind, p.provider, now()
FROM inc i, unnest(i.providers) AS t(p)
WHERE i._kind = 'hit' AND i.providers IS NOT NULL;

INSERT OR REPLACE INTO tmdb_misses SELECT tconst, reason, now() FROM inc WHERE _kind = 'miss';
DELETE FROM tmdb_misses WHERE tconst IN (SELECT tconst FROM inc WHERE _kind = 'hit');

INSERT OR REPLACE INTO tmdb_meta VALUES ('last_run', strftime(now(), '%Y-%m-%dT%H:%M:%S'));
SQL

duckdb -box "$CACHE" <<'SQL'
SELECT (SELECT count(*) FROM tmdb_titles)    AS cached_titles,
       (SELECT count(*) FROM tmdb_titles WHERE full_fetch) AS full_records,
       (SELECT count(*) FROM tmdb_titles WHERE overview IS NOT NULL) AS with_overview,
       (SELECT count(*) FROM tmdb_providers) AS provider_rows,
       (SELECT count(*) FROM tmdb_misses)    AS cached_misses;
SQL
echo "cache: $CACHE"
