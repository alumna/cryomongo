# Changelog

## Unreleased

Client-Side Field Level Encryption (CSFLE)

### Added
- Explicit client-side encryption (`Mongo::ClientEncryption`), local KMS only
  - libmongocrypt bindings (official **1.20.4** vendored by default)
  - `create_data_key`, `encrypt`, `decrypt`
  - Key vault: `get_key`, `get_keys`, `delete_key`,
    `add_key_alt_name`, `remove_key_alt_name`, `get_key_by_alt_name`
  - `rewrap_many_data_key` (local KMS; empty match has no `bulkWriteResult`)
  - Encrypted values are BSON binary subtype `0x06`
  - Compile `-Dwithout_libmongocrypt` skips the link; the type then raises
  - Specs skip the live encrypt path when the library is missing
  - GitHub CI runs `scripts/vendor-libmongocrypt.sh` (does not install `libmongocrypt-dev`)
  - Linux official tarball is nocrypto; OpenSSL AES / HMAC / SHA / RAND hooks fill that gap
- Auto-encryption on `Mongo::Client` (`Mongo::AutoEncryption`, FLE1 `schemaMap`)
  - Local KMS only; crypt_shared (`mongo_crypt_v1.so`) for query analysis
  - `extraOptions.cryptSharedLibPath` or `CRYPT_SHARED_LIB_PATH`
  - Insert / find / update / delete encrypt marked fields and decrypt results
  - Key-vault commands bypass auto-encryption (no deadlock)
  - Specs skip when libmongocrypt or crypt_shared is missing
  - GitHub CI downloads crypt_shared (does not commit the `.so`)
  - mongocryptd is not spawned
  - `bypass_query_analysis` skips crypt_shared (writes still encrypt from the map)
- Queryable Encryption on `Mongo::Client` (`encryptedFieldsMap`, MongoDB 8.0 equality)
  - `Mongo::AutoEncryption.new(..., encrypted_fields_map:)`
  - `ClientEncryption#create_encrypted_collection` (null `keyId` → data key)
  - `Database#create_collection` creates ESC / ECOC and `__safeContent__`
  - `Collection#compact_structured_encryption_data` (auto-encryption fills tokens)
  - Specs skip when libmongocrypt or crypt_shared is missing
  - Queryable Encryption collections need a replica set or sharded cluster
  - MongoDB 8.0 range is in the official UTF slice
  - Prefix / suffix / substring and MongoDB 8.2+ stay out
- First official CSFLE unified batch (local KMS, MongoDB 8.0)
  - Copied: `localKMS`, `namedKMS`, `namedKMS-explicit`, `keyCache`,
    `create-and-createIndexes`, `fle2v2-InsertFind-Indexed`
  - UTF `clientEncryption` entity; `encrypt` / `decrypt` ops
  - UTF client `autoEncryptOpts` (schemaMap, encryptedFieldsMap, extraOptions)
  - Named local KMS (`local:name`); master key may be base64
  - `key_expiration_ms` on `ClientEncryption` and `AutoEncryption`
- Rest of official CSFLE UTF that can run on MongoDB 8.0 + local KMS (Wave 25)
  - 71 more files (key vault, FLE1 local validator, QE equality, QE range)
  - UTF ops: `createDataKey`, `rewrapManyDataKey`, key-vault helpers
  - UTF relaxed JSON integers that fit in Int32 are Int32
  - UTF `initialData` insert uses `bypassDocumentValidation`
  - Auto-encryption: `bypass_query_analysis`
  - Client `bulkWrite` collinfo on the op database (`mongo_db`)
  - Cloud KMS / 8.2+ text files are leftover with reasons

### Fixed
- Do not call `mongocrypt_destroy` from `ClientEncryption` GC finalize
  - Finalize runs during `GC_malloc`; libmongocrypt uses libc free
  - GitHub four-topology CI crashed (double free / SIGSEGV)
- `Insert.with_ids` keeps BSON binary subtype when it generates `_id`
  - `[]=` of `Bytes` wrote generic `0x00` and dropped FLE `0x06`
- UTF simple `createCollection` / `dropCollection` use `Database#create_collection`
  and `Collection#drop` so Queryable Encryption creates ESC / ECOC and
  `keyAltName` is resolved (`fle2v2-InsertFind-keyAltName`)

### Changed
- Default CSFLE link is official libmongocrypt **1.20.4** (`scripts/vendor-libmongocrypt.sh`).
  `USE_SYSTEM_LIBMONGOCRYPT=true` uses pkg-config (needs >= 1.20.0).
  GitHub Ubuntu 24.04 `libmongocrypt-dev` does not export
  `mongocrypt_setopt_key_expiration`,
  `mongocrypt_setopt_use_need_mongo_collinfo_with_db_state`, or
  `mongocrypt_ctx_mongo_db` (PR 37). Default vendor so apt cannot win.
- GitHub Linux CI: four topologies on Ubuntu **22.04**, **24.04**, and
  **26.04** (preview) for both x64 and arm64 (24 cells). Pin image labels
  (`ubuntu-22.04`, `ubuntu-24.04`, `ubuntu-26.04`, `ubuntu-22.04-arm`,
  `ubuntu-24.04-arm`, `ubuntu-26.04-arm`). Do not use `ubuntu-latest`.
  Skip `ubuntu-slim`. Cache keys include OS and arch. `fail-fast: false`.
  No `GLIBC_TUNABLES` on GitHub.
