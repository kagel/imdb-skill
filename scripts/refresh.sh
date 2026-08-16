#!/usr/bin/env bash
# Refresh the local IMDb dataset: download today's dumps, rebuild the DuckDB,
# swap it in, delete the previous version.
#
# Usage:
#   refresh.sh            # refresh only if IMDb published newer files
#   refresh.sh --check    # report local vs remote freshness, change nothing
#   refresh.sh --force    # rebuild even if already current
#   refresh.sh --keep-raw # keep the .tsv.gz dumps (default: delete after build)
#
# Layout under $IMDB_DATA_DIR (default ~/.local/share/imdb):
#   imdb.duckdb   the queryable database
#   RELEASE       manifest of what's loaded (source timestamps, row counts)
#   .build/       staging, exists only during a refresh
#   raw/          the .tsv.gz dumps, only with --keep-raw
#
# The old database is deleted only after the new one is built AND passes row
# count checks, so a failed refresh leaves the working copy untouched.
set -euo pipefail

DATA_DIR="${IMDB_DATA_DIR:-$HOME/.local/share/imdb}"
DB="$DATA_DIR/imdb.duckdb"
STAGE="$DATA_DIR/.build"
RELEASE="$DATA_DIR/RELEASE"
BASE="https://datasets.imdbws.com"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILES=(title.ratings title.episode title.crew title.basics name.basics title.akas title.principals)
NEED_GB=8

FORCE=0; KEEP_RAW=0; CHECK_ONLY=0
for a in "$@"; do
  case "$a" in
    --force)    FORCE=1 ;;
    --keep-raw) KEEP_RAW=1 ;;
    --check)    CHECK_ONLY=1 ;;
    -h|--help)  sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown arg: $a (try --help)" >&2; exit 2 ;;
  esac
done

command -v duckdb >/dev/null || { echo "duckdb CLI not found — brew install duckdb" >&2; exit 1; }
mkdir -p "$DATA_DIR"

# ---------- what does IMDb have right now ----------
echo "checking $BASE ..."
REMOTE=$(mktemp)
trap 'rm -f "$REMOTE"' EXIT
for f in "${FILES[@]}"; do
  hdr=$(curl -sSfI -m 60 --retry 3 "$BASE/$f.tsv.gz" | tr -d '\r')
  lm=$(sed -n 's/^[Ll]ast-[Mm]odified: //p' <<<"$hdr")
  sz=$(sed -n 's/^[Cc]ontent-[Ll]ength: //p' <<<"$hdr")
  [[ -n "$lm" && -n "$sz" ]] || { echo "no Last-Modified/Content-Length for $f" >&2; exit 1; }
  printf '%s\t%s\t%s\n' "$f" "$lm" "$sz" >> "$REMOTE"
done

LOCAL_MANIFEST=""
[[ -f "$RELEASE" ]] && LOCAL_MANIFEST=$(sed -n '/^\[source\]$/,/^\[/p' "$RELEASE" | sed '1d;/^\[/d;/^$/d')

if (( CHECK_ONLY )); then
  echo; echo "remote:"; cat "$REMOTE"
  echo; echo "local:"
  if [[ -f "$RELEASE" ]]; then cat "$RELEASE"; else echo "  (nothing built yet)"; fi
  echo
  if [[ -f "$DB" && "$LOCAL_MANIFEST" == "$(cat "$REMOTE")" ]]; then
    echo "=> current"
  else
    echo "=> stale or missing — run refresh.sh"
  fi
  exit 0
fi

if (( ! FORCE )) && [[ -f "$DB" && "$LOCAL_MANIFEST" == "$(cat "$REMOTE")" ]]; then
  echo "already current (IMDb has published nothing new since the last build)"
  echo "use --force to rebuild anyway"
  exit 0
fi

rm -rf "$STAGE"   # drop any half-finished previous attempt before sizing the disk
# df -k is the portable form; -g is macOS-only and -BG is GNU-only
avail_gb=$(df -k "$DATA_DIR" | awk 'NR==2{printf "%d", $4/1048576}')
(( avail_gb >= NEED_GB )) || { echo "need ~${NEED_GB}GB free, have ${avail_gb}GB" >&2; exit 1; }

# ---------- download ----------
mkdir -p "$STAGE/raw"
echo "downloading 7 dumps (~1.9 GB) ..."
for f in "${FILES[@]}"; do
  curl -sSf -m 1800 --retry 3 -o "$STAGE/raw/$f.tsv.gz" "$BASE/$f.tsv.gz"
  printf '  %-18s %s\n' "$f" "$(du -h "$STAGE/raw/$f.tsv.gz" | cut -f1)"
done

# ---------- build ----------
echo "building duckdb ..."
( cd "$STAGE" && duckdb "$STAGE/imdb.duckdb" < "$SCRIPT_DIR/build.sql" >/dev/null )

# ---------- verify before destroying the old copy ----------
echo "verifying ..."
rows() { duckdb -readonly -noheader -list "$STAGE/imdb.duckdb" -c "SELECT count(*) FROM $1"; }
declare -a COUNTS=()
fail=0
while read -r tbl floor; do
  n=$(rows "$tbl")
  COUNTS+=("$tbl	$n")
  if (( n < floor )); then echo "  FAIL $tbl: $n rows, expected >= $floor" >&2; fail=1
  else printf '  %-18s %12s rows\n' "$tbl" "$n"; fi
done <<'EOF'
title_basics	10000000
title_ratings	1000000
title_akas	30000000
title_crew	10000000
title_episode	5000000
title_principals	50000000
name_basics	10000000
EOF

# \N must have been consumed as NULL, not stored as a literal string
leak=$(duckdb -readonly -noheader -list "$STAGE/imdb.duckdb" \
  -c "SELECT count(*) FROM title_basics WHERE originalTitle = chr(92) || 'N'")
if [[ "$leak" != "0" ]]; then echo "  FAIL: $leak rows carry a literal \\N — nullstr did not apply" >&2; fail=1; fi

if (( fail )); then
  rm -rf "$STAGE"   # 5.4 GB of staging is not worth keeping for a rerun
  echo "build rejected; existing database left in place at $DB" >&2
  exit 1
fi

# ---------- swap in, delete the old version ----------
{
  echo "[build]"
  echo "built_at	$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "db_bytes	$(stat -f %z "$STAGE/imdb.duckdb" 2>/dev/null || stat -c %s "$STAGE/imdb.duckdb")"
  echo
  echo "[rows]"
  printf '%s\n' "${COUNTS[@]}"
  echo
  echo "[source]"
  cat "$REMOTE"
} > "$STAGE/RELEASE"

if [[ -f "$DB" ]]; then
  mv "$DB" "$DB.old"
  rm -f "$DB.wal" "$DB.old.wal"
fi
mv "$STAGE/imdb.duckdb" "$DB"
mv "$STAGE/RELEASE" "$RELEASE"
rm -f "$DB.old"

# The previous raw/ is stale the moment a new build lands, so it goes either
# way — replaced when keeping, deleted when not.
rm -rf "$DATA_DIR/raw"
if (( KEEP_RAW )); then mv "$STAGE/raw" "$DATA_DIR/raw"; fi
rm -rf "$STAGE"

echo
echo "$DB  ($(du -h "$DB" | cut -f1))"
echo "source date: $(awk -F'\t' '$1=="title.ratings"{print $2}' "$REMOTE")"
