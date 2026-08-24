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

Phase 3 is done. GitHub `crystal spec -Dpreview_mt -Dexecution_context` with `CRYSTAL_WORKERS=2` and `compressors=zlib` after Phase **3.2** is **783** examples: standalone **2:02 / 209 pending**, replica set **6:08 / 94 pending**, sharded **8:05 / 101 pending**, load-balanced **5:25 / 136 pending**. Local after Phase **3.8** is **785** examples: standalone **2:13 / 183 pending**, replica set **6:23 / 67 pending**, sharded **8:17 / 77 pending**, load-balanced **5:22 / 116 pending**. What is still skipped, and what is out of scope, is listed below and in `FIXES.md`.

### Concurrency
- [x] **CI Parallel Testing:** GitHub runs `crystal spec -Dpreview_mt -Dexecution_context` and sets `CRYSTAL_WORKERS=2` so the default execution context is resized.
- [x] **Connection Pool Refactoring:** One lock for the address-to-pool map. Handshake I/O no longer nests that lock with a per-address mutex.

### Zero-Allocation & Network I/O
- [x] **Compression (OP_COMPRESSED):** zlib, snappy, and zstd on the wire. URI `compressors` / `zlibCompressionLevel`. zstd needs libzstd.
- [x] **Greedy Network Reads:** OP_MSG / OP_REPLY / header use `IO#read_greedy` and a `Channel(Bytes)` buffer pool. A short frame raises `IO::EOFError` (retryable network error).
- [x] **SDAM Event Optimization:** `Monitoring::Observable` copy-on-write subscriber list. Broadcast does not allocate a copy on the hot path.
- [x] **Reduced or zero-allocation:** Server-selection pick without a window Array. GridFS batched `insertMany` and one find cursor for download (zero-length files do not query chunks). Connection compression staging reuses `IO::Memory`.

### Validation
- [x] **Benchmarking:** `bench/driver_bench.cr` runs BSON DriverBench plus live single-doc / multi-doc / collection and client `bulkWrite` / GridFS / fiber-parallel insert when `MONGODB_URI` is set. `BENCH_FULL=1` uses the spec time bounds. Each run writes JSON under `bench/results/`. Latest full `--release` snapshot: `bench/results/2026-08-23T203227Z-full-replica-set.json`. See [BENCHMARK.md](BENCHMARK.md).

---

## Remaining work (MongoDB 8.0, toward production grade)

Phases 1–3 are done. GitHub Docker Phase **3.13.1** `crystal spec` is **905** examples: standalone **2:01 / 167 pending**, replica set **4:29 / 45 pending**, sharded **8:11 / 56 pending**, load-balanced **4:13 / 102 pending**. Replica set is **3** members. Phase **3.13.1** closed leftover UTF `dropDatabase` and GridFS `drop`. Wrong-topology UTF files are omitted from Crystal spec (not `pending`). Remaining pending is newer-server / `auth: false` / official `skipReason` / out of scope. Optional CMAP wait-queue options are 3.13.2. **1.0** waits on Phase 4 (CSFLE) and Phase 5 (AWS / OIDC). Details: `FIXES.md`. Un-skip a UTF file only after it passes. Each sub-phase is one conversation.

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

`pool-clear-min-pool-size-error.json` non-auth test runs (3.4). The auth test runs in 3.10 when the URI has credentials (standalone). After the first `poolReady`, checkout while paused raises `PoolClearedError` (3.5). Before that, checkout may still handshake an Unknown seed. Official CMAP JSON copy is 3.11 (done).

GitHub Docker `replicaset` is **3** members (`scripts/docker-topology.sh`), same as local `rs0`. `replicaset-emit-topology-changed-before-close.json` runs (3.7).

### Phase 3.2 — Monitor hello errors

- [x] Handle monitor hello command and network `failCommand`.
- [x] Un-skip `hello-command-error.json` and `hello-network-error.json`.

Awaitable hello (MongoDB 4.4+) and an RTT fiber are on so those UTF files can consume `failCommand` times on monitor sockets, not application handshakes. `serverMonitoringMode=poll` is honored so `minPoolSize-error.json` stays on polling. Awaitable hello timeout is `connectTimeoutMS` plus `heartbeatFrequencyMS` (SDAM spec). On mongod the extra is at least 1s when the spec sum is under 1s (MongoDB 8.0 default hello wait is ~1s when `topologyVersion` does not change; test topologies set `minWaitForStreamingHelloMillis=0`). mongos keeps the spec sum. Single topology can select Unknown at once, so leftover `failCommand` `closeConnection` on hello can still hit the application handshake; checkout retries that network error on Unknown until the wait budget ends (not a write retry). A labeled handshake error on a known server fails checkout at once (3.4). Heartbeat events are Phase 3.3 (done).

