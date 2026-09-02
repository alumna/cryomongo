# DriverBench

This driver runs a subset of the official [MongoDB Driver Performance Benchmark](https://github.com/mongodb/specifications/blob/master/source/benchmarking/benchmarking.md) (DriverBench).

The number on each task is **megabytes per second** (1 MB = 1,000,000 bytes) from the **median** iteration. BSON tasks always run. Live tasks need a MongoDB 8.0 server and `MONGODB_URI`.

This file is the human summary: how to run, what the scores mean, and the tables we quote. Each run also writes JSON under [`bench/results/`](bench/results/). Those files are the history.

## Contents

1. [What this measures](#what-this-measures)
2. [How scores work](#how-scores-work)
3. [BSON, Hash, and the live path](#bson-hash-and-the-live-path)
4. [Prerequisites](#prerequisites)
5. [Run your own](#run-your-own)
6. [How to read the output](#how-to-read-the-output)
7. [What each composite includes](#what-each-composite-includes)
8. [Latest numbers](#latest-numbers)
   - [Live replica set (bson 0.9.0)](#live-replica-set-bson-090)
   - [BSON rematch (bson 0.9.2)](#bson-rematch-bsoncr-092)
9. [Versus other language drivers](#versus-other-language-drivers)
10. [Earlier local runs](#earlier-local-runs)
11. [How results are stored](#how-results-are-stored)

---

## What this measures

DriverBench is meant for **one driver over time**, and for a rough look across languages. It is not a ranking of laptops.

Two kinds of work:

- **BSON** — encode and decode documents in memory. No server.
- **Live** — find, insert, `bulkWrite`, GridFS. Needs MongoDB 8.0.

Composites are simple averages of matching tasks. **BSONBench does not enter DriverBench** (spec rule).

Client `bulkWrite` tasks need MongoDB 8.0 (wire version 25). They are skipped on older servers. Official 500,000-document LDJSON parallel files are not vendored, so those spec tasks are missing.

---

## How scores work

Each printed line looks like this:

```text
flat bson encode: median=12.34ms  6100.12 MB/s  (n=20)
```

- **median** — wall time of the middle iteration
- **MB/s** — task bytes / median seconds
- **n** — how many iterations ran

Tiny MB/s on hello and small `insertOne` is normal: many round trips, small spec byte size. Very high MB/s on find many and GridFS download is usual on localhost with a warm cache.

Compare scores only when **all** of these match:

- same machine
- same MongoDB topology
- same `BENCH_FULL` setting
- same `--release` flag (or both debug)

A default `crystal run` build is much slower than `--release`. Do not treat a laptop number as a cross-language ranking.

---

## BSON, Hash, and the live path

Three layers. They are easy to mix up.

- **`BSON`** is the wire document (bytes). Field order is the order on the wire. Nested values from `each` are views into the parent buffer. Copy before that buffer is gone.
- **`to_h`** is a Crystal Hash (Go **`M`**). We have no Go **`D`** (slice of pairs). Crystal Hash is insertion-ordered.
- **Live driver path** is `BSON` / views / `Builder`. Commands use `Builder`. Find and insert pass `BSON`. The Alumna adapter walks `each` into AnyData. It does not call `to_h`.

Official DriverBench **decode is `to_h`**. That is the comparable row (Go map, our history). Do not replace it with `each`, `[]`, or `BSON::Serializable`.

The runner also times **walk** (`BSON#each`, recurse nested views) and **one field** (`bson["left"]` on deep, `bson["_id"]` on flat/full). Those numbers sit beside the table. They are **not** DriverBench and they are **not** in BSONBench. Walk is closer to how the driver reads a document. `to_h` is “turn the whole tree into Hash”.

Deep encode vs deep `to_h` is **uneven work**. `deep_source` children are already `BSON.new`, so timed encode copies two ready buffers. Timed decode builds about 127 Hash objects and copies keys and strings. Official `deep_bson.json` would be a fairer encode rematch.

---

## Prerequisites

From the **cryomongo project root**, after a normal clone:

| Need | For |
|---|---|
| Crystal `>= 1.20.0` (we use 1.21.0) | Every run |
| `shards install` | Every run |
| MongoDB **8.0** on a URI you control | Live tasks only |
| Quiet machine, `--release` | A number you might quote |

BSON-only needs no server. Unset `MONGODB_URI` if you only want BSON (`env -u MONGODB_URI`).

For live tasks, any topology the driver already supports is fine. Match the URI to the server:

| Topology | Typical URI |
|---|---|
| Standalone | `mongodb://localhost:27017` |
| Replica set | `mongodb://localhost:27017/?replicaSet=rs0` |
| Sharded | `mongodb://localhost:27017,localhost:27016` |
| Load-balanced | `mongodb://127.0.0.1:8000/?loadBalanced=true` (`loadBalanced=true` cannot list two hosts) |

Local topologies (native or Docker):

```bash
sudo scripts/mongo-topology.sh replicaset    # native; 2 GiB WiredTiger cache per member
sudo scripts/docker-topology.sh replicaset  # Docker; see cache note below
scripts/mongo-topology.sh status
scripts/mongo-topology.sh stop
```

Default WiredTiger cache is about 50% of RAM **per process**. Three replica-set members on a ~27 GiB host would want ~13 GiB each and can run out of memory. `scripts/mongo-topology.sh replicaset` starts each member with `--wiredTigerCacheSizeGB 2`. Keep that cap on this host.

Newer Linux kernels (including 7.1.x-zabbly+): mongod 8.0 can abort in TCMalloc/rseq. The native topology script sets `GLIBC_TUNABLES=glibc.pthread.rseq=1`. Docker on that kernel needs the same on the container. GitHub `ubuntu-latest` does not need it.

Optional official files in `bench/data/` (`tweet.json`, `small_doc.json`, `large_doc.json`, `gridfs_large.bin`, `flat_bson.json`, `deep_bson.json`, `full_bson.json`): our snapshots used generated in-memory docs of spec sizes because those files were not present. A safer next snapshot would vendor them and put `mongod` on another host.

---

## Run your own

### 1. Install

```bash
shards install
```

### 2. BSON only (no server)

Default Crystal build, short time bounds. Good to see that the runner works. Not a number to quote.

```bash
crystal run bench/driver_bench.cr
```

### 3. Live tasks

Point at a reachable MongoDB 8.0. BSON still runs first. If the URI is missing or the server is down, live tasks are skipped.

```bash
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

Load-balanced:

```bash
export MONGODB_URI='mongodb://127.0.0.1:8000/?loadBalanced=true'
crystal run bench/driver_bench.cr
```

### 4. A number you can compare

Spec time bounds, optimized binary, ~50 MB GridFS, 10,000 mixed `bulkWrite` documents. This is the shape of our public snapshots. A full replica-set run is about **21 minutes** on this host. Mixed collection `bulkWrite` can hit the 5 minute cap.

```bash
shards build --release driver_bench
BENCH_FULL=1 MONGODB_URI='mongodb://localhost:27017/?replicaSet=rs0' bin/driver_bench
```

BSON-only reference (no live tasks):

```bash
shards build --release driver_bench
env -u MONGODB_URI BENCH_FULL=1 bin/driver_bench
```

### 5. Time bounds and env

| Mode | Env | Per task | Stop |
|---|---|---|---|
| Default (short) | (unset) | at least 2s | 100 iterations or 8s |
| Spec (full) | `BENCH_FULL=1` | 100 samples, or 5 minutes if a sample is slow | 100 iterations or 5 minutes |

Full mode also uses the spec GridFS size (about 50 MB) and 10,000 mixed `bulkWrite` documents (collection and client). Short mode uses 1 MB and 200 mixed documents so a laptop can finish.

| Env | Effect |
|---|---|
| `MONGODB_URI` | Enable live tasks. Unset for BSON-only. |
| `BENCH_FULL=1` | Spec time bounds, 50 MB GridFS, 10,000 mixed docs |
| `BENCH_SAVE=0` | Skip the JSON write (throwaway check). Do not use this if you want a history file. |
| `BENCH_RESULTS_DIR` | Override the results folder (default `bench/results`) |

### 6. After a run

The runner writes `bench/results/<utc>-<mode>-<topology>.json` and updates `index.json`. Credentials in the URI become `***`.

If that run should be the public snapshot, copy its tables into [Latest numbers](#latest-numbers) below. Keep the old JSON files.

### 7. Spec sanity (not a performance gate)

```bash
crystal spec spec/benchmark_spec.cr spec/bench_report_spec.cr
```

`benchmark_spec.cr` only checks that BSON encode/decode works. `bench_report_spec.cr` checks URI redaction, topology names, that composites omit extra tasks (parallel insertMany, walk / one-field), and that client `bulkWrite` tasks enter WriteBench and MultiBench.

---

## How to read the output

BSON prints first, then walk / one-field beside `to_h`, then live tasks if a server answered, then composites.

A `ns does not exist` log on the first GridFS drop is expected when `perftest.fs.*` is not there yet. It is not a failed task.

Composite lines are simple averages of the matching tasks. Walk / one-field and the extra parallel `insertMany` do not enter those averages.

---

## What each composite includes

**BSONBench** (no server): flat, deep, and full document encode and decode. Average of those **six** official scores. Walk / one-field tasks also run on the same byte buffers. They are **not** in BSONBench.

**SingleBench** (needs a server): find one by id, small `insertOne`, large `insertOne`. The spec `hello` command is reported but is not part of SingleBench.

**MultiBench** (needs a server): find many, small/large `insertMany`, collection `bulkWrite` insert, mixed collection `bulkWrite`, client `bulkWrite` insert, mixed client `bulkWrite`, GridFS upload and download.

**ReadBench / WriteBench / DriverBench**: averages as in the spec. Client `bulkWrite` insert and mixed tasks are in MultiBench, WriteBench, and DriverBench when the server is MongoDB 8.0.

An extra **parallel small insertMany** task uses Crystal fibers. It is a local concurrency check. It is **not** in WriteBench or DriverBench.

---

## Latest numbers

Two current snapshots. Do not fold them into one fake “latest DriverBench”.

| Quote this | File | bson.cr | Server |
|---|---|---|---|
| Live DriverBench / Read / Write | [`2026-09-01T223259Z-full-replica-set.json`](bench/results/2026-09-01T223259Z-full-replica-set.json) | 0.9.0 | replica set `rs0` |
| BSONBench / `to_h` / walk | [`2026-09-02T112234Z-full-bson-only.json`](bench/results/2026-09-02T112234Z-full-bson-only.json) | **0.9.2** | none |

Both are `--release` + `BENCH_FULL=1` on the same development host.

### Live replica set (bson 0.9.0)

Wall time **20.9 minutes**. Decode uses `to_h` (native Hash). GridFS is the spec ~50 MB file. Mixed `bulkWrite` is 10,000 documents. Client `bulkWrite` tasks run. bson.cr **0.9.0** (`Builder#document` / `#array`).

File: [`bench/results/2026-09-01T223259Z-full-replica-set.json`](bench/results/2026-09-01T223259Z-full-replica-set.json)

| | |
|---|---|
| Date | 2026-09-01 |
| Host | Linux x86_64, AMD Ryzen 7 5700G (16 threads), ~27 GiB RAM |
| Crystal | 1.21.0 `--release` |
| MongoDB | 8.0.29 replica set `rs0` (3 members), same machine as the client (`localhost`) |
| URI | `mongodb://localhost:27017/?replicaSet=rs0` |
| Mode | full (`min_iters=100`, `max_s=300`) |
| Data | in-memory docs of spec sizes (`bench/data/` files were not present) |
| GridFS | 52,428,800 bytes |
| Mixed `bulkWrite` | 10,000 documents |
| WiredTiger cache | 2 GiB per member (`--wiredTigerCacheSizeGB 2`) |
| bson.cr | 0.9.0 |

**Verdict vs 2026-08-23** (`2026-08-23T203227Z-full-replica-set.json`, same host, same `rs0` + 2 GiB cache): BSONBench **improved** (974 → 1018). Deep encode (nested Hash, the 0.9.0 signal) 930 → 1000 MB/s. Other BSON encode/decode tasks moved a few percent the same way. Live writes are **flat** (small insertOne 0.41 → 0.42; WriteBench 129 → 131). Find many and GridFS download were **noisier** this run (1454 → 1177, 1189 → 1021), so ReadBench and DriverBench dropped. That is localhost cache noise, not a bson 0.9.0 signal. **Do not treat DriverBench 435 vs 508 as a driver regression.** Do not compare WriteBench to 2026-08-21 (different cache and client tasks).

The BSON rows below are bson **0.9.0**. The published **0.9.2** rematch is in the next section.

#### BSON (no server)

| Task | Median | MB/s | n |
|---|---|---|---|
| flat bson encode | 46.29 ms | 1627.06 | 100 |
| flat bson decode (`to_h`) | 83.24 ms | 904.73 | 100 |
| deep bson encode | 22.85 ms | 999.52 | 100 |
| deep bson decode (`to_h`) | 227.7 ms | 100.31 | 100 |
| full bson encode | 33.67 ms | 1702.81 | 100 |
| full bson decode (`to_h`) | 74.24 ms | 772.32 | 100 |
| **BSONBench** | | **1017.79** | |

Deep decode is the BSON slow path: a tall nested tree allocates many hashes. Encode of that same in-memory tree is cheaper (and is the nested-Hash 0.9.0 path). Official `deep_bson.json` would be a fairer encode rematch.

#### Live (needs a server)

| Task | Median | MB/s | n | Notes |
|---|---|---|---|---|
| run command hello | 597.54 ms | 0.22 | 100 | Spec task size is 0.13 MB. Not in SingleBench. |
| find one by id | 948.21 ms | 17.11 | 100 | 10,000 point queries |
| small insertOne | 6486.66 ms | 0.42 | 47 | 10,000 round trips. Hits the 5 minute cap. |
| large insertOne | 114.52 ms | 238.49 | 100 | One ~2.75 MB generated payload per op, localhost |
| find many | 13.78 ms | 1177.15 | 100 | 10,000 generated tweets, WiredTiger cache |
| small insertMany | 86.18 ms | 31.91 | 100 | Batches of 10,000 |
| large insertMany | 98.32 ms | 277.77 | 100 | Batches of 10 |
| small collection bulkWrite | 85.47 ms | 32.18 | 100 | Insert-only |
| large collection bulkWrite | 93.1 ms | 293.36 | 100 | 10 large docs, one round trip, localhost |
| small collection bulkWrite mixed | 22818.63 ms | 0.24 | 13 | 10,000 docs. Hits the 5 minute cap. |
| small client bulkWrite | 85.14 ms | 32.3 | 100 | Insert-only, `Client#bulk_write`, one namespace |
| large client bulkWrite | 95.15 ms | 287.02 | 100 | 10 large docs, `Client#bulk_write` |
| small client bulkWrite mixed | 3103.2 ms | 1.77 | 97 | 10,000 docs, 10 namespaces `corpus_1`…`corpus_10` |
| gridfs upload | 213.06 ms | 246.07 | 100 | Spec ~50 MB file |
| gridfs download | 51.34 ms | 1021.15 | 100 | Spec ~50 MB file, localhost |
| parallel small insertMany | 186.94 ms | 47.07 | 100 | Extra local task. Not in the composites. |

A `ns does not exist` log on the first GridFS drop is expected when `perftest.fs.*` is not there yet. It is not a failed task.

#### Client vs collection bulkWrite (same run)

| Task | Collection MB/s | Client MB/s | Notes |
|---|---|---|---|
| small insert bulkWrite | 32.18 | 32.3 | 10,000 small docs, one namespace |
| large insert bulkWrite | 293.36 | 287.02 | 10 large docs, one namespace |
| mixed bulkWrite | 0.24 | 1.77 | 10,000 docs. Client mixed uses 10 namespaces |

Insert-only scores are the same within noise. Mixed client `bulkWrite` is about **7×** mixed collection `bulkWrite`: one `bulkWrite` command on `admin` instead of separate insert / update / delete commands. PyMongo Evergreen 8.0 standalone (PR [1796](https://github.com/mongodb/mongo-python-driver/pull/1796)) showed the same direction for mixed (client 1.35 vs collection 0.65) and the opposite for insert-only (client slower: 8.4 / 21 vs collection insertMany 42 / 105).

#### Composites

| Composite | MB/s | How it is built |
|---|---|---|
| BSONBench | 1017.79 | Mean of the six BSON tasks |
| SingleBench | 85.34 | Mean of find one, small insertOne, large insertOne |
| MultiBench | 309.17 | Mean of the multi-doc tasks (not parallel), including client bulkWrite |
| ReadBench | 738.47 | Mean of find one, find many, GridFS download |
| WriteBench | 131.05 | Mean of insert, collection bulk, client bulk, mixed, and GridFS upload |
| DriverBench | 434.76 | Mean of ReadBench and WriteBench |

BSONBench does not enter DriverBench (spec rule). SingleBench is pulled up by large `insertOne` 238 and pulled down by small `insertOne` 0.42. ReadBench is pulled up by find many 1177 and GridFS download 1021. WriteBench is pulled down by mixed collection 0.24 and mixed client 1.77. Do not quote DriverBench 435 against Evergreen. ReadBench is lower than 2026-08-23 because find many and GridFS download moved; writes did not.

### BSON rematch (bson.cr 0.9.2)

`--release` + `BENCH_FULL=1`, no server (`env -u MONGODB_URI`). Official decode is still `to_h`. The live replica-set table above is unchanged (bson 0.9.0, 2026-09-01).

File: [`bench/results/2026-09-02T112234Z-full-bson-only.json`](bench/results/2026-09-02T112234Z-full-bson-only.json)

| | |
|---|---|
| Date | 2026-09-02 |
| Host | Linux x86_64, AMD Ryzen 7 5700G (16 threads), ~27 GiB RAM |
| Crystal | 1.21.0 `--release` |
| Mode | full (`min_iters=100`, `max_s=300`) |
| Data | in-memory docs of spec sizes (`bench/data/` files were not present) |
| bson.cr | **0.9.2** (GitHub) |

#### Official DriverBench BSON (`to_h`)

| Task | Median | MB/s | n |
|---|---|---|---|
| flat bson encode | 45.61 ms | 1651.09 | 100 |
| flat bson decode (`to_h`) | 62.59 ms | 1203.28 | 100 |
| deep bson encode | 21.98 ms | 1038.97 | 100 |
| deep bson decode (`to_h`) | 167.62 ms | 136.26 | 100 |
| full bson encode | 33.38 ms | 1717.95 | 100 |
| full bson decode (`to_h`) | 70.05 ms | 818.58 | 100 |
| **BSONBench** | | **1094.35** | |

**Verdict vs 2026-09-01** (bson 0.9.0): BSONBench 1018 → **1094**. Deep `to_h` 100 → **136** MB/s (intern of the deep-tree keys). Encode and full moved a few percent (noise). Flat decode 905 → 1203 is the 0.9.1 fill-from-buffer win, plus a quieter host than the 9.4.1 override.

**vs Wave 9.4.1 local override** (deep ~134): deep `to_h` **136** matches. BSONBench 1069 → 1094. Encode / flat / full within a few percent except flat decode, which was noisier on the override host. Intern in bson.cr 0.9.2 helps this deep `to_h` tree. A busy host can move encode / flat / full a few percent; that is noise.

#### Side walk / one-field (not DriverBench)

Same byte buffers as the official table. Date **2026-09-02**, **n=100**. Walk is `BSON.new(bytes).each` (recurse nested views; do not call `to_h`). One field is `bson["left"]` on deep, `bson["_id"]` on flat/full.

| Corpus | `to_h` MB/s | walk MB/s | one-field MB/s |
|---|---|---|---|
| deep | 136.26 | 216.36 | 3031.06 |
| flat | 1203.28 | 1376.25 | 8904.82 |
| full | 818.58 | 1589.35 | 12336.48 |

Do not quote walk / one-field as DriverBench. They are not in BSONBench.

---

## Versus other language drivers

There is **no public DriverBench on the same machine**. Numbers below come from GitHub PRs and MongoDB Evergreen comments. Hardware, MongoDB version, TLS, and data files differ. Treat this as a **direction** check: which band we sit in, and which tasks are weak.

Peer JSON (every published task we copied, plus notes): [`bench/results/peers.json`](bench/results/peers.json)

### How to read the columns

- **cryomongo short** — debug build, 2026-08-21, replica set, same host as `mongod`, generated docs, 1 MB GridFS. Decode is copy + header, not `to_h`.
- **cryomongo full** — `--release`, 2026-09-01, replica set `rs0`, spec time bounds, 50 MB GridFS, decode with `to_h`, client `bulkWrite` included. bson.cr 0.9.0. WiredTiger cache is 2 GiB per member. Still localhost and generated docs. BSON 0.9.2 rematch (no live): deep `to_h` 136, BSONBench 1094 — see [BSON rematch](#bson-rematch-bsoncr-092).
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
| flat encode | 453 | 1627 | 94 | 116 | 238 | 193 | — |
| flat decode | 154* | 905 | 83 | 106 | — | — | 312 |
| deep encode | 925 | 1000 | 25 | 31 | 57 | 124 | — |
| deep decode | 38* | 100 | 25 | 31 | — | — | 189 |
| full encode | 471 | 1703 | 50 | 59 | 177 | 152 | — |
| full decode | 231* | 772 | 56 | 76 | — | — | 222 |
| BSONBench | 379* | 1018 | 55 | 70 | — | — | — |

\* Short decode is copy + header, not `to_h`. Compare decode to other languages using the **full** column.

Go rows are `json.gz` decode-to-map from PR [2022](https://github.com/mongodb/mongo-go-driver/pull/2022) (contributor machine, not Evergreen). Decode-to-`D` is faster (flat 526, deep 195, full 273). Struct decode is much faster still (simple 617, nested 1844) and is not comparable to Crystal hashes.

Go marshal of a different “code” corpus (PR [1323](https://github.com/mongodb/mongo-go-driver/pull/1323), darwin arm64) reached about **840 Mi/s** unmarshal and **2444 Mi/s** marshal. Those units are mebibytes. Rough SI: 881 / 2562 MB/s. Ceiling for compiled BSON, not a DriverBench row.

Java ASCII **before** the 2025 opts: flat encode 105, deep 47, full 111.

### Single-doc live (MB/s)

| Task | short | full | Node main | Node PR | Java ASCII | Java UTF-8 | Python sync | Python async |
|---|---|---|---|---|---|---|---|---|
| hello | 0.12 | 0.22 | 0.040 | 0.066 | — | — | 0.065 | 0.028 |
| find one | 12 | 17 | 2.54 | 4.00 | — | — | 4.45 | 1.21 |
| small insertOne | 0.34 | 0.42 | 0.53 | 0.82 | — | — | 0.87 | 0.49 |
| large insertOne | 66 | 238 | 14 | 19 | 67 | 53 | 99 | 153 |
| SingleBench | 26 | 85 | 5.6 | 7.8 | — | — | — | — |

Java ASCII **before** opts: large insertOne 51.

### Multi-doc and GridFS (MB/s)

| Task | short | full | Node main | Node PR | Java ASCII | Java UTF-8 | Python sync | Python async |
|---|---|---|---|---|---|---|---|---|
| find many | 1229 | 1177 | 34 | 45 | — | — | 67 | 70 |
| small insertMany | 23 | 32 | 13 | 16 | 28 | 54 | 37 | 36 |
| large insertMany | 69 | 278 | 17 | 22 | 62 | 46 | 98 | 97 |
| small collection bulkWrite | 33 | 32 | — | — | — | — | — | — |
| large collection bulkWrite | 522 | 293 | — | — | — | — | — | — |
| mixed collection bulkWrite | 0.19 | 0.24 | — | — | — | — | 0.64 | 0.32 |
| small client bulkWrite | — | 32 | — | — | — | — | 8.4† | — |
| large client bulkWrite | — | 287 | — | — | — | — | 21† | — |
| mixed client bulkWrite | — | 1.77 | — | — | — | — | 1.35† | — |
| GridFS upload | 248 (1 MB) | 246 (50 MB) | 255 (~50 MB) | 400 (~50 MB) | — | — | 443 (~50 MB) | 502 |
| GridFS download | 1138 (1 MB) | 1021 (50 MB) | 481 (~50 MB) | 703 (~50 MB) | — | — | 636 (~50 MB) | 795 |

Java ASCII **before** opts: large bulk insert 47, small bulk insert 25.

† PyMongo Evergreen 8.0 standalone (PR [1796](https://github.com/mongodb/mongo-python-driver/pull/1796), 2024), not cryomongo. Same PR: large insertMany **105**, small insertMany **42**, mixed collection **0.65**. Collection bulk was much faster than `client.bulk_write` for insert-only in that snapshot. cryomongo insert-only collection and client scores are a tie on this host.

### Composites (MB/s)

| Composite | short | full | Node main | Node PR |
|---|---|---|---|---|
| BSONBench | 379* | 1018 | 55 | 70 |
| SingleBench | 26 | 85 | 5.6 | 7.8 |
| MultiBench | 408 | 309 | 160 | 237 |
| ReadBench | 793 | 738 | 172 | 251 |
| WriteBench | 120 | 131 | 60 | 92 |
| DriverBench | 457 | 435 | 116 | 171 |

Java and Python PRs did not publish a full composite table. Do not quote cryomongo DriverBench **435** against Evergreen: find many 1177 and GridFS download 1021 (localhost, generated tweets, cache) inflate ReadBench. The 2026-08-23 full DriverBench 508 is not a regression target for this row: find many and GridFS download were noisier here; BSONBench and WriteBench did not drop. The 2026-08-21 full WriteBench 261 is not comparable: it had no client tasks and a larger WiredTiger cache.

A 2021 insert-then-fetch bake-off ([Clarity AI](https://medium.com/clarityai-engineering/mongodb-driver-performance-in-several-languages-888899494b88), not DriverBench) put C++ and Java first, then Go, then .NET, with Node and Python slower on concurrent inserts. That grouping still matches these tables: native drivers in one band, Node/Python in another.

**cryomongo belongs in the native band for large documents and batches** on this host. It is not ahead of Java overall.

### Where this driver is in good shape

Use the **full** column unless a note says otherwise.

- **Flat and full BSON.** Encode ~1627 / 1703 MB/s vs Java ASCII 238 and Node 94–116. Decode `to_h` 905 / 772 vs Go map 312 / 222 and Node 83 / 56 (0.9.2 rematch: 1203 / 819). Generated documents help encode; decode is a real Hash walk and still sits in the compiled-language band. Deep encode 1000 is the nested-Hash 0.9.0 path (930 on 2026-08-23; 1039 on 0.9.2).
- **Small batches.** Full small `insertMany` 32, small collection `bulkWrite` 32, and small client `bulkWrite` 32 sit next to Python sync insertMany (~37) and beat Java ASCII (~28) and Node (~13–16).
- **Client vs collection insert.** On this host they match (small 32 vs 32, large 287 vs 293). Mixed client 1.77 vs mixed collection 0.24 is the gap that matters.
- **GridFS upload (spec ~50 MB).** 246 MB/s sits next to Node 255–400 and Python sync 443 on a different host. This is the most honest large-file write we have.
- **Command and find-one vs Node/Python.** Hello 0.22 vs Node 0.04–0.07 and Python sync 0.065. Find one 17 vs Node 2.5–4 and Python sync 4.5. Same spec byte sizes; localhost still helps.

### Where this driver needs work

- **Small `insertOne` (the live-path hole).** Full 0.42 MB/s vs Node 0.53–0.82 and Python sync 0.87. About 1,500 inserts/s. `--release` did not fix it (47 samples still hit the 5 minute cap). Likely costs: a new BSON per insert, implicit sessions, replica-set write concern, Crystal IO. This task is the one SingleBench number that is not inflated by a fat payload.
- **Deep BSON decode (`to_h`).** This is the Hash row, not find/insert. 0.9.2 rematch: **136** MB/s vs Go decode-to-map ~189. Intern of `"left"` / `"right"` / `"leftValue"` / `"rightValue"` is why 100 → 136 vs bson 0.9.0. Walk of the same deep tree (not DriverBench) is **216** MB/s; one-field `["left"]` is **3031** MB/s (2026-09-02, n=100). Official `deep_bson.json` is still the fairer encode rematch. Do not replace DriverBench decode with `each` or `[]`.
- **Mixed collection `bulkWrite`.** Full 0.24 MB/s vs Python sync 0.64 (10,000 docs, 5 minute cap, n=13). Replace/delete plus insert is much slower than insert-only bulk. Mixed client `bulkWrite` (1.77 MB/s, n=97) is the better mixed path on MongoDB 8.0.
- **Do not quote these localhost-inflated tasks against Evergreen:** find many 1177 vs Node 34–45 / Python 67; GridFS download 1021 vs Python 636 / Node 481–703; large `insertOne` 238 vs Java 67 / Python 99; large `insertMany` 278 vs Java 62 / Python 98. Generated payloads plus same-machine `mongod` are the main reason.
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

---

## Earlier local runs

These are not the public snapshot. They stay here so old numbers are not lost.

### 2026-08-23 full replica set (bson 0.8.1)

`--release` + `BENCH_FULL=1`. Wall time 21.3 minutes. Decode uses `to_h`. GridFS ~50 MB. Mixed `bulkWrite` 10,000 documents. Client `bulkWrite` tasks run. bson.cr 0.8.1. WiredTiger cache 2 GiB per member.

File: [`bench/results/2026-08-23T203227Z-full-replica-set.json`](bench/results/2026-08-23T203227Z-full-replica-set.json)

This was the public snapshot before bson 0.9.0. Compare BSON and live writes to 2026-09-01. Do not treat 2026-09-01 DriverBench 435 vs 508 here as a driver regression (find many / GridFS download noise). **Do not treat WriteBench 129 vs 2026-08-21 261 as a driver regression** (client tasks + 2 GiB cache).

| Composite | MB/s |
|---|---|
| BSONBench | 973.98 |
| SingleBench | 82.67 |
| MultiBench | 348.26 |
| ReadBench | 886.7 |
| WriteBench | 128.98 |
| DriverBench | 507.84 |

BSON: flat encode 1590.86, deep encode 930.03, full encode 1628.97. Live: small insertOne 0.41 (n=46), find many 1454.42, GridFS download 1189.29, mixed collection 0.23, mixed client 1.70.

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

BSONBench does not enter DriverBench. SingleBench is pulled up by large `insertOne` 372. ReadBench is pulled up by find many 1458 and GridFS download 1260. Do not quote DriverBench 587 against Evergreen. Do not compare WriteBench 261 to the 2026-08-23 WriteBench 129 without the notes in [Live replica set (bson 0.9.0)](#live-replica-set-bson-090).

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

---

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
  2026-08-23T203227Z-full-replica-set.json       full --release with client bulkWrite (bson 0.8.1)
  2026-09-01T223259Z-full-replica-set.json       full --release, bson 0.9.0 (current live snapshot)
  2026-09-02T112234Z-full-bson-only.json         full --release, bson 0.9.2, BSON only
```

File name: `<utc>-<mode>-<topology>.json`. Credentials in the URI are replaced with `***`.

To add a run, execute the runner (it writes JSON and updates `index.json`). If that run should be the public snapshot, copy its tables into [Latest numbers](#latest-numbers).
