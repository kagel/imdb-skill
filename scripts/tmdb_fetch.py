#!/usr/bin/env python3
"""Fetch TMDb records for IMDb tconsts read from stdin; emit NDJSON on stdout.

Standard library only — no pip, no uv, no venv. Runs on the python3 that ships
with macOS and any Linux.

The efficiency rules this encodes, which are the whole point of the file:

* One request per title in the default mode. `/find/{tconst}?external_source=
  imdb_id` returns the full movie object, so the description, poster, TMDb
  rating and tmdb_id all arrive without a second call.
* `--full` costs a second request but collapses what would be five into one:
  `/movie/{id}?append_to_response=keywords,watch/providers` — TMDb allows up
  to 20 appended sub-requests per call.
* A shared token bucket keeps the whole worker pool under TMDb's ~40 req/s
  ceiling. Workers are for hiding latency, not for going faster than the limit.
* 429 is honoured via Retry-After rather than guessed at; 5xx backs off
  exponentially; 404 is a miss, not an error, and is reported so the caller can
  cache it negatively.
"""

import argparse
import json
import os
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor

# Overridable so the fetch path can be tested against a local mock without a
# real token. Leave unset in normal use.
BASE = os.environ.get("TMDB_API_BASE", "https://api.themoviedb.org/3")


class Limiter:
    """Shared token bucket: no more than `rps` requests per second in total."""

    def __init__(self, rps):
        self.interval = 1.0 / rps
        self.lock = threading.Lock()
        self.next_at = time.monotonic()

    def wait(self):
        with self.lock:
            now = time.monotonic()
            if self.next_at < now:
                self.next_at = now
            slot = self.next_at
            self.next_at += self.interval
        delay = slot - time.monotonic()
        if delay > 0:
            time.sleep(delay)


class Client:
    def __init__(self, token, limiter, tries=4, timeout=30):
        self.limiter = limiter
        self.tries = tries
        self.timeout = timeout
        # v4 read access tokens are JWTs and go in the header; a v3 key is a
        # query parameter. Accept whichever the user pasted.
        self.bearer = token.startswith("ey") and token.count(".") == 2
        self.token = token
        self.stats = {"requests": 0, "retries": 0, "throttled": 0}
        self.lock = threading.Lock()

    def get(self, path, params=None):
        params = dict(params or {})
        if not self.bearer:
            params["api_key"] = self.token
        url = f"{BASE}{path}?{urllib.parse.urlencode(params)}"
        headers = {"accept": "application/json"}
        if self.bearer:
            headers["Authorization"] = f"Bearer {self.token}"

        for attempt in range(self.tries):
            self.limiter.wait()
            req = urllib.request.Request(url, headers=headers)
            try:
                with self.lock:
                    self.stats["requests"] += 1
                with urllib.request.urlopen(req, timeout=self.timeout) as r:
                    return json.load(r)
            except urllib.error.HTTPError as e:
                if e.code == 404:
                    return None
                if e.code == 401:
                    raise SystemExit("TMDb rejected the token (401). Check TMDB_TOKEN.")
                if e.code == 429:
                    with self.lock:
                        self.stats["throttled"] += 1
                    time.sleep(float(e.headers.get("Retry-After", 1)) + 0.5)
                    continue
                if 500 <= e.code < 600:
                    with self.lock:
                        self.stats["retries"] += 1
                    time.sleep(2 ** attempt)
                    continue
                raise
            except (urllib.error.URLError, TimeoutError, json.JSONDecodeError):
                with self.lock:
                    self.stats["retries"] += 1
                time.sleep(2 ** attempt)
        raise RuntimeError(f"giving up on {path} after {self.tries} attempts")


def names(seq, key="name"):
    return [x[key] for x in (seq or []) if x.get(key)]


def unknown_is_zero(v):
    """TMDb writes 0, not null, for an unknown runtime/budget/revenue.

    Storing the 0 makes every avg() and every "cheapest film" query quietly
    wrong — a 1921 stub record would claim a runtime of zero minutes. No film
    has any of these legitimately at 0, so 0 means "not recorded".
    """
    return None if v in (0, None) else v