GitHub after 3.2 (**783** examples): standalone **2:02 / 209 pending**, replica set **6:08 / 94 pending**, sharded **8:05 / 101 pending**, load-balanced **5:25 / 136 pending**. Streaming hello makes the suite slower than Phase 3 polling. Standalone and replica set failed hello-timeout streaming wait until the 1s mongod extra.

### Phase 3.3 — Heartbeat events and `serverMonitoringMode`

URI `serverMonitoringMode` is already parsed (needed for 3.2 poll vs stream).

- [x] `ServerHeartbeatStartedEvent` / `Succeeded` / `Failed`.
- [x] Un-skip `serverMonitoringMode.json`.

### Phase 3.4 — Handshake backpressure

Handshake network / timeout while filling the pool: `SystemOverloadedError` + `RetryableError`. Do not change the server description.

- [x] Un-skip `backpressure-network-error-fail-replicaset.json` and `backpressure-network-timeout-fail-replicaset.json`.
- [x] Un-skip `backpressure-network-error-fail-single.json` and `backpressure-network-timeout-fail-single.json`.
- [x] Un-skip `backpressure-server-description-unchanged-on-min-pool-size-population-error.json`.
- [x] Un-skip the non-auth test in `pool-clear-min-pool-size-error.json` if it passes.

### Phase 3.5 — `interruptInUseConnections`

- [x] Close in-use sockets when the pool is cleared with that flag.
- [x] Un-skip `interruptInUse-pool-clear.json`.
- [x] Checkout while paused: non-timeout network error that does not mark the server Unknown (needed for official CMAP JSON).

Monitor timeout clears the pool with `interruptInUseConnections: true` and unblocks in-use sockets (`LibC.shutdown`, not `Socket#close` from another thread). After the first `poolReady`, paused checkout raises `PoolClearedError`. Test topologies set `minWaitForStreamingHelloMillis=0`. The file runs on replica set and sharded.

### Phase 3.6 — Concurrent shutdown stale-generation

- [x] Ignore stale-generation errors so UTF does not see two Unknown events.
- [x] Un-skip `find-shutdown-error.json` and `insert-shutdown-error.json`.

The files run on standalone, replica set, and sharded. Load-balanced skips them (`runOnRequirements`).

### Phase 3.7 — UTF topology helpers

- [x] `waitForPrimaryChange`, `recordTopologyDescription`, `assertTopologyType`.
- [x] Un-skip `rediscover-quickly-after-step-down.json`.

The file needs a replica set with a secondary (`replSetStepDown`). Native and Docker `replicaset` topologies are 3 members on 27017/27018/27019. That also un-skips `replicaset-emit-topology-changed-before-close.json` (4 `topologyDescriptionChanged` events). The leftover skip audit is still 3.13.

### Phase 3.8 — Collection CRUD leftovers

- [x] `let` on find / aggregate / updates / deletes / findOneAnd* / collection `bulkWrite` (not insert). Un-skip CRUD `*-let.json` and `aggregate-let.json`.
- [x] Legacy `count` command (not `countDocuments`). Un-skip `count.json`, `count-collation.json`, `count-empty.json`, `retryable-reads/count.json`, `count-serverErrors.json`, `transactions/count.json`. `count-rawdata.json` test 1 stays pending on 8.0 (needs **8.2**).
- [x] `mapReduce` helper. Not retryable. Un-skip `retryable-reads/mapReduce.json`. Crystal uses `output:` (`out` is reserved).
- [x] Copy GridFS `deleteByName` / `renameByName` (7 of 8 copied; leftover is `upload-disableMD5`). Remaining official index-management JSON is Atlas Search only (out of scope).

### Phase 3.9 — Client `bulkWrite`

- [x] Client-level `bulkWrite` (MongoDB 8.0).
- [x] Un-skip `crud/client-bulkWrite-*.json`, `retryable-writes/client-bulkWrite-*.json`, `transactions/client-bulkWrite.json`, `causal-consistency-clientBulkWrite.json`.

### Phase 3.10 — Auth on CI, speculative auth (monitors stay unauthenticated)

CI creates user `bob` / `pwd123` on `admin` (no `--auth`). The URI has credentials so SASL runs:

- [x] Honor `auth: true` / `auth: false` in `meets_requirements?` from URI userinfo.
- [x] Speculative auth on the first application hello. Monitor sockets must **not** authenticate (SDAM).
- [x] Un-skip `retryable-reads/handshakeError.json` and `retryable-writes/handshakeError.json`.
- [x] Un-skip unified SDAM `auth-error.json`, `auth-misc-command-error.json`, `auth-network-error.json`, `auth-network-timeout-error.json`, `auth-shutdown-error.json`, `pool-clear-checkout-error.json`.
- [x] Live SCRAM prose. X509 / PLAIN stay pending unless `MONGODB_X509_URI` / `MONGODB_PLAIN_URI` is set.

