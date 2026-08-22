<div align="center">
	<img src="icon.svg" width="128" height="128" />
	<h1>cryomongo</h1>
  <h3>A MongoDB driver written in pure Crystal.</h3>
  <a href="https://github.com/alumna/cryomongo/actions/workflows/specs.yml"><img alt="Build Status" src="https://github.com/alumna/cryomongo/actions/workflows/specs.yml/badge.svg?branch=master"></a>
  <a href="https://github.com/alumna/cryomongo/tags"><img alt="GitHub tag (latest SemVer)" src="https://img.shields.io/github/v/tag/alumna/cryomongo"></a>
  <a href="https://github.com/alumna/cryomongo/blob/master/LICENSE"><img alt="GitHub" src="https://img.shields.io/github/license/alumna/cryomongo"></a>
</div>

<hr/>

This is a fork of `elbywan/cryomongo`. The goal is to make the driver ready for **MongoDB 8.0** and **Crystal 1.21**. We plan to merge back to the original project when that work is done.

The driver speaks OP_MSG only. The max wire version is **25** (MongoDB 8.0). Semver is **0.x**. **Phase 1**, **Phase 2**, and **Phase 3** of [ROADMAP.md](ROADMAP.md) are done. Local `crystal spec -Dpreview_mt -Dexecution_context` after Phase **3.4** is **783** examples: standalone **2:04 / 204 pending**, replica set **6:05 / 92 pending**, sharded **8:06 / 100 pending**, load-balanced **5:41 / 136 pending**. Spec jobs resize the default execution context (`CRYSTAL_WORKERS=2`) and use zlib wire compression.

The driver is ready for **core CRUD, sessions, and transactions** on MongoDB 8.0. **1.0** waits on client-side encryption (Phase 4) and cloud auth (Phase 5: AWS / OIDC). Remaining 8.0 work is [ROADMAP.md](ROADMAP.md) Phase 3.1–3.14.

What is already in place:

* **MongoDB 8.0:** `hello`, sessions, transactions, retryable reads and writes, Versioned API, and a Unified Test Format (UTF) runner.
* **Crystal 1.21:** `Sync::Mutex`, `Time.instant`, no `spawn(same_thread:)`. Execution contexts are on by default. Spec CI resizes the default context.
* **BSON:** `alumna/bson.cr` 0.8.1. Commands use `BSON.build` / `append`. Receive uses `BSON.view`. Dates decode as `BSON::DateTime` (model fields of type `Time` still convert). Vector / ExtJSON are not on the hot path.
* **Auth:** SCRAM-SHA-1, SCRAM-SHA-256 (SASLprep on the password), X509, and PLAIN.
* **Compression:** zlib via URI `compressors=zlib`. snappy and zstd are not wired yet.

The UTF runner is **clear**: unknown operations become Crystal `pending`, they do not fake a pass. Files that are still skipped because a feature is missing (not AWS / OIDC / MongoDB 8.1+) are listed in [ROADMAP.md](ROADMAP.md) and [FIXES.md](FIXES.md).

### Where the work stands

The driver is **0.x**. It is ready for core CRUD, sessions, and transactions on standalone, replica set, and sharded MongoDB 8.0. It is not an official-driver equivalent for every MongoDB shop. **1.0** waits on CSFLE and cloud auth.

