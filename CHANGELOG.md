# Changelog

## Unreleased

Phase 3 of the roadmap is done. Remaining 8.0 work is Phase 3.13–3.14.

**3.13.1:** Audit of leftover skips and GitHub pending lists. Almost all pending UTF files are `runOnRequirements` (wrong topology, `auth: false`, old `maxServerVersion`) or official `skipReason`. The leftover `skip_op` holes were UTF `dropDatabase` and GridFS `drop`. `Database#drop` and `Collection#drop` send those commands. GridFS `drop` now drops the files collection then the chunks collection and shares one CSOT deadline. CMAP `waitQueueSize` / `waitQueueMultiple` stay skipped (deprecated; the spec allows that skip).

**3.12:** TLS `tlsCertificateKeyFilePassword` loads PKCS#8 and traditional encrypted PEM. Stapled OCSP is requested unless `tlsDisableCertificateRevocationCheck` is true (this driver does not contact OCSP HTTP endpoints). `authMechanismProperties` is a Hash on Credentials. snappy and zstd OP_COMPRESSED (zstd needs libzstd; GitHub installs `libzstd-dev`). `enableOverloadRetargeting` drops the last server on an overload retry (34 Deprioritized JSON files). One implicit session per fiber. After `BSON.view`, BSON is copied and the OP_MSG buffer returns to the Channel pool. Shared SDAM `ApplicationError.decide` for the legacy runner and production. Load-balanced CSOT keeps the pin after a getMore timeout, drains the late reply, and sends `killCursors` on the same socket (`timeoutMS is refreshed for close`). HAProxy waits until both mongos backends are UP, uses roundrobin, and sets `UTF_RUN_TWO_MONGOS=1`. Idle pool checkout is LIFO so a failPoint and the next command share one mongos. GitHub URI lists `compressors=snappy,zstd,zlib` (snappy first). `Client#close` wakes awaitable hello with a 1ms read timeout plus `shutdown` (`interrupt_and_wake`).

**3.11:** Spec log components (`command`, `topology`, `connection`; `serverSelection` is parsed and unused). Env `MONGODB_LOG_COMMAND`, `MONGODB_LOG_TOPOLOGY`, `MONGODB_LOG_SERVER_SELECTION`, `MONGODB_LOG_CONNECTION`, `MONGODB_LOG_ALL`, `MONGODB_LOG_PATH`, `MONGODB_LOG_MAX_DOCUMENT_LENGTH`. UTF `observeLogMessages` / `expectLogMessages`. Unified SDAM `logging-standalone.json`, `logging-replicaset.json`, `logging-sharded.json`, `logging-loadbalanced.json` run. CLAM is 23 files; succeeded / failed events match `reply`. Write errors with `ok: 1` emit CommandSucceeded (then raise). Official CMAP: 33 cmap-format files plus UTF `connection-logging.json` / `connection-pool-options.json`. cmap-format `failCommand` uses the same `directConnection` host as the pool (a replica-set admin client with `replicaSet=rs0` was setting the fail point on the primary while the pool talked to 27017). Client close emits `ServerClosedEvent` before the Unknown topology change. Pool clear closes idle sockets; checkout emits stale / idle `ConnectionClosed` before `ConnectionCheckedOut`. Hello 91 during minPoolSize fill still clears the pool; checkout hello errors before handshake completes are ignored (load-balancer SDAM).

**3.10:** Users on CI and local topologies (`bob` / `pwd123` on `admin`, no `--auth`). UTF `auth: true` follows URI userinfo. Speculative SCRAM / X509 on the first application hello. Auth errors after hello mark Unknown and clear the pool (load-balanced: that `serviceId` only). Monitors stay unauthenticated (SDAM). Checkout does not retry unlabeled handshake network errors (retryable reads/writes start a new checkout). Unified handshake-error files and SDAM auth-error files run. Live SCRAM prose; X509 / PLAIN need extra env. OIDC / AWS UTF stays pending unless the URI asks for that mechanism. Docker replica set waits for a writable primary on 27017/27018/27019 before `createUser` (27017 is often a secondary). Client `bulkWrite` in a sharded transaction stays on the pinned mongos (a second random pick hit the other router and `mongos-pin-auto.json` saw NoSuchTransaction 251).