### Phase 3.11 — SDAM / CMAP logging and remaining official JSON

- [x] SDAM / CMAP log messages. Un-skip `logging-standalone.json`, `logging-replicaset.json`, `logging-sharded.json`, `logging-loadbalanced.json`.
- [x] CLAM UTF: match `reply` on succeeded / failed events. Copy the other 22 of 23 CLAM files as matching allows.
- [x] Copy official CMAP JSON (33 cmap-format + 2 UTF) after 3.1 and 3.5 exist.

Env: `MONGODB_LOG_COMMAND`, `MONGODB_LOG_TOPOLOGY`, `MONGODB_LOG_CONNECTION`, `MONGODB_LOG_ALL`, `MONGODB_LOG_PATH`, `MONGODB_LOG_MAX_DOCUMENT_LENGTH`. `serverSelection` is parsed and unused. Write errors with `ok: 1` emit CommandSucceeded. Client close emits `ServerClosedEvent` before the Unknown topology change.

### Phase 3.12 — URI, compression, sessions, IO, load-balancer leftovers

- [x] `tls_certificate_key_file_password` and stapled OCSP (`tlsDisableCertificateRevocationCheck`). No OCSP HTTP fetch.
- [x] `auth_mechanism_properties` stored as a Hash on Credentials (GSSAPI / Kerberos stay out of scope).
- [x] snappy / zstd wire compression (zlib is done).
- [x] `enableOverloadRetargeting` deprioritizes the last server on an overload retry.
- [x] Fiber-local implicit session.
- [x] Return the OP_MSG receive buffer to the Channel pool after `BSON.view` (do not claim zero-allocation).
- [x] Shared SDAM `ApplicationError.decide` for the legacy runner and production.
- [x] Load-balanced CSOT: after a timed-out getMore, `killCursors` stays on the pin (`timeoutMS is refreshed for close`).
- [x] Two mongos `serviceId`s from HAProxy (`UTF_RUN_TWO_MONGOS=1`) for `sdam-error-handling.json`.

### Phase 3.13 — Leftover skip audit

`replicaset-emit-topology-changed-before-close.json` wants **4** `topologyDescriptionChanged` events before close. The 3-member `rs0` (native and GitHub Docker, added in 3.7) emits 4, so that file runs.

GitHub Docker 3.13.1 pending counts (file-level Crystal `pending`) were standalone **167**, replica set **45**, sharded **56**, load-balanced **102**. Wrong-topology UTF files are now omitted from Crystal spec (not `pending`). Newer-server files stay `pending`. Intra-file `skip_op` leftovers are done in 3.13.1.

- [x] Add a 3-member replica set (native `scripts/mongo-topology.sh` and GitHub Docker), **or** skip this file only when the set has one member.
- [x] Un-skip `replicaset-emit-topology-changed-before-close.json` when the topology can emit 4 events.
- [x] **3.13.1** Audit leftover skips and pending lists. UTF `dropDatabase` and GridFS `drop` (CSOT `gridfs-advanced.json` drop tests). `Database#drop` / `Collection#drop`. Omit Crystal examples for UTF files that cannot run on the current topology. RTT `close` interrupts an in-flight hello.
- [ ] **3.13.2** Optional CMAP `waitQueueSize` / `waitQueueMultiple` (deprecated; the spec says skip if the driver does not support them). Do not start unless we want those two log tests.
- [x] Audit leftover skips from Phases 1–3 that should not have stayed skipped.
- [x] Audit any item showed as "Pending" when executing crystal spec in the multiple different topologies. Wrong-topology UTF files are omitted (not pending). Remaining pending is newer-server / auth / skipReason / out of scope. Details: `FIXES.md`.

### Phase 3.14 — Performance review and improvement

Not a spec hole. Review every hot path after 3.1–3.13: allocations, `insertOne` vs Node / Python, pool checkout, DriverBench, and execution-context use. Change only what measurements support. Fiber-local sessions and receive-buffer return are done in 3.12.

---

## Phase 4: Client-side encryption (Post-1.0)

In scope for production-grade completeness. Not AWS / OIDC / MongoDB 8.1+. Start only when the user asks.

- [ ] **Client-Side Field Level Encryption (CSFLE / Queryable Encryption):** Crystal bindings for `libmongocrypt`, intercept queries, encrypt fields locally, official CSFLE suite (224 files, none copied).

## Phase 5: Cloud and External Authentication

Out of scope until the user asks. Needs external services and accounts.

### Cloud Authentication Specs
- [ ] `MONGODB-OIDC` (Machine-flow auth)
- [ ] `MONGODB-AWS` (Requires AWS SigV4 signing)