- GitHub macOS CI: four topologies on **macos-15** and **macos-26** (arm64)
  using native Community MongoDB **8.0.29** (not Docker). Pin labels; do
  not use `macos-latest`. Skip **macos-14** (deprecated) and intel
  `macos-*-large`. HAProxy via Homebrew for load-balanced.
  Windows GitHub is leftover: the driver does not compile (`LibC::SHUT_RDWR`,
  zstd.cr bash `pkg-libs.sh`, no `mongocrypt.lib` in the 1.20.4 tarball).
  `windows-11-arm` has no libmongocrypt 1.20.4 tarball.
- `scripts/download-crypt-shared.sh` picks linux **x86_64** or **aarch64**
  and ubuntu2204 (22.04) or ubuntu2404 (24.04 and 26.04), plus official
  macos **arm64** / **x86_64** `.dylib` and windows x86_64 `.zip`. Official
  8.0.29 aarch64 and macos-arm64 packages exist. There is no ubuntu2604
  crypt_shared tarball. Windows CI jobs are not added.
- **docs:** Phase 4 (CSFLE) is Waves 21–25 plus Wave 27 (vendor 1.20.4).
  Wave 21 is bindings plus explicit local KMS.
  Wave 22 is auto-encryption (`schemaMap`).
  Wave 23 is Queryable Encryption (`encryptedFieldsMap`, 8.0 equality).
  Official CSFLE tests are Waves 24–25 (local KMS + 8.0 done;
  leftover is cloud KMS and 8.2+ text).
  Wave 27 vendors official libmongocrypt 1.20.4 (GitHub apt was too old).
  Wave 28 is Linux OS/arch four-topology GitHub CI.
  Wave 29 is macOS arm64 four-topology GitHub CI (native mongod).
  Windows GitHub is leftover (driver does not compile).
  Adapter CI four-topology matrix is Wave 20.
  Phase 3.14 (performance) is later and is not in those waves.

## 0.17.5 - 2026-09-02

Replica-set GitHub extra `insert` events after 0.17.4 (`deprecated-options.json`, `legacy-timeouts.json`, `interruptInUse-pool-clear.json`, `rediscover-quickly-after-step-down.json`).

Cause: retryable writes handshaked the URI seed while it was Unknown (GitHub 27017 is often a secondary), sent the insert there, then retried on the primary. Leftover `failCommand` and live prose overlapping UTF (`CRYSTAL_WORKERS=2`) can add the same extra events.

### Fixed
- After handshake, do not send a replica-set write to a member that is not a primary; check the socket in and select again (not a retryable-write attempt)
- Do not pick a lone Unknown replica-set seed as a write target (that seed is often a secondary)
- `disable_fail_points` sends `mode=off` on every replica-set member through a cached `directConnection` client
- Those clients use a unique `appName`, omit URI userinfo, and poll with a 1000s heartbeat (a later hello failPoint must not pause the pool)
- Member list includes `hello.hosts` so a secondary seed still gets `mode=off`
- Retry `mode=off`; recreate the direct client only after retries fail
- A sharded URI has two mongos; `mongodb_seed_address` is the first host only (`directConnection` cannot use the whole host list)
- Live prose that talks to mongod (auth, compression, RTT, find/getMore, transaction write concern, UTF bootstrap / close) uses the same cluster lock as UTF

## 0.17.4 - 2026-09-02

### Changed
- Pins **bson.cr 0.9.2** (interned deep-tree keys on `to_h`)
- Handshake `os` / `env` / `container` and SCRAM `options` write into the parent Builder IO (no child `BSON.build`; that path landed with bson 0.9.0)

### Bench
- Live DriverBench snapshot is still [`2026-09-01T223259Z-full-replica-set.json`](bench/results/2026-09-01T223259Z-full-replica-set.json) (bson 0.9.0)
- BSON-only rematch on 0.9.2: [`2026-09-02T112234Z-full-bson-only.json`](bench/results/2026-09-02T112234Z-full-bson-only.json) (deep `to_h` 136 MB/s, BSONBench 1094)
- Official decode stays `to_h`; walk / one-field tasks are extra and not in BSONBench
- Live path stays BSON / views / Builder
- [`BENCHMARK.md`](BENCHMARK.md) order: concepts → how to run → numbers (live 0.9.0 and BSON 0.9.2)

## 0.17.3 - 2026-08-25

Replica-set GitHub flake after 0.17.2: `logging-replicaset.json` **Failing heartbeat** (`waitForEvent` `serverHeartbeatFailedEvent` got 0 in 10s).

### Fixed
- After a hello `closeConnection` / `errorCode` failPoint, UTF aborts in-progress monitor hello on that appName client when it sees `serverHeartbeatFailedEvent`
- Awaitable hello does not see `failCommand` until the default 10s heartbeat wait ends (`waitForEvent` is also 10s)
- Backpressure tests freeze monitors (`heartbeatFrequencyMS` 1000000) and are not aborted
- Do not copy this failPoint to all members
- `:nodoc:` helper on `Client` / `Monitor`; production call sites unchanged

## 0.17.2 - 2026-08-25

Replica-set GitHub flake after 0.17.1 on squash-and-merge (5 extra insert events). No production `src/` change.

### Fixed
- Seed hello failPoint applies only to handshake errors (`errorCode` or `closeConnection`), not CSOT alwaysOn `blockConnection`
- `disable_fail_points` turns off `failCommand` on every member through a `directConnection` client, including Unknown / paused pools
- `waitForPrimaryChange` also does a w:1 insert on that primary

