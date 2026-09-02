<div align="center">
	<img src="icon.svg" width="128" height="128" />
	<h1>cryomongo</h1>
  <h3>A MongoDB driver written in pure Crystal.</h3>
  <a href="https://github.com/alumna/cryomongo/actions/workflows/specs.yml"><img alt="Build Status" src="https://github.com/alumna/cryomongo/actions/workflows/specs.yml/badge.svg?branch=master"></a>
  <a href="https://github.com/alumna/cryomongo/tags"><img alt="GitHub tag (latest SemVer)" src="https://img.shields.io/github/v/tag/alumna/cryomongo"></a>
  <a href="https://github.com/alumna/cryomongo/blob/master/LICENSE"><img alt="GitHub" src="https://img.shields.io/github/license/alumna/cryomongo"></a>
</div>

<hr/>

A MongoDB driver in Crystal (no mongo-c-driver). Tested against **MongoDB 8.0**. zstd wire compression links libzstd.

> If you are looking for a higher-level object-document mapper, see [`moongoon`](https://github.com/elbywan/moongoon).

## Contents

- [This fork](#this-fork)
- [Features](#features)
- [Installation](#installation)
- [Usage](#usage)
- [Conventions](#conventions)
- [Connection](#connection)
- [Authentication](#authentication)
- [Basic operations](#basic-operations)
- [Bulk operations](#bulk-operations)
- [Indexes](#indexes)
- [GridFS](#gridfs)
- [Change streams](#change-streams)
- [Raw commands](#raw-commands)
- [Concerns and preference](#concerns-and-preference)
- [Commands and SDAM monitoring](#commands-and-sdam-monitoring)
- [Causal consistency](#causal-consistency)
- [Transactions](#transactions)
- [Benchmarks](#benchmarks)
- [Contributing](#contributing)
- [Contributors](#contributors)

## This fork

`alumna/cryomongo` is a fork of [`elbywan/cryomongo`](https://github.com/elbywan/cryomongo). The work here is for **MongoDB 8.0** (max wire version **25**, OP_MSG-only) and **Crystal 1.21**. It is meant to merge into the upstream repository.

The driver is **0.x**. Phases 1–3 of [ROADMAP.md](ROADMAP.md) are done (CRUD, sessions, transactions, CSOT, load balancer, CMAP/SDAM, compression). Next is Phase **3.14** (performance). **1.0** waits on client-side encryption (Phase 4). Cloud auth (Phase 5: AWS / OIDC) is after 1.0.

Not in this fork: Atlas Search, MongoDB newer than 8.0, `MONGODB-AWS`, `MONGODB-OIDC`. Open work: [ROADMAP.md](ROADMAP.md).

## Features

- **[CRUD](https://docs.mongodb.com/manual/crud/index.html)** - helpers, collection bulk, client `bulkWrite` (MongoDB 8.0), `let`, legacy `count`, mapReduce, `Database#drop` / `Collection#drop`
- **[Aggregation](https://docs.mongodb.com/manual/aggregation/)**
- **[Read](https://docs.mongodb.com/manual/reference/read-concern/index.html) / [write](https://docs.mongodb.com/manual/reference/write-concern/) concerns** and **[read preference](https://docs.mongodb.com/manual/core/read-preference/index.html)**
- **[Authentication](https://docs.mongodb.com/manual/core/authentication/index.html)** - SCRAM-SHA-1/256 (SASLprep on SHA-256 passwords), X509, PLAIN
- **[TLS](https://docs.mongodb.com/manual/core/security-transport-encryption/)** - `tlsCertificateKeyFilePassword`; stapled OCSP unless `tlsDisableCertificateRevocationCheck`
- **[Indexes](https://docs.mongodb.com/manual/indexes/index.html)**
- **[GridFS](https://docs.mongodb.com/manual/core/gridfs/index.html)** - `session:`, `delete_by_name` / `rename_by_name`, `drop`
- **[Change streams](https://docs.mongodb.com/manual/changeStreams/index.html)** - `#next` waits; `#try_next` polls; resume after a labeled getMore error
- **[Tailable cursors](https://docs.mongodb.com/manual/core/tailable-cursors/index.html)** and **[collation](https://docs.mongodb.com/manual/reference/collation/index.html)**
- **Standalone, [replica set](https://docs.mongodb.com/manual/replication/), [sharded](https://docs.mongodb.com/manual/sharding/), load-balanced**
- **[CSOT](https://github.com/mongodb/specifications/blob/master/source/client-side-operations-timeout/client-side-operations-timeout.md)** - URI / client / database / collection `timeoutMS`; remaining time becomes `maxTimeMS`
- **[Wire compression](https://github.com/mongodb/specifications/blob/master/source/compression/OP_COMPRESSED.md)** - zlib, snappy, zstd (`compressors=`)
- **[Command monitoring](https://github.com/mongodb/specifications/blob/master/source/command-monitoring/command-monitoring.rst)** - sensitive commands are redacted; CMAP subscribe; spec logs `MONGODB_LOG_*`
- **Retryable [reads](https://docs.mongodb.com/manual/core/retryable-reads/) and [writes](https://docs.mongodb.com/manual/core/retryable-writes/)**
- **[Causal consistency](https://docs.mongodb.com/manual/core/read-isolation-consistency-recency/#client-sessions-and-causal-consistency-guarantees)** and **[transactions](https://docs.mongodb.com/manual/core/transactions/)** - pinned mongos; handshake retry on that pin
- **[Versioned API](https://www.mongodb.com/docs/manual/reference/versioned-api/)**
- **Raw commands** - `command`, `Database#run_command` / `#run_cursor_command`

Generated API pages live in [`docs/`](docs/Mongo.html). That folder is stale until it is regenerated.

## Installation

1. Add the dependency to your `shard.yml`:

```yaml
dependencies:
  cryomongo:
    github: alumna/cryomongo
```

2. Run `shards install`

zstd wire compression links **libzstd**. On Debian/Ubuntu: `sudo apt-get install libzstd-dev`. snappy is pure Crystal. zlib is in the Crystal stdlib.

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

## Conventions

- Methods and arguments names are in **snake case**.
- Object arguments can usually be passed as a **[NamedTuple](https://crystal-lang.org/api/NamedTuple.html)**, **[Hash](https://crystal-lang.org/api/Hash.html)**, **[BSON::Serializable](https://github.com/alumna/bson.cr#serialization)** or a **[BSON](https://github.com/alumna/bson.cr)** instance.

## Connection

```crystal
require "cryomongo"

# Mongo::Client is the root object for interacting with a MongoDB deployment.
# It is responsible for monitoring the cluster, routing the requests and managing the socket pools.

# A client can be instantiated using a standard mongodb connection string.
# Replica set:
#   Mongo::Client.new("mongodb://localhost:27017/?replicaSet=rs0")
# Load balancer:
#   Mongo::Client.new("mongodb://localhost:8000/?loadBalanced=true")
# CSOT (one deadline for selection, checkout, and maxTimeMS):
#   Mongo::Client.new("mongodb://localhost:27017/?timeoutMS=5000")

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
# To enable SSL/TLS, use the `tls` option, alongside `tlsCAFile` and `tlsCertificateKeyFile`.
# Encrypted PEM keys use `tlsCertificateKeyFilePassword`.
uri = "mongodb://localhost:27017/?tls=true&tlsCAFile=./ca.crt&tlsCertificateKeyFile=./client.pem&tlsCertificateKeyFilePassword=secret"
ssl_client = Mongo::Client.new uri
```

```crystal
# Wire compression. The driver uses the first name that the server also has.
uri = "mongodb://localhost:27017/?compressors=snappy,zlib,zstd"
client = Mongo::Client.new uri
```

```crystal
# CSOT: remaining timeoutMS becomes maxTimeMS. timeoutMS=0 means no timeout.
client = Mongo::Client.new("mongodb://localhost:27017/?timeoutMS=5000")
```

**Links**

- [Mongo::Client](docs/Mongo/Client.html)
- [Mongo::Options](docs/Mongo/Options.html)

## Authentication

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

## Basic operations

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

# Drop the collection (NamespaceNotFound is ignored) or the database.
collection.drop
client["database_name"].drop

# Aggregate

# Perform an aggregation pipeline query
cursor = collection.aggregate([
  {"$match": { status: "available" }},
  {"$limit": 5},
])
cursor.try &.each { |bson| puts bson.to_json }

# let variables (also on find, updates, deletes, find_one_and_*, bulk_write)
cursor = collection.aggregate(
  [{"$match": {"$expr": {"$eq": ["$status", "$$st"]}}}],
  let: { st: "available" },
)

# Map-Reduce (not retryable). Crystal uses output: because out is reserved.
inline = collection.map_reduce(
  "function() { emit(this.status, 1) }",
  "function(key, values) { return Array.sum(values) }",
  output: {inline: 1},
)

# Distinct collection values
values = collection.distinct(
  key: "field",
  filter: { age: { "$gt": 18 }}
)

# Documents count (returns Int64)
counter = collection.count_documents({ age: { "$lt": 18 }})

# Estimated count (also Int64)
counter = collection.estimated_document_count

# Legacy count command (prefer count_documents). Empty filter omits query.
counter = collection.count({ age: { "$lt": 18 }})

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

## Bulk operations

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

Client `bulkWrite` (MongoDB 8.0) can write to more than one namespace in one command:

```crystal
result = client.bulk_write([
  Mongo::ClientBulk::InsertOne.new("database_name.collection_name", {number: 1}),
  Mongo::ClientBulk::DeleteOne.new("database_name.other", {number: 1}),
])
puts result.inserted_count
```

**Links**

- [Mongo::Bulk](docs/Mongo/Bulk.html)
- [Mongo::Client#bulk_write](docs/Mongo/Client.html#bulk_write-instance-method)

## Indexes

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

## GridFS

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

# Delete by id or by filename
gridfs.delete(id)
gridfs.delete_by_name("file.txt")

# Rename by id or by filename
gridfs.rename(id, "new.txt")
gridfs.rename_by_name("file.txt", "new.txt")

# Drop the files and chunks collections
gridfs.drop

# And many more methods… (check the link below.)
```

**Links**

- [Mongo::GridFS::Bucket](docs/Mongo/GridFS/Bucket.html)

## Change streams

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

# 3. Connection pool (CMAP) subscriber
# Tracks pool create / ready / clear / close and checkout.

cmap_subscription = client.subscribe_cmap { |event|
  case event
  when Mongo::Monitoring::CMAP::PoolClearedEvent
    Log.info { "POOL.#{event.address} CLEARED interrupt=#{event.interrupt_in_use_connections}" }
  when Mongo::Monitoring::CMAP::ConnectionCheckedOutEvent
    Log.info { "POOL.#{event.address} CHECKED OUT id=#{event.connection_id}" }
  when Mongo::Monitoring::CMAP::ConnectionClosedEvent
    Log.info { "POOL.#{event.address} CLOSED id=#{event.connection_id} reason=#{event.reason}" }
  end
}

# Make some queries…
client["database_name"]["collection_name"].find({ hello: "world" })

# …and eventually at some point, unsubscribe the loggers.
client.unsubscribe_commands(cmd_subscription)
client.unsubscribe_sdam(sdam_subscription)
client.unsubscribe_cmap(cmap_subscription)
```

Optional spec logs (off unless you set env). `MONGODB_LOG_ALL=debug` turns every component on. Per component: `MONGODB_LOG_COMMAND`, `MONGODB_LOG_TOPOLOGY`, `MONGODB_LOG_CONNECTION` (`debug` is the usual value). `MONGODB_LOG_PATH` is `stdout`, `stderr`, or a file (default stderr). `MONGODB_LOG_MAX_DOCUMENT_LENGTH` truncates command and reply JSON (default 1000). `MONGODB_LOG_SERVER_SELECTION` is accepted; this driver does not emit those messages yet.

```crystal
# Example: MONGODB_LOG_COMMAND=debug MONGODB_LOG_PATH=stderr crystal run app.cr
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

See [BENCHMARK.md](BENCHMARK.md) (how to run, then the numbers). BSON-only: `crystal run bench/driver_bench.cr`. Live tasks need `MONGODB_URI`. A number you can quote: `shards build --release driver_bench` then `BENCH_FULL=1`. JSON history: [`bench/results/`](bench/results/).

## Contributing

1. Fork it (<https://github.com/alumna/cryomongo/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

Spec CI runs `crystal spec -Dpreview_mt -Dexecution_context` with `CRYSTAL_WORKERS=2` and `compressors=snappy,zstd,zlib` (snappy is first, so the suite uses snappy; zlib and zstd run in compression prose). UTF holds one cluster lock per JSON file so failCommand and step-down do not overlap. Replica-set leftover failCommand is turned off with `directConnection` so an Unknown member cannot keep it.

## Contributors

- [elbywan](https://github.com/elbywan) - creator and maintainer
- [paulocoghi](https://github.com/paulocoghi) - contributor

## Credit

- Icon made by [Smashicons](https://www.flaticon.com/authors/smashicons) from [www.flaticon.com](https://www.flaticon.com).
