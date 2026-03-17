# LocalStorage GetAll() Performance Test

A simple static website to benchmark the `GetAll()` Mojo IPC call that fires
when a Chromium renderer first accesses `localStorage` for an origin. Use this
to compare performance between the **SQLite** and **LevelDB** DOM Storage
backends.

## Quick Start

### 1. Serve the site

LocalStorage requires an HTTP origin (not `file://`). Use any simple server:

```bash
cd localstorage-getall-perf/
python3 -m http.server 8080
```

Then open `http://localhost:8080` in Chrome.

### 2. Launch Chrome with the desired backend

**SQLite backend (new):**
```bash
chrome --enable-features=DomStorageSqlite,DomStorageSqliteInMemory \
       --user-data-dir=/tmp/chrome-sqlite-test
```

**LevelDB backend (legacy):**
```bash
chrome --disable-features=DomStorageSqlite,DomStorageSqliteInMemory \
       --user-data-dir=/tmp/chrome-leveldb-test
```

> **Important:** Use separate `--user-data-dir` paths for each backend to
> avoid cross-contamination. A fresh profile ensures no pre-existing data
> skews results.

### 3. Run the benchmark

1. **Configure** the number of entries, value size, and iterations
2. Click **"Populate localStorage"** to write test data
3. Click **"Run GetAll() Benchmark"** to measure
4. View results in the log and summary section
5. Click **"Copy Results to Clipboard"** to export for comparison

## How It Works

### What is GetAll()?

When JavaScript first accesses `localStorage` (e.g., `localStorage.length`),
the Blink renderer calls `CachedStorageArea::EnsureLoaded()`, which makes a
**synchronous** Mojo IPC call to the browser process to fetch all key-value
pairs for the origin. This is the `GetAll()` call. All subsequent reads hit
an in-memory cache.

### Measurement approach

Since `GetAll()` only fires once per `CachedStorageArea` lifetime (tied to the
`Document`), we use an **iframe-based approach** to get multiple measurements:

1. Create a hidden `<iframe>` pointing to `worker.html?cmd=measure`
2. The iframe loads, accesses `localStorage.length` (triggering `GetAll()`),
   and times it with `performance.now()`
3. The iframe posts the duration back to the parent
4. The parent destroys the iframe and repeats

Each iframe gets a fresh `Document` → fresh `CachedStorageArea` → fresh
`GetAll()` IPC call.

## Configuration Options

| Option | Values | Notes |
|--------|--------|-------|
| Number of entries | 100 – 10,000 | More entries = more data to fetch |
| Value size | 10, 100, 1,000 bytes | Affects total data size |
| Iterations | 1 – 1,000 | More iterations = more reliable stats |

The page shows estimated total data size and warns if approaching the
~10 MB per-origin limit.

## Interpreting Results

- **Median** is the most reliable single metric (robust to outliers)
- **First iteration** may be slower due to cold caches in the browser process
- Compare SQLite vs LevelDB by running the same configuration with both
  Chrome flag settings and comparing median/mean times
- Look at **standard deviation** to assess consistency

## GitHub Pages

To host on GitHub Pages:

1. Create a new GitHub repository
2. Push these files to the `main` branch
3. Enable GitHub Pages in repo Settings → Pages → Source: `main` branch
4. Access at `https://<username>.github.io/<repo-name>/`

## Files

```
index.html    — Main test harness (config UI, benchmark runner, results)
worker.html   — Iframe page for localStorage operations (populate/measure)
plan.md       — Implementation plan and design notes
README.md     — This file
```