GitHub Docker: 0 failures on all four topologies. Same example / pending / time band as 0.17.1 (2:01 / 4:32 / 6:55 / 4:03).

## 0.17.1 - 2026-08-25

UTF harness. Per-test locks still let another file run `killAllSessions` / `failCommand` between tests, so retryable writes retried and replica-set `expectEvents` failed.

### Fixed
- One cluster lock per UTF JSON file (CMAP cmap-format and prose `failCommand` use the same lock)
- Do not send every `failPoint` to all replica-set members (that caused extra Unknown / checkout events and leftover `failGetMoreAfterCursorCheckout`)
- A hello `failPoint` for an appName client that does not exist yet is also set on the URI seed (often a secondary)
- `waitForPrimaryChange` waits until that primary answers hello as writable
- UTF event lists are pinned per client and appended under a mutex, so a closed client’s late callback cannot land in the next test

GitHub Docker (`CRYSTAL_WORKERS=2`): standalone **2:01 / 14 pending / 754**, replica set **4:32 / 15 / 879**, sharded **6:55 / 15 / 868**, load-balanced **4:03 / 15 / 822**. 0 failures. Same band as 3.13.3.

## 0.17.0 - 2026-08-25

Phase 3 of the roadmap (3.1–**3.13.3**). Next 8.0 work is Phase **3.14** (performance review).

### Phase 3 map
- **3.1** CMAP pool at discovery (`poolCreatedEvent` / `poolReadyEvent`, background `minPoolSize`); local `crystal spec -Dpreview_mt -Dexecution_context` with `CRYSTAL_WORKERS=2`
- **3.2** Monitor hello command and network errors
- **3.3** Monitor heartbeat events and `serverMonitoringMode` UTF
- **3.4** Handshake backpressure labels (`SystemOverloadedError` + `RetryableError`)
- **3.5** Pool clear with `interruptInUseConnections`
- **3.6** Ignore stale-generation application errors; `find-shutdown-error.json` / `insert-shutdown-error.json`
- **3.7** UTF `waitForPrimaryChange` / `recordTopologyDescription` / `assertTopologyType`; replica set is 3 members
- **3.8** `let`, legacy `count`, `mapReduce`, GridFS `delete_by_name` / `rename_by_name`
- **3.9** Client `bulkWrite` (MongoDB 8.0)
- **3.10** CI/local users, speculative SCRAM / X509, auth-error SDAM
- **3.11** Spec logs, CLAM (23 files), official CMAP (33 cmap-format + UTF)
- **3.12** TLS password, snappy/zstd, `authMechanismProperties`, implicit session per fiber, OP_MSG buffer pool, load-balanced CSOT pin
- **3.13.1** `dropDatabase` / collection and GridFS `drop`; omit wrong-topology UTF; `after_suite` does not drop leftover databases
- **3.13.3** Pinned mongos after handshake/heartbeat error; load-balanced stale pin drop; `retryable-commit-handshake.json` / `retryable-abort-handshake.json`

Example counts: **796** after 3.9, **859** after 3.11, **905** after 3.12 (34 Deprioritized files, compression, TLS password). 3.13.1 omits wrong-topology UTF, so GitHub example counts drop (see 0.17.1).

GitHub Docker after 3.12 close-wake + snappy-first (`CRYSTAL_WORKERS=2`): **905** examples, 0 failures. Standalone **1:59 / 167 pending**, replica set **4:26 / 45**, sharded **6:56 / 56**, load-balanced **4:24 / 102**. Before those two changes: 2:59 / 7:45 / 12:20 / 6:35.

### Added

**crud / gridfs**
- `Database#drop` (`dropDatabase`); `Collection#drop` (`drop`; NamespaceNotFound ignored)
- `let` on find, aggregate (collection and database), update / replace / delete, findOneAnd*, and collection `bulkWrite` (update and delete groups only; not insert)
- Legacy `Collection#count` (empty filter omits `query`); `Collection#map_reduce` (not a retryable read; inline output may use a secondary)
- Client `bulkWrite` (`Client#bulk_write`) on MongoDB 8.0; generated `_id` is first on insert and client bulkWrite; in a sharded transaction it stays on the pinned mongos
- GridFS `delete_by_name` / `rename_by_name`; `drop` on files then chunks with one CSOT deadline
- UTF: `*-let.json`, count / mapReduce, GridFS `deleteByName` / `renameByName` / `drop`, client-bulkWrite files, causal-consistency `dropDatabase` / `clientBulkWrite`; `*-rawdata.json` that need 8.2 stay pending (`count-rawdata.json` test 1 on 8.0 too)

**tls / compression / uri**
- `tlsCertificateKeyFilePassword` decrypts PKCS#8 and traditional encrypted PEM; stapled OCSP is requested unless `tlsDisableCertificateRevocationCheck` is true (no OCSP HTTP; `tlsDisableOCSPEndpointCheck` is the effective default)
- snappy and zstd OP_COMPRESSED (zstd needs libzstd / `libzstd-dev`); handshake lists usable names; zstd reuses one compress context and buffer under a mutex
- URI `compressors=snappy,zstd,zlib` (snappy first on CI); `authMechanismProperties` is `Hash(String, String)` (GSSAPI still injects `SERVICE_NAME=mongodb`)
- `enableOverloadRetargeting` deprioritizes the last server on an overload retry (not in a transaction); 34 official Deprioritized JSON files

**sessions**
- One implicit `ClientSession` per fiber; a dirty ServerSession is replaced on the next implicit command; `Client#close` ends fiber sessions before `endSessions`

