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

Example: `2026-08-23T203227Z-full-replica-set.json`

- `mode` is `short` (default) or `full` (`BENCH_FULL=1`)
- `topology` comes from the URI (`replica-set`, `standalone`, `load-balanced`, `multi-host`, or `bson-only`)

## How to add a run

From the project root:

Live runs must set `w=1`. The runner does not add a write concern. Files through `2026-10-07` have no `w`; do not compare their write composites to a `w=1` run. See `BENCHMARK.md`.

```bash
# Laptop / default Crystal build
MONGODB_URI='mongodb://localhost:27017/?replicaSet=rs0&w=1' crystal run bench/driver_bench.cr

# Reference run (spec time bounds, --release, w:1)
shards build --release driver_bench
BENCH_FULL=1 MONGODB_URI='mongodb://localhost:27017/?replicaSet=rs0&w=1' bin/driver_bench
```

Then point `BENCHMARK.md` **Latest numbers** at the new `full` file if that run should be the public snapshot. Say that the live tasks used `w=1`. Live DriverBench and BSON-only rematch stay separate; do not fold them into one table.

Current files:

```text
bench/results/
  README.md                                      schema and how to add a run
  index.json                                     list of runs (composites only)
  peers.json                                     published numbers from other drivers
  2026-08-21T093500Z-short-replica-set.json      first local short run (debug build)
  2026-08-21T100223Z-full-replica-set.json       full --release, no client bulkWrite
  2026-08-23T200927Z-short-standalone.json       short --release with client bulkWrite
  2026-08-23T203227Z-full-replica-set.json       full --release with client bulkWrite (bson 0.8.1)
  2026-09-01T223259Z-full-replica-set.json       full --release, bson 0.9.0, 3-member rs0
  2026-09-02T112234Z-full-bson-only.json         full --release, bson 0.9.2, BSON only
  2026-10-07T173751Z-full-replica-set.json       full --release, bson 0.9.3 workbench, 1-member rs0, no w
  2026-10-07T183707Z-full-replica-set.json       full --release, bson 0.9.3 workbench, 1-member rs0, w:1 (current snapshot)
```

Client `bulkWrite` tasks (`small client bulkWrite`, `large client bulkWrite`, `small client bulkWrite mixed`) run on MongoDB 8.0 and enter MultiBench, WriteBench, and DriverBench. Older JSON files in this folder do not have those rows; composites from those files omit the missing names.

`BENCH_RESULTS_DIR` can override this folder. `BENCH_SAVE=0` skips the write (useful for a throwaway local check).

BSON decode in the runner is `BSON.new(bytes).to_h`. Walk / one-field tasks have `"group": "extra"` and are not in BSONBench. A default `crystal run` build is not a reference; use `--release` for numbers you might compare to other drivers.