**3.9:** Client `bulkWrite` (`Mongo::Client#bulk_write`, mixed namespaces, MongoDB 8.0). UTF `crud/client-bulkWrite-*.json`, `retryable-writes/client-bulkWrite-*.json`, `transactions/client-bulkWrite.json`, `causal-consistency-clientBulkWrite.json`. CRUD prose 3–9, 11, 12, 15, 16. Generated `_id` is the first field on insert and client bulkWrite.

**3.8:** `let` on find / aggregate / updates / deletes / findOneAnd* / collection `bulkWrite` (not insert). Legacy `count` helper. `mapReduce` helper (not retryable; Crystal `output:`). GridFS `delete_by_name` / `rename_by_name`. UTF matcher accepts `$numberDouble` as `$$type: double`.

**3.7:** UTF `waitForPrimaryChange` / `recordTopologyDescription` / `assertTopologyType`. Unified `rediscover-quickly-after-step-down.json` runs on replica set. Native and Docker `replicaset` topologies are 3 members, so `replicaset-emit-topology-changed-before-close.json` also runs.

**3.6:** Ignore stale-generation application errors so two concurrent shutdowns emit one Unknown and one `poolClearedEvent`. Unified `find-shutdown-error.json` and `insert-shutdown-error.json` run on standalone, replica set, and sharded.

**3.5:** Pool clear with `interruptInUseConnections` closes in-use sockets. Unified `interruptInUse-pool-clear.json` runs on replica set and sharded.

**3.4:** Handshake backpressure labels (`SystemOverloadedError` + `RetryableError`) on TCP / hello network and timeout.

**3.3:** Monitor heartbeat events (`ServerHeartbeatStartedEvent` / `Succeeded` / `Failed`) and `serverMonitoringMode` UTF.

**3.2:** Monitor hello command and network errors.

**3.1:** CMAP pool at discovery (`poolCreatedEvent` / `poolReadyEvent`, background `minPoolSize`). Local `crystal spec -Dpreview_mt -Dexecution_context` with `CRYSTAL_WORKERS=2`.

Number of examples after 3.12: **905** (859 after 3.11 plus 34 Deprioritized selection files, compression, and TLS password specs). After 3.11: **859** (802 after 3.10 plus 22 CLAM, 2 CMAP UTF, 33 cmap-format). After 3.9: **796** (785 after 3.8 plus 11 client bulkWrite prose).

GitHub Docker - Phase 3.9 (`CRYSTAL_WORKERS=2`): standalone **2:22 / 168 pending**, replica set **6:45 / 47 pending**, sharded **8:26 / 57 pending**, load-balanced **5:39 / 96 pending**. 0 failures, 0 errors. 

GitHub Docker - Phase 3.12 after close-wake + snappy-first: **905** examples, 0 failures, 0 errors. Standalone **1:59 / 167 pending**, replica set **4:26 / 45 pending**, sharded **6:56 / 56 pending**, load-balanced **4:24 / 102 pending**. The run before those two changes was 2:59 / 7:45 / 12:20 / 6:35. Pending counts match 3.11. Local 3.12 before close-wake: standalone **2:55 / 167**, replica set **7:24 / 45**, load-balanced **6:28 / 102**.

GitHub Docker - Phase 3.11: **859** examples, 0 failures, 0 errors. Standalone **2:55 / 167 pending**, replica set **7:25 / 45 pending**, sharded **9:24 / 56 pending**, load-balanced **6:26 / 102 pending**. cmap-format `failCommand` uses the same `directConnection` host as the pool. Native `mongo-topology.sh replicaset` waits for a PRIMARY, not only 3 data-bearing members.

mongod 8.0 default awaitable hello wait is ~1s; test topologies set `minWaitForStreamingHelloMillis=0`. The awaitable socket extra is still at least 1s on non-mongos when the spec sum is under 1s.