**sdam**
- Shared `ApplicationError.decide` for network / timeout / command errors (legacy runner uses it)
- Monitor hello `ok: 0` and `failCommand` `closeConnection` → Unknown + pool clear; network error on a known server starts the next check at once; new monitor socket uses handshake as the check
- MongoDB 4.4+: awaitable hello + RTT fiber unless `serverMonitoringMode=poll` (or auto on FaaS); `exhaustAllowed`; each `moreToCome` is one check; application network/shutdown cancels in-progress hello (read in short slices so cancel does not `shutdown` the fd); client close wakes the RTT wait
- Awaitable deadline is `connectTimeoutMS` (default 10s) + `heartbeatFrequencyMS`; on mongod the extra is at least 1s if that sum is under 1s (unpatched 8.0 default wait ~1s; keeps `hello-timeout.json`); test topologies set `minWaitForStreamingHelloMillis=0`; mongos ticks sooner
- Heartbeat events Started / Succeeded / Failed (`awaited` for awaitable and exhaust); first check fires Started before TCP connect; RTT fiber emits none; skip objects when nobody is subscribed
- `hello.me` host replace (`localhost` vs `127.0.0.1`) does not close the application pool; checkout retries handshake network error on Unknown until the wait budget ends (connection setup, not a write retry) → `Error::Network`; full pool still uses `waitQueueTimeoutMS`
- TCP / hello network / timeout on an application socket: `SystemOverloadedError` + `RetryableError`; SDAM leaves the description and does not clear the pool; DNS and auth-after-hello do not get those labels; checkout on a known server fails at once with them
- Ignore concurrent shutdown / network when socket generation is older than the pool, or error `topologyVersion` is not newer; pool clear stays under the topology lock
- `TopologyDescription#snapshot` copies type and servers under lock; `#primary_address` is the current RSPrimary
- Pinned mongos after handshake/heartbeat network error: wait until that address is a mongos again before commit/abort; do not pick another mongos while pinned; after unpin, commit can still move (recovery token)
- Unified: `hello-*-error.json`, `hello-timeout.json`, `serverMonitoringMode.json` (standalone and sharded), handshake backpressure, non-auth `pool-clear-min-pool-size-error.json`, `find-shutdown-error.json`, `insert-shutdown-error.json`, `retryable-*-handshake.json`

**cmap**
- `poolCreatedEvent` / `poolReadyEvent` when a monitor finds a data-bearing server (load-balanced: at client init); `minPoolSize` fill in a background fiber after ready (shutdown hello 91 during fill → Unknown + pool clear)
- Load-balanced does not pre-create sockets; checkout hello errors before handshake completes are ignored
- `interruptInUseConnections` closes in-use sockets (`LibC.shutdown` + 1ms timeout, not `Socket#close` from the monitor); `PoolClearedEvent` includes the flag
- After first `poolReady`, paused checkout raises `PoolClearedError` and waits for the monitor; before first ready, checkout may handshake an Unknown seed
- Pool clear closes idle sockets (`stale`); dropping idle/stale emits `ConnectionClosed` before `ConnectionCheckedOut`; closed / check-out-failed events can carry `error`
- Unified: `minPoolSize-error.json`, `interruptInUse-pool-clear.json` (replica set and sharded)

**load balancer**
- CSOT getMore timeout: keep the pin, drain the late reply, `killCursors` on the same socket; drop a transaction pin whose pool generation is old so the next command retries handshake
- HAProxy waits until both mongos are UP, roundrobin, `UTF_RUN_TWO_MONGOS=1`
- Unified `sdam-error-handling.json` (two `serviceId`s) and CSOT `timeoutMS is refreshed for close`

**logging / auth**
- Spec components `command`, `topology`, `connection` (`serverSelection` parsed, unused); env `MONGODB_LOG_*`; UTF `observeLogMessages` / `expectLogMessages`; SDAM `logging-*.json`; CLAM matches `reply`
- Handshake and monitor hello do not emit command logs; write errors with `ok: 1` emit CommandSucceeded then raise
- CI/local users `bob` / `pwd123` on `admin` (no `--auth`); UTF `auth: true` follows URI userinfo; speculative SCRAM / X509 on first application hello; monitors stay unauthenticated
- Auth errors after hello → Unknown + pool clear (load-balanced: that `serviceId` only); unlabeled handshake network errors are not retried on checkout
- Live SCRAM prose; X509 / PLAIN need extra env; OIDC / AWS UTF stay pending unless the URI asks for that mechanism

**testing / scripts**
- UTF `recordTopologyDescription` / `assertTopologyType` / `waitForPrimaryChange`; `rediscover-quickly-after-step-down.json`; `crystal spec -Dpreview_mt -Dexecution_context` with `CRYSTAL_WORKERS=2`
- Offline compression specs; live zlib / snappy / zstd ping/insert prose
- DriverBench (`bench/driver_bench.cr`, `BENCHMARK.md`): BSON `to_h` decode, live single/multi/GridFS/fiber-parallel insert, collection and client `bulkWrite` (skipped below 8.0); JSON under `bench/results/` + `index.json`; `peers.json`; WriteBench omits the extra parallel task; missing client-task names are skipped in the mean
- GitHub MongoDB via `scripts/docker-topology.sh`; CLAM 23 UTF files; CMAP 33 cmap-format files plus UTF `connection-logging.json` / `connection-pool-options.json`; `waitQueueSize` / `waitQueueMultiple` stay skipped (deprecated)
- Wrong-topology UTF is not a Crystal example; `after_suite` does not drop leftover databases; CMAP admin client closes when CMAP examples finish
- Topology helpers in `scripts/`: 3-member replica set on 27017/27018/27019; native members `--wiredTigerCacheSizeGB 2`; `createUser` on the elected PRIMARY; `load-balanced` maps `loadBalancerPort` 27050/27051; `stop_all` SIGKILLs leftovers and removes `/tmp/mongodb-*.sock`
- Native and Docker set `minWaitForStreamingHelloMillis=0`; `run-specs.sh` / `mongo-rs.sh` can set it at runtime; `run-load-balancer.sh` removes leftover `tmp/haproxy.sock` (including root-owned) and writes `UTF_RUN_TWO_MONGOS=1`

