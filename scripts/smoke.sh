#!/usr/bin/env bash
# Assert the local IMDb build is sane. Run after every refresh.
#
#   smoke.sh          # all checks, one line each
#   smoke.sh -q       # only failures
#   smoke.sh --tmdb   # additionally hit the real TMDb API (needs a token,
#                     # costs 3 requests) and check the enrichment path
#
# Every check is a boolean SQL expression. Thresholds are deliberately loose
# where IMDb data drifts daily (ratings, row counts) and exact where a wrong
# answer means the build is broken (parsing, list splitting, NULL handling).
set -uo pipefail

DATA_DIR="${IMDB_DATA_DIR:-$HOME/.local/share/imdb}"
DB="$DATA_DIR/imdb.duckdb"
QUIET=0; TMDB=0
for a in "$@"; do
  case "$a" in
    -q) QUIET=1 ;;
    --tmdb) TMDB=1 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
  esac
done
[[ -f "$DB" ]] || { echo "no database at $DB — run refresh.sh" >&2; exit 1; }

pass=0; fail=0
check() { # check <name> <sql returning boolean>
  local name=$1 sql=$2 got
  got=$(duckdb -readonly -noheader -list "$DB" -c "SELECT ($sql)::VARCHAR" 2>&1)
  if [[ "$got" == "true" ]]; then
    (( QUIET )) || printf '  ok    %s\n' "$name"; ((pass++))
  else
    printf '  FAIL  %s  -> %s\n' "$name" "$got" >&2; ((fail++))
  fi
}

echo "== volume =="
check "12M+ titles"                 "(SELECT count(*) FROM title_basics) > 12000000"
check "15M+ names"                  "(SELECT count(*) FROM name_basics) > 15000000"
check "100M+ principals"            "(SELECT count(*) FROM title_principals) > 100000000"
check "55M+ akas"                   "(SELECT count(*) FROM title_akas) > 55000000"
check "9M+ episodes"                "(SELECT count(*) FROM title_episode) > 9000000"
check "1.5M+ rated titles"          "(SELECT count(*) FROM title_ratings) > 1500000"

echo "== parsing =="
check "no literal \\N in titles"     "(SELECT count(*) FROM title_basics WHERE originalTitle = chr(92)||'N') = 0"
check "no literal \\N in names"      "(SELECT count(*) FROM name_basics WHERE primaryName = chr(92)||'N') = 0"
check "no literal \\N in akas"       "(SELECT count(*) FROM title_akas WHERE region = chr(92)||'N') = 0"
check "genres split to a list"      "(SELECT genres FROM title_basics WHERE tconst='tt0111161') = ['Drama']"
check "akas types split on 0x02"    "(SELECT count(*) FROM title_akas WHERE len(types) > 1) BETWEEN 100 AND 100000"
check "characters parsed from JSON" "(SELECT characters FROM title_principals WHERE tconst='tt0133093' AND nconst='nm0000206') = ['Neo']"
check "crew directors are a list"   "(SELECT len(directors) FROM title_crew WHERE tconst='tt0133093') = 2"
check "years are numeric"           "(SELECT startYear FROM title_basics WHERE tconst='tt1375666') = 2010"
check "runtime is numeric"          "(SELECT runtimeMinutes FROM title_basics WHERE tconst='tt1375666') = 148"
check "isAdult is boolean"          "(SELECT isAdult FROM title_basics WHERE tconst='tt1375666') = false"

echo "== content =="
check "Shawshank is tt0111161"      "(SELECT primaryTitle FROM title_basics WHERE tconst='tt0111161') = 'The Shawshank Redemption'"
check "Inception rated 8+ / 2M+"    "(SELECT averageRating > 8 AND numVotes > 2000000 FROM title_ratings WHERE tconst='tt1375666')"
check "originalTitle differs"       "(SELECT primaryTitle <> originalTitle FROM title_basics WHERE tconst='tt0064116')"
# 'Начало' is on Inception twice (region RU and region KZ) — the aka table is
# many-rows-per-title by design, which is exactly why joins need DISTINCT.
check "Cyrillic aka resolves"       "(SELECT count(*) FROM title_akas WHERE titleId='tt1375666' AND title='Начало') >= 1"
check "ILIKE folds Cyrillic"        "(SELECT count(*) FROM title_akas WHERE title ILIKE 'начало') = (SELECT count(*) FROM title_akas WHERE title = 'Начало')"
check "accents need strip_accents"  "(SELECT count(*) FROM title_basics WHERE strip_accents(primaryTitle) ILIKE 'amelie') > (SELECT count(*) FROM title_basics WHERE primaryTitle ILIKE 'amelie')"
check "list_contains beats equality" "(SELECT count(*) FROM title_crew WHERE list_contains(directors,'nm0001054')) > (SELECT count(*) FROM title_crew WHERE directors = ['nm0001054'])"
# 74 rows, because episodeNumber 0 is the unaired pilot
check "GoT has 73 numbered episodes" "(SELECT count(*) FROM title_episode WHERE parentTconst='tt0944947' AND episodeNumber >= 1) = 73"
check "Breaking Bad finale 9.5+"    "(SELECT averageRating FROM episodes WHERE parentTconst='tt0903747' AND seasonNumber=5 AND episodeNumber=16) >= 9.5"

