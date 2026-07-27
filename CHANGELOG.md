# Changelog

## 0.10.0 - 2026-07-27

### Added
* **sdam:** Added the complete SDAM Pub/Sub Event API (`TopologyOpeningEvent`, `TopologyDescriptionChangedEvent`, `ServerOpeningEvent`, `ServerClosedEvent`, `ServerDescriptionChangedEvent`, `TopologyClosedEvent`).
* **sdam:** Added support for the `LoadBalanced` topology type and `LoadBalancer` server type.
* **testing:** Created a dedicated `spec/sdam_runner_spec.cr` test runner and achieved 100% compliance on the MongoDB SDAM legacy test suite.

### Changed
* **performance:** Eliminated global class-level locks (`@@`) in favor of instance-level locks (`@`) in `Mongo::Client`, preventing cross-client contention in multi-cluster applications.
* **performance:** Restructured `Mongo::Connection::Pool` checkout logic to drastically reduce the scope of critical locks, preventing thread starvation during network I/O and handshake authentication.
* **testing:** Reorganized the spec tests with `spec/tests/unified/` and `spec/tests/legacy/` to isolate the Unified Test Format (UTF) from the legacy/transitional specs.

### Fixed
* **connection:** Fixed a parsing bug where IPv6 addresses with brackets (`[::1]`) would crash `TCPSocket` or fail OpenSSL certificate hostname validation. The driver now safely preserves brackets for SDAM string-matching but strips them at the socket level.
* **sdam:** Fixed a bug where `logical_session_timeout_minutes` was not properly cleared when a cluster lost its last data-bearing node.
* **sdam:** Implemented MongoDB 6.0+ staleness tuple comparison, ensuring `electionId` takes precedence over `setVersion` on wire versions >= 17.
* **sdam:** Fixed an issue where `ServerClosedEvent` was not emitted when a server was evicted from a primary's host list.
* **sdam:** Enforced strict fallback to `Unknown` server types whenever a server responds with `ok: 0.0`, even if structural flags like `isWritablePrimary` are mocked in the payload.
* **uri:** Corrected URI path decoding to use strict percent-decoding instead of `x-www-form-urlencoded` decoding, ensuring database names with literal `+` characters are not mangled into spaces.

## 0.9.0 - 2026-07-25

### Added
* **sdam:** Implemented strict `topologyVersion` tracking across `ServerDescription`, network errors, and `Mongo::Error` to prevent race conditions during concurrent topology state changes.
* **sdam:** Implemented `Mongo::Error::PoolCleared` to gracefully signal waiting fibers when a connection pool is purged due to network backpressure.
* **spec:** Added multi-threading execution support (`runOnThread`, `waitForThread`) to the Unified Test Runner Dispatcher.
* **spec:** Integrated the official Server Discovery and Monitoring (SDAM) Unified Test Format suite.

### Changed
* **sdam:** `TopologyDescription#update` now strictly enforces `topologyVersion` comparisons, discarding stale heartbeat responses and mitigating split-brain split-second races.

### Fixed
* **connection:** Mapped `connectTimeoutMS=0` to `nil` internally, ensuring Crystal's `TCPSocket` correctly interprets it as an infinite timeout.
* **cmap:** Fixed a connection pool starvation issue where fibers waiting in `checkout` would hang until timeout if the pool was concurrently cleared. They are now instantly awakened via `Channel::ClosedError` to seamlessly trigger the CMAP retry logic.

## 0.8.0 - 2026-07-22

### Added
* **sessions:** Fully implemented the MongoDB 5.0+ Snapshot Reads specification (`snapshot: true` and `snapshot_time`).
* **causal-consistency:** Fully updated causally-consistent sessions to propagate `afterClusterTime` on all write commands (`insert`, `update`, `delete`, `findAndModify`, `bulkWrite`, etc.) outside transactions.
* **sessions:** Added strict `SessionOptions` validation: enforced mutual exclusion between `snapshot` and `causal_consistency`, required `snapshot` mode when `snapshot_time` is specified, and prohibited `start_transaction` calls on snapshot sessions.
* **testing:** Enhanced the Unified Test Runner with support for `getSnapshotTime`, `assertSessionDirty`, `assertSessionNotDirty`, `assertSameLsidOnLastTwoCommands`, and `assertDifferentLsidOnLastTwoCommands`.

### Fixed
* **compatibility:** Enforced minimum server wire version check (`maxWireVersion >= 13` / MongoDB 5.0+) for snapshot sessions, raising clean client-side errors on unsupported topology versions.
* **spec:** Fixed BSON response parsing to extract `atClusterTime` from both top-level replies and `cursor` documents.

## 0.7.0 - 2026-07-20

### Added
* **deps:** Integrated `jgaskins/pipe` to replace kernel-level `IO.pipe` with a fast and efficient user-space pipe implementation, increasing throughput for GridFS streaming.

