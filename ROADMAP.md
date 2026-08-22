# ROADMAP: MongoDB 8.0 & Crystal 1.21+ Readiness

This roadmap defines the implementation checklist to achieve 100% compliance with official MongoDB driver specifications, while simultaneously optimizing for Crystal 1.21's Parallel Execution Contexts and ensuring enterprise-grade stability.

## Phase 1: Security, Stability & Core Compliance (Blockers for v1.0.0)

This phase focuses on ensuring the driver is safe, doesn't leak resources, and passes all baseline tests across all topologies.

### Security & Resource Management
- [x] **Command Logging and Monitoring:** Redact `authenticate`, `saslStart`, `createUser`, and the other sensitive commands in `Log.trace` and APM events.
- [x] **Cursors & Deterministic Cleanup:** `#each` and block `find` close the cursor. `finalize` is only a last resort. Call `#close` if you iterate with `#next`.

### Testing Infrastructure
- [x] **Strict UTF Dispatcher:** Unknown operations raise `SKIP_TEST` (no silent pass).
- [x] **Topology CI Matrix:** GitHub Actions runs standalone, replica set, sharded, and load-balanced. Push a PR to run that matrix.
- [x] **Dynamic Test Skipping:** `runOnRequirements` uses live topology or `TOPOLOGY`. Files that still skip because a feature is missing are listed under Remaining work (not AWS / OIDC / MongoDB 8.1+).

### Core Specifications (JSON & Legacy)
- [x] CRUD, Retryable Reads, Retryable Writes (UTF)
- [x] Transactions & Convenient API (UTF)
- [x] Sessions & Causal Consistency (UTF)
- [x] Server Discovery and Monitoring (SDAM) (Legacy state-machine tests)
- [x] Versioned API (UTF)
- [x] OP_MSG (Implemented)
- [x] Handshake / Hello (metadata, `backpressure: "2"`, UTF `metadata-not-propagated`)
- [x] Server Selection & Max Staleness (offline JSON)
- [x] Find, GetMore, KillCursors Commands (prose + live APM)

### Mandatory Prose Tests
- [x] **Client Backpressure:** `SystemOverloadedError` backoff. UTF retry-loop / max-attempts files pass.
- [x] **SDAM RTT:** Monitor updates RTT. Prose test checks a non-zero RTT after heartbeats.
- [x] **Transactions:** Write concern is not inherited from the collection inside a transaction.
- [x] **CMAP:** `PoolClearedError` is retried. Prose test passes. Unified `pool-cleared-error.json` passes (generation bump, waiters woken, handshake rediscovery).

---

## Phase 2: Cloud, Enterprise & Advanced Features

This phase addresses the complexities of running in modern cloud environments, handling dynamic scaling, and verifying advanced MongoDB features.

Phase 2 is done. GitHub runs `crystal spec` on standalone, replica set, sharded, and load-balanced. Named holes below stay open. Details are in `FIXES.md`.

### Cloud Architecture Specs
- [x] **SRV Polling:** Background fiber for `mongodb+srv://` (Sharded or Unknown). Adds and removes mongos hosts. `srvMaxHosts` / `srvServiceName`. No polling when `loadBalanced=true`.
- [x] **Load Balancers (core):** No `minPoolSize` pre-create. Hello must return `serviceId`. Pin the TCP socket for a transaction and for an open cursor. Official UTF is copied. HAProxy: mongos `--setParameter loadBalancerPort` plus `spec/support/run-load-balancer.sh`. GitHub load-balanced runs `crystal spec`.
- [x] **CSOT (core):** URI `timeoutMS` is a deadline for selection, checkout, socket wait, and `maxTimeMS` (remaining minus min RTT). Code 50 becomes `Error::Timeout`. Collection / database / operation `timeoutMS` and `timeoutMode`. GridFS, tailable, change-stream, session, and `with_transaction` timeouts. `runCursorCommand` helper. Official CSOT UTF is 28 files.

### Advanced Application Features
- [x] **Change Streams:** Iterate helpers exist. `watch` sends `comment`, `showExpandedEvents`, and `fullDocumentBeforeChange`. A labeled getMore error resumes with a new aggregate. `change-streams.json` passes on a replica set (22 tests). The other unified files run on replica set and sharded.
- [x] **GridFS:** Official UTF `upload` / `download` / `downloadByName` / `delete` / `rename` pass on sharded 8.0.
- [x] **Index Management:** Official `index-rawdata.json` runs (`rawData` ignored on 8.0).
- [x] **Enumerate Collections & Databases:** Official collection-management UTF runs (create / collMod / listCollections / timeseries / clustered index).

### Advanced Authentication Specs
- [x] Basic Auth (SCRAM-SHA-1/256 with SASLprep on SHA-256 passwords, X509, PLAIN)

