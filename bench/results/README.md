# DriverBench result files

Each run of `bench/driver_bench.cr` writes one JSON file here, unless `BENCH_SAVE=0`.

`index.json` lists every run. `peers.json` holds published numbers from other language drivers. Those peer files are not produced by this runner.

## Why this layout

| Option | Verdict |
|---|---|
| Append tables to `BENCHMARK.md` | Rejected. The file would grow and a program cannot load it cleanly. |
| CSV only | Rejected as the only format. Nested host/URI/dataset metadata does not fit a row. |
| SQLite or a database | Rejected. Git cannot diff it well. |
| One folder per date | Extra nesting with no gain. UTC names already sort. |
| **One JSON file per run + `index.json`** | **Chosen.** Machines can load a run. Humans can read `BENCHMARK.md` for the latest full snapshot. |

## File name

```text
<utc>-<mode>-<topology>.json
```

Example: `2026-08-21T120000Z-full-replica-set.json`

- `mode` is `short` (default) or `full` (`BENCH_FULL=1`)
- `topology` comes from the URI (`replica-set`, `standalone`, `load-balanced`, `multi-host`, or `bson-only`)

## How to add a run

From the project root:

```bash
# Laptop / default Crystal build
MONGODB_URI='mongodb://localhost:27017/?replicaSet=rs0' crystal run bench/driver_bench.cr

# Reference run (spec time bounds, --release)
shards build --release driver_bench
BENCH_FULL=1 MONGODB_URI='mongodb://localhost:27017/?replicaSet=rs0' bin/driver_bench
```

Then point `BENCHMARK.md` at the new `full` file if that run should be the public snapshot.

`BENCH_RESULTS_DIR` can override this folder. `BENCH_SAVE=0` skips the write (useful for a throwaway local check).

BSON decode in the runner is `BSON.new(bytes).to_h`. A default `crystal run` build is not a reference; use `--release` for numbers you might compare to other drivers.
