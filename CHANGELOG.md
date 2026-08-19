# Changelog

## Unreleased

Phase 1 of the MongoDB 8.0 / Crystal 1.21 roadmap.

### Added
* **security:** Redact `authenticate`, `saslStart`, `saslContinue`, `createUser`, `updateUser`, `getnonce`, `copydb*`, and hello with `speculativeAuthenticate` in APM events and `Log.trace`.
* **handshake:** Send `backpressure: "2"`, OS name / architecture / version, platform, and optional env metadata. First handshake uses legacy hello when Server API and load-balanced are unset. `Client#append_metadata` for wrapping libraries.
* **cursors:** `#each` and block `Collection#find` close the cursor. Do not rely on `finalize` for `killCursors`.
* **backpressure:** Retry `SystemOverloadedError` + `RetryableError` with exponential backoff. URI option `maxAdaptiveRetries` (default 2).
* **cmap:** Pool events (`poolClearedEvent`, checkout / checkin). Retry `PoolClearedError` on retryable writes and reads.
* **selection:** Shared `Mongo::SDAM::Selector` plus official server-selection, max-staleness, and RTT JSON tests (no mongod).
* **testing:** Prose tests for transaction write concern, SDAM RTT, PoolCleared retry, backpressure, and find/getMore. UTF `waitForEvent`, `assertEventCount`, `wait`, `close`, `appendMetadata`.
* **ci:** GitHub Actions matrix for standalone, replica set, and sharded. Local `scripts/mongo-topology.sh`. `TOPOLOGY` selects the default URI.

### Changed
* Network errors on a command now request an immediate monitor scan so the server can be rediscovered faster.

### Fixed
* **uri:** Options after the host with no delimiting slash parse correctly (`mongodb://localhost:27017?k=v`). The connection-string spec allows that form. The old parse kept a trailing `/` in the last option value.
* **ci:** mongos no longer receives `transactionLifetimeLimitSeconds` (mongod-only; mongos exits with "Unknown --setParameter"). Spec helpers append `/?` when they add URI options.
* **testing:** Map CI `TOPOLOGY=standalone` to UTF topology `single`. Skip or split `useMultipleMongoses` from the URI. Sharded CI starts two mongos. Turn failCommand off in `ensure`.
* **transactions:** Copy `errorLabels` from the reply and from `writeConcernError` so a retryable write-concern error is retried.

## 0.14.0 - 2026-08-19

Updating driver implementation with the recent and more efficient BSON v0.8.1

### Changed
* **bson:** Command bodies use one `BSON.append` for options and session fields. Receive reads documents with `BSON.view` over the OP_MSG buffer. `copy_with` is one builder pass.
* **hello:** `lastWrite` is a typed document. `lastWriteDate` is `BSON::DateTime` on the wire and becomes `Time` for max-staleness.
* **apm:** `safe_payload` builds a new document. It does not mutate the live reply (`BSON.new(BSON)` is a no-op).
* **utf:** Date match accepts both canonical `$numberLong` and relaxed ISO `$date`.
* **insert:** `inserted_ids` is ignored on BSON decode. The server does not send this field.
* **bson.cr:** `Serializable` / `Array` / `Hash` can deserialize `BSON::Value` after 0.8.0 (no duplicate `when BSON::DateTime`). This reflected in an update to `alumna/bson.cr`, released as v0.8.1.

### Fixed
* Replica-set hello no longer raises `TypeCastError` on `lastWriteDate`.
* Removed the unused `UNACKNOWLEDGED_WRITE_PROHIBITED_OPTIONS` constant. Unack writes still omit `lsid` and still send `hint` / `collation` / `arrayFilters` (UTF wants that).

## 0.13.0 - 2026-08-17

Correctness release for MongoDB 8.0 and Crystal 1.21.
This release was focused in improving the rough edges before continuing with the roadmap.

### Added
* **insert:** Client-generated `_id` and `insertedIds` on insert results. `insertMany` is one retryable command.
* **gridfs:** `session:` on all methods. Stream `#close` waits for the background fiber.
* **testing:** Honest UTF runner (results, errors, events, outcomes). Local `scripts/mongo-rs.sh` and `LOCAL_TESTING.md`.

### Changed
* **cursors / change streams:** Pin session and server. Tailable streams stay open on an empty getMore. `find` honors `limit`. `getMore` can retry.
* **sessions / transactions:** One implicit session for a whole bulk. Empty commit is reset. Cluster time and txn numbers are locked.
* **sdam / selection:** `Time.instant` for selection, monitor cooldown, and session idle. `serverSelectionTryOnce` works (default `false`). Stale `topologyVersion` errors do not mark the server Unknown.
* **uri / tls / pool:** Case-insensitive URI bools, typed `loadBalanced`, `maxIdleTimeMS`, hostname TLS flags.
* **crystal:** `Sync::Mutex`, `Time.instant`, no `spawn(same_thread:)`, no `.not_nil!`.
* **testing:** Live UTF is 362 examples, 0 failures, about 5.5 minutes (was ~25). Unknown work is `pending`, not a fake pass.

### Fixed
* GridFS chunk math, index names, and optional metadata. Counts return `Int64`. Timeout units. Tag-set match. `list*` can use a secondary.
* Monitor close, APM request ids, APM callbacks without the list lock, client close ends sessions first.

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
* **testing:** Created new test runner `spec/sdam_runner_spec.cr`. The runner checks topology type and set name for the legacy SDAM suite. Event body checks and live pool-generation rules are still incomplete.

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
* **commands:** Unacknowledged writes omit `lsid`. `hint` is still validated on old servers. Other prohibited options are sent as-is. Current UTF tests do not want a client-side raise.

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
