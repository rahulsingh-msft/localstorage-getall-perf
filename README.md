# LocalStorage First Read Benchmark

A benchmark tool that measures the first `localStorage` access time in a fresh
browser instance. Includes a web UI for manual testing and PowerShell scripts
for automated multi-run comparisons across different DOM Storage backends.

## Files

| File | Description |
|------|-------------|
| `index.html` | Benchmark web page (manual UI + URL-driven automation) |
| `benchmark.ps1` | Automated single-origin cold-read benchmark |
| `benchmark-warm-db.ps1` | Automated cross-origin warm-DB benchmark |

## Manual Testing

### 1. Open the benchmark page

Use the deployed GitHub Pages site:

```
https://rahulsingh-msft.github.io/localstorage-getall-perf/
```

Or serve locally:
```bash
python -m http.server 9090
```

### 2. Launch the browser with the desired backend

**SQLite backend:**
```powershell
msedge.exe --enable-features=DomStorageSqlite `
           --user-data-dir="$env:TEMP\edge-sqlite-test" `
           https://rahulsingh-msft.github.io/localstorage-getall-perf/
```

**LevelDB backend (default):**
```powershell
msedge.exe --disable-features=DomStorageSqlite `
           --user-data-dir="$env:TEMP\edge-leveldb-test" `
           https://rahulsingh-msft.github.io/localstorage-getall-perf/
```

Use separate `--user-data-dir` paths so databases don't interfere.

### 3. Benchmark workflow

1. **Populate** — select entry count and value size, click *Populate*
2. **Close the browser** — ensures data is persisted to disk
3. **Reopen the browser** with the same `--user-data-dir`
4. **Measure** — click *Measure* to time the first `localStorage` read

Use the *Delay before read* option to let browser startup I/O settle.

## Automated Testing

### Cold-read benchmark (`benchmark.ps1`)

Measures the first `localStorage` read after a browser restart across multiple
runs for both LevelDB and SQLite backends.

```powershell
.\benchmark.ps1 -Runs 10 -Entries 10000 -ValueSize 100 -Delay 5000
```

Results are written to `results.txt`.

### Warm-DB benchmark (`benchmark-warm-db.ps1`)

Isolates DB opening overhead from data retrieval cost. Populates two origins
on separate ports, then measures:

- **Tab 1** (origin A) — cold read (DB not yet open)
- **Tab 2** (origin B) — warm-DB read (DB already open, data not cached)

The delta between the two reveals how much time is spent opening the database
vs reading data.

```powershell
.\benchmark-warm-db.ps1 -Runs 10 -Entries 10000 -Delay 5000
```

Results are written to `results-warm-db.txt`.

Requires Python for local HTTP servers (two ports for two origins).

### Common parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-Runs` | 10 | Measurement cycles per backend |
| `-Entries` | 10000 | localStorage entries to populate |
| `-ValueSize` | 100 | Characters per value |
| `-Delay` | 5000 | Milliseconds to wait before measuring |
| `-EdgePath` | Edge SxS | Path to `msedge.exe` |

### URL parameters for automation

The page supports URL parameters for script-driven use:

| Parameter | Example | Description |
|-----------|---------|-------------|
| `?populate=N&valueSize=V` | `?populate=10000&valueSize=100` | Auto-populates localStorage, sets `document.title` to `POPULATED:<count>` |
| `?auto&delay=Ms` | `?auto&delay=5000` | Waits, then measures first read, sets `document.title` to `RESULT:<ms>:<entries>` |

## Notes

- **Why restart?** — Browsers cache localStorage in memory at multiple levels.
  These caches persist across tab opens/closes. Restarting guarantees a true
  first read from disk.
- **Warm read detection** — if you populate and measure without restarting,
  the UI flags the result as *warm*.
- **Quota** — localStorage allows ~5M characters per origin (~10 MB as UTF-16).
