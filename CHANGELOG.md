# Changelog

## 0.12.0 - 2026-07-30

### Added
* **versioned-api:** Added the Versioned API feature. You can now configure the `ServerApi` version, strict mode, and deprecation errors on the client.
* **auth:** Added the `MONGODB-X509` authentication mechanism.
* **auth:** Added the `PLAIN` (LDAP) authentication mechanism.
* **testing:** Added the legacy authentication test runner. It uses the `Mongo::SpecSharding` tool to run tests in parallel.
* **testing:** Added the Versioned API unified test runner.

### Changed
* **uri:** The URI parser now uses the last value if an option occurs multiple times in the connection string. This matches the MongoDB specification.
* **uri:** The driver now keeps the correct uppercase and lowercase letters for Unix socket paths.

### Fixed
* **uri:** The URI parser now splits strings safely to prevent out-of-bounds errors.
* **uri:** The URI parser now safely isolates changes to `query_params` during the parsing step.

## 0.11.0 - 2026-07-30

### Added
* **testing:** Created a custom test sharding tool (`Mongo::SpecSharding`). This tool measures file sizes to divide tests equally across CI runners.

### Changed
* **architecture:** Separated data models from business logic in the `Bulk` and `GridFS` modules.
* **architecture:** Separated the routing logic and the operation logic in the Unified Test Runner.
* **performance:** Decreased the CI test duration from 19 minutes to 5.5 minutes.
* **performance:** Changed the default test log level from `:debug` to `:info`. This change stops slow STDOUT operations during tests.
* **performance:** Optimized the file size calculation in the test sharding tool. It now uses a tuple map (Schwartzian Transform) to prevent redundant operating system calls.

### Fixed
* **testing:** Fixed a duplicate key error (`E11000`) in the Unified Test Runner. The runner now correctly deletes all collections between tests to keep test isolation.
* **testing:** Applied the custom `CI_SHARD` tool to the legacy SDAM tests to prevent redundant test execution.

## 0.10.0 - 2026-07-27

### Added
* **sdam:** Added full SDAM Publish/Subscribe Event API. The API includes `TopologyOpeningEvent`, `TopologyDescriptionChangedEvent`, `ServerOpeningEvent`, `ServerClosedEvent`, `ServerDescriptionChangedEvent`, and `TopologyClosedEvent`.
* **sdam:** Added support for `LoadBalanced` topology type. Also added support for `LoadBalancer` server type.
* **testing:** Created new test runner `spec/sdam_runner_spec.cr`. The runner achieves 100% compliance with MongoDB SDAM legacy test suite.

### Changed
* **performance:** Removed global class-level locks (`@@`) from `Mongo::Client`. Now it uses instance-level locks (`@`). This prevents contention between clients in multi-cluster applications.
* **performance:** Changed checkout logic in `Mongo::Connection::Pool`. Reduced scope of critical locks. This prevents thread starvation during network I/O and handshake authentication.
* **testing:** Reorganized spec tests into two folders. Folder `spec/tests/unified/` contains Unified Test Format (UTF) tests. Folder `spec/tests/legacy/` contains legacy tests. This isolates the two formats.

### Corrected
* **connection:** Corrected parsing error for IPv6 addresses with brackets (`[::1]`). Before, these addresses caused `TCPSocket` to fail. They also caused OpenSSL hostname validation to fail. Now the driver keeps brackets for SDAM string matching. The driver removes brackets at socket level.
* **sdam:** Corrected error where `logical_session_timeout_minutes` did not clear. This occurred when cluster lost last data-bearing node. Now it clears correctly.
* **sdam:** Added MongoDB 6.0+ staleness comparison. Now `electionId` has precedence over `setVersion` when wire version is >= 17.
* **sdam:** Corrected issue where driver did not send `ServerClosedEvent`. This occurred when primary host list removed a server. Now it sends the event.
* **sdam:** Added strict fallback to `Unknown` server type when server response is `ok: 0.0`. This occurs even if payload contains flags such as `isWritablePrimary`. Now driver ignores these flags.
* **uri:** Corrected URI path decoding. Now uses strict percent-decoding. Before, it used `x-www-form-urlencoded` decoding. This prevents database names with `+` character from changing to space.

