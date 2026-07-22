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
- [x] find_getmore_killcursors_commands
- [x] server_write_commands
- [x] enumerate-collections
- [x] enumerate-databases
- [ ] compression
- [ ] OP_MSG

## Correctness (Reliability)
- [x] retryable-reads
- [x] retryable-writes
- [ ] client-backpressure
- [x] crud
- [ ] command-logging-and-monitoring
- [ ] logging
- [ ] cursors

## Features (Progressive Enhancements)
- [ ] auth (SCRAM-SHA-1/256, mongodb-aws, mongodb-oidc, x509)
- [x] transactions (Core & Convenient API)
- [x] causal-consistency & sessions
- [ ] change-streams
- [ ] index-management
- [ ] gridfs
- [ ] client-side-operations-timeout
- [ ] client-side-encryption
- [ ] versioned-api

## Testing & Meta
- [x] unified-test-format
- [ ] benchmarking
- [ ] driver-mantras
- [ ] driver-bulk-update