### Changed

**pool / cmap**
- One `Sync::Exclusive` for the address-to-pool map; pool starts empty and paused; a successful SDAM check marks ready and starts `minPoolSize` fill after unlock; default `minPoolSize` is 0; per-address nested locks are gone
- Idle checkout is LIFO (failPoint and next command share a mongos under HAProxy)
- Network error (not socket timeout) bumps generation, wakes waiters with `PoolClearedError`, and keeps the pool; retryable writes handshake Unknown when no primary is known; `pool-cleared-error.json` runs

**sdam**
- `Monitor#close` uses `interrupt_and_wake` (1ms read timeout + `shutdown`) so `Client#close` does not sit out the 100ms awaitable slice, and interrupts the RTT fiber before scan wait; `cancelCheck` still uses `interrupt` only
- Socket timeout after handshake does not mark Unknown or clear the pool
- URI `serverMonitoringMode`: `auto` / `poll` / `stream` (default `auto`)
- Client close: `ServerClosedEvent` per server, then Unknown topology, then `topologyDescriptionChangedEvent` before `topologyClosedEvent`; `serverDescriptionChangedEvent` uses the current server as previous

**apm / io / gridfs / utf**
- Copy-on-write APM subscriber list; `ok: 1` is CommandSucceeded even when write errors later raise; `Selector.pick` does not build a latency-window Array
- GridFS: `insertMany` chunk batches, one find cursor on download, `read_greedy` into chunks; zero-length file does not query chunks; `update_many` accepts `deadline`
- OP_MSG / OP_REPLY / headers use `read_greedy`; short frame → `IO::EOFError`; after `BSON.view`, BSON is copied and the buffer returns to a `Channel(Bytes)` pool
- UTF outcomes sorted `{_id: 1}`; `$$type: double` matches `$numberDouble`; `waitForEvent` also counts `connectionReadyEvent`, checkout started/failed, `poolClosedEvent`
- Find UTF: `projection`, `max`, `min`, `return_key`, `show_record_id`; Atlas Search index ops stay `SKIP_TEST`
- Handshake-error and SDAM auth files run when the URI has credentials; cmap-format `failCommand` uses the same `directConnection` host as the pool; GitHub URI `compressors=snappy,zstd,zlib`
- Added UTF files run when `runOnRequirements` match; next 8.0 work is Phase 3.14 (`FIXES.md` / `ROADMAP.md`)

### Fixed
- Commit / abort and retryable writes still send `lsid`, `txnNumber`, and `autocommit` after network or state-change errors (including Unknown, and sharded with the only mongos Unknown and session timeout cleared)
- Commit retry keeps `j` / `wtimeout` and sets `w` to majority; handshake rediscovers Unknown instead of “retryable writes off”; standalone writes omit `txnNumber`; sharded commit retry may use another known mongos
- Subscribe to SDAM before monitors start; `waitForEvent` counts `topologyDescriptionChangedEvent`
- Short socket read after `read_greedy` is `IO::EOFError` again (a generic `Mongo::Error` skipped retry and pool clear on `closeConnection`)
- Zero-length GridFS download does not query chunks; an extra empty chunk is ignored

## 0.16.0 - 2026-08-20

Phase 2: cloud, GridFS UTF, SASLprep, CSOT, load-balanced full spec. GitHub `crystal spec` is green on standalone, replica set, sharded, and load-balanced.

### Added

**auth / uri**
- SASLprep (RFC 4013) for SCRAM-SHA-256 passwords; printable ASCII is unchanged (no extra allocation); usernames are not prepared
- `timeoutMS` (CSOT deadline), `srvMaxHosts`, `srvServiceName`; `timeoutMS=0` means infinite; negative `timeoutMS` is rejected
- `mongodb+srv` URI validation for `loadBalanced`, `replicaSet`, and `directConnection`

**sdam / csot**
- SRV polling for `mongodb+srv://` on Sharded or Unknown (add/remove mongos; not in load-balanced mode); last 10 RTT samples for CSOT min RTT
- Remaining `timeoutMS` minus min RTT → `maxTimeMS`; server 50 (`MaxTimeMSExpired`) → `Error::Timeout`; `timeoutMS=0` retries forever; `wTimeoutMS` omitted when `timeoutMS` is set; wait-queue timeout is `Error::Timeout` when `timeoutMS` is set
- `timeoutMS` on client, database, collection, CRUD, indexes, GridFS, commit, and abort; `timeoutMode` (`cursorLifetime` / `iteration`) on find, aggregate, listCollections, listIndexes
- Tailable awaitData: `maxTimeMS` on find, `maxAwaitTimeMS` on getMore; change streams use iteration timeouts and resume in the same `next`; GridFS uses one deadline for the whole upload/download (including `listIndexes`)
- Official CSOT UTF: 28 files

