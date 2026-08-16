#!/usr/bin/env bash
# Run read-only SQL against the local IMDb DuckDB.
#
# Usage:
#   q.sh "SELECT ..."                 # inline SQL
#   q.sh path/to/query.sql            # a .sql file
#   q.sh <<'SQL' ... SQL              # heredoc (preferred for multi-line)
#   q.sh --csv "SELECT ..."           # also --json --markdown --line --table
#   q.sh --info                       # what's loaded and how fresh it is
#
# SQL is passed on stdin, so quotes/$/backticks inside the query are safe.
# The database is opened read-only — a query can never damage the build.
set -euo pipefail

DATA_DIR="${IMDB_DATA_DIR:-$HOME/.local/share/imdb}"
DB="$DATA_DIR/imdb.duckdb"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FMT=-box

while [[ $# -gt 0 ]]; do
  case "$1" in
    --csv|--json|--markdown|--line|--table|--box) FMT="${1/--/-}"; shift ;;
    --info)
      [[ -f "$DATA_DIR/RELEASE" ]] && cat "$DATA_DIR/RELEASE" || echo "nothing built yet"
      exit 0 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) break ;;
  esac
done

if [[ ! -f "$DB" ]]; then
  echo "no database at $DB — build it first:" >&2
  echo "  $SCRIPT_DIR/refresh.sh" >&2
  exit 1
fi

if [[ $# -gt 0 && -f "$1" ]]; then
  SQL=$(cat "$1")
elif [[ $# -gt 0 ]]; then
  SQL="$1"
else
  SQL=$(cat)
fi

exec duckdb -readonly "$FMT" "$DB" <<<"$SQL"