### Leftovers to close Phase 2

- [x] **Official load-balancer UTF leftovers:** `assertNumberConnectionsCheckedOut`. Wait-queue error lists cursor / txn / other in-use counts. `serviceId` on `poolClearedEvent` and on command events. Pin CMAP checkedOut / checkedIn (`cursors.json` and `transactions.json`). Pool clear per `serviceId`. `non-lb-connection-establishment.json` stays pending on load-balanced. `lb-connection-establishment.json` stays skipped (MongoDB 8.0 still accepts `loadBalanced=false` on the LB port). One `sdam-error-handling` test stays skipped (HAProxy often sends both sockets to one mongos).
- [x] **CSOT API and more UTF:** `timeoutMS` on collection / database / operation, `timeoutMode` on find, aggregate, listCollections, and listIndexes. Session `defaultTimeoutMS` and `with_transaction` deadline. GridFS stream lifetime, tailable `timeoutMode` / `maxAwaitTimeMS`, change-stream iteration, override / session JSON. `Database#run_command` and `#run_cursor_command`. Official CSOT UTF is 28 files. Official run-command UTF is copied.
- [x] **Widen the GitHub load-balanced job.** LoadBalancer always allows retryable reads and writes (no monitor hello). `failCommand` / `closeConnection` UTF retries. Phase 2 close numbers (766 examples): standalone **23.86s / 219 pending**, replica set **3:36 / 104 pending**, sharded **7:05 / 112 pending**, load-balanced **2:58 / 137 pending**. Phase 3 GitHub numbers are in the Phase 3 section.

### Stay open after Phase 2 (moved)

Unified `pool-cleared-error.json` passes. zlib is Phase 3 (done). Everything still open is in **Remaining work** or **Out of scope** below.

---

## Phase 3: Crystal 1.21 Concurrency & Performance Optimization

This phase optimizes the driver to take full advantage of Crystal's new `-Dpreview_mt` / `Execution Contexts` and reduces network overhead.

Phase 3 is done. GitHub `crystal spec -Dpreview_mt -Dexecution_context` with `CRYSTAL_WORKERS=2` and `compressors=zlib` after Phase **3.2** is **783** examples: standalone **2:02 / 209 pending**, replica set **6:08 / 94 pending**, sharded **8:05 / 101 pending**, load-balanced **5:25 / 136 pending**. What is still skipped, and what is out of scope, is listed below and in `FIXES.md`.

### Concurrency
- [x] **CI Parallel Testing:** GitHub runs `crystal spec -Dpreview_mt -Dexecution_context` and sets `CRYSTAL_WORKERS=2` so the default execution context is resized.
- [x] **Connection Pool Refactoring:** One lock for the address-to-pool map. Handshake I/O no longer nests that lock with a per-address mutex.

### Zero-Allocation & Network I/O
- [x] **Compression (OP_COMPRESSED):** zlib on the wire. URI `compressors` / `zlibCompressionLevel`. snappy and zstd are not wired yet.
- [x] **Greedy Network Reads:** OP_MSG / OP_REPLY / header use `IO#read_greedy` and a `Channel(Bytes)` buffer pool. A short frame raises `IO::EOFError` (retryable network error).
- [x] **SDAM Event Optimization:** `Monitoring::Observable` copy-on-write subscriber list. Broadcast does not allocate a copy on the hot path.
- [x] **Reduced or zero-allocation:** Server-selection pick without a window Array. GridFS batched `insertMany` and one find cursor for download (zero-length files do not query chunks). Connection compression staging reuses `IO::Memory`.

### Validation
- [x] **Benchmarking:** `bench/driver_bench.cr` runs BSON DriverBench plus live single-doc / multi-doc / GridFS / fiber-parallel insert when `MONGODB_URI` is set. `BENCH_FULL=1` uses the spec time bounds. Each run writes JSON under `bench/results/`. See [BENCHMARK.md](BENCHMARK.md).

---

## Remaining work (MongoDB 8.0, toward production grade)

Phases 1–3 are done. Local Phase **3.2** `crystal spec` is green (**783** examples). Push a PR so GitHub Docker confirms the matrix. The driver is production-capable for core 8.0 (CRUD, sessions, transactions). It is still **0.x**. **1.0** waits on Phase 4 (CSFLE) and Phase 5 (AWS / OIDC). The **3.x** sub-phases below close remaining 8.0 holes. Details: `FIXES.md`. Un-skip a UTF file only after it passes. Each sub-phase is one conversation.

### Out of scope until the user asks

Do not treat these as the next work.

