# LocalStorage GetAll() Cold Read Benchmark

A single-page benchmark that measures the synchronous `GetAll()` Mojo IPC call
triggered when a Chromium renderer first accesses `localStorage` for an origin.
Use this to compare cold-read performance between the **SQLite** and **LevelDB**
DOM Storage backends.

## Why a cold read?

When JavaScript touches `localStorage` for the first time, the renderer's
`CachedStorageArea` is empty. It fires a synchronous `GetAll()` Mojo IPC to the
browser process, which reads every key-value pair from disk (via `StorageAreaImpl
→ AsyncDomStorageDatabase`). This is the critical path we want to benchmark.

There are **two caching layers** that can hide the true disk cost:

| Layer | Where | Survives tab close? | Survives browser restart? |
|-------|-------|---------------------|---------------------------|
| `CachedStorageArea::map_` | Renderer process | No | No |
| `StorageAreaImpl::keys_values_map_` | Browser process | Yes | No |

Because the browser-side cache persists across tab opens/closes, **you must
restart the browser** between populating data and measuring the read to
guarantee a true cold read from disk.

## Quick Start

### 1. Serve the site

LocalStorage requires an HTTP origin (not `file://`):

```bash
cd localstorage-getall-perf/
python3 -m http.server 8080
```

### 2. Launch Chrome with the desired backend

**SQLite backend (new):**
```bash
chrome --enable-features=DomStorageSqlite,DomStorageSqliteInMemory \
       --user-data-dir=/tmp/chrome-sqlite-test \
       http://localhost:8080
```

**LevelDB backend (legacy):**
```bash
chrome --disable-features=DomStorageSqlite \
       --user-data-dir=/tmp/chrome-leveldb-test \
       http://localhost:8080
```

### 3. Cold-read workflow

1. **Populate** — select entry count and value size, click *Populate localStorage*
2. **Close the browser** — this flushes uncommitted data to disk
   (`ScheduleImmediateCommit`) and tears down all in-memory caches
3. **Reopen the browser** with the same `--user-data-dir` and navigate to
   `http://localhost:8080`
4. **Measure** — click *Measure Cold GetAll()* to time the first
   `localStorage` access (the cold `GetAll()` from disk)

## Architecture notes

- **No iframes** — the page reads and writes `localStorage` directly.
  Since a browser restart is required between populate and measure, there is no
  need to isolate contexts.
- **Cold vs warm detection** — if you populate and then measure without
  restarting, the page flags the result as *warm* since both the renderer-side
  `CachedStorageArea` and browser-side `StorageAreaImpl` caches are hot.
- **Quota** — the Web Storage spec allows ~10 MB per origin, stored as UTF-16
  internally, giving a practical limit of ~5 million characters across all
  keys and values.
