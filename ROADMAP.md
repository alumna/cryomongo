# ROADMAP: MongoDB 8.0 & Crystal 1.20+ Compatibility

This roadmap defines the implementation checklist against the official MongoDB driver specifications, ensuring 100% compliance.

## Core (Connection & Discovery)
- [x] connection-string
- [x] uri-options
- [x] server-discovery-and-monitoring (SDAM)
- [x] server-selection
- [x] connection-monitoring-and-pooling (CMAP)
- [ ] handshake (hello)
- [ ] max-staleness
- [ ] load-balancers
- [ ] mongodb-handshake
- [ ] wireversion-featurelist
- [ ] find_getmore_killcursors_commands
- [ ] server_write_commands
- [ ] enumerate-collections
- [ ] enumerate-databases
- [ ] compression
- [ ] OP_MSG

## Correctness (Reliability)
- [ ] retryable-reads
- [ ] retryable-writes
- [ ] client-backpressure
- [ ] crud
- [ ] command-logging-and-monitoring
- [ ] logging
- [ ] cursors

## Features (Progressive Enhancements)
- [ ] auth (SCRAM-SHA-1/256, mongodb-aws, mongodb-oidc, x509)
- [ ] transactions
- [ ] causal-consistency
- [ ] change-streams
- [ ] index-management
- [ ] gridfs
- [ ] client-side-operations-timeout
- [ ] client-side-encryption
- [ ] versioned-api

## Testing & Meta
- [ ] unified-test-format
- [ ] benchmarking
- [ ] driver-mantras
- [ ] driver-bulk-update