## 0.9.0 - 2026-07-25

### Added
* **sdam:** Added strict `topologyVersion` tracking. Tracking occurs in `ServerDescription`, network errors, and `Mongo::Error`. This prevents race conditions during concurrent topology changes.
* **sdam:** Added new error `Mongo::Error::PoolCleared`. The error signals waiting fibers when driver purges connection pool because of network backpressure.
* **spec:** Added multi-threading support to Unified Test Runner Dispatcher. Support includes `runOnThread` and `waitForThread`.
* **spec:** Added official Server Discovery and Monitoring (SDAM) Unified Test Format suite.

### Changed
* **sdam:** Changed `TopologyDescription#update`. It now compares `topologyVersion` values. It discards stale heartbeat responses. This prevents split-brain races.

### Corrected
* **connection:** Corrected handling of `connectTimeoutMS=0`. Internally maps value to `nil`. This lets Crystal `TCPSocket` use infinite timeout.
* **cmap:** Corrected pool starvation issue. Before, fibers in `checkout` waited until timeout if pool cleared at same time. Now driver wakes these fibers immediately with `Channel::ClosedError`. This starts CMAP retry logic.

## 0.8.0 - 2026-07-22

### Added
* **sessions:** Added full support for MongoDB 5.0+ Snapshot Reads. Support includes `snapshot: true` and `snapshot_time`.
* **causal-consistency:** Updated causally-consistent sessions. Now they send `afterClusterTime` on all write commands outside transactions. Commands include `insert`, `update`, `delete`, `findAndModify`, and `bulkWrite`.
* **sessions:** Added strict validation for `SessionOptions`. Validation does three checks. It prevents use of `snapshot` with `causal_consistency` at same time. It requires `snapshot` mode when `snapshot_time` is present. It prevents `start_transaction` on snapshot sessions.
* **testing:** Enhanced Unified Test Runner. Added support for `getSnapshotTime`, `assertSessionDirty`, `assertSessionNotDirty`, `assertSameLsidOnLastTwoCommands`, and `assertDifferentLsidOnLastTwoCommands`.

### Corrected
* **compatibility:** Added minimum wire version check for snapshot sessions. Requires `maxWireVersion >= 13` (MongoDB 5.0+). Driver now shows clear client error if topology does not support it.
* **spec:** Corrected BSON response parsing. Now extracts `atClusterTime` from top-level replies and from `cursor` documents.

## 0.7.0 - 2026-07-20

### Added
* **dependencies:** Added `jgaskins/pipe`. It replaces kernel-level `IO.pipe`. It uses user-space pipe. This increases throughput for GridFS streaming.

### Changed
* **architecture:** Split large classes `Mongo::Client` and `Mongo::Collection`. Moved code to modules `src/cryomongo/client/*` and `src/cryomongo/collection/*`. This improves organization.
* **performance:** Changed TCP socket reading for `OP_MSG` and `OP_REPLY`. Now uses length-prefixed `read_fully` framing. Uses read-only `IO::Memory` buffers. Uses direct `memchr` scanning with `gets('\0')`. This removes intermediate `Bytes` allocations. This increases network throughput.
* **performance:** Removed one `Mutex` for message request ID tracking. Replaced it with lock-free `Atomic(Int32)`.
* **performance:** Optimized BSON document building, read-preference tag parsing, and topology filtering. Now uses single-pass logic, lazy iterators, and `String.build`. This reduces Garbage Collector (GC) pressure.
* **modernization:** Replaced `Mutex` with `Sync::Mutex` from Crystal 1.20+. This improves compatibility with Parallel Execution Contexts.
* **testing:** Changed Unified Test Runner structure. Split monolithic runner into modular directory `spec/unified/`. Added dedicated `Dispatcher`. This makes future specification implementation easier.

