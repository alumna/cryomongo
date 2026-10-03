# Roadmap

Open work for cryomongo **1.0.0-beta**. Nothing in this file has a target version. Pull requests are welcome for every item below, and for anything the list misses: another operating system, another cloud, another command.

The public API can still change before 1.0.0. What already shipped is the short section under this one, the [README](README.md), and [CHANGELOG.md](CHANGELOG.md).

## Shipped in 1.0.0-beta

Linux. Crystal 1.21 in CI (`shard.yml` allows >= 1.20.0). MongoDB 8.0, wire versions 25 through 29.

The README is the feature list. It covers the core driver (CRUD, aggregation, bulk writes, retryable reads and writes, sessions, causal consistency, transactions, SDAM, CSOT, compression, load balancers, change streams, GridFS), SCRAM-SHA-1 and SCRAM-SHA-256, X.509, PLAIN, and client-side encryption with local KMS: explicit encrypt and decrypt, automatic encryption, and Queryable Encryption equality and range.

GitHub Actions runs `crystal spec -Dpreview_mt -Dexecution_context` with `CRYSTAL_WORKERS=2` on Ubuntu 22.04, 24.04, and 26.04, x64 and arm64, for standalone, replica set, sharded, and load-balanced.

## Operating systems

| Target | Compile | CI | Field-encryption libraries |
| --- | --- | --- | --- |
| Linux | yes | the matrix above | `libmongocrypt.so` 1.20.4 and, for automatic encryption, `mongo_crypt_v1.so` |
| macOS | raises | none | a macOS dylib, and `mongo_crypt_v1.dylib` for automatic encryption |
| Windows | no build in this repo | none | the Windows build of the same two libraries |

`mongodb+srv://` host discovery, SCRAM, and local-KMS encryption behave the same once a platform can compile and run the suite. The platform work is the compile, the libraries, and a job that proves the suite.

### macOS

A Darwin compile raises in `src/cryomongo.cr`:

```text
cryomongo supports Linux only. macOS is not a supported target.
```

Darwin-only branches are still in the source. The raise is compiled first, so those branches are never type-checked on macOS and no macOS job runs them.