**run command**
- `Database#run_command` and `#run_cursor_command`; the caller’s document is copied; not retryable; database read/write concern is not applied
- `timeoutMode` and `cursorType` follow CSOT; `batch_size`, `comment`, and `max_time_ms` go on getMore only
- Official run-command UTF is copied

**load balancer**
- Do not pre-create `minPoolSize` sockets; require `serviceId` on hello
- Pin the TCP socket for a transaction and for an open cursor; unpin returns the socket to the pool; pool generation is per `serviceId`
- Wait-queue timeout lists cursor / transaction / other in-use counts; `poolClearedEvent` and command events include `serviceId`
- CMAP `connectionReadyEvent` and `connectionClosedEvent` with a reason; UTF `assertNumberConnectionsCheckedOut`
- Official load-balancer UTF runs (except the JSON `skipReason` file and one per-`serviceId` test that needs two mongos from HAProxy)

**change streams**
- `watch` sends `comment` on aggregate and getMore (string or document); `showExpandedEvents` and `fullDocumentBeforeChange` go on `$changeStream`
- A labeled getMore error resumes with a new aggregate (getMore is not a retryable read)
- `maxAwaitTimeMS` must be less than `timeoutMS` when both are set

**testing**
- UTF ops: `iterateUntilDocumentOrError`, `iterateOnce`, `createFindCursor`, `runCursorCommand`, `createCommandCursor`, GridFS `upload` / `delete` / `rename`, `dropIndex` / `dropIndexes`, `assertNumberConnectionsCheckedOut`
- Official GridFS, collection-management, index-management, run-command, and CSOT JSON
- CLAM `redacted-commands.json` and CRUD `create-null-ids.json` run
- GitHub uploads `tmp/utf-timing.log`; GitHub load-balanced runs full `crystal spec` (HAProxy via `spec/support/run-load-balancer.sh`)

### Changed
- Cursor `finalize` no longer sends `killCursors` or touches the pool (GC thread); call `#close`, `#each`, or a block `find`
- Load-balanced topology does not start monitor sockets; sessions and retryable reads/writes are always allowed (hello fields stay unset without monitors)
- `getMore` is not retried as a retryable read; overload retry still runs
- `timeoutMode` iteration starts a fresh `timeoutMS` on each `next` / `try_next` (change streams still own the deadline for resume)
- HAProxy multi-mongos uses roundrobin and health-checks the normal mongos ports (not the PROXY v2 ports)

### Fixed
- Upsert reply with `_id: null` deserializes; duplicate-key write errors expose `code`
- GridFS `rename` errors when the file id is missing; UTF `downloadByName` honors `revision`
- UTF matcher: `$date` canonical vs relaxed; `$$type` int/long with `$numberInt`
- Find omits `tailable` and `awaitData` unless they are true (`tailable: false` broke Versioned API strict)
- A `runCommand` reply with a cursor id pins the load-balanced socket (raw BSON scanned for `cursor.id`)
- UTF `createCollection` stores the collection entity and sends `capped` / `size` / `max`
- `runCommand` does not send `$readPreference` to a standalone, even when the caller asked for a non-primary mode
- `getMore` and `killCursors` do not get `readConcern` / `afterClusterTime` (explicit causal sessions)

## 0.15.0 - 2026-08-20

Phase 1 of the roadmap.

### Added
- **security:** Redact `authenticate`, `saslStart`, `saslContinue`, `createUser`, `updateUser`, `getnonce`, `copydb*`, and hello with `speculativeAuthenticate` in APM events and `Log.trace`
- **handshake:** `backpressure: "2"`, OS name / architecture / version, platform, optional env metadata; first handshake uses legacy hello when Server API and load-balanced are unset; `Client#append_metadata` for wrapping libraries
- **cursors:** `#each` and block `Collection#find` close the cursor; do not rely on `finalize` for `killCursors`
- **backpressure:** Retry `SystemOverloadedError` + `RetryableError` with exponential backoff; URI `maxAdaptiveRetries` (default 2)
- **cmap:** Pool events (`poolClearedEvent`, checkout / checkin); retry `PoolClearedError` on retryable writes and reads
- **selection:** Shared `Mongo::SDAM::Selector` plus official server-selection, max-staleness, and RTT JSON tests (no mongod)
- **testing:** Prose for transaction write concern, SDAM RTT, PoolCleared retry, backpressure, and find/getMore; UTF `waitForEvent`, `assertEventCount`, `wait`, `close`, `appendMetadata`
- **ci:** GitHub Actions matrix for standalone, replica set, and sharded; local `scripts/mongo-topology.sh`; `TOPOLOGY` selects the default URI

### Changed
- Network errors on a command request an immediate monitor scan so the server can be rediscovered faster

### Fixed
- **uri:** Options after the host with no delimiting slash parse (`mongodb://localhost:27017?k=v`); the old parse kept a trailing `/` in the last option value
- **ci:** mongos no longer receives `transactionLifetimeLimitSeconds` (mongod-only); spec helpers append `/?` when they add URI options
- **testing:** Map `TOPOLOGY=standalone` to UTF topology `single`; skip or split `useMultipleMongoses` from the URI; sharded CI starts two mongos; prose uses one mongos so failCommand matches the operation; turn failCommand off on every mongos in `ensure`; UTF setup uses majority write concern
- **transactions:** Copy `errorLabels` from the reply and from `writeConcernError`; unpin a mongos session on startTransaction, when a non-transaction operation uses the session, and when commit fails with TransientTransactionError; stay pinned after UnknownTransactionCommitResult; after closeConnection, wait for that mongos to be rediscovered instead of skipping the commit retry
- **utf:** Setup uses the internal client and majority writes, then copies cluster time and refreshes each mongos catalog so test-client pools stay empty; `killAllSessions` on every mongos after each test
- **retryable reads:** After a retryable error on standalone, do not abort the retry just because the only server is temporarily Unknown; handshake rediscovers it; catch wrapped `Error::Network` as `Mongo::Error`
- **sdam:** An immediate monitor scan is not dropped when the monitor is already in `hello`; a flag makes the next loop check again instead of waiting a full heartbeat
- **sessions:** `Session::Pool#close` no longer holds the pool mutex while sending `endSessions` (nested lock plus IO caused GitHub sharded `signal 11`)