**Done enough to build apps (Phase 1, Phase 2, and Phase 3)**
- CRUD helpers, bulk, aggregation (no mapReduce).
- Sessions, causal consistency, transactions, convenient `with_transaction`.
- Retryable reads and writes (including `insertMany` as one command).
- Command redaction in APM / `Log.trace`. Handshake metadata. Cursor `#each` / block `find` close the cursor.
- Backpressure retry and `PoolClearedError` retry.
- Legacy SDAM state-machine tests. Versioned API.
- SCRAM-SHA-256 with SASLprep, X509, and PLAIN.
- Change streams: `comment`, `showExpandedEvents`, `fullDocumentBeforeChange`, resume after a labeled getMore error.
- CSOT `timeoutMS`: remaining time becomes `maxTimeMS`. Code 50 is `Error::Timeout`. Collection / database / operation `timeoutMS`, `timeoutMode`, GridFS lifetime, tailable / change-stream iteration. `run_command` / `run_cursor_command`. Official CSOT UTF is 28 files.
- Load-balancer pin, `serviceId` on command and pool-cleared events, wait-queue cursor/txn counts, pool clear per `serviceId`. Retryable reads/writes after `failCommand` / `closeConnection`. GitHub load-balanced runs full `crystal spec`.
- CI matrix: standalone, replica set, sharded, and load-balanced. Spec jobs resize the default execution context.
- zlib OP_COMPRESSED (`compressors=zlib`). Pool map lock is not nested with handshake I/O.
- Unified `pool-cleared-error.json`. Socket timeouts after handshake do not mark the server Unknown.

**Not done yet (MongoDB 8.0). See [ROADMAP.md](ROADMAP.md) Phase 3.1–3.14 and [FIXES.md](FIXES.md).**
- Unified SDAM still skipped: `interruptInUseConnections`, concurrent shutdown extra Unknown, SDAM logging. `minPoolSize-error.json`, `hello-command-error.json`, `hello-network-error.json`, `serverMonitoringMode.json`, and handshake backpressure files now run. `replicaset-emit-topology-changed-before-close.json` needs a 3-member replica set (local and GitHub Docker are one member).
- UTF ops still `SKIP_TEST`: client `bulkWrite`, `let` on CRUD, legacy `count`, `mapReduce`, `waitForPrimaryChange` / `recordTopologyDescription` / `assertTopologyType`.
- No users on CI, so `auth: true` UTF does not run (handshake-error files, unified SDAM auth-error files). Speculative auth and monitor auth are missing.
- snappy / zstd. TLS key-file password and OCSP flags are parsed and unused. Official CMAP JSON is not copied. CLAM is 1 of 23 files. GridFS `deleteByName` / `renameByName` not copied.
- CSFLE (`libmongocrypt`) is Phase 4. AWS / OIDC is Phase 5.

**Out of scope until we ask for it**
- `MONGODB-AWS`, `MONGODB-OIDC`.
- MongoDB newer than 8.0 (example: change-stream `nsType` needs 8.1).
- Atlas Search.

#### Cryomongo is a MongoDB driver written in pure Crystal (no C library).

*Works with MongoDB 8.0+. Tested against 8.0.*