### Corrected
* **stability:** Removed unsafe unboxings. Removed risk of silent panics. Now uses type-narrowing and explicit `Mongo::Error`.
* **protocol:** Corrected off-by-4 byte error in `OP_MSG` sequence size parsing. Now it conforms to MongoDB wire protocol.
* **error-handling:** Changed `message` getter in `Error::Command`. Now it always returns non-nil `String`. Also removed duplicate error codes. This improves exception matching.

## 0.6.0 - 2026-07-17

### Added
* **transactions:** Added full support for MongoDB 4.0+ Core Transactions. Added support for MongoDB 4.2+ Convenient API `with_transaction`.
* **transactions:** Added 120-second fallback timeouts. Added exponential backoff with jitter. Added retry logic based on error labels `TransientTransactionError` and `UnknownTransactionCommitResult`.
* **spec:** Added official Unified Test Format suites for `transactions` and `transactions-convenient-api`. All 324 tests pass.
* **commands:** Added `Mongo::Commands::MayUseSecondary` to `RawCommand`. This lets raw commands use secondary read preference inside transactions.

### Corrected
* **connection:** Corrected timeout propagation. Now `@options.socket_timeout` and `@options.connect_timeout` go to `TCPSocket` and `UNIXSocket`. This enforces correct network timeouts.
* **sdam:** Corrected SDAM Monitor behavior. `Mongo::Connection` instances from monitor now use connection timeout parameter. This follows server monitoring specification.
* **spec:** Corrected test runner. Fixed `Session` entity parsing. Fixed database targeting for `ConfigureFailPoint` operations.

### Removed
* **dependencies:** Removed unused development dependency `crystal-ameba/ameba`. This ensures compatibility with Crystal 1.21+.

## 0.5.0 - 2026-07-16

### Added
* **spec:** Added official MongoDB Unified Test Format (UTF) runner. It replaces legacy test suite.
* **spec:** Synced and passed official MongoDB test suites for `crud`, `retryable-reads`, and `retryable-writes`.
* **error:** Added support for top-level `errorLabels` such as `RetryableWriteError`. Now extracts them from server `OP_MSG` responses and adds them to `Mongo::Error`.
* **error:** Added error codes `133` and `134` (`ReadConcernMajorityNotAvailableYet`) to `RETRYABLE_READ_CODES`.

### Changed
* **commands:** Changed handling of prohibited options during unacknowledged writes. Prohibited options are `hint`, `collation`, `array_filters`, and `bypass_document_validation`. Now driver removes these options. Before, driver raised client error. This follows current specification.

### Corrected
* **spec:** Corrected state leaks in Unified Test Runner. Now disables `failCommand` and `onPrimaryTransactionalWrite` fail points between tests. This prevents next tests from failing with `EOFError`.

## 0.4.0 - 2026-07-14

### Added
* **core:** Increased `Mongo::Client::MAX_WIRE_VERSION` to `25`. This adds support for MongoDB 8.0 topologies.
* **ci:** Updated GitHub Actions `specs.yml`. Now uses `ubuntu-24.04`. Runs tests against persistent MongoDB 8.0 Docker ReplicaSet.
* **test:** Rewrote test runner based on Unified Test Format. Now all CRUD unified tests from latest MongoDB specification pass.

### Changed
* **tooling:** Increased minimum Crystal version in `shard.yml` to `>= 1.20.0`.
* **concurrency:** Replaced `Time.monotonic` with `Time.instant`. This adds compatibility with Crystal 1.20+.
* **concurrency:** Changed `GridFS`. Removed `same_thread: true` from fiber spawns. This does not cause deadlocks. This adapts code to Crystal 1.20 execution contexts.