## 0.14.0 - 2026-08-19

Driver on BSON **v0.8.1**.

### Changed
- **bson:** Command bodies use one `BSON.append` for options and session fields; receive reads documents with `BSON.view` over the OP_MSG buffer; `copy_with` is one builder pass
- **hello:** `lastWrite` is a typed document; `lastWriteDate` is `BSON::DateTime` on the wire and becomes `Time` for max-staleness
- **apm:** `safe_payload` builds a new document and does not mutate the live reply (`BSON.new(BSON)` is a no-op)
- **utf:** Date match accepts both canonical `$numberLong` and relaxed ISO `$date`
- **insert:** `inserted_ids` is ignored on BSON decode (the server does not send this field)
- **bson.cr:** `Serializable` / `Array` / `Hash` can deserialize `BSON::Value` after 0.8.0 (no duplicate `when BSON::DateTime`); alumna/bson.cr v0.8.1

### Fixed
- Replica-set hello no longer raises `TypeCastError` on `lastWriteDate`
- Removed unused `UNACKNOWLEDGED_WRITE_PROHIBITED_OPTIONS`; unack writes still omit `lsid` and still send `hint` / `collation` / `arrayFilters`

## 0.13.0 - 2026-08-17

Correctness for MongoDB 8.0 and Crystal 1.21, before the roadmap phases.

### Added
- **insert:** Client-generated `_id` and `insertedIds`; `insertMany` is one retryable command
- **gridfs:** `session:` on all methods; stream `#close` waits for the background fiber
- **testing:** Honest UTF runner (results, errors, events, outcomes); local `scripts/mongo-rs.sh` and `LOCAL_TESTING.md`

### Changed
- **cursors / change streams:** Pin session and server; tailable streams stay open on an empty getMore; `find` honors `limit`; `getMore` can retry
- **sessions / transactions:** One implicit session for a whole bulk; empty commit is reset; cluster time and txn numbers are locked
- **sdam / selection:** `Time.instant` for selection, monitor cooldown, and session idle; `serverSelectionTryOnce` works (default `false`); stale `topologyVersion` errors do not mark Unknown
- **uri / tls / pool:** Case-insensitive URI bools, typed `loadBalanced`, `maxIdleTimeMS`, hostname TLS flags
- **crystal:** `Sync::Mutex`, `Time.instant`, no `spawn(same_thread:)`, no `.not_nil!`
- **testing:** Live UTF is 362 examples, 0 failures, about 5.5 minutes (was ~25); unknown work is `pending`, not a fake pass

### Fixed
- GridFS chunk math, index names, and optional metadata; counts return `Int64`; timeout units; tag-set match; `list*` can use a secondary
- Monitor close, APM request ids, APM callbacks without the list lock, client close ends sessions first

## 0.12.0 - 2026-07-30

### Added
- **versioned-api:** `ServerApi` version, strict mode, and deprecation errors on the client
- **auth:** `MONGODB-X509` and `PLAIN` (LDAP)
- **testing:** Legacy authentication runner (`Mongo::SpecSharding`); Versioned API unified runner

### Changed
- **uri:** Last value wins when an option occurs multiple times (spec); Unix socket paths keep original case

### Fixed
- **uri:** Safe string splits (no out-of-bounds); `query_params` isolated during parse

## 0.11.0 - 2026-07-30

### Added
- **testing:** `Mongo::SpecSharding` divides tests by file size across CI runners

### Changed
- **architecture:** Data models separated from logic in `Bulk` and `GridFS`; UTF runner separates routing from operations
- **performance:** CI duration 19 min → 5.5 min; default test log `:debug` → `:info`; sharding size map uses a tuple (Schwartzian Transform) to avoid extra OS calls

### Fixed
- UTF runner deletes all collections between tests (`E11000`); `CI_SHARD` applied to legacy SDAM tests

## 0.10.0 - 2026-07-27

### Added
- **sdam:** Publish/Subscribe events: `TopologyOpeningEvent`, `TopologyDescriptionChangedEvent`, `ServerOpeningEvent`, `ServerClosedEvent`, `ServerDescriptionChangedEvent`, `TopologyClosedEvent`
- **sdam:** `LoadBalanced` topology and `LoadBalancer` server type
- **testing:** `spec/sdam_runner_spec.cr` checks topology type and set name for the legacy SDAM suite (event body and live pool-generation rules still incomplete)

### Changed
- **performance:** `Mongo::Client` uses instance locks (`@`) instead of class-level `@@`; `Mongo::Connection::Pool` checkout holds locks for a shorter time (less starvation during I/O and auth)
- **testing:** `spec/tests/unified/` vs `spec/tests/legacy/`

