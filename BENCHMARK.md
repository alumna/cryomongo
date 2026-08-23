# DriverBench

This driver runs a subset of the official MongoDB Driver Performance Benchmark (DriverBench). Scores are megabytes per second (1 MB = 1,000,000 bytes) from the **median** iteration.

BSON tasks always run. Live tasks need a MongoDB 8.0 server and `MONGODB_URI`.

Each run writes a JSON file under [`bench/results/`](bench/results/). This file is the human summary. The JSON files are the history.

**Contents:** [How to run](#how-to-run) · [What is measured](#what-is-measured) · [Latest reference run](#latest-reference-run) · [Versus other drivers](#versus-other-language-drivers) · [Earlier local runs](#earlier-local-runs) · [How results are stored](#how-results-are-stored)

## How to run

From the project root, after `shards install`:

```bash
# BSON only (no server). Default Crystal build, short time bounds.
crystal run bench/driver_bench.cr

# Live tasks. Any topology. Use a URI that matches your server.
export MONGODB_URI='mongodb://localhost:27017'
crystal run bench/driver_bench.cr
```

Replica set:

```bash
export MONGODB_URI='mongodb://localhost:27017/?replicaSet=rs0'
crystal run bench/driver_bench.cr
```

Sharded:

```bash
export MONGODB_URI='mongodb://localhost:27017,localhost:27016'
crystal run bench/driver_bench.cr
```

Load-balanced (`loadBalanced=true` cannot list two hosts):

```bash
export MONGODB_URI='mongodb://127.0.0.1:8000/?loadBalanced=true'
crystal run bench/driver_bench.cr
```

Reference run (spec time bounds, optimized binary, 50 MB GridFS):

```bash
shards build --release driver_bench
BENCH_FULL=1 MONGODB_URI='mongodb://localhost:27017/?replicaSet=rs0' bin/driver_bench
```

`BENCH_SAVE=0` skips the JSON write. `BENCH_RESULTS_DIR` overrides the folder (default `bench/results`).

## Time bounds

| Mode | Env | Per task | Stop |
|---|---|---|---|
| Default (short) | (unset) | at least 2s | 100 iterations or 8s |
| Spec (full) | `BENCH_FULL=1` | 100 samples, or 5 minutes if a sample is slow | 100 iterations or 5 minutes |

Full mode also uses the spec GridFS size (about 50 MB) and 10,000 mixed `bulkWrite` documents (collection and client). Short mode uses 1 MB and 200 mixed documents so a laptop can finish.

Use `--release` for a number you might compare to Java or Go. A default `crystal run` build is much slower.

## What is measured

**BSONBench** (no server): flat, deep, and full document encode and decode. Average of those six scores.

**SingleBench** (needs a server): find one by id, small `insertOne`, large `insertOne`. The spec `hello` command is reported but is not part of SingleBench.

**MultiBench** (needs a server): find many, small/large `insertMany`, collection `bulkWrite` insert, mixed collection `bulkWrite`, client `bulkWrite` insert, mixed client `bulkWrite`, GridFS upload and download.

**ReadBench / WriteBench / DriverBench**: averages as in the spec. Client `bulkWrite` insert and mixed tasks are in MultiBench, WriteBench, and DriverBench when the server is MongoDB 8.0 (wire version 25). Official 500,000-document LDJSON parallel files are not vendored.

An extra **parallel small insertMany** task uses Crystal fibers. It is a local concurrency check. It is **not** in WriteBench or DriverBench.

## How to read the output

Each line is one task:

```text
flat bson encode: median=12.34ms  6100.12 MB/s  (n=20)
```

- `median` is wall time of the middle iteration
- `MB/s` is task bytes / median seconds
- `n` is how many iterations ran

Composite lines are simple averages of the matching tasks.

Compare scores on the same machine, the same MongoDB topology, the same `BENCH_FULL` setting, and the same `--release` flag. Do not treat a laptop number as a cross-language ranking.

A `ns does not exist` log on the first GridFS drop is expected when `perftest.fs.*` is not there yet. It is not a failed task.

## Latest reference run

`--release` + `BENCH_FULL=1` on this development host. Wall time **21.3 minutes**. Decode uses `to_h` (native Hash). GridFS is the spec ~50 MB file. Mixed `bulkWrite` is 10,000 documents. Client `bulkWrite` tasks run.

File: [`bench/results/2026-08-23T203227Z-full-replica-set.json`](bench/results/2026-08-23T203227Z-full-replica-set.json)

| | |
|---|---|
| Date | 2026-08-23 |
| Host | Linux x86_64, AMD Ryzen 7 5700G (16 threads), ~27 GiB RAM |
| Crystal | 1.21.0 `--release` |
| MongoDB | 8.0.29 replica set `rs0` (3 members), same machine as the client (`localhost`) |
| URI | `mongodb://localhost:27017/?replicaSet=rs0` |
| Mode | full (`min_iters=100`, `max_s=300`) |
| Data | in-memory docs of spec sizes (`bench/data/` files were not present) |
| GridFS | 52,428,800 bytes |
| Mixed `bulkWrite` | 10,000 documents |
| WiredTiger cache | 2 GiB per member (`--wiredTigerCacheSizeGB 2`) |

The first attempt on this replica set died: the primary ran out of memory. Default WiredTiger cache is about 50% of RAM **per process**, so three members wanted ~13 GiB each on a 27 GiB host. `scripts/mongo-topology.sh replicaset` now starts each member with a 2 GiB cache. Large write and GridFS scores are therefore lower than the 2026-08-21 full run (that snapshot had no client tasks and used the default cache). **Do not treat WriteBench 129 vs 261 as a driver regression.** Two things changed: WriteBench now averages three extra client tasks (small/large insert plus mixed 1.70 MB/s), and the cache cap slows large payloads. Mixed collection `bulkWrite` was already in the old average (0.18 then, 0.23 now).

To refresh this snapshot, run `--release` + `BENCH_FULL=1` and copy the new JSON tables here.

### BSON (no server)

| Task | Median | MB/s | n |
|---|---|---|---|
| flat bson encode | 47.34 ms | 1590.86 | 100 |
| flat bson decode (`to_h`) | 87.12 ms | 864.44 | 100 |
| deep bson encode | 24.56 ms | 930.03 | 100 |
| deep bson decode (`to_h`) | 243.96 ms | 93.62 | 100 |
| full bson encode | 35.2 ms | 1628.97 | 100 |
| full bson decode (`to_h`) | 77.91 ms | 735.94 | 100 |
| **BSONBench** | | **973.98** | |

Deep decode is the BSON slow path: a tall nested tree allocates many hashes. Encode of that same in-memory tree is cheaper. Official `deep_bson.json` would be a fairer encode rematch.

### Live (needs a server)

| Task | Median | MB/s | n | Notes |
|---|---|---|---|---|
| run command hello | 654.32 ms | 0.20 | 100 | Spec task size is 0.13 MB. Not in SingleBench. |
| find one by id | 990.31 ms | 16.38 | 100 | 10,000 point queries |
| small insertOne | 6646.49 ms | 0.41 | 46 | 10,000 round trips. Hits the 5 minute cap. |
| large insertOne | 118.12 ms | 231.22 | 100 | One ~2.75 MB generated payload per op, localhost |
| find many | 11.15 ms | 1454.42 | 100 | 10,000 generated tweets, WiredTiger cache |
| small insertMany | 87.42 ms | 31.46 | 100 | Batches of 10,000 |
| large insertMany | 100.58 ms | 271.53 | 100 | Batches of 10 |
| small collection bulkWrite | 87.58 ms | 31.40 | 100 | Insert-only |
| large collection bulkWrite | 97.52 ms | 280.07 | 100 | 10 large docs, one round trip, localhost |
| small collection bulkWrite mixed | 23481.18 ms | 0.23 | 13 | 10,000 docs. Hits the 5 minute cap. |
| small client bulkWrite | 88.56 ms | 31.05 | 100 | Insert-only, `Client#bulk_write`, one namespace |
| large client bulkWrite | 96.03 ms | 284.39 | 100 | 10 large docs, `Client#bulk_write` |
| small client bulkWrite mixed | 3238.46 ms | 1.70 | 93 | 10,000 docs, 10 namespaces `corpus_1`…`corpus_10` |
| gridfs upload | 205.31 ms | 255.36 | 100 | Spec ~50 MB file |
| gridfs download | 44.08 ms | 1189.29 | 100 | Spec ~50 MB file, localhost |
| parallel small insertMany | 182.36 ms | 48.26 | 100 | Extra local task. Not in the composites. |

A `ns does not exist` log on the first GridFS drop is expected when `perftest.fs.*` is not there yet. It is not a failed task.

### Client vs collection bulkWrite (same run)

| Task | Collection MB/s | Client MB/s | Notes |
|---|---|---|---|
| small insert bulkWrite | 31.40 | 31.05 | 10,000 small docs, one namespace |
| large insert bulkWrite | 280.07 | 284.39 | 10 large docs, one namespace |
| mixed bulkWrite | 0.23 | 1.70 | 10,000 docs. Client mixed uses 10 namespaces |

Insert-only scores are the same within noise. Mixed client `bulkWrite` is about **7×** mixed collection `bulkWrite`: one `bulkWrite` command on `admin` instead of separate insert / update / delete commands. PyMongo Evergreen 8.0 standalone (PR [1796](https://github.com/mongodb/mongo-python-driver/pull/1796)) showed the same direction for mixed (client 1.35 vs collection 0.65) and the opposite for insert-only (client slower: 8.4 / 21 vs collection insertMany 42 / 105).

### Composites

| Composite | MB/s | How it is built |
|---|---|---|
| BSONBench | 973.98 | Mean of the six BSON tasks |
| SingleBench | 82.67 | Mean of find one, small insertOne, large insertOne |
| MultiBench | 348.26 | Mean of the multi-doc tasks (not parallel), including client bulkWrite |
| ReadBench | 886.7 | Mean of find one, find many, GridFS download |
| WriteBench | 128.98 | Mean of insert, collection bulk, client bulk, mixed, and GridFS upload |
| DriverBench | 507.84 | Mean of ReadBench and WriteBench |

BSONBench does not enter DriverBench (spec rule). SingleBench is pulled up by large `insertOne` 231 and pulled down by small `insertOne` 0.41. ReadBench is pulled up by find many 1454 and GridFS download 1189. WriteBench is pulled down by mixed collection 0.23 and mixed client 1.70. Do not quote DriverBench 508 against Evergreen.

## Versus other language drivers

There is **no public DriverBench on the same machine**. Numbers below come from GitHub PRs and MongoDB Evergreen comments. Hardware, MongoDB version, TLS, and data files differ. Treat this as a **direction** check: which band we sit in, and which tasks are weak.

The spec says DriverBench is for tracking one driver over time and for a rough look across languages. BSONBench does not enter DriverBench.

Peer JSON (every published task we copied, plus notes): [`bench/results/peers.json`](bench/results/peers.json)

**How to read the columns**

- **cryomongo short** — debug build, 2026-08-21, replica set, same host as `mongod`, generated docs, 1 MB GridFS. Decode is copy + header, not `to_h`.
- **cryomongo full** — `--release`, 2026-08-23, replica set `rs0`, spec time bounds, 50 MB GridFS, decode with `to_h`, client `bulkWrite` included. WiredTiger cache is 2 GiB per member. Still localhost and generated docs.
- **Node main** — official Node driver, `js-bson`, PR [3419](https://github.com/mongodb/node-mongodb-native/pull/3419) *main* sample (GitHub Actions, 2022).
- **Node PR** — same PR, *migrate-deque* sample (not merged). Shows noise plus a small internal change.
- **Java ASCII** — official Java driver on Evergreen after 2025 string-write opts, PR [1651](https://github.com/mongodb/mongo-java-driver/pull/1651). Only the tasks they published.
- **Java UTF-8** — same PR, 3-byte UTF-8 suite (harder encode path).
- **Python sync** — PyMongo Evergreen 8.0, no TLS, sync column of PR [2188](https://github.com/mongodb/mongo-python-driver/pull/2188).
- **Python async** — same table, async column.
- **Go** — no live DriverBench table in public PRs. BSON micro-benchmarks only (see the Go table).

### BSON (MB/s)

| Task | short | full | Node main | Node PR | Java ASCII | Java UTF-8 | Go v2 to map |
|---|---|---|---|---|---|---|---|
| flat encode | 453 | 1591 | 94 | 116 | 238 | 193 | — |
| flat decode | 154* | 864 | 83 | 106 | — | — | 312 |
| deep encode | 925 | 930 | 25 | 31 | 57 | 124 | — |
| deep decode | 38* | 94 | 25 | 31 | — | — | 189 |
| full encode | 471 | 1629 | 50 | 59 | 177 | 152 | — |
| full decode | 231* | 736 | 56 | 76 | — | — | 222 |
| BSONBench | 379* | 974 | 55 | 70 | — | — | — |

\* Short decode is copy + header, not `to_h`. Compare decode to other languages using the **full** column.

Go rows are `json.gz` decode-to-map from PR [2022](https://github.com/mongodb/mongo-go-driver/pull/2022) (contributor machine, not Evergreen). Decode-to-`D` is faster (flat 526, deep 195, full 273). Struct decode is much faster still (simple 617, nested 1844) and is not comparable to Crystal hashes.

Go marshal of a different “code” corpus (PR [1323](https://github.com/mongodb/mongo-go-driver/pull/1323), darwin arm64) reached about **840 Mi/s** unmarshal and **2444 Mi/s** marshal. Those units are mebibytes. Rough SI: 881 / 2562 MB/s. Ceiling for compiled BSON, not a DriverBench row.

Java ASCII **before** the 2025 opts: flat encode 105, deep 47, full 111.

### Single-doc live (MB/s)

| Task | short | full | Node main | Node PR | Java ASCII | Java UTF-8 | Python sync | Python async |
|---|---|---|---|---|---|---|---|---|
| hello | 0.12 | 0.20 | 0.040 | 0.066 | — | — | 0.065 | 0.028 |
| find one | 12 | 16 | 2.54 | 4.00 | — | — | 4.45 | 1.21 |
| small insertOne | 0.34 | 0.41 | 0.53 | 0.82 | — | — | 0.87 | 0.49 |
| large insertOne | 66 | 231 | 14 | 19 | 67 | 53 | 99 | 153 |
| SingleBench | 26 | 83 | 5.6 | 7.8 | — | — | — | — |

Java ASCII **before** opts: large insertOne 51.

### Multi-doc and GridFS (MB/s)

| Task | short | full | Node main | Node PR | Java ASCII | Java UTF-8 | Python sync | Python async |
|---|---|---|---|---|---|---|---|---|
| find many | 1229 | 1454 | 34 | 45 | — | — | 67 | 70 |
| small insertMany | 23 | 31 | 13 | 16 | 28 | 54 | 37 | 36 |
| large insertMany | 69 | 272 | 17 | 22 | 62 | 46 | 98 | 97 |
| small collection bulkWrite | 33 | 31 | — | — | — | — | — | — |
| large collection bulkWrite | 522 | 280 | — | — | — | — | — | — |
| mixed collection bulkWrite | 0.19 | 0.23 | — | — | — | — | 0.64 | 0.32 |
| small client bulkWrite | — | 31 | — | — | — | — | 8.4† | — |
| large client bulkWrite | — | 284 | — | — | — | — | 21† | — |
| mixed client bulkWrite | — | 1.70 | — | — | — | — | 1.35† | — |
| GridFS upload | 248 (1 MB) | 255 (50 MB) | 255 (~50 MB) | 400 (~50 MB) | — | — | 443 (~50 MB) | 502 |
| GridFS download | 1138 (1 MB) | 1189 (50 MB) | 481 (~50 MB) | 703 (~50 MB) | — | — | 636 (~50 MB) | 795 |

Java ASCII **before** opts: large bulk insert 47, small bulk insert 25.

† PyMongo Evergreen 8.0 standalone (PR [1796](https://github.com/mongodb/mongo-python-driver/pull/1796), 2024), not cryomongo. Same PR: large insertMany **105**, small insertMany **42**, mixed collection **0.65**. Collection bulk was much faster than `client.bulk_write` for insert-only in that snapshot. cryomongo insert-only collection and client scores are a tie on this host.

### Composites (MB/s)

| Composite | short | full | Node main | Node PR |
|---|---|---|---|---|
| BSONBench | 379* | 974 | 55 | 70 |
| SingleBench | 26 | 83 | 5.6 | 7.8 |
| MultiBench | 408 | 348 | 160 | 237 |
| ReadBench | 793 | 887 | 172 | 251 |
| WriteBench | 120 | 129 | 60 | 92 |
| DriverBench | 457 | 508 | 116 | 171 |

Java and Python PRs did not publish a full composite table. Do not quote cryomongo DriverBench **508** against Evergreen: find many 1454 and GridFS download 1189 (localhost, generated tweets, cache) inflate ReadBench. The 2026-08-21 full WriteBench 261 is not comparable: it had no client tasks and a larger WiredTiger cache.

A 2021 insert-then-fetch bake-off ([Clarity AI](https://medium.com/clarityai-engineering/mongodb-driver-performance-in-several-languages-888899494b88), not DriverBench) put C++ and Java first, then Go, then .NET, with Node and Python slower on concurrent inserts. That grouping still matches these tables: native drivers in one band, Node/Python in another.

**cryomongo belongs in the native band for large documents and batches** on this host. It is not ahead of Java overall.

### Where this driver is in good shape

Use the **full** column unless a note says otherwise.

- **Flat and full BSON.** Encode ~1591 / 1629 MB/s vs Java ASCII 238 and Node 94–116. Decode `to_h` 864 / 736 vs Go map 312 / 222 and Node 83 / 56. Generated documents help encode; decode is a real Hash walk and still sits in the compiled-language band.
- **Small batches.** Full small `insertMany` 31, small collection `bulkWrite` 31, and small client `bulkWrite` 31 sit next to Python sync insertMany (~37) and beat Java ASCII (~28) and Node (~13–16).
- **Client vs collection insert.** On this host they match (small 31 vs 31, large 284 vs 280). Mixed client 1.70 vs mixed collection 0.23 is the gap that matters.
- **GridFS upload (spec ~50 MB).** 255 MB/s sits next to Node 255–400 and Python sync 443 on a different host. This is the most honest large-file write we have.
- **Command and find-one vs Node/Python.** Hello 0.20 vs Node 0.04–0.07 and Python sync 0.065. Find one 16 vs Node 2.5–4 and Python sync 4.5. Same spec byte sizes; localhost still helps.

### Where this driver needs work

- **Small `insertOne` (the live-path hole).** Full 0.41 MB/s vs Node 0.53–0.82 and Python sync 0.87. About 1,500 inserts/s. `--release` did not fix it (46 samples still hit the 5 minute cap). Likely costs: a new BSON per insert, implicit sessions, replica-set write concern, Crystal IO. This task is the one SingleBench number that is not inflated by a fat payload.
- **Deep BSON decode.** Full `to_h` 94 MB/s vs Go decode-to-map ~189. Nested hashes allocate. Official `deep_bson.json` is the fair rematch.
- **Mixed collection `bulkWrite`.** Full 0.23 MB/s vs Python sync 0.64 (10,000 docs, 5 minute cap, n=13). Replace/delete plus insert is much slower than insert-only bulk. Mixed client `bulkWrite` (1.70 MB/s, n=93) is the better mixed path on MongoDB 8.0.
- **Do not quote these localhost-inflated tasks against Evergreen:** find many 1454 vs Node 34–45 / Python 67; GridFS download 1189 vs Python 636 / Node 481–703; large `insertOne` 231 vs Java 67 / Python 99; large `insertMany` 272 vs Java 62 / Python 98. Generated payloads plus same-machine `mongod` are the main reason.
- **Missing spec tasks** keep the composite incomparable: no official 500,000-document LDJSON parallel files.

**Safer next snapshot:** official files in `bench/data/`, and `mongod` on another host. Keep `--release` + `BENCH_FULL=1`. Keep the 2 GiB WiredTiger cache on this 3-member host (or the primary can run out of memory again).

### Sources

- MongoDB DriverBench spec: [source/benchmarking/benchmarking.md](https://github.com/mongodb/specifications/blob/master/source/benchmarking/benchmarking.md)
- Node.js full micro-benchmark dump (both samples): [mongodb/node-mongodb-native PR 3419](https://github.com/mongodb/node-mongodb-native/pull/3419)
- Java Evergreen ASCII and UTF-8 encode / insert tables: [mongodb/mongo-java-driver PR 1651](https://github.com/mongodb/mongo-java-driver/pull/1651)
- PyMongo sync vs async 8.0 (MB/s columns): [mongodb/mongo-python-driver PR 2188](https://github.com/mongodb/mongo-python-driver/pull/2188)
- PyMongo collection vs client bulkWrite 8.0 standalone: [mongodb/mongo-python-driver PR 1796](https://github.com/mongodb/mongo-python-driver/pull/1796)
- Go BSON unmarshal micro-benchmarks: [mongo-go-driver PR 2022](https://github.com/mongodb/mongo-go-driver/pull/2022)
- Go BSON marshal allocs (Mi/s, different corpus): [mongo-go-driver PR 1323](https://github.com/mongodb/mongo-go-driver/pull/1323)
- 2021 insert/fetch grouping (not DriverBench): [Clarity AI, Medium](https://medium.com/clarityai-engineering/mongodb-driver-performance-in-several-languages-888899494b88)
- Local runs and the copied peer tables: [`bench/results/`](bench/results/)

## Earlier local runs

These are not the public snapshot. They stay here so old numbers are not lost.

### 2026-08-21 full replica set (no client tasks)

`--release` + `BENCH_FULL=1`. Wall time 15.2 minutes. Decode uses `to_h`. GridFS ~50 MB. Mixed collection `bulkWrite` 10,000 documents. **No client `bulkWrite` tasks.** WiredTiger cache was the default (~13 GiB on one process; this run did not use the 2 GiB cap).

File: [`bench/results/2026-08-21T100223Z-full-replica-set.json`](bench/results/2026-08-21T100223Z-full-replica-set.json)

| | |
|---|---|
| Date | 2026-08-21 |
| Host | Linux x86_64, AMD Ryzen 7 5700G (16 threads), ~27 GiB RAM |
| Crystal | 1.21.0 `--release` |
| MongoDB | 8.0.29 replica set `rs0`, same machine as the client (`localhost`) |
| URI | `mongodb://localhost:27017/?replicaSet=rs0` |
| Mode | full (`min_iters=100`, `max_s=300`) |
| Data | in-memory docs of spec sizes (`bench/data/` files were not present) |
| GridFS | 52,428,800 bytes |
| Mixed `bulkWrite` | 10,000 documents |

#### BSON

| Task | Median | MB/s | n |
|---|---|---|---|
| flat bson encode | 53.45 ms | 1408.98 | 100 |
| flat bson decode (`to_h`) | 100.28 ms | 750.98 | 100 |
| deep bson encode | 29.83 ms | 765.74 | 100 |
| deep bson decode (`to_h`) | 275.6 ms | 82.88 | 100 |
| full bson encode | 40.64 ms | 1410.77 | 100 |
| full bson decode (`to_h`) | 89.7 ms | 639.24 | 100 |
| **BSONBench** | | **843.1** | |

#### Live

| Task | Median | MB/s | n | Notes |
|---|---|---|---|---|
| run command hello | 639.59 ms | 0.20 | 100 | Spec task size is 0.13 MB. Not in SingleBench. |
| find one by id | 949.09 ms | 17.09 | 100 | 10,000 point queries |
| small insertOne | 8686.46 ms | 0.32 | 35 | 10,000 round trips. Hits the 5 minute cap. |
| large insertOne | 73.37 ms | 372.23 | 100 | One ~2.75 MB generated payload per op, localhost |
| find many | 11.12 ms | 1458.3 | 100 | 10,000 generated tweets, WiredTiger cache |
| small insertMany | 72.11 ms | 38.14 | 100 | Batches of 10,000 |
| large insertMany | 43.1 ms | 633.6 | 100 | Batches of 10 |
| small collection bulkWrite | 71.56 ms | 38.43 | 100 | Insert-only |
| large collection bulkWrite | 43.64 ms | 625.81 | 100 | 10 large docs, one round trip, localhost |
| small collection bulkWrite mixed | 30220.94 ms | 0.18 | 10 | 10,000 docs. Hits the 5 minute cap. |
| gridfs upload | 137.19 ms | 382.15 | 100 | Spec ~50 MB file |
| gridfs download | 41.62 ms | 1259.79 | 100 | Spec ~50 MB file, localhost |
| parallel small insertMany | 155.39 ms | 56.63 | 100 | Extra local task. Not in the composites. |

#### Composites

| Composite | MB/s | How it is built |
|---|---|---|
| BSONBench | 843.1 | Mean of the six BSON tasks |
| SingleBench | 129.88 | Mean of find one, small insertOne, large insertOne |
| MultiBench | 554.55 | Mean of the multi-doc tasks (not parallel) |
| ReadBench | 911.73 | Mean of find one, find many, GridFS download |
| WriteBench | 261.36 | Mean of the insert, collection bulk, and GridFS upload tasks (no client bulkWrite) |
| DriverBench | 586.54 | Mean of ReadBench and WriteBench |

BSONBench does not enter DriverBench. SingleBench is pulled up by large `insertOne` 372. ReadBench is pulled up by find many 1458 and GridFS download 1260. Do not quote DriverBench 587 against Evergreen. Do not compare WriteBench 261 to the 2026-08-23 WriteBench 129 without the notes in [Latest reference run](#latest-reference-run).

### 2026-08-23 short `--release` (standalone)

Same host. Standalone MongoDB 8.0.29 (not a replica set). Short bounds (2s / 8s). Mixed tasks use 200 documents. GridFS is 1 MB. `--release`. First run that included client `bulkWrite` tasks. Wall time **1.7 minutes**.

File: [`bench/results/2026-08-23T200927Z-short-standalone.json`](bench/results/2026-08-23T200927Z-short-standalone.json)

| | |
|---|---|
| Date | 2026-08-23 |
| Crystal | 1.21.0 `--release` |
| MongoDB | 8.0.29 standalone, localhost |
| URI | `mongodb://localhost:27017` |
| Mode | short (`task_s=2`, `max_s=8`) |
| GridFS | 1,048,576 bytes |
| Mixed `bulkWrite` | 200 documents |

Do not compare these composites to a full replica-set snapshot: topology, GridFS size, mixed document count, and time bounds all differ.

| Task | Collection MB/s | Client MB/s | Notes |
|---|---|---|---|
| small insert bulkWrite | 29.19 | 27.14 | 10,000 small docs, one namespace |
| large insert bulkWrite | 279.48 | 291.81 | 10 large docs, one namespace |
| mixed bulkWrite | 0.18 | 1.73 | 200 docs. Client mixed uses 10 namespaces |

| Composite | MB/s |
|---|---|
| BSONBench | 768.38 |
| SingleBench | 80.75 |
| MultiBench | 184.64 |
| ReadBench | 318.65 |
| WriteBench | 119.76 |
| DriverBench | 219.2 |

WriteBench and MultiBench include the three client tasks. Parallel insertMany (38.81 MB/s) is not in those averages.

### 2026-08-21 short debug (replica set)

Not a reference for other languages. Default Crystal build, short time bounds, 1 MB GridFS, 200 mixed documents, generated data, client and `mongod` on the same machine. No client `bulkWrite` tasks. BSON **decode** is `BSON.new(bytes)` only (copy + header), not `to_h`.

File: [`bench/results/2026-08-21T093500Z-short-replica-set.json`](bench/results/2026-08-21T093500Z-short-replica-set.json)

| | |
|---|---|
| Host | Linux x86_64, AMD Ryzen 7 5700G (16 threads), ~27 GiB RAM |
| Crystal | 1.21.0, **not** `--release` |
| MongoDB | 8.0.29 replica set `rs0`, localhost |
| Mode | short (`task_s=2`, `max_s=8`) |

| Composite | MB/s |
|---|---|
| BSONBench | 378.9 |
| SingleBench | 26.02 |
| MultiBench | 407.92 |
| ReadBench | 793.08 |
| WriteBench | 120.28 |
| DriverBench | 456.68 |

WriteBench excludes the extra parallel task. An older stdout line of 109.79 MB/s included it.

Tiny MB/s on hello and small `insertOne` is normal (many round trips, small spec byte size). Very high MB/s on find many and 1 MB GridFS download is localhost plus cache. Those two pull ReadBench and DriverBench up.

Do not compare those decode scores to Java or Go. Later `--release` runs decode with `to_h`.

## How results are stored

### Options we considered

| Option | Why we did not use it (or did) |
|---|---|
| Keep appending tables to this markdown file | The file would grow. A program cannot load a run. |
| CSV only | Easy to plot, but host / URI / dataset notes do not fit a row. |
| SQLite | Git cannot diff it well. Extra tooling. |
| One folder per date | Extra nesting. UTC file names already sort. |
| **One JSON file per run + `index.json`** | **Chosen.** Machines load one object. This file stays a snapshot plus how to read the history. |

### Layout

```text
bench/results/
  README.md                                      schema and how to add a run
  index.json                                     list of runs (composites only)
  peers.json                                     published numbers from other drivers
  2026-08-21T093500Z-short-replica-set.json      first local short run (debug build)
  2026-08-21T100223Z-full-replica-set.json       full --release, no client bulkWrite
  2026-08-23T200927Z-short-standalone.json       short --release with client bulkWrite
  2026-08-23T203227Z-full-replica-set.json       full --release with client bulkWrite
```

File name: `<utc>-<mode>-<topology>.json`. Credentials in the URI are replaced with `***`.

To add a run, execute the runner (it writes JSON and updates `index.json`). If that run should be the public snapshot, copy its tables into the **Latest reference run** section above.

## Spec sanity test

```bash
crystal spec spec/benchmark_spec.cr spec/bench_report_spec.cr
```

`benchmark_spec.cr` only checks that BSON encode/decode works. `bench_report_spec.cr` checks URI redaction, topology names, that composites omit the extra parallel task, and that client bulkWrite tasks enter WriteBench and MultiBench. Neither is a performance gate.
