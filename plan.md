# LocalStorage GetAll() Performance Test Website

## Problem Statement

We have two storage backends for DOM Storage (LocalStorage): the legacy LevelDB
and the newly added SQLite. We need a test website that benchmarks the
`GetAll()` Mojo IPC call that fires when a renderer first accesses
`localStorage` for an origin. The user will launch Chrome with the SQLite
feature flag enabled/disabled to compare backends — the website just needs to
populate data and measure performance.

## Key Technical Insight

`GetAll()` is a **synchronous** Mojo IPC call triggered once per origin on
first `localStorage` access (via `CachedStorageArea::EnsureLoaded()`). After
that, all reads hit an in-memory `StorageAreaMap`. To re-benchmark GetAll(), we
must invalidate the cache — we'll use an **iframe-based approach**: the actual
localStorage operations run inside an iframe that gets destroyed and recreated
between measurement runs, forcing a fresh `EnsureLoaded()` → `GetAll()` each
time.

## Approach

Create a static single-page website (with a helper iframe page) at
`/workspace/code/localstorage-getall-perf/`. The site will:

1. Let the user configure test parameters (number of entries, value size preset)
2. Populate `localStorage` with the configured data inside an iframe
3. Destroy the iframe, recreate it, and measure how long the first
   `localStorage` access takes (this triggers GetAll())
4. Repeat N times, logging each duration
5. Show summary stats (min, max, median, average)

## File Structure

```
/workspace/code/localstorage-getall-perf/
├── index.html          # Main test harness page (controls, results log)
├── worker.html         # Iframe page that does the actual localStorage work
└── README.md           # Usage instructions
```

## Todos

### 1. `worker.html` — iframe page for localStorage operations

This page runs inside an iframe. It communicates with the parent via
`postMessage`. It handles two commands:

- **`populate`**: Receives `{ numEntries, valueSize }`. Clears localStorage,
  then writes `numEntries` key-value pairs. Keys are `"k_0"`, `"k_1"`, etc.
  Values are strings of length `valueSize`. Reports progress back to parent.
  
- **`measure`**: On load (when the iframe is freshly created), immediately
  accesses `localStorage.length` (triggering GetAll()), measures the wall-clock
  time using `performance.now()`, and posts the duration back to the parent.

### 2. `index.html` — main test harness

**Configuration UI:**
- Number of entries: dropdown or input (presets: 100, 500, 1000, 5000, 10000)
- Value size: dropdown (Small ~10 bytes, Medium ~100 bytes, Large ~1000 bytes)
- Number of measurement iterations: input (default: 20)
- Shows estimated total data size based on selections

**Buttons:**
- "Populate localStorage" — creates iframe, sends populate command, shows
  progress bar, disables other buttons during population
- "Run GetAll() Benchmark" — runs N iterations:
  1. Create a fresh iframe pointing to `worker.html?cmd=measure`
  2. Wait for iframe to post back the GetAll() duration
  3. Destroy the iframe
  4. Log the result
  5. Repeat
- "Clear localStorage" — creates iframe, calls `localStorage.clear()`
- "Stop" — stops benchmark mid-run

**Results display:**
- Ordered list log (like the reference IndexedDB site): each entry shows
  iteration number and duration in ms
- Summary stats section: min, max, median, mean, std dev
- A "Copy Results" button to copy all timings to clipboard (for easy
  pasting into spreadsheets)

**Page structure:**
- Clean, minimal HTML (no build tools, no frameworks)
- All JS inline in a `<script>` tag (like the reference site)
- Basic CSS for readability

### 3. `README.md` — usage documentation

- How to serve the site (e.g., `python3 -m http.server` or GitHub Pages)
- How to launch Chrome with SQLite enabled vs disabled:
  - `--enable-features=DomStorageSqlite` 
  - `--disable-features=DomStorageSqlite`
- How to interpret results
- Note about using fresh profiles to avoid cross-contamination

## Design Details

### Iframe-based Cache Invalidation

The critical challenge: `GetAll()` only fires once per `CachedStorageArea`
lifetime. A `CachedStorageArea` is tied to the renderer's
`LocalFrame`/`Document`. By destroying and recreating the iframe, we get a
fresh `Document` → fresh `CachedStorageArea` → fresh `GetAll()` call.

Flow per measurement iteration:
```
Parent: create <iframe src="worker.html?cmd=measure">
  └→ Iframe loads, JS runs:
       t0 = performance.now()
       localStorage.length    // triggers EnsureLoaded() → GetAll()
       t1 = performance.now()
       parent.postMessage({ duration: t1 - t0 })
Parent: receives message, logs duration, removes iframe
Parent: setTimeout(next iteration, small delay for cleanup)
```

### Value Generation

Pre-generate a string of each size category to avoid measuring string
generation overhead:
- Small: 10 chars of `"a"` repeated
- Medium: 100 chars
- Large: 1000 chars

### Quota Awareness

LocalStorage has a ~10MB per-origin limit. The UI should display the estimated
total data size and warn if it approaches the limit. Approximate formula:
`totalBytes ≈ numEntries * (avgKeyLength + valueSize) * 2` (×2 for UTF-16).

### Error Handling

- Catch `QuotaExceededError` during population and report how many entries
  were actually stored
- Handle iframe load failures gracefully
- Timeout per measurement iteration (e.g., 30s) to avoid hanging

## Future Extensibility

### Multi-Origin Testing

To test how total DB size (across origins) affects single-origin GetAll():
1. Host the site on multiple subdomains (or use `localhost` + different ports)
2. Use cross-origin iframes to populate localStorage for other origins
3. Then measure GetAll() for the test origin
4. This would test the underlying DB's scan performance when it has data from
   many origins

### Additional Metrics

- Could add `performance.measure()` / `PerformanceObserver` integration
- Could measure `setItem` write performance too
- Could test `sessionStorage` (same GetAll() mechanism)