### Fixed
- **connection:** IPv6 with brackets (`[::1]`): keep brackets for SDAM matching, strip at socket (fixes `TCPSocket` and OpenSSL hostname)
- **sdam:** `logical_session_timeout_minutes` clears when the cluster loses the last data-bearing node
- **sdam:** MongoDB 6.0+ staleness: `electionId` before `setVersion` when wire version >= 17
- **sdam:** `ServerClosedEvent` when the primary host list removes a server
- **sdam:** `ok: 0.0` forces `Unknown` even if the payload has `isWritablePrimary`
- **uri:** Strict percent-decoding (not `x-www-form-urlencoded`); `+` in a database name stays `+`

## 0.9.0 - 2026-07-25

### Added
- **sdam:** Strict `topologyVersion` tracking on `ServerDescription`, network errors, and `Mongo::Error`
- **sdam:** `Mongo::Error::PoolCleared` wakes waiting fibers when the pool is purged
- **spec:** UTF Dispatcher `runOnThread` / `waitForThread`; official SDAM UTF suite

### Changed
- **sdam:** `TopologyDescription#update` compares `topologyVersion` and discards stale heartbeats

### Fixed
- **connection:** `connectTimeoutMS=0` maps to `nil` (Crystal `TCPSocket` infinite timeout)
- **cmap:** Pool clear during `checkout` wakes waiters with `Channel::ClosedError` so CMAP retry can start (no wait until timeout)

## 0.8.0 - 2026-07-22

### Added
- **sessions:** MongoDB 5.0+ snapshot reads (`snapshot: true`, `snapshot_time`)
- **causal-consistency:** `afterClusterTime` on write commands outside transactions (`insert`, `update`, `delete`, `findAndModify`, `bulkWrite`)
- **sessions:** `SessionOptions` rejects `snapshot` with `causal_consistency`, requires `snapshot` when `snapshot_time` is set, and rejects `start_transaction` on snapshot sessions
- **testing:** UTF `getSnapshotTime`, `assertSessionDirty` / `NotDirty`, `assertSameLsidOnLastTwoCommands` / `assertDifferentLsidOnLastTwoCommands`

### Fixed
- Snapshot sessions require `maxWireVersion >= 13` (MongoDB 5.0+); clear client error if the topology does not support it
- BSON replies extract `atClusterTime` from top-level and from `cursor` documents

## 0.7.0 - 2026-07-20

### Added
- **dependencies:** `jgaskins/pipe` (user-space pipe instead of kernel `IO.pipe`) for GridFS streaming

### Changed
- **architecture:** `Mongo::Client` and `Mongo::Collection` split into `src/cryomongo/client/*` and `src/cryomongo/collection/*`
- **performance:** OP_MSG / OP_REPLY use length-prefixed `read_fully`, read-only `IO::Memory`, and `memchr` / `gets('\0')` (no intermediate `Bytes`)
- **performance:** Request IDs use lock-free `Atomic(Int32)` instead of a `Mutex`
- **performance:** BSON build, read-preference tags, and topology filtering use single-pass logic, lazy iterators, and `String.build`
- **modernization:** `Sync::Mutex` (Crystal 1.20+) for parallel execution contexts
- **testing:** UTF runner split into `spec/unified/` with a dedicated Dispatcher

### Fixed
- Unsafe unboxings replaced with type-narrowing and explicit `Mongo::Error`
- Off-by-4 in `OP_MSG` sequence size (wire protocol)
- `Error::Command#message` always returns a `String`; duplicate error codes removed

## 0.6.0 - 2026-07-17

### Added
- **transactions:** MongoDB 4.0+ core transactions and 4.2+ `with_transaction`; 120s fallback timeouts; exponential backoff with jitter; retry on `TransientTransactionError` and `UnknownTransactionCommitResult`
- **spec:** Official UTF `transactions` and `transactions-convenient-api` (324 tests pass)
- **commands:** `Mongo::Commands::MayUseSecondary` on `RawCommand` so raw commands can use secondary read preference inside transactions

### Fixed
- `@options.socket_timeout` and `@options.connect_timeout` go to `TCPSocket` and `UNIXSocket`
- Monitor `Mongo::Connection` instances use the connection timeout (server monitoring spec)
- UTF `Session` entity parsing and `ConfigureFailPoint` database targeting

### Removed
- Unused development dependency `crystal-ameba/ameba` (Crystal 1.21+)

## 0.5.0 - 2026-07-16

### Added
- Official UTF runner (replaces the legacy suite); synced `crud`, `retryable-reads`, and `retryable-writes`
- Top-level `errorLabels` (for example `RetryableWriteError`) from `OP_MSG` onto `Mongo::Error`
- Error codes `133` and `134` (`ReadConcernMajorityNotAvailableYet`) in `RETRYABLE_READ_CODES`

### Changed
- Unacknowledged writes omit `lsid`; `hint` is still validated on old servers; other prohibited options are sent as-is (UTF does not want a client-side raise)

### Fixed
- UTF runner disables `failCommand` and `onPrimaryTransactionalWrite` between tests (stops `EOFError` leaks)

## 0.4.0 - 2026-07-14

### Added
- `Mongo::Client::MAX_WIRE_VERSION` 25 (MongoDB 8.0)
- GitHub Actions `specs.yml` on `ubuntu-24.04` against persistent MongoDB 8.0 Docker replica set
- UTF-based test runner; CRUD unified tests from the latest spec pass

### Changed
- Minimum Crystal `>= 1.20.0`
- `Time.instant` instead of `Time.monotonic`
- GridFS: no `same_thread: true` on fiber spawns (Crystal 1.20 execution contexts)