def fetch_one(client, tconst, lang, full, genre_map, providers):
    found = client.get(f"/find/{tconst}", {"external_source": "imdb_id", "language": lang})
    results = (found or {}).get("movie_results") or []
    if not results:
        # A tv_results hit means the tconst is a series, not a movie — still a
        # miss for this table, but worth distinguishing in the reason.
        kind = "series" if (found or {}).get("tv_results") else "not_found"
        return {"_kind": "miss", "tconst": tconst, "reason": kind}

    m = results[0]
    rec = {
        "_kind": "hit",
        "tconst": tconst,
        "tmdb_id": m.get("id"),
        "lang": lang,
        "title": m.get("title"),
        "original_title": m.get("original_title"),
        "tagline": None,
        "overview": m.get("overview") or None,
        "status": None,
        "release_date": m.get("release_date") or None,
        "runtime": None,
        "budget": None,
        "revenue": None,
        "popularity": m.get("popularity"),
        "vote_average": m.get("vote_average"),
        "vote_count": m.get("vote_count"),
        "homepage": None,
        "poster_path": m.get("poster_path"),
        "backdrop_path": m.get("backdrop_path"),
        "original_language": m.get("original_language"),
        "genres": [genre_map[g] for g in (m.get("genre_ids") or []) if g in genre_map],
        "production_countries": None,
        "spoken_languages": None,
        "keywords": None,
        "collection_id": None,
        "collection_name": None,
        "full_fetch": False,
        "providers": [],
    }

    if full:
        append = ["keywords"]
        if providers:
            append.append("watch/providers")
        d = client.get(f"/movie/{rec['tmdb_id']}",
                       {"language": lang, "append_to_response": ",".join(append)})
        if d:
            coll = d.get("belongs_to_collection") or {}
            rec.update({
                "tagline": d.get("tagline") or None,
                "overview": d.get("overview") or rec["overview"],
                "status": d.get("status"),
                "runtime": unknown_is_zero(d.get("runtime")),
                "budget": unknown_is_zero(d.get("budget")),
                "revenue": unknown_is_zero(d.get("revenue")),
                "homepage": d.get("homepage") or None,
                "genres": names(d.get("genres")) or rec["genres"],
                "production_countries": [c.get("iso_3166_1") for c in d.get("production_countries") or []],
                "spoken_languages": [c.get("iso_639_1") for c in d.get("spoken_languages") or []],
                "keywords": names((d.get("keywords") or {}).get("keywords")),
                "collection_id": coll.get("id"),
                "collection_name": coll.get("name"),
                "full_fetch": True,
            })
            if providers:
                out = []
                for country, blocks in ((d.get("watch/providers") or {}).get("results") or {}).items():
                    if providers != "ALL" and country not in providers:
                        continue
                    for kind in ("flatrate", "rent", "buy", "free", "ads"):
                        for p in blocks.get(kind) or []:
                            out.append({"country": country, "kind": kind,
                                        "provider": p.get("provider_name")})
                rec["providers"] = out
    return rec


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--token", required=True)
    ap.add_argument("--lang", default="en-US")
    ap.add_argument("--full", action="store_true",
                    help="second request per title: runtime, budget, keywords, collection")
    ap.add_argument("--providers", action="store_true", help="watch providers (implies --full)")
    ap.add_argument("--provider-countries", default="ALL",
                    help="comma-separated ISO country codes, or ALL. TMDb returns every "
                         "market it knows: one popular film can be 700+ rows.")
    ap.add_argument("--workers", type=int, default=12)
    ap.add_argument("--rps", type=float, default=30.0, help="TMDb's ceiling is ~40/s")
    ap.add_argument("--progress-every", type=int, default=200)
    args = ap.parse_args()
    full = args.full or args.providers
    countries = ("ALL" if args.provider_countries.strip().upper() == "ALL"
                 else {c.strip().upper() for c in args.provider_countries.split(",") if c.strip()})
    want_providers = countries if args.providers else None

    tconsts = [l.strip() for l in sys.stdin if l.strip() and l.strip().startswith("tt")]
    if not tconsts:
        print("nothing to fetch", file=sys.stderr)
        return 0

    client = Client(args.token, Limiter(args.rps))
    genres = client.get("/genre/movie/list", {"language": args.lang}) or {}
    genre_map = {g["id"]: g["name"] for g in genres.get("genres", [])}
    print(f"{len(tconsts)} to fetch, {len(genre_map)} genres, lang={args.lang}, "
          f"{'2 requests' if full else '1 request'}/title, {args.rps}/s cap",
          file=sys.stderr)

    done = hits = misses = errors = 0
    started = time.time()
    lock = threading.Lock()
    out = sys.stdout

    def work(tc):
        nonlocal done, hits, misses, errors
        try:
            rec = fetch_one(client, tc, args.lang, full, genre_map, want_providers)
        except Exception as e:                      # noqa: BLE001 - report, keep going
            rec = {"_kind": "error", "tconst": tc, "reason": f"{type(e).__name__}: {e}"}
        with lock:
            out.write(json.dumps(rec, ensure_ascii=False) + "\n")
            done += 1
            hits += rec["_kind"] == "hit"
            misses += rec["_kind"] == "miss"
            errors += rec["_kind"] == "error"
            if done % args.progress_every == 0:
                rate = done / max(time.time() - started, 0.001)
                print(f"  {done}/{len(tconsts)}  {rate:.1f}/s  "
                      f"hit {hits} miss {misses} err {errors}", file=sys.stderr)

    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        list(pool.map(work, tconsts))

    elapsed = time.time() - started
    print(f"done: {hits} hit, {misses} miss, {errors} error in {elapsed:.1f}s "
          f"({client.stats['requests']} requests, {client.stats['retries']} retried, "
          f"{client.stats['throttled']} throttled)", file=sys.stderr)
    return 1 if errors and not hits else 0


if __name__ == "__main__":
    sys.exit(main())