### Added
* **crud:** `Database#drop` (`dropDatabase`). `Collection#drop` (`drop`; NamespaceNotFound is ignored).
* **tls:** `tlsCertificateKeyFilePassword` decrypts PKCS#8 and traditional encrypted PEM (`PEM_read_bio_PrivateKey`). Stapled OCSP is requested unless `tlsDisableCertificateRevocationCheck` is true. This driver does not contact OCSP HTTP endpoints (`tlsDisableOCSPEndpointCheck` is the effective default).
* **compression:** snappy and zstd OP_COMPRESSED. Handshake lists names the driver can use. zstd reuses one compress context and output buffer under a mutex. GitHub installs `libzstd-dev`. URI `compressors=snappy,zstd,zlib` (snappy first on CI; zlib and zstd still run in compression prose).
* **uri:** `authMechanismProperties` is a `Hash(String, String)` on Credentials. GSSAPI still injects `SERVICE_NAME=mongodb`. `enableOverloadRetargeting` deprioritizes the last server on an overload retry (not in a transaction). Official Deprioritized server-selection JSON is copied (34 files).
* **sessions:** One implicit `ClientSession` per fiber. A dirty ServerSession is replaced on the next implicit command. `Client#close` ends fiber sessions before `endSessions`.
* **sdam:** Shared `ApplicationError.decide` for network / timeout / command application errors. The legacy SDAM runner uses it.
* **load balancer:** After a CSOT getMore timeout, keep the pin, drain the late reply, and send `killCursors` on the same socket. HAProxy waits until both mongos backends are UP, uses roundrobin, and sets `UTF_RUN_TWO_MONGOS=1`. Unified `sdam-error-handling.json` (two `serviceId`s) and CSOT `timeoutMS is refreshed for close` run on load-balanced.
* **cmap:** `poolCreatedEvent` and `poolReadyEvent`. The pool is created when a monitor check finds a data-bearing server (load-balanced: at client init). `minPoolSize` is filled in a background fiber after ready. A shutdown hello (code 91) during that fill marks the server Unknown and clears the pool. Checkout hello errors before handshake completes are ignored (load-balancer SDAM). Unified `minPoolSize-error.json` runs. Load-balanced still does not pre-create sockets. Pool clear with `interruptInUseConnections` closes in-use sockets (`LibC.shutdown` plus a 1ms timeout; not `Socket#close` from the monitor). `PoolClearedEvent` includes that flag. After the first `poolReady`, checkout while paused raises `PoolClearedError` and waits for the monitor (does not mark Unknown). Before the first ready, checkout may still handshake an Unknown seed. Unified `interruptInUse-pool-clear.json` runs on replica set and sharded. Pool clear closes idle sockets (`stale`). Checkout that drops an idle or stale socket emits `ConnectionClosed` before `ConnectionCheckedOut`. `ConnectionClosedEvent` / `ConnectionCheckOutFailedEvent` can carry `error` for CMAP logs.
* **sdam:** Monitor hello command errors (`ok: 0`) and network errors (`failCommand` `closeConnection`) mark the server Unknown and clear the pool. A network error on a known server starts the next check at once. A new monitor socket uses the handshake as the check (no second hello). MongoDB 4.4+ uses awaitable hello plus an RTT fiber, unless `serverMonitoringMode=poll` (or auto on FaaS). Awaitable hello sets OP_MSG `exhaustAllowed` and treats each `moreToCome` reply as one check. An application network or shutdown error cancels the in-progress monitor hello. Awaitable hello is read in short slices so cancel does not `shutdown` a monitor fd. Client close wakes the RTT wait channel so it does not sit out `heartbeatFrequencyMS`. Awaitable hello uses `connectTimeoutMS` (default 10s) plus `heartbeatFrequencyMS` as the overall read deadline. On mongod the extra is at least 1s when that sum is under 1s, so an unpatched MongoDB 8.0 (default hello wait ~1s) does not fail `hello-timeout.json`. Test topologies set `minWaitForStreamingHelloMillis=0`. mongos ticks sooner and keeps the spec sum. Monitor scan does not close the application pool when `hello.me` replaces the seed host (`localhost` vs `127.0.0.1`), so an in-use insert is not closed. Application checkout retries a handshake network error on an Unknown server until the wait budget ends (Single topology can select Unknown while leftover `failCommand` `closeConnection` is still on). That retry is connection setup, not a write retry. Handshake I/O errors become `Error::Network`. The pool still uses `waitQueueTimeoutMS` for a full pool. Unified `hello-command-error.json`, `hello-network-error.json`, and `hello-timeout.json` run. Monitor checks emit `ServerHeartbeatStartedEvent`, `ServerHeartbeatSucceededEvent`, and `ServerHeartbeatFailedEvent`. `awaited` is true for awaitable hello and exhaust `moreToCome` reads. The first check on a new socket fires Started before the TCP connect. The RTT fiber does not emit heartbeat events. Heartbeat objects (and the hello reply BSON) are skipped when nobody is subscribed. Unified `serverMonitoringMode.json` runs on standalone and sharded (`runOnRequirements`; not replica set or load-balanced). TCP connect and hello network / timeout on an application socket get `SystemOverloadedError` and `RetryableError`. SDAM then leaves the server description and does not clear the pool. DNS lookup failures and auth after hello do not get those labels. Checkout on a known server fails at once with those labels. Unified handshake backpressure files run. The non-auth test in `pool-clear-min-pool-size-error.json` runs. A concurrent application shutdown or network error is ignored when the socket generation is older than the pool, or when the error `topologyVersion` is not newer than the live server. Pool clear stays under the topology lock with that check. Unified `find-shutdown-error.json` and `insert-shutdown-error.json` run on standalone, replica set, and sharded. `TopologyDescription#snapshot` copies type and servers under the topology lock. `#primary_address` returns the current RSPrimary host.
* **crud:** `let` on find, aggregate (collection and database), update / replace / delete, findOneAnd*, and collection `bulkWrite` (update and delete groups only). Legacy `Collection#count` (empty filter omits `query`). `Collection#map_reduce` (not a retryable read; inline output may use a secondary). Unified CRUD `*-let.json`, `aggregate-let.json`, `count.json`, `count-collation.json`, `count-empty.json`, retryable-reads `count.json` / `count-serverErrors.json` / `mapReduce.json`, and transactions `count.json` run. `count-rawdata.json` test 1 stays pending on 8.0 (needs 8.2). Client `bulkWrite` (`Client#bulk_write`) on MongoDB 8.0. Unified `client-bulkWrite-*.json`, retryable-writes / transactions client bulkWrite files, and `causal-consistency-clientBulkWrite.json` run. `*-rawdata.json` tests that need 8.2 stay pending. In a sharded transaction, client `bulkWrite` uses the pinned mongos instead of a second random pick.
* **gridfs:** `delete_by_name` and `rename_by_name`. Unified `deleteByName.json` and `renameByName.json` run. `drop` sends `drop` on the files collection first, then the chunks collection, with one CSOT deadline. UTF `drop` and causal-consistency `dropDatabase` run.
* **logging:** Spec components `command`, `topology`, `connection` (and `serverSelection`, unused). Env `MONGODB_LOG_*`. UTF `observeLogMessages` / `expectLogMessages`. Unified SDAM `logging-*.json` runs. CLAM UTF matches `reply`. Handshake and monitor hello do not emit command logs.
* **testing:** UTF `recordTopologyDescription`, `assertTopologyType`, and `waitForPrimaryChange`. Unified `rediscover-quickly-after-step-down.json` runs. `crystal spec -Dpreview_mt -Dexecution_context` with `CRYSTAL_WORKERS=2` so the default execution context is resized. Offline compression specs. Live zlib / snappy / zstd ping/insert prose. DriverBench (`bench/driver_bench.cr`, `BENCHMARK.md`): BSON encode/decode (`to_h` for decode), live single-doc / multi-doc / GridFS / fiber-parallel insert, collection `bulkWrite`, and client `bulkWrite` (insert and mixed; skipped below MongoDB 8.0). Each run writes `bench/results/<utc>-<mode>-<topology>.json` and updates `index.json`. Latest full `--release` snapshot is `2026-08-23T203227Z-full-replica-set.json`. `peers.json` holds published Node / Java / Python / Go numbers. WriteBench no longer includes the extra parallel task. Missing client-task names are skipped in the mean so older JSON still composites. GitHub starts MongoDB through `scripts/docker-topology.sh`. Official CLAM is 23 UTF files. Official CMAP is 33 cmap-format files (`spec/cmap_runner_spec.cr`) plus UTF `connection-logging.json` / `connection-pool-options.json`.
* **scripts:** Topology helpers at `scripts/` (native and Docker). Replica set is 3 members on 27017/27018/27019. Native replica set members start with `--wiredTigerCacheSizeGB 2` so three members fit ~27 GiB RAM (default cache is ~50% of RAM per process). Docker replica set `createUser` runs on the elected primary (poll `hello` on all three ports; do not `quit(1)` from 27017 under `set -e`). Native `replicaset` waits for a PRIMARY plus 3 data-bearing members before `createUser`. `load-balanced` maps mongos `loadBalancerPort` 27050/27051. `stop_all` waits, then SIGKILL leftover mongos / shard / config / `rs0` processes, and removes `/tmp/mongodb-*.sock` so systemd mongod can bind 27017. Native and Docker topologies set `minWaitForStreamingHelloMillis=0` so awaitable hello honors `maxAwaitTimeMS`. Runtime `setParameter` in `run-specs.sh` / `mongo-rs.sh` covers an old mongod.conf. mongos 8.0 accepts that parameter. `spec/support/run-load-balancer.sh` removes a leftover `tmp/haproxy.sock` (including one owned by root) so HAProxy can bind again. It waits until both mongos backends are UP and writes `UTF_RUN_TWO_MONGOS=1` into `tmp/lb-uri.env`.