echo "== views =="
check "titles view joins ratings"   "(SELECT averageRating IS NOT NULL FROM titles WHERE tconst='tt1375666')"
check "movies view filters type"    "(SELECT count(*) FROM movies WHERE titleType <> 'movie') = 0"
check "episodes view resolves series" "(SELECT seriesTitle FROM episodes WHERE tconst='tt2301451') = 'Breaking Bad'"
check "credits view joins names"    "(SELECT count(*) FROM credits WHERE tconst='tt0133093' AND primaryName='Keanu Reeves') = 1"

echo "== cross-file integrity =="
# The seven dumps are published minutes to a day apart, so a few thousand
# dangling ids are normal. A jump means a genuinely broken download.
check "principals->basics dangling < 50k" \
  "(SELECT count(*) FROM (SELECT DISTINCT tconst FROM title_principals) p ANTI JOIN title_basics b USING (tconst)) < 50000"
check "principals->names dangling < 50k" \
  "(SELECT count(*) FROM (SELECT DISTINCT nconst FROM title_principals) p ANTI JOIN name_basics n USING (nconst)) < 50000"
check "akas->basics dangling < 50k" \
  "(SELECT count(*) FROM (SELECT DISTINCT titleId AS tconst FROM title_akas) a ANTI JOIN title_basics b USING (tconst)) < 50000"

if (( TMDB )); then
  echo "== tmdb enrichment (live API) =="
  # Checked against the real service, not a stand-in: the only thing worth
  # knowing is whether TMDb still answers in the shape the fetcher expects.
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  TOKEN="${TMDB_TOKEN:-}"
  [[ -z "$TOKEN" && -n "${TMDB_TOKEN_FILE:-}" && -f "$TMDB_TOKEN_FILE" ]] && TOKEN=$(tr -d '[:space:]' < "$TMDB_TOKEN_FILE")
  [[ -z "$TOKEN" && -f "$DATA_DIR/tmdb.token" ]] && TOKEN=$(tr -d '[:space:]' < "$DATA_DIR/tmdb.token")
  if [[ -z "$TOKEN" ]]; then
    echo "  SKIP  no TMDb token — see 'Getting a TMDb token' in SKILL.md" >&2
  else
    OUT=$(printf 'tt1375666\ntt0944947\n' \
          | python3 "$SCRIPT_DIR/tmdb_fetch.py" --token "$TOKEN" --full 2>/dev/null || true)
    jq_get() { python3 -c "
import json,sys
want=sys.argv[1]
for l in sys.stdin:
    r=json.loads(l)
    if r['tconst']==want: print(json.dumps(r)); break
" "$1" <<<"$OUT"; }
    HIT=$(jq_get tt1375666); MISS=$(jq_get tt0944947)
    pycheck() { python3 -c "
import json,sys
r=json.loads(sys.argv[1] or '{}')
print('true' if eval(sys.argv[2], {'r': r}) else f'got {r.get(sys.argv[3])!r}')
" "$1" "$2" "$3" 2>/dev/null || echo "no response"; }
    livecheck() { local name=$1 got; got=$(pycheck "$2" "$3" "$4")
      if [[ "$got" == "true" ]]; then (( QUIET )) || printf '  ok    %s\n' "$name"; ((pass++))
      else printf '  FAIL  %s -> %s\n' "$name" "$got" >&2; ((fail++)); fi; }
    livecheck "movie resolves by imdb id" "$HIT" "r.get('_kind')=='hit' and r.get('tmdb_id')==27205" "_kind"
    livecheck "overview arrives"          "$HIT" "bool(r.get('overview'))" "overview"
    livecheck "full fetch fills runtime"  "$HIT" "isinstance(r.get('runtime'), int) and r['runtime']>0" "runtime"
    livecheck "keywords parsed"           "$HIT" "isinstance(r.get('keywords'), list) and len(r['keywords'])>0" "keywords"
    livecheck "series is a miss"          "$MISS" "r.get('_kind')=='miss' and r.get('reason')=='series'" "reason"
  fi
fi

echo
echo "$pass passed, $fail failed"
(( fail == 0 ))
