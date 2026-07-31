# ROADMAP: MongoDB 8.0 & Crystal 1.21+ Readiness

This roadmap defines the implementation checklist to achieve 100% compliance with official MongoDB driver specifications, while simultaneously optimizing for Crystal 1.21's Parallel Execution Contexts and ensuring enterprise-grade stability.

## Phase 1: Security, Stability & Core Compliance (Blockers for v1.0.0)

This phase focuses on ensuring the driver is safe, doesn't leak resources, and passes all baseline tests across all topologies.

### Security & Resource Management
- [ ] **Command Logging and Monitoring:** Implement a redaction helper to prevent `Log.trace` and APM events from logging plaintext passwords and PII (e.g., redact `authenticate`, `saslStart`, `createUser` bodies).
- [ ] **Cursors & Deterministic Cleanup:** Ensure Cursors don't rely solely on the Boehm GC (`finalize`) for sending `OP_KILL_CURSORS`. Implement block-based iteration or clear documentation for manual `.close`. 

### Testing Infrastructure
- [ ] **Strict UTF Dispatcher:** Update `spec/unified/dispatcher.cr` to explicitly `raise SKIP_TEST` for unknown operations instead of silently ignoring them, ensuring no false positives.
- [ ] **Topology CI Matrix:** Expand GitHub Actions to test against `Standalone`, `ReplicaSet`, and `Sharded` (mongos) topologies.
- [ ] **Dynamic Test Skipping:** Refactor the test runner to use the `runOnRequirements` topology field against the CI environment variable, removing hardcoded test skips.

### Core Specifications (JSON & Legacy)
- [x] CRUD, Retryable Reads, Retryable Writes (UTF)
- [x] Transactions & Convenient API (UTF)
- [x] Sessions & Causal Consistency (UTF)
- [x] Server Discovery and Monitoring (SDAM) (Legacy state-machine tests)
- [x] Versioned API (UTF)
- [x] OP_MSG (Implemented)
- [ ] Handshake / Hello (Wire up UTF tests)
- [ ] Server Selection & Max Staleness (Wire up spec tests)
- [ ] Find, GetMore, KillCursors Commands (Wire up spec tests)

### Mandatory Prose Tests
- [ ] **Client Backpressure:** Implement `SystemOverloadedError` exponential backoff prose tests.
- [ ] **SDAM RTT:** Ensure Round Trip Time is continuously updated by monitor fibers.
- [ ] **Transactions:** Implement "Write concern not inherited from collection object inside transaction" prose test.
- [ ] **CMAP:** Implement `PoolClearedError` retryability prose test.

---

## Phase 2: Cloud, Enterprise & Advanced Features

This phase addresses the complexities of running in modern cloud environments (like Atlas), handling dynamic scaling, and verifying advanced MongoDB features.

### Cloud Architecture Specs
- [ ] **SRV Polling:** Spawn a background fiber for `mongodb+srv://` connections to poll DNS records periodically and dynamically add/remove `mongos` routers from the topology.
- [ ] **Load Balancers:** Implement the Load Balancer spec (disable `minPoolSize` background creation, and pin consecutive transaction/cursor operations to the exact same TCP socket).
- [ ] **Client-Side Operations Timeout (CSOT):** Implement the modern `timeoutMS` specification to unify connection, handshake, and execution timeouts into a single deadline.

### Advanced Application Features (Needs Test Hookup)
- [ ] **Change Streams:** Run the official JSON/YAML spec tests to verify resume token and failover logic.
- [ ] **GridFS:** Wire up and pass official GridFS spec tests.
- [ ] **Index Management:** Wire up and pass official Index Management spec tests.
- [ ] **Enumerate Collections & Databases:** Wire up and pass official spec tests.

### Advanced Authentication Specs
- [x] Basic Auth (SCRAM-SHA-1/256, X509, PLAIN)
- [ ] `MONGODB-AWS` (Requires AWS SigV4 signing)
- [ ] `MONGODB-OIDC` (Machine-flow auth)

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

### Validation
- [ ] **Benchmarking:** Implement the official MongoDB Driver Benchmarking spec to formally measure and prove the performance gains of the zero-allocation BSON and Crystal 1.21 optimizations.

---

## Phase 4: The Final Boss (Post-1.0)

- [ ] **Client-Side Field Level Encryption (CSFLE / Queryable Encryption):** Write Crystal bindings for the `libmongocrypt` C library, intercept queries, encrypt fields locally, and implement the associated legacy CSFLE test suite.