### Changed
* **pool:** One lock for the address-to-pool map (`Sync::Exclusive`). The pool is created empty and paused under that lock. A successful SDAM check marks it ready and starts `minPoolSize` fill after unlock. Default `minPoolSize` is 0 (CMAP spec). Per-address nested locks are gone. Idle checkout is LIFO so a failPoint and the next command reuse the same mongos under HAProxy.
* **cmap:** A network error (not a socket timeout) bumps pool generation, wakes waiters with `PoolClearedError`, and keeps the pool. The pool is not deleted. Retryable writes handshake an Unknown member when no primary is known. Unified `pool-cleared-error.json` runs.
* **sdam:** `Monitor#close` calls `interrupt_and_wake` (1ms read timeout plus `shutdown`) so `Client#close` does not sit out the 100ms awaitable-hello slice. `cancelCheck` still uses `interrupt` only. A socket timeout after handshake does not mark the server Unknown and does not clear the pool (slow operation, not a dead server). URI `serverMonitoringMode` is `auto` / `poll` / `stream` (default `auto`). Client close emits `ServerClosedEvent` for each server, then sets the topology type to Unknown and replaces each server with an Unknown description, then emits `topologyDescriptionChangedEvent` before `topologyClosedEvent`. `serverDescriptionChangedEvent` uses the current server as previous, not the description from when the command started.
* **apm:** `Monitoring::Observable` uses a copy-on-write subscriber list. Broadcast does not dup the list on every event. A reply with `ok: 1` is CommandSucceeded even when write errors later raise.
* **selection:** `Selector.pick` does not build a latency-window Array.
* **gridfs:** Upload sends chunk `insertMany` batches. Download reads chunks with one find cursor. Upload fills each chunk with `read_greedy`. A zero-length file does not query chunks. `update_many` accepts `deadline` so GridFS CSOT can pass it through `rename_by_name`.
* **io:** OP_MSG / OP_REPLY / header reads use `read_greedy`. A short frame raises `IO::EOFError` (same as `read_fully`) so retryable reads/writes and pool clear still treat it as a network error. A `Channel(Bytes)` pool lends receive buffers. After parse, BSON is copied and the buffer returns to the pool.
* **utf:** Outcome documents are read with sort `{_id: 1}`. `$$type: double` matches `$numberDouble`. Unified SDAM files that only need existing ops now run. Standalone / sharded / load-balanced topology-lifecycle files run, including SDAM `expectEvents`. Unified `minPoolSize-error.json`, `hello-command-error.json`, `hello-network-error.json`, `serverMonitoringMode.json`, handshake backpressure files, the non-auth test in `pool-clear-min-pool-size-error.json`, `interruptInUse-pool-clear.json`, `find-shutdown-error.json`, `insert-shutdown-error.json`, `rediscover-quickly-after-step-down.json`, `replicaset-emit-topology-changed-before-close.json`, CRUD `*-let.json`, count / mapReduce files, GridFS `deleteByName.json` / `renameByName.json`, and client `bulkWrite` files run. Unified SDAM `logging-*.json`, CLAM (23 files), and CMAP UTF run when `runOnRequirements` match. `waitForEvent` also counts `connectionReadyEvent`, checkout started / failed, and `poolClosedEvent`. Find UTF passes `projection`, `max`, `min`, `return_key`, `show_record_id`. Atlas Search index ops stay `SKIP_TEST`. Handshake-error and unified SDAM auth files run when the URI has credentials (3.10). Remaining 8.0 holes are Phase 3.13–3.14 (`FIXES.md` / `ROADMAP.md`).

