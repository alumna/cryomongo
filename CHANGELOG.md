# Changelog

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