Commenting the raise out is a trap. Crystal still lexes `{% if flag?(:darwin) %}` when that text sits inside a `#` comment. Deleting the raise, or moving it out of the compilation unit, is what turns the compiler back on. After that, `scripts/vendor-libmongocrypt.sh` is the wrong archive: it downloads the Linux nocrypto build. macOS needs the official dylib, and automatic encryption needs the macOS crypt_shared library. The README [Encryption](README.md#encryption) section is the Linux procedure to mirror.

The suite failure that took macOS off the matrix was client-side operations timeout, on every macOS cell. `timeoutMS` is one deadline for server selection, checkout, the socket read, and `maxTimeMS`. On Darwin the deadline arrived during `read` while the kernel receive queue was empty (`FIONREAD` was 0). The driver stayed inside that read past the deadline, so the operation did not finish inside the test's window. In the gridfs case the next find was never sent. Three changes were measured and did not fix it: a longer sleep in the poll, shutting the socket down to unblock `read`, and polling reads that are not under `timeoutMS`. Each of those pushed the suite past the 45-minute job limit. The Linux CSOT read is the one the Ubuntu jobs pass with. A macOS port leaves that path alone and makes a Darwin read return when the deadline passes and the socket has no bytes.

A green macOS job, with the same spec command as Linux, is the point at which the raise comes out and the job stays.

### Windows

There is no Windows compiler target, vendor script, or workflow in this repository. A contribution is a compile that links libmongocrypt, crypt_shared for automatic encryption, and a way to run the suite. Crystal's Windows support is part of that work.

## MongoDB Atlas and other clouds

Atlas is several features that share a product name. A connection string of the form `mongodb+srv://…` with a SCRAM user already works: the driver polls SRV records, adds and removes hosts, honors `srvMaxHosts` and `srvServiceName`, and does not poll when `loadBalanced=true`. The open Atlas work is search indexes and the login methods Atlas database users often use. Encrypting field values is a third track, and it is independent of how the client logged in.

| Goal | Spec name | Today |
| --- | --- | --- |
| Find the hosts | `mongodb+srv` | shipped |
| Search indexes | index-management search commands | runner raises `SKIP_TEST` |
| Log in with AWS IAM | `MONGODB-AWS` | URI rules only |
| Log in with an identity provider | `MONGODB-OIDC` | URI rules only |
| Wrap data keys in a cloud KMS | client-side encryption KMS | local KMS only; cloud providers raise |
| Prefix, suffix, substring queries | Queryable Encryption on MongoDB 8.2+ | equality and range are shipped |

### Atlas Search

The commands are `createSearchIndex`, `createSearchIndexes`, `dropSearchIndex`, and `updateSearchIndex`. `spec/unified/dispatcher.cr` lists those four and raises `SKIP_TEST`. Any other search-index operation falls through the same skip. `listSearchIndexes` has no implementation.

Community `mongo:8.0`, which every current CI job runs, does not serve these commands. The official tests need an Atlas cluster, or a server that implements the same commands. Implement the driver operations, then enable those tests. The [index management specification](https://github.com/mongodb/specifications/tree/master/source/index-management) is the behavior.

### `MONGODB-AWS`

This mechanism logs the MongoDB client in as an AWS IAM principal. Wrapping field-encryption keys is [Cloud KMS](#cloud-kms). A deployment can use the login, the KMS, both, or neither.

`src/cryomongo/uri/uri.cr` accepts the mechanism and rejects an access key, a secret, or `authMechanismProperties` in the connection string. The [authentication specification](https://github.com/mongodb/specifications/blob/master/source/auth/auth.md) also rejects those values in client options. There is no SASL client. The files under `src/cryomongo/connection/auth/` are SCRAM, X.509, and PLAIN.

The conversation, once credentials exist:

1. The client sends a nonce. The first message also carries the channel-binding flag the spec requires (`n`, sent as the integer 110). The driver must not advertise channel binding.
2. The server returns a nonce and an STS host. The server nonce is 64 bytes, and its first 32 bytes are the client nonce. The host is a DNS name of 1 to 255 bytes, with no empty label and no leading or trailing dot.
3. The client answers with a [Signature Version 4](https://docs.aws.amazon.com/general/latest/gr/signature-version-4.html) authorization header and the date. A session token is included when the credentials are temporary, and omitted when they are not.

Credentials are an access key id and a secret, plus a session token when one exists. The spec's fetch order is:

1. A custom provider, if the driver offers one (`AWS_CREDENTIAL_PROVIDER` on the client, matching an AWS SDK provider). Crystal has no AWS SDK wired in. A first implementation can skip this step.
2. The environment: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, and `AWS_SESSION_TOKEN` when it is set. Read them at authorization time. Lambda refreshes them in the process environment.
3. `AssumeRoleWithWebIdentity` when both `AWS_WEB_IDENTITY_TOKEN_FILE` and `AWS_ROLE_ARN` are set. This is the EKS path. `AssumeRole` (the STS call that takes a role without a web-identity token) is not a driver responsibility.
4. The ECS credential endpoint when `AWS_CONTAINER_CREDENTIALS_RELATIVE_URI` is set. Otherwise the EC2 instance-metadata endpoint.

The official auth tests are the acceptance check. A live test needs credentials the job is allowed to hold. Cache the result of a metadata fetch the way the spec describes, including the case where the environment was empty on the first attempt and populated later.

### `MONGODB-OIDC`

This mechanism logs the client in with an OIDC access token. It is the login Atlas workforce identity and many cloud workloads use. It is independent of [Cloud KMS](#cloud-kms).

The URI parser accepts `ENVIRONMENT` and `TOKEN_RESOURCE` only.

| `ENVIRONMENT` | URI rules the parser enforces |
| --- | --- |
| `test` | no username |
| `azure`, `gcp` | `TOKEN_RESOURCE` required |
| `k8s` | no username |
| anything else | error |

Password is always an error. `authSource` defaults to `$external`. There is no SASL client, no callback, and no HTTP call to a metadata service.

The specification splits the work into two flows. They share the SASL conversation (present the token, refresh it, reauthenticate) and diverge in how the token is obtained.

**Programmatic flow.** No person is present. The [authentication specification](https://github.com/mongodb/specifications/blob/master/source/auth/auth.md) requires all four built-in environments:

- `test` reads a token from the file in `OIDC_TOKEN_FILE`. The unified tests and the Evergreen `auth_oidc` helper use this. `mongodb-oidc-no-retry.json` stays pending until the client exists. `test` is a test hook, not a user-facing mode.
- `azure` fetches a token from the Azure instance-metadata service. `TOKEN_RESOURCE` is the resource.
- `gcp` fetches a token from the GCE metadata identity endpoint. `TOKEN_RESOURCE` is the audience.
- `k8s` reads the Kubernetes service-account token.

A driver also exposes an OIDC callback on the client for an application that obtains the token itself. The spec allows that callback as client configuration. It forbids configuring both the callback and `ENVIRONMENT` on the same client. A `TOKEN_RESOURCE` that contains a comma cannot travel in the connection string, because the comma separates mechanism properties. That value needs a client option, and the README has to say so.

**Human flow.** A person signs in. The requirements are in [Workforce (Human) OIDC](https://github.com/mongodb/specifications/blob/master/docs/workforce-human-oidc-auth.md), and the driver hook is the human callback in the auth spec. The client asks the server for the identity provider, loads that provider's metadata ([RFC 8414](https://datatracker.ietf.org/doc/html/rfc8414)), and sends the person to the provider. Two grants are specified: Authorization Code with PKCE, and the Device Authorization Grant. Authorization Code is the one to implement when only one grant is in scope. The driver then caches the token and refreshes it. `ALLOWED_HOSTS` is checked after SRV resolution and before any callback. It is not accepted in the connection string. The spec's default list covers `*.mongodb.net`, the QA and dev and gov hosts, `*.mongo.com`, `localhost`, `127.0.0.1`, and `::1`. The current parser has no human callback and would reject `ALLOWED_HOSTS` if someone put it in the URI.

Machine flow and human flow are separate contributions. Each one can land, with its own tests, while the other is still absent.

### Cloud KMS

libmongocrypt performs the cryptography. When the master key is local, the 96-byte key stays in the process and libmongocrypt never asks for the network. That path is shipped, including named keys (`local:name`).

When the master key lives in a remote KMS, libmongocrypt hands the driver an endpoint and a request body and waits for the response bytes. `src/cryomongo/client_encryption/context.cr` raises `KMS HTTP is not implemented` on that path. `src/cryomongo/client_encryption/kms.cr` rejects a provider whose name is not `local` or `local:<name>`. `create_encrypted_collection` and `rewrap_many_data_key` reject the same set, so a cloud provider cannot be reached by going around the context.

The providers in the official tests:

| Provider name | Service | Exchange |
| --- | --- | --- |
| `aws` | AWS KMS | HTTPS request libmongocrypt builds |
| `azure` | Azure Key Vault | HTTPS |
| `gcp` | Cloud KMS | HTTPS |
| `kmip` | a KMIP server | the KMIP bytes libmongocrypt builds |

Named providers (`aws:name`, and the same pattern for the others) are the same exchange with a different entry in the credential map. Local named keys are already accepted. Cloud named keys start working when the exchange exists.

The contribution is that request loop: read the endpoint and the bytes, perform the exchange, feed the response back, and repeat until libmongocrypt is done. Then run the official `createDataKey` and `rewrapManyDataKey` tests for those providers. The Ubuntu jobs have no cloud credentials, and the tests that need them are skipped. Local-KMS tests have to stay green with those credentials absent.

Login (`MONGODB-AWS`, `MONGODB-OIDC`) and key wrapping (`aws` KMS, and the other providers in the table) are independent. Either one can ship while the other is still open.

### Queryable Encryption prefix, suffix, and substring

Equality and range are in 1.0.0-beta and run on MongoDB 8.0. A range query sets `queryType: "range"` together with `contention`, `trimFactor`, and `sparsity`. The README sample is equality.

Prefix, suffix, and substring are query types MongoDB 8.2 added. Driver support and a server image newer than the CI `mongo:8.0` image land together. The job that runs them stays beside the 8.0 matrix. Automatic encryption and these query types use the same `mongo_crypt_v1.so` the README already describes.

## Authentication the suite does not exercise

SCRAM-SHA-1 and SCRAM-SHA-256 run in the four topology jobs (user `bob` / `pwd123` on `admin`, no TLS, no `--auth`). Three other mechanisms need their own proof.

### X.509 in CI

The client is implemented in `src/cryomongo/connection/auth/x509.cr`. `authenticate` sends mechanism `MONGODB-X509` and `$db: $external`. The first application hello may carry the same document as speculative authentication. Monitor sockets stay unauthenticated. The URI rejects a password and rejects an `authSource` other than `$external`. The username is optional. When it is present it is the certificate subject.

`spec/prose/auth_spec.cr`, the example "authenticates with MONGODB-X509", pings with `MONGODB_X509_URI` and is pending when that variable is unset. GitHub never sets it.

A contribution is a separate standalone job. Community `mongo:8.0` is enough. X.509 client authentication does not need Enterprise, Atlas, or a secret stored in the repository.

- Generate a CA, a server certificate, and a client certificate on the runner with `openssl`. Keep them under `tmp/` (gitignored) for that job only.
- The server certificate's subject alternative name matches the host in the URI. The standalone URI host is `localhost` or `127.0.0.1`. Pick one and use it in both places.
- The `$external` user name is the client certificate subject in RFC 2253 form (`openssl x509 -noout -subject -nameopt RFC2253`).
- `tlsCertificateKeyFile` is one PEM containing the client certificate and its private key.
- Example URI, with job-local paths:

```text
mongodb://127.0.0.1:27017/?authMechanism=MONGODB-X509&tls=true&tlsCAFile=/path/ca.crt&tlsCertificateKeyFile=/path/client.pem
```

- Prefer `--auth` on this job, so a ping without a certificate fails and the prose test is the thing that succeeded.
- The command that un-pends the existing example:

```text
CRYSTAL_WORKERS=2 crystal spec spec/prose/auth_spec.cr -Dpreview_mt -Dexecution_context
```

- The full suite belongs on this job only when `MONGODB_URI` is still the SCRAM user, over TLS. An X.509-only `MONGODB_URI` changes `auth: true` detection, and the SCRAM `saslContinue` handshake-error files stop applying.
- The four topology jobs stay without TLS. Once `tls=true` is set, every socket in the process uses TLS: application, monitors, RTT, and the extra clients the tests open. Those jobs' handshake-error files assume a plaintext SCRAM URI.
- A self-signed server certificate has no OCSP staple. If the handshake fails for that reason, set `tlsDisableCertificateRevocationCheck=true` on this URI. The driver requests a stapled status and does not call an OCSP responder. See [OCSP over HTTP](#ocsp-over-http).
- Replica-set, sharded, and load-balanced TLS come after this standalone job is green. Each one has its own certificate layout: member-to-member on a replica set, config servers and mongos when sharded, HAProxy in front of `loadBalancerPort` when load-balanced.

### PLAIN

`Mongo::Auth::Plain` exists. The live prose test runs when `MONGODB_PLAIN_URI` is set. MongoDB accepts SASL PLAIN through LDAP, and that server is MongoDB Enterprise plus a directory. Community `mongo:8.0` cannot prove it. The job uses a different image than the X.509 job.

### GSSAPI (Kerberos)

The URI requires a username and `authSource=$external`. `SERVICE_NAME` defaults to `mongodb`. `CANONICALIZE_HOST_NAME`, when set, has to be one of `true`, `false`, `none`, `forward`, `forwardAndReverse`. There is no GSSAPI SASL client and no ticket-cache integration. The live tests need a KDC and a server built with GSSAPI. Community `mongo:8.0` does not provide that server. The [authentication specification](https://github.com/mongodb/specifications/blob/master/source/auth/auth.md) is the conversation.

## Servers newer than 8.0

`MAX_WIRE_VERSION` is 29, so a MongoDB 9.0 hello is accepted. `src/cryomongo/client.cr` states the two ends: 8.0 is wire 25, 9.0 is wire 29. Accepting the hello does not add that server's fields or commands. There is no formula from a server version to a wire version. The sequence skips values (10 through 12, and 20).

CI runs Community 8.0. A test the spec marks with a higher `minServerVersion` stays pending. One example is change-stream `nsType` (`change-streams-nsType.json`), which needs 8.1 and runs on a replica set or a sharded cluster. Add the field in a job whose server image actually has it, and leave the 8.0 matrix on 8.0.

New server features are welcome under that rule. Queryable Encryption prefix, suffix, and substring, above, are the same kind of gap with a name.

## Smaller gaps

### Server-selection logs

`Mongo::Log::Component` parses the name `serverSelection` and the environment variable `MONGODB_LOG_SERVER_SELECTION`. Command, topology, and connection messages are emitted. Server-selection messages are not. The [logging specification](https://github.com/mongodb/specifications/blob/master/source/logging/logging.md) describes them: the driver is waiting for a suitable server, then it succeeded or it failed. Emitting those messages is the work. The unified logging tests that this driver already runs do not require them.

### OCSP over HTTP

TLS asks for a stapled OCSP response unless `tlsDisableCertificateRevocationCheck`, `tlsInsecure`, or `tlsAllowInvalidCertificates` is set (`src/cryomongo/connection/tls.cr`). The driver never contacts an OCSP responder. `tlsDisableOCSPEndpointCheck` is parsed. Because there is no HTTP fetch, the flag currently has nothing to turn off. A fetch has to honor it, and has to stay off in the three cases above.

### `waitQueueSize` and `waitQueueMultiple`

`waitQueueTimeoutMS` is implemented. `waitQueueSize` and `waitQueueMultiple` are not. The [connection pool specification](https://github.com/mongodb/specifications/blob/master/source/connection-monitoring-and-pooling/connection-monitoring-and-pooling.md) marks those two deprecated and allows a driver to skip their tests. Implementing them is optional.

### Performance

[BENCHMARK.md](BENCHMARK.md) and `bench/driver_bench.cr` measure BSON encode and decode, and, when `MONGODB_URI` is set, live find, insert, `bulkWrite`, and GridFS. A change to a hot path belongs in the driver when a run of that bench, or a profile of the suite, shows the cost. The spec job timeout is 45 minutes. A change that slows the Ubuntu matrix has to fit in that budget.

### Generated API pages

`docs/` is a generated tree and it is behind the source. The README says to regenerate it before trusting it. A regeneration that matches 1.0.0-beta is welcome.

## Compatibility floor

The product speaks MongoDB 8.0 and newer. Two pieces of the code still follow older behavior, because the Linux suite still requires them. Raising `MIN_WIRE_VERSION`, or deleting the timeout options below, fails that suite while the fixtures still depend on them.

**Wire minimum.** `MIN_WIRE_VERSION` is 6. A server description is incompatible when its minimum wire is above `MAX_WIRE_VERSION` (29) or its maximum wire is below 6. Descriptions that have not completed hello report max wire 0 and are left alone. Load-balanced mode has no wire version on the handshake.

The legacy SDAM and max-staleness fixtures still present max wire 21 as a stand-in for a current server. The comment on `MIN_WIRE_VERSION` in `src/cryomongo/client.cr` records why. Raising the constant to 25 marks those descriptions incompatible. The work is to update the fixtures to a wire range an 8.0 server would advertise, then raise the minimum to 25, then delete the command paths that exist only for the older range. Several error and command branches still switch on wire versions below 25 because those fixtures exercise them. Delete a branch in the same change that stops the fixture from needing it.

The first handshake can still send `isMaster`. MongoDB 8.0 accepts it. A handshake that uses the versioned API already sends `hello`.

**Timeout options that CSOT replaced.** The suites still send `socketTimeoutMS`, `waitQueueTimeoutMS`, `wTimeoutMS`, and the CRUD fields `maxTimeMS` and `maxCommitTimeMS`. The driver still accepts them. `timeoutMS` is the deadline the README documents: one budget for selection, checkout, the socket, and `maxTimeMS` (remaining time minus the minimum RTT). Dropping the older options is the second half of this cleanup, after the tests that still send them have been updated.

## Contributing

1. Fork and open a pull request, as in the README [Contributing](README.md#contributing) section.
2. Run specs with `crystal spec -Dpreview_mt -Dexecution_context` and `CRYSTAL_WORKERS=2`.
3. Take behavior from the [MongoDB driver specifications](https://github.com/mongodb/specifications). Implement the spec, then enable the test that covers it.
4. Keep the Ubuntu matrix on Community MongoDB 8.0, SCRAM, and no TLS. A new operating system, a TLS job, or a job that holds cloud credentials is a separate workflow entry.
5. Work that this file does not mention is still welcome. Open the issue or the pull request.