### Fixed
* **sessions:** After a network or state-change error, commit / abort and retryable writes still send `lsid`, `txnNumber`, and `autocommit`. That includes an Unknown server and a sharded topology where the only mongos is Unknown and the session timeout is cleared. A commit retry keeps `j` / `wtimeout` and sets `w` to majority. Handshake rediscovers an Unknown member instead of treating it as "retryable writes off". Standalone writes do not send `txnNumber`. A sharded commit retry uses another mongos when one is already known.
* **utf:** Subscribe to SDAM before monitors start, and `waitForEvent` counts `topologyDescriptionChangedEvent`.
* **io:** A short socket read after `read_greedy` is `IO::EOFError` again. A generic `Mongo::Error` skipped retry and pool clear on failCommand `closeConnection`.
* **gridfs:** A zero-length download does not query chunks (GridFS spec). An extra empty chunk is ignored.

## 0.16.0 - 2026-08-20

Phase 2 of the roadmap is done (cloud, GridFS UTF, SASLprep, CSOT, load-balanced full spec). GitHub `crystal spec` is green on standalone, replica set, sharded, and load-balanced.

### Added
* **auth:** SASLprep (RFC 4013) for SCRAM-SHA-256 passwords. Printable ASCII is unchanged (no extra allocation). Usernames are not prepared.
* **uri:** `timeoutMS` (CSOT deadline), `srvMaxHosts`, `srvServiceName`. `mongodb+srv` URI validation for `loadBalanced`, `replicaSet`, and `directConnection`. `timeoutMS=0` means infinite. Negative `timeoutMS` is rejected.
* **sdam:** SRV polling fiber for `mongodb+srv://` on Sharded or Unknown. Adds and removes mongos hosts. Does not run in load-balanced mode. Monitor hellos keep the last 10 RTT samples for CSOT min RTT.
* **csot:** Remaining `timeoutMS` minus min RTT is sent as `maxTimeMS`. Server code 50 (`MaxTimeMSExpired`) becomes `Error::Timeout`. `timeoutMS` on the client, database, collection, CRUD, indexes, GridFS, `commit_transaction`, and `abort_transaction`. `timeoutMode` (`cursorLifetime` / `iteration`) on find, aggregate, listCollections, and listIndexes. Tailable awaitData sends `maxTimeMS` on find and caps getMore with `maxAwaitTimeMS`. Change streams use iteration timeouts and resume in the same `next` call. GridFS uses one deadline for the whole upload/download (including `listIndexes` before the first write). Retryable reads/writes retry until `timeoutMS` (or forever if `timeoutMS=0`). Wait-queue timeout is `Error::Timeout` when `timeoutMS` is set. `wTimeoutMS` is omitted when `timeoutMS` is set. Official CSOT UTF is 28 files.
* **run command:** `Database#run_command` and `#run_cursor_command`. The caller's document is copied. Not retryable. Database read/write concern is not applied. `timeoutMode` and `cursorType` follow CSOT. `batch_size`, `comment`, and `max_time_ms` go on getMore only. Official run-command UTF is copied.
* **load balancer:** Do not pre-create `minPoolSize` sockets. Require `serviceId` on hello. Pin the TCP socket for a transaction and for an open cursor. Unpin returns the socket to the pool. Pool generation is per `serviceId`. Wait-queue timeout lists cursor / transaction / other in-use counts. `poolClearedEvent` includes `serviceId`. Command events include `serviceId`. CMAP `connectionReadyEvent` and `connectionClosedEvent` with a reason. UTF `assertNumberConnectionsCheckedOut`. Official load-balancer UTF runs (except the JSON `skipReason` file and one per-`serviceId` test that needs two mongos from HAProxy).
* **testing:** UTF ops `iterateUntilDocumentOrError`, `iterateOnce`, `createFindCursor`, `runCursorCommand`, `createCommandCursor`, GridFS `upload` / `delete` / `rename`, `dropIndex` / `dropIndexes`, `assertNumberConnectionsCheckedOut`. Official GridFS, collection-management, index-management, run-command, and CSOT JSON. CLAM `redacted-commands.json` and CRUD `create-null-ids.json` now run. GitHub uploads `tmp/utf-timing.log`. GitHub load-balanced runs full `crystal spec` (HAProxy via `spec/support/run-load-balancer.sh`).
* **change streams:** `watch` sends `comment` on aggregate and getMore (string or document). `showExpandedEvents` and `fullDocumentBeforeChange` go on `$changeStream`. A labeled getMore error resumes with a new aggregate (getMore is not a retryable read). `maxAwaitTimeMS` must be less than `timeoutMS` when both are set.