### Changed
* **architecture:** Split `Mongo::Client` and `Mongo::Collection` large classed into better organized modules (`src/cryomongo/client/*` and `src/cryomongo/collection/*`).
* **performance:** Revamped TCP socket reading for `OP_MSG` and `OP_REPLY`. The driver now uses length-prefixed `read_fully` framing combined with read-only `IO::Memory` buffers and direct `memchr` (`gets('\0')`) scanning. Eliminates intermediate `Bytes` allocations and maximizes network throughput.
* **performance:** Replaced one instance  of `Mutex` for tracking message request IDs with a lock-free `Atomic(Int32)`.
* **performance:** Optimized internal BSON document building, read-preference tag parsing, and topology array filtering to use single-pass logic, lazy iterators, and `String.build`, reducing Garbage Collector (GC) pressure.
* **modernization:** Updated other instances of `Mutex` with `Sync::Mutex` from Crystal 1.20+, for better compatibility with the new `Parallel` Execution Contexts.
* **testing:** Refactored the monolithic Unified Test Runner into a clean, modular directory structure (`spec/unified/`) with a dedicated `Dispatcher`, making future specification implementations much easier to create and test.

### Fixed
* **stability:** Eliminated unsafe unboxings and the risk of silently panics from the driver, replacing them with type-narrowing and explicit `Mongo::Error` raises.
* **protocol:** Fixed an off-by-4 byte boundary bug in `OP_MSG` sequence size parsing to strictly conform to the MongoDB wire protocol.
* **error-handling:** Shadowed the `message` getter in `Error::Command` to guarantee a non-nil `String`, and deduplicated error codes for better exception matching.

## 0.6.0 - 2026-07-17

### Added
* **transactions:** Fully implemented the MongoDB 4.0+ Core Transactions and the MongoDB 4.2+ Convenient API for Transactions (`with_transaction`).
* **transactions:** Implemented strict 120-second fallback timeouts, exponential backoff with jitter, and robust error-label-based retry logic (`TransientTransactionError`, `UnknownTransactionCommitResult`).
* **spec:** Fully integrated the official `transactions` and `transactions-convenient-api` Unified Test Format (UTF) suites (324/324 tests passing).
* **commands:** Added `Mongo::Commands::MayUseSecondary` to `RawCommand`, allowing raw commands to properly respect secondary read preferences within transactions.

### Fixed
* **connection:** Properly propagated `@options.socket_timeout` and `@options.connect_timeout` to the underlying `TCPSocket` and `UNIXSocket` instances, ensuring accurate network timeout enforcement.
* **sdam:** Ensured `Mongo::Connection` instances spawned by the SDAM Monitor explicitly use the connection timeout parameter, complying with the server monitoring spec.
* **spec:** Fixed test runner `Session` entity parsing and explicit database targeting for `ConfigureFailPoint` operations.

### Removed
* **deps:** Removed the unused `crystal-ameba/ameba` development dependency, ensuring compatibility with the latest Crystal 1.21+ releases.

## 0.5.0 - 2026-07-16

### Added
* **spec:** Implemented the official MongoDB Unified Test Format (UTF) runner, replacing the legacy bespoke test suite.
* **spec:** Fully synced and passed the official MongoDB `crud`, `retryable-reads`, and `retryable-writes` test suites.
* **error:** Added support for extracting and propagating top-level `errorLabels` (e.g., `RetryableWriteError`) from server `OP_MSG` responses into `Mongo::Error` exceptions.
* **error:** Recognized Error Codes `133` and `134` (`ReadConcernMajorityNotAvailableYet`) as valid `RETRYABLE_READ_CODES`.

### Changed
* **commands:** Driver now gracefully strips prohibited options (`hint`, `collation`, `array_filters`, `bypass_document_validation`) during unacknowledged writes instead of aggressively raising client-side errors, matching modern specification requirements.

### Fixed
* **spec:** Fixed state leaks in the Unified Test Runner by strictly disabling `failCommand` and `onPrimaryTransactionalWrite` fail points between test executions, preventing subsequent tests from failing with `EOFError`s.

## 0.4.0 - 2026-07-14

### Added
* **core:** Bumped `Mongo::Client::MAX_WIRE_VERSION` to `25` to officially support MongoDB 8.0 topologies.
* **ci:** Updated GitHub Actions (`specs.yml`) to use `ubuntu-24.04` and run tests against a persistent MongoDB 8.0 Docker ReplicaSet.
* **test:** Completely rewritten test runner based on Unified Test Format
* **test:** Fully passing CRUD unifies tests from latest MongoDB Specification

### Changed
* **tooling:** Bumped the minimum Crystal version constraint in `shard.yml` to `>= 1.20.0`.
* **concurrency:** Replaced deprecated `Time.monotonic` usages with `Time.instant` for Crystal 1.20+ compatibility.
* **concurrency:** Refactored `GridFS` to safely remove `same_thread: true` from fiber spawns without introducing deadlocks, adapting to the new Crystal 1.20 execution contexts.
