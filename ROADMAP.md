# ROADMAP: MongoDB 8.0 & Crystal 1.21+ Readiness

This roadmap defines the implementation checklist to achieve 100% compliance with official MongoDB driver specifications, while simultaneously optimizing for Crystal 1.21's Parallel Execution Contexts and ensuring enterprise-grade stability.

## Phase 1: Security, Stability & Core Compliance (Blockers for v1.0.0)

This phase focuses on ensuring the driver is safe, doesn't leak resources, and passes all baseline tests across all topologies.

### Security & Resource Management
- [x] **Command Logging and Monitoring:** Redact `authenticate`, `saslStart`, `createUser`, and the other sensitive commands in `Log.trace` and APM events.
- [x] **Cursors & Deterministic Cleanup:** `#each` and block `find` close the cursor. `finalize` is only a last resort. Call `#close` if you iterate with `#next`.

### Testing Infrastructure
- [x] **Strict UTF Dispatcher:** Unknown operations raise `SKIP_TEST` (no silent pass).
- [x] **Topology CI Matrix:** GitHub Actions runs standalone, replica set, and sharded. Push a PR to run that matrix.
- [x] **Dynamic Test Skipping:** `runOnRequirements` uses live topology or `TOPOLOGY`. A few files stay skipped because the feature is not implemented (`interruptInUseConnections`, most unified SDAM).

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
- [x] **CMAP:** `PoolClearedError` is retried. Prose test passes. The unified `pool-cleared-error.json` file is still skipped (rediscovery race).

---

## Phase 2: Cloud, Enterprise & Advanced Features

This phase addresses the complexities of running in modern cloud environments, handling dynamic scaling, and verifying advanced MongoDB features.

### Cloud Architecture Specs
- [x] **SRV Polling:** Background fiber for `mongodb+srv://` (Sharded or Unknown). Adds and removes mongos hosts. `srvMaxHosts` / `srvServiceName`. No polling when `loadBalanced=true`.
- [x] **Load Balancers:** No `minPoolSize` pre-create. Hello must return `serviceId`. Pin the TCP socket for a transaction and for an open cursor. Official load-balancer UTF is not copied yet (needs a real load balancer).
- [ ] **Client-Side Operations Timeout (CSOT):** URI `timeoutMS` starts a deadline used for server selection and socket wait. Full CSOT (maxTimeMS rules, UTF) is still open.

### Advanced Application Features (Needs Test Hookup)
- [ ] **Change Streams:** Iterate helpers exist. `clusterTime`, `errors`, and `resume-allowlist` pass on sharded. Four files are skipped (`showExpandedEvents`, pre/post images, resume errorLabels). `change-streams.json` asks for replica set.
- [x] **GridFS:** Official UTF `upload` / `download` / `downloadByName` / `delete` / `rename` pass on sharded 8.0.
- [x] **Index Management:** Official `index-rawdata.json` runs (`rawData` ignored on 8.0). Search-index ops still `SKIP_TEST`.
- [x] **Enumerate Collections & Databases:** Official collection-management UTF runs (create / collMod / listCollections / timeseries / clustered index).

### Advanced Authentication Specs
- [x] Basic Auth (SCRAM-SHA-1/256 with SASLprep on SHA-256 passwords, X509, PLAIN)

---

## Phase 3: Crystal 1.21 Concurrency & Performance Optimization

This phase optimizes the driver to take full advantage of Crystal's new `-Dpreview_mt` / `Execution Contexts` and reduces network overhead.

### Concurrency
- [ ] **CI Parallel Testing:** Ensure the CI pipeline compiles the test suite with `crystal spec -Dpreview_mt -Dexecution_context` to surface potential race conditions under true parallel thread execution.
- [ ] **Connection Pool Refactoring:** Analyze and remove nested `Sync::Mutex` locks in `Mongo::Connection::Pool` and `Mongo::Client#get_connection` to prevent thread starvation under high fiber contention. 

### Zero-Allocation & Network I/O
- [ ] **Compression (OP_COMPRESSED):** Implement wire protocol compression (zlib, snappy, or zstd) to drastically reduce bandwidth on large queries.
- [ ] **Greedy Network Reads:** Upgrade socket reading to use Crystal 1.20's `IO#read_greedy` combined with a `Channel(Bytes)` buffer pool to eliminate repetitive `Bytes` slice allocations per incoming `OP_MSG`.
- [ ] **SDAM Event Optimization:** Ensure APM/SDAM `Monitoring::Observable` broadcasts do not allocate intermediate arrays or closure objects in the hot path.
- [ ] **Reduced or zero-allocation:** Check the codebase for all possible opportunities to reduce allocations even more, including zero-allocation operations whenever possible.

### Validation
- [ ] **Benchmarking:** Implement the official MongoDB Driver Benchmarking spec to formally measure and prove the performance gains of the zero-allocation BSON and Crystal 1.21 optimizations.

---

## Phase 4: The Final Boss (Post-1.0)

- [ ] **Client-Side Field Level Encryption (CSFLE / Queryable Encryption):** Write Crystal bindings for the `libmongocrypt` C library, intercept queries, encrypt fields locally, and implement the associated legacy CSFLE test suite.

## Phase 5: Cloud and External Authentication

This phase will be done with the help of the community, because it requires external services and accounts, in order to be done.

### Cloud Authentication Specs
- [ ] `MONGODB-OIDC` (Machine-flow auth)
- [ ] `MONGODB-AWS` (Requires AWS SigV4 signing)