### Changed
* Cursor `finalize` no longer sends `killCursors` or touches the pool (GC thread). Call `#close`, `#each`, or a block `find`.
* Load-balanced topology does not start monitor sockets. Sessions are always supported in that mode. LoadBalancer always allows retryable reads and writes (hello fields stay unset without monitors).
* `getMore` is not retried as a retryable read. Overload retry still runs.
* `timeoutMode` iteration starts a fresh `timeoutMS` on each `next` / `try_next` (change streams still own the deadline for resume).
* HAProxy multi-mongos uses roundrobin and health-checks the normal mongos ports (not the PROXY v2 ports).

### Fixed
* Upsert reply with `_id: null` deserializes. Duplicate-key write errors expose `code`.
* GridFS `rename` errors when the file id is missing. UTF `downloadByName` honors `revision`.
* UTF matcher: `$date` canonical vs relaxed, `$$type` int/long with `$numberInt`.
* Find omits `tailable` and `awaitData` unless they are true. Sending `tailable: false` broke Versioned API strict (`crud-api-version-1-strict.json`).
* A `runCommand` reply with a cursor id pins the load-balanced socket (the raw BSON is scanned for `cursor.id`).
* UTF `createCollection` stores the collection entity and sends `capped` / `size` / `max`.
* `runCommand` does not send `$readPreference` to a standalone, even when the caller asked for a non-primary mode.
* `getMore` and `killCursors` do not get `readConcern` / `afterClusterTime` (explicit causal sessions).