> If you are looking for a higher-level object-document mapper library, you might want to check out the [`moongoon`](https://github.com/elbywan/moongoon) shard.

## Installation

1. Add the dependency to your `shard.yml`:

```yaml
dependencies:
  cryomongo:
    github: alumna/cryomongo
```

2. Run `shards install`

## Usage

### Minimal working example

```crystal
require "cryomongo"

# Create a Mongo client, using a standard mongodb connection string.
client = Mongo::Client.new # defaults to: "mongodb://localhost:27017"

# Get database and collection.
database = client["database_name"]
collection = database["collection_name"]

# Perform crud operations.
result = collection.insert_one({ one: 1 })
# The driver adds `_id` when the document is a BSON. inserted_ids is on the result.
puts result.try(&.inserted_ids)
collection.replace_one({ one: 1 }, { two: 2 })
bson = collection.find_one({ two: 2 })
puts bson.try(&.["two"]) # => 2
collection.delete_one({ two: 2 })
puts collection.count_documents # => 0_i64
client.close
```

### Complex example with serialization

```crystal
require "cryomongo"

# We take advantage of the BSON serialization capabilities provided by the `bson.cr` shard.
record User,
  name : String,
  banned : Bool? = false,
  _id : BSON::ObjectId = BSON::ObjectId.new,
  creation_date : Time = Time.utc do
  include BSON::Serializable
  include JSON::Serializable
end

# Initialize Client, Database and Collection.
client = Mongo::Client.new
database = client["database"]
users = database["users"]

# We set majority read and write at the Database level.
database.read_concern = Mongo::ReadConcern.new(level: "majority")
database.write_concern = Mongo::WriteConcern.new(w: "majority")

# Drop and recreate the Collection to ensure that we read later only the documents we inserted in this example.
{ Mongo::Commands::Drop, Mongo::Commands::Create }.each do |command|
  database.command(command, name: "users")
rescue e : Mongo::Error::Command
  # ignore the server error, drop will fail if the collection has not been created before.
end

# Insert User structures that are automatically serialized to BSON.
users.insert_many(["John", "Jane"].map { |name| User.new(name: name) })

# Fetch a Cursor pointing to the users collection.
# `#each` (and `to_a`) close the cursor when iteration ends.
# You can also pass a block to `find`. Call `#close` if you use `#next` yourself.
cursor = users.find

# Iterate the cursor and use `.of(User)` to deserialize as the cursor gets iterated.
# Then push the users into an array that gets pretty printed.
puts cursor.of(User).to_a.to_pretty_json
# => [
#   {
#     "name": "John",
#     "banned": false,
#     "_id": {
#       "$oid": "f2001c5fb0a33e0264e2ea05"
#     },
#     "creation_date": "2020-07-25T09:52:50Z"
#   },
#   {
#     "name": "Jane",
#     "banned": false,
#     "_id": {
#       "$oid": "f2001c5fb0a33e0264e2ea07"
#     },
#     "creation_date": "2020-07-25T09:52:50Z"
#   }
# ]
```

## Features

- **[CRUD operations](https://docs.mongodb.com/manual/crud/index.html)**
- **[Aggregation](https://docs.mongodb.com/manual/aggregation/) (except: Map-Reduce)**
- **[Bulk](https://docs.mongodb.com/manual/reference/method/Bulk/index.html)**
- **[Read](https://docs.mongodb.com/manual/reference/read-concern/index.html) and [Write](https://docs.mongodb.com/manual/reference/write-concern/) Concerns**
- **[Read Preference](https://docs.mongodb.com/manual/core/read-preference/index.html)**
- **[Authentication](https://docs.mongodb.com/manual/core/authentication/index.html)** — SCRAM-SHA-1/256 (SASLprep on SHA-256 passwords), X509, PLAIN
- **[TLS encryption](https://docs.mongodb.com/manual/core/security-transport-encryption/)**
- **[Indexes](https://docs.mongodb.com/manual/indexes/index.html)**
- **[GridFS](https://docs.mongodb.com/manual/core/gridfs/index.html)** (methods accept `session:`)
- **[Change Streams](https://docs.mongodb.com/manual/changeStreams/index.html)** (`#next` waits; use `#try_next` to poll)
- **[Admin/Diagnostic commands](docs/Mongo/Commands.html)** and raw `Database#run_command` / `#run_cursor_command`
- **[Tailable and Awaitable cursors](https://docs.mongodb.com/manual/core/tailable-cursors/index.html)**
- **[Collation](https://docs.mongodb.com/manual/reference/collation/index.html)**
- **Standalone, [Sharded](https://docs.mongodb.com/manual/sharding/) or [ReplicaSet](https://docs.mongodb.com/manual/replication/) topologies**
- **[Wire compression](https://github.com/mongodb/specifications/blob/master/source/compression/OP_COMPRESSED.md)** — zlib (`compressors=zlib`)
- **[Command monitoring](https://github.com/mongodb/specifications/blob/master/source/command-monitoring/command-monitoring.rst)** (sensitive commands are redacted)
- **Retryable [reads](https://docs.mongodb.com/manual/core/retryable-reads/) and [writes](https://docs.mongodb.com/manual/core/retryable-writes/)**
- **[Causal consistency](https://docs.mongodb.com/manual/core/read-isolation-consistency-recency/#client-sessions-and-causal-consistency-guarantees)**
- **[Transactions](https://docs.mongodb.com/manual/core/transactions/)**
- **[Versioned API](https://www.mongodb.com/docs/manual/reference/versioned-api/)**

## Conventions

- Methods and arguments names are in **snake case**.
- Object arguments can usually be passed as a **[NamedTuple](https://crystal-lang.org/api/NamedTuple.html)**, **[Hash](https://crystal-lang.org/api/Hash.html)**, **[BSON::Serializable](https://github.com/alumna/bson.cr#serialization)** or a **[BSON](https://github.com/alumna/bson.cr)** instance.

## Documentation

Generated API pages live in [`docs/`](docs/Mongo.html). The old `elbywan.github.io` site is stale.

### Connection

```crystal
require "cryomongo"

# Mongo::Client is the root object for interacting with a MongoDB deployment.
# It is responsible for monitoring the cluster, routing the requests and managing the socket pools.

# A client can be instantiated using a standard mongodb connection string.
# Against a replica set:
#   Mongo::Client.new("mongodb://localhost:27017/?replicaSet=rs0")
# GitHub Actions also runs standalone and sharded.

# Client options can be passed as query parameters…
client = Mongo::Client.new("mongodb://address:port/database?appname=MyApp")
# …or with a Mongo::Options instance…
options = Mongo::Options.new(appname: "MyApp")
client = Mongo::Client.new("mongodb://address:port/database", options)
# …or both.

# Instantiate objects to interact with a specific database or a collection…
database   = client["database_name"]
collection = database["collection_name"]

# …or using `default_database` if the connection uri string contains a default auth database component ("/database").
if database = client.default_database
  collection = database["collection_name"]
end

# The overwhelming majority of programs should use a single client and should not bother with closing clients.
# Otherwise, to free the underlying resources a client must be manually closed.
client.close
```

```crystal
# To enable SSL/TLS, use the `tls` option, alongside the `tlsCAFile` and `tlsCertificateKeyFile` options.
uri = "mongodb://localhost:27017/?tls=true&tlsCAFile=./ca.crt&tlsCertificateKeyFile=./client.pem"
ssl_client = Mongo::Client.new uri
```

**Links**

- [Mongo::Client](docs/Mongo/Client.html)
- [Mongo::Options](docs/Mongo/Options.html)

### Authentication

Supported: **SCRAM-SHA-1**, **SCRAM-SHA-256** (SASLprep on the password), **X509**, and **PLAIN**.

Not supported yet: `MONGODB-AWS`, `MONGODB-OIDC`.

```crystal
require "cryomongo"

# Username and password. The server picks SCRAM-SHA-1 or SCRAM-SHA-256.
client = Mongo::Client.new("mongodb://username:password@localhost:27017")

# Or set the mechanism:
# mongodb://username:password@localhost:27017/?authMechanism=SCRAM-SHA-256
# mongodb://localhost:27017/?authMechanism=MONGODB-X509&tls=true
# mongodb://user:pass@localhost:27017/?authMechanism=PLAIN
```

### Basic operations

```crystal
require "cryomongo"

client = Mongo::Client.new

# Most CRUD operations are performed at collection-level.
collection = client["database_name"]["collection_name"]

# The examples below are very basic, but the methods can accept all the options documented in the MongoDB manual.

## Create

# Insert a single document
collection.insert_one({ key: "value" })
# Insert multiple documents
collection.insert_many((1..100).map { |i| { count: i } })

# To track the _id, generate and pass it as a property
id = BSON::ObjectId.new
collection.insert_one({ _id: id, key: "value" })

## Read

# Find a single document
document = collection.find_one({ _id: id })
document.try { |d| puts d.to_json }

# Find multiple documents.
cursor = collection.find({ qty: { "$gt": 4 }})
elements = cursor.to_a # cursor is an Iterator(BSON)
cursor.close           # send killCursors if the server cursor is still open

## Update

# Replace a single document.
collection.replace_one({ name: "John" }, { name: "Jane" })
# Update a single document.
collection.update_one({ name: "John" }, { "$set": { name: "Jane" }})
# Update multiple documents
collection.update_many({ name: { "$in": ["John", "Jane"] }}, { "$set": { name: "Jules" }})
# Find one document and replace it
document = collection.find_one_and_replace({ name: "John" }, { name: "Jane" })
puts document.try &.["name"]
# Find one document and update it
document = collection.find_one_and_update({ name: "John" }, { "$set": { name: "Jane" }})
puts document.try &.["name"]

## Delete

# Delete one document
collection.delete_one({ age: 20 })
# Delete multiple documents
collection.delete_many({ age: { "$lt": 18 }})
# find_one_and_delete
document = collection.find_one_and_delete({ age: { "$lt": 18 }})
puts document.try &.["age"]

# Aggregate

# Perform an aggregation pipeline query
cursor = collection.aggregate([
  {"$match": { status: "available" }},
  {"$limit": 5},
])
cursor.try &.each { |bson| puts bson.to_json }

# Distinct collection values
values = collection.distinct(
  key: "field",
  filter: { age: { "$gt": 18 }}
)

# Documents count (returns Int64)
counter = collection.count_documents({ age: { "$lt": 18 }})

# Estimated count (also Int64)
counter = collection.estimated_document_count

# Raw command (not retryable; database read/write concern is not applied).
database = client["database_name"]
ping = database.run_command({ping: 1})
puts ping["ok"]

# Command that returns a cursor. getMore stays on the same server.
cursor = database.run_cursor_command({find: "collection_name", batchSize: 2}, batch_size: 2)
cursor.each { |doc| puts doc.to_json }
```

**Links**

- [Mongo::Collection](docs/Mongo/Collection.html)
- [Mongo::Database](docs/Mongo/Database.html)

### Bulk operations

```crystal
require "cryomongo"

client = Mongo::Client.new

# A Bulk object can be initialized by calling `.bulk` on a collection.
collection = client["database_name"]["collection_name"]
bulk = collection.bulk
# A bulk is ordered by default.
bulk.ordered? # => true

500.times do |idx|
  # Build the queries by calling bulk methods multiple times.
  bulk.insert_one({number: idx})
  bulk.delete_many({number: {"$lt": 450}})
  bulk.replace_one({ number: idx }, { number: idx + 1})
end

# Execute all the queries and return an aggregated result.
pp bulk.execute(write_concern: Mongo::WriteConcern.new(w: 1))
```

**Links**

- [Mongo::Bulk](docs/Mongo/Bulk.html)

### Indexes

```crystal
require "cryomongo"

client = Mongo::Client.new
collection = client["database_name"]["collection_name"]

# Create one index without options…
collection.create_index(
  keys: {
    "a":  1,
    "b":  -1,
  }
)
# or with options (snake_cased)…
collection.create_index(
  keys: {
    "a":  1,
    "b":  -1,
  },
  options: {
    unique: true
  }
)
# and optionally specify the name.
collection.create_index(
  keys: {
    "a":  1,
    "b":  -1,
  },
  options: {
    name: "index_name",
  }
)

# Follow the same rules to create multiple indexes with a single method call.
collection.create_indexes([
  {
    keys: { a: 1 }
  },
  {
    keys: { b: 2 }, options: { expire_after_seconds: 3600 }
  }
])
```

**Links**

- [Mongo::Collection](docs/Mongo/Collection.html)

### GridFS

```crystal
require "cryomongo"

client = Mongo::Client.new
database = client["database_name"]

# A GridFS bucket belongs to a database.
gridfs = database.grid_fs

# Upload (using File.open ensures the file descriptor is closed automatically).
# All GridFS methods accept session: if you need a transaction or causal reads.
id = File.open("file.txt") do |file|
  gridfs.upload_from_stream("file.txt", file)
end

# Download
stream = IO::Memory.new
gridfs.download_to_stream(id, stream)
puts stream.rewind.gets_to_end

# Find
files = gridfs.find({
  length: {"$gte": 5000},
})
files.each do |file|
  puts file.filename
end

# Delete
gridfs.delete(id)

# And many more methods… (check the link below.)
```

**Links**

- [Mongo::GridFS::Bucket](docs/Mongo/GridFS/Bucket.html)

### Change streams

```crystal
require "cryomongo"

# Change streams can watch a client, database or collection for change.
# This code snippet will focus on watching a single collection.

client = Mongo::Client.new
collection = client["database_name"]["collection_name"]

spawn do
  cursor = collection.watch(
    [
      {"$match": {"operationType": "insert"}},
    ],
    max_await_time_ms: 10000
  )
  # `#each` / `#next` wait while the stream is open. An empty getMore does not stop.
  # Use `#try_next` when you want one poll (and the latest resume_token) without blocking.
  begin
    cursor.of(BSON).each do |doc|
      puts doc.document_key
      puts doc.full_document.to_json
    end
  ensure
    cursor.close
  end
end

100.times do |i|
  collection.insert_one({count: i})
end

sleep
```

**Links**

- [Mongo::ChangeStream::Cursor](docs/Mongo/ChangeStream/Cursor.html)
- [Mongo::ChangeStream::Document](docs/Mongo/ChangeStream/Document.html)

## Raw commands

```crystal
require "cryomongo"

# Commands can be run on a client, database or collection depending on the command target.

client = Mongo::Client.new

# Call the `.command` method to run a command against the server.
# The first argument is a `Mongo::Commands` sub-class, followed by the mandatory arguments
# and finally an *options* named tuple containing the optional parameters in snake_case.
result = client.command(Mongo::Commands::ServerStatus, options: {
  repl: 0
})
puts result.to_bson

# The .command method can also be called against a Database…
client["database"].command(Mongo::Commands::Create, name: "collection")
client["database"].command(Mongo::Commands::Drop, name: "collection")
# …or a Collection.
client["database"]["collection"].command(Mongo::Commands::Validate)
```
**Links**

- [Mongo::Commands](docs/Mongo/Commands.html)
- [Mongo::Client#command](docs/Mongo/Client.html#command(command,write_concern:WriteConcern?=nil,read_concern:ReadConcern?=nil,read_preference:ReadPreference?=nil,server_description:SDAM::ServerDescription?=nil,session:Session::ClientSession?=nil,operation_id:Int64?=nil,**args)-instance-method)
- [Mongo::Database#command](docs/Mongo/Database.html#command(operation,write_concern:WriteConcern?=nil,read_concern:ReadConcern?=nil,read_preference:ReadPreference?=nil,session:Session::ClientSession?=nil,**args)-instance-method)
- [Mongo::Collection#command](docs/Mongo/Collection.html#command(operation,write_concern:WriteConcern?=nil,read_concern:ReadConcern?=nil,read_preference:ReadPreference?=nil,session:Session::ClientSession?=nil,**args)-instance-method)

## Concerns and Preference

```crystal
require "cryomongo"

# Instantiate Read/Write Concerns and Preference
read_concern = Mongo::ReadConcern.new(level: "majority")
write_concern = Mongo::WriteConcern.new(w: 1, j: true)
read_preference = Mongo::ReadPreference.new(mode: "primary")

# They can be set at the client, database or client level…
client = Mongo::Client.new
database = client["database_name"]
collection = database["collection_name"]

client.read_concern = read_concern
database.write_concern = write_concern
collection.read_preference = read_preference

# …or by passing an extra argument when calling a method.
collection.find(
  filter: { key: "value" },
  read_concern:  Mongo::ReadConcern.new(level: "local"),
  read_preference: Mongo::ReadPreference.new(mode: "secondary")
)
```

**Links**

- [Mongo::ReadConcern](docs/Mongo/ReadConcern.html)
- [Mongo::WriteConcern](docs/Mongo/WriteConcern.html)
- [Mongo::ReadPreference](docs/Mongo/ReadPreference.html)

## Commands and SDAM Monitoring

```crystal
require "cryomongo"

client = Mongo::Client.new

# 1. Command Monitoring Subscriber
# Tracks the execution of database commands (e.g., find, insert, aggregate).
# Sensitive commands (authenticate, saslStart, createUser, …) are redacted.

cmd_subscription = client.subscribe_commands { |event|
  case event
  when Mongo::Monitoring::Commands::CommandStartedEvent
    Log.info { "COMMAND.#{event.command_name} #{event.address} STARTED: #{event.command.to_json}" }
  when Mongo::Monitoring::Commands::CommandSucceededEvent
    Log.info { "COMMAND.#{event.command_name} #{event.address} COMPLETED (#{event.duration}s)" }
  when Mongo::Monitoring::Commands::CommandFailedEvent
    Log.info { "COMMAND.#{event.command_name} #{event.address} FAILED: #{event.failure.inspect} (#{event.duration}s)" }
  end
}

# 2. SDAM (Server Discovery and Monitoring) Subscriber
# Tracks the lifecycle and topology changes of the MongoDB cluster.

sdam_subscription = client.subscribe_sdam { |event|
  case event
  when Mongo::Monitoring::SDAM::ServerDescriptionChangedEvent
    Log.info { "SERVER.#{event.address} CHANGED: #{event.previous_description.type} -> #{event.new_description.type}" }
  when Mongo::Monitoring::SDAM::TopologyDescriptionChangedEvent
    Log.info { "TOPOLOGY CHANGED: #{event.previous_description.type} -> #{event.new_description.type}" }
  when Mongo::Monitoring::SDAM::ServerHeartbeatStartedEvent
    Log.info { "HEARTBEAT.#{event.address} STARTED awaited=#{event.awaited}" }
  when Mongo::Monitoring::SDAM::ServerHeartbeatSucceededEvent
    Log.info { "HEARTBEAT.#{event.address} OK awaited=#{event.awaited} (#{event.duration})" }
  when Mongo::Monitoring::SDAM::ServerHeartbeatFailedEvent
    Log.info { "HEARTBEAT.#{event.address} FAILED awaited=#{event.awaited}: #{event.failure}" }
  when Mongo::Monitoring::SDAM::ServerClosedEvent
    Log.info { "SERVER.#{event.address} REMOVED FROM TOPOLOGY" }
  end
}

# Make some queries…
client["database_name"]["collection_name"].find({ hello: "world" })

# …and eventually at some point, unsubscribe the loggers.
client.unsubscribe_commands(cmd_subscription)
client.unsubscribe_sdam(sdam_subscription)
```

**Links**

- [Mongo::Client#subscribe_commands](docs/Mongo/Client.html#subscribe_commands(&callback:Monitoring::Commands::Event->Nil):Monitoring::Commands::Event->Nil-instance-method)
- [Mongo::Client#unsubscribe_commands](docs/Mongo/Client.html#unsubscribe_commands(callback:Monitoring::Commands::Event->Nil):Nil-instance-method)
- [Mongo::Monitoring::Observable](docs/Mongo/Monitoring/Observable.html)
- [Mongo::Monitoring::CommandStartedEvent](docs/Mongo/Monitoring/Commands/CommandStartedEvent.html)
- [Mongo::Monitoring::CommandSucceededEvent](docs/Mongo/Monitoring/Commands/CommandSucceededEvent.html)
- [Mongo::Monitoring::CommandFailedEvent](docs/Mongo/Monitoring/Commands/CommandFailedEvent.html)

## Causal Consistency

```crystal
require "cryomongo"

client = Mongo::Client.new
# It is important to ensure that both read and writes are performed with "majority" concern.
# See: https://docs.mongodb.com/manual/core/causal-consistency-read-write-concerns/
client.read_concern = Mongo::ReadConcern.new(level: "majority")
client.write_concern = Mongo::WriteConcern.new(w: "majority")

# Reusing the original Mongodb example.
# See: https://docs.mongodb.com/manual/core/read-isolation-consistency-recency/#examples

current_date = Time.utc
items_collection = client["test"]["items"]

# MongoDB enables causal consistency in client sessions by default.
# This is the block syntax that creates, ends and passes the session to collection methods automatically.
items_collection.with_session do |items|
  # Using a causally consistent session ensures that the update occurs before the insert.
  items.update_one(
    { sku: "111", end: { "$exists": false } },
    { "$set": { end: current_date }}
  )
  items.insert_one({ sku: "nuts-111", name: "Pecans", start: current_date })
  puts items.find.to_a.to_pretty_json
end

client.close
```

**Links**

- [Mongo::Session](docs/Mongo/Session.html)
- [Mongo::Client#start_session](docs/Mongo/Client.html#start_session(*,causal_consistency:Bool=true):Session::ClientSession-instance-method)
- [Mongo::Collection#with_session](docs/Mongo/Collection.html#with_session(**args,&)-instance-method)

## Transactions

```crystal
require "cryomongo"

# Initialize Client and Database instances.
client = Mongo::Client.new
database = client["db"]
collection = database["collection"]

# Create the collection.
{Mongo::Commands::Drop, Mongo::Commands::Create}.each do |command|
  database.command(command, name: "collection")
rescue e : Mongo::Error::Command
  # ignore the server error, drop will fail if the collection has not been created before.
end

# Set read and write concerns to perform isolated transactions.
# See: https://docs.mongodb.com/master/core/transactions/#transactions-and-sessions
transaction_options = Mongo::Session::TransactionOptions.new(
  read_concern: Mongo::ReadConcern.new(level: "snapshot"),
  write_concern: Mongo::WriteConcern.new(w: "majority")
)

# There are two ways to perform transactions:

collection.with_session(default_transaction_options: transaction_options) do |collection, session|
  puts collection.find.to_a.to_json # => "[]"

  # 1. by calling the `with_transaction` method.

  # `with_transaction` will commit after the block ends.
  # if the block raises, the transaction will be aborted.
  session.with_transaction do
    collection.insert_one({_id: 1})
    collection.insert_one({_id: 2})
  end
  puts collection.find.to_a.to_json # => [{"_id":1},{"_id":2}]

  # The transaction below will be aborted because the block raises an Exception.
  begin
    session.with_transaction do
      collection.insert_one({_id: 3})
      raise "Interrupted!"
      collection.insert_one({_id: 4})
    end
  rescue e
    puts e # => Interrupted!
  end
  puts collection.find.to_a.to_json # => [{"_id":1},{"_id":2}]

  # 2. by calling the `start_transaction`, `commit_transaction` and `abort_transaction` methods.
  session.start_transaction
  collection.insert_one({_id: 3})
  # The transaction is isolated, reading outside of the session scope does not return documents impacted by the transaction…
  puts database["collection"].find.to_a.to_json # => [{"_id":1},{"_id":2}]
  # but reading within the session scope does.
  puts collection.find.to_a.to_json # => [{"_id":1},{"_id":2},{"_id":3}]
  session.commit_transaction
  # The transaction is now committed and visible outside of the transaction scope.
  puts collection.find.to_a.to_json             # => [{"_id":1},{"_id":2},{"_id":3}]
  puts database["collection"].find.to_a.to_json # => [{"_id":1},{"_id":2},{"_id":3}]
end
```

**Links**

- [Mongo::Session#with_transaction](docs/Mongo/Session/ClientSession.html#with_transaction(**options,&)-instance-method)
- [Mongo::Session#start_transaction](docs/Mongo/Session/ClientSession.html#start_transaction(**options)-instance-method)
- [Mongo::Session#commit_transaction](docs/Mongo/Session/ClientSession.html#commit_transaction(*,write_concern:WriteConcern?=nil)-instance-method)
- [Mongo::Session#abort_transaction](docs/Mongo/Session/ClientSession.html#abort_transaction(*,write_concern:WriteConcern?=nil)-instance-method)
- [Mongo::Session::TransactionOptions](docs/Mongo/Session/TransactionOptions.html)

## Benchmarks

See [BENCHMARK.md](BENCHMARK.md). BSON tasks: `crystal run bench/driver_bench.cr`. Live tasks need `MONGODB_URI`. JSON history: [`bench/results/`](bench/results/).

## Contributing

1. Fork it (<https://github.com/alumna/cryomongo/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [elbywan](https://github.com/elbywan) - creator and maintainer
- [paulocoghi](https://github.com/paulocoghi) - contributor

## Credit

- Icon made by [Smashicons](https://www.flaticon.com/authors/smashicons) from [www.flaticon.com](https://www.flaticon.com).