- **Phase 5:** `MONGODB-AWS` (SigV4, AWS accounts).
- **Phase 5:** `MONGODB-OIDC` (identity provider). UTF `mongodb-oidc-no-retry.json` stays pending.
- **MongoDB newer than 8.0.** Example: change-stream `nsType` needs **8.1**. Do not add 8.1+ fields now.
- **Atlas Search.** Keep `SKIP_TEST` for search-index ops. Do not copy search-index JSON.
- Official JSON `skipReason` that is a server or spec bug (`lb-connection-establishment.json` on 8.0; CSOT `runCursorCommand` “failure” tests with `blockTimeMS` < `timeoutMS`; DRIVERS-2032 handshake skips).

### Phase 3.1 — CMAP pool at discovery

Foundation for later CMAP / SDAM files. Create the pool when a monitor check finds a data-bearing server (or on load-balanced init). Emit `poolCreatedEvent` / `poolReadyEvent`. Fill `minPoolSize` in a background fiber after ready. A shutdown command error (code 91) during that fill marks the server Unknown and clears the pool.

- [x] `poolCreatedEvent` / `poolReadyEvent`. Create the pool at discovery, not only on first checkout.
- [x] Background `minPoolSize` after `poolReadyEvent` (not on the checkout path). Default `minPoolSize` is 0 (CMAP spec).
- [x] Un-skip `minPoolSize-error.json` (standalone).
- [x] Honest README: drop the lone BETA. Keep 0.x. Core CRUD / sessions / transactions on MongoDB 8.0.

`pool-clear-min-pool-size-error.json` stays skipped until 3.4 (handshake network during fill) and 3.10 (auth test). Checkout while the pool is paused still allows a new handshake; full paused-checkout (CMAP JSON) is 3.5 / 3.11.

GitHub Docker `replicaset` is **one** member, same as local `rs0`. The old note that GitHub is 3 members was wrong. `replicaset-emit-topology-changed-before-close.json` stays skipped until 3.13.

### Phase 3.2 — Monitor hello errors (this conversation)

- [x] Handle monitor hello command and network `failCommand`.
- [x] Un-skip `hello-command-error.json` and `hello-network-error.json`.

Awaitable hello (MongoDB 4.4+) and an RTT fiber are on so those UTF files can consume `failCommand` times on monitor sockets, not application handshakes. `serverMonitoringMode=poll` is honored so `minPoolSize-error.json` stays on polling. Awaitable hello timeout is `connectTimeoutMS` plus `heartbeatFrequencyMS` (SDAM spec). On mongod the extra is at least 1s (MongoDB 8.0 hello wait is ~1s when `topologyVersion` does not change). mongos keeps the spec sum. Single topology can select Unknown at once, so leftover `failCommand` `closeConnection` on hello can still hit the application handshake; checkout retries that network error until the wait budget ends (not a write retry). Heartbeat events stay Phase 3.3.

GitHub after 3.2 (**783** examples): standalone **2:02 / 209 pending**, replica set **6:08 / 94 pending**, sharded **8:05 / 101 pending**, load-balanced **5:25 / 136 pending**. Streaming hello makes the suite slower than Phase 3 polling. Standalone and replica set failed hello-timeout streaming wait until the 1s mongod extra.

### Phase 3.3 — Heartbeat events and `serverMonitoringMode`

URI `serverMonitoringMode` is already parsed (needed for 3.2 poll vs stream). Still to do:

- [ ] `ServerHeartbeatStartedEvent` / `Succeeded` / `Failed`.
- [ ] Un-skip `serverMonitoringMode.json`.

### Phase 3.4 — Handshake backpressure

Handshake network / timeout while filling the pool: `SystemOverloadedError` + `RetryableError`. Do not change the server description.

- [ ] Un-skip `backpressure-network-error-fail-replicaset.json` and `backpressure-network-timeout-fail-replicaset.json`.
- [ ] Un-skip `backpressure-network-error-fail-single.json` and `backpressure-network-timeout-fail-single.json`.
- [ ] Un-skip `backpressure-server-description-unchanged-on-min-pool-size-population-error.json`.
- [ ] Un-skip the non-auth test in `pool-clear-min-pool-size-error.json` if it passes.

### Phase 3.5 — `interruptInUseConnections`

- [ ] Close in-use sockets when the pool is cleared with that flag.
- [ ] Un-skip `interruptInUse-pool-clear.json`.
- [ ] Checkout while paused: non-timeout network error that does not mark the server Unknown (needed for official CMAP JSON).

### Phase 3.6 — Concurrent shutdown stale-generation

- [ ] Ignore stale-generation errors so UTF does not see two Unknown events.
- [ ] Un-skip `find-shutdown-error.json` and `insert-shutdown-error.json`.

### Phase 3.7 — UTF topology helpers

- [ ] `waitForPrimaryChange`, `recordTopologyDescription`, `assertTopologyType`.
- [ ] Un-skip `rediscover-quickly-after-step-down.json`.

### Phase 3.8 — Collection CRUD leftovers