## 0.15.0 - 2026-08-20

Phase 1 of the roadmap completed

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
* **testing:** Map CI `TOPOLOGY=standalone` to UTF topology `single`. Skip or split `useMultipleMongoses` from the URI. Sharded CI starts two mongos. Prose tests use one mongos so failCommand matches the operation. Turn failCommand off on every mongos in `ensure`. UTF setup uses majority write concern.
* **transactions:** Copy `errorLabels` from the reply and from `writeConcernError` so a retryable write-concern error is retried.
* **retryable reads:** After a retryable error on a standalone, do not abort the retry just because the only server is temporarily Unknown. Handshake rediscovers it. Catch wrapped `Error::Network` as `Mongo::Error`.
* **transactions:** Unpin a mongos session when startTransaction runs, when a non-transaction operation uses the session, and when commit fails with TransientTransactionError. Stay pinned after UnknownTransactionCommitResult. After closeConnection, wait for that mongos to be rediscovered instead of skipping the commit retry. UTF setup uses the internal client and majority writes, then copies cluster time and refreshes each mongos catalog so test-client pools stay empty. The UTF runner runs `killAllSessions` on every mongos after each test, as the spec asks, so a leftover sharded txn does not block the next drop for `transactionLifetimeLimitSeconds`.
* **sdam:** An immediate monitor scan is not dropped when the monitor is already in `hello`. A flag makes the next loop check again instead of waiting a full heartbeat.
* **sessions:** `Session::Pool#close` no longer holds the pool mutex while sending `endSessions`. That nested lock plus IO made GitHub sharded CI crash (`signal 11` in `Sync::Mutex#unlock`).

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
