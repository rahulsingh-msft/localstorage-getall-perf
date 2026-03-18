# LocalStorage First Read Benchmark

A single-page benchmark that measures the time for the first `localStorage`
access in a fresh browser instance. Use this to compare cold-read performance
between different DOM Storage backends (e.g. SQLite vs LevelDB).

## Why restart the browser?

Browsers cache localStorage data in memory at multiple levels. These caches
persist across tab opens/closes within the same browser session. Restarting
the browser guarantees a true first read from disk.

## Quick Start

### 1. Serve the site

LocalStorage requires an HTTP origin (not `file://`):

```bash
cd localstorage-getall-perf/
python3 -m http.server 8080
```

### 2. Launch the browser with the desired backend

**SQLite backend:**
```bash
chrome --enable-features=DomStorageSqlite \
       --user-data-dir=/tmp/chrome-sqlite-test \
       http://localhost:8080
```

**LevelDB backend (legacy):**
```bash
chrome --disable-features=DomStorageSqlite \
       --user-data-dir=/tmp/chrome-leveldb-test \
       http://localhost:8080
```

Use separate `--user-data-dir` paths so databases don't interfere.

### 3. Benchmark workflow

1. **Populate** — select entry count and value size, click *Populate*
2. **Close the browser** — ensures data is persisted to disk
3. **Reopen the browser** with the same `--user-data-dir` and navigate to
   `http://localhost:8080`
4. **Measure** — click *Measure* to time the first `localStorage` read

Use the *Delay before read* option if you see high variance from browser
startup disk activity — a 5–10 second delay lets startup I/O settle.

## Notes

- **Warm read detection** — if you populate and measure without restarting,
  the result is flagged as *warm*.
- **Quota** — localStorage allows ~5M characters per origin (~10 MB as UTF-16).