- [ ] `let` on find / aggregate / updates / deletes / findOneAnd*. Un-skip CRUD `*-let.json` and `aggregate-let.json`.
- [ ] Legacy `count` command (not `countDocuments`). Un-skip `count-rawdata.json`, `retryable-reads/count.json`, `count-serverErrors.json`, `transactions/count.json`.
- [ ] `mapReduce` helper. Un-skip `retryable-reads/mapReduce.json`.
- [ ] Copy GridFS `deleteByName` / `renameByName` (5 of 8 copied) and non-search index-management JSON (1 of 7 copied).

### Phase 3.9 — Client `bulkWrite`

- [ ] Client-level `bulkWrite` (MongoDB 8.0).
- [ ] Un-skip `crud/client-bulkWrite-*.json`, `retryable-writes/client-bulkWrite-*.json`, `transactions/client-bulkWrite.json`, `causal-consistency-clientBulkWrite.json`.

### Phase 3.10 — Auth on CI, speculative auth, monitor auth

CI sets `auth: true` to not met. After users exist on mongod (not AWS / OIDC):

- [ ] Honor `auth: true` in `meets_requirements?`.
- [ ] Speculative auth. Monitor sockets must authenticate.
- [ ] Un-skip `retryable-reads/handshakeError.json` and `retryable-writes/handshakeError.json`.
- [ ] Un-skip unified SDAM `auth-error.json`, `auth-misc-command-error.json`, `auth-network-error.json`, `auth-network-timeout-error.json`, `auth-shutdown-error.json`, `pool-clear-checkout-error.json`.
- [ ] Live SCRAM / X509 / PLAIN prose (X509 needs TLS certs).

### Phase 3.11 — SDAM / CMAP logging and remaining official JSON

- [ ] SDAM / CMAP log messages. Un-skip `logging-standalone.json`, `logging-replicaset.json`, `logging-sharded.json`, `logging-loadbalanced.json`.
- [ ] CLAM UTF: match `reply` on succeeded / failed events. Copy the other 22 of 23 CLAM files as matching allows.
- [ ] Copy official CMAP JSON (35 files, none copied) after 3.1 and 3.5 exist.

### Phase 3.12 — URI, compression, sessions, IO, load-balancer leftovers

- [ ] `tls_certificate_key_file_password` and OCSP / CRL flags (parsed, unused).
- [ ] `auth_mechanism_properties` beyond URI validation (GSSAPI and similar).
- [ ] snappy / zstd wire compression (zlib is done).
- [ ] `enableOverloadRetargeting` (parsed, unused).
- [ ] Fiber-local implicit session (acquire/release still runs per command).
- [ ] Return the OP_MSG receive buffer to the Channel pool after `BSON.view` (do not claim zero-allocation).
- [ ] Move pool generation / handshake-before-complete from `spec/sdam_runner_spec.cr` into production if the legacy SDAM JSON still needs that.
- [ ] Load-balanced CSOT: after a dead pin, `killCursors` must not open a new socket (`timeoutMS is refreshed for close`).
- [ ] Two mongos `serviceId`s from HAProxy (`UTF_RUN_TWO_MONGOS=1`) for `sdam-error-handling.json`.

### Phase 3.13 — Replica-set topology-lifecycle and leftover skip audit

`replicaset-emit-topology-changed-before-close.json` wants **4** `topologyDescriptionChanged` events before close. One-member `rs0` (local **and** GitHub Docker) only gets 3, so `waitForEvent` hangs. Standalone / sharded / load-balanced emit files already run.

- [ ] Add a 3-member replica set (native `scripts/mongo-topology.sh` and GitHub Docker), **or** skip this file only when the set has one member.
- [ ] Un-skip `replicaset-emit-topology-changed-before-close.json` when the topology can emit 4 events.
- [ ] Audit leftover skips from Phases 1–3 that should not have stayed skipped.

### Phase 3.14 — Performance review and improvement

Not a spec hole. Review every hot path after 3.1–3.13: allocations, `insertOne` vs Node / Python, pool checkout, BSON receive buffer return, fiber-local sessions if not done in 3.12, DriverBench, and execution-context use. Change only what measurements support.

---

## Phase 4: Client-side encryption (Post-1.0)

In scope for production-grade completeness. Not AWS / OIDC / MongoDB 8.1+. Start only when the user asks.

- [ ] **Client-Side Field Level Encryption (CSFLE / Queryable Encryption):** Crystal bindings for `libmongocrypt`, intercept queries, encrypt fields locally, official CSFLE suite (224 files, none copied).

## Phase 5: Cloud and External Authentication

Out of scope until the user asks. Needs external services and accounts.

### Cloud Authentication Specs
- [ ] `MONGODB-OIDC` (Machine-flow auth)
- [ ] `MONGODB-AWS` (Requires AWS SigV4 signing)
