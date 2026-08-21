#!/usr/bin/env bash
# Run Crystal specs. Default is offline suites plus live UTF on a replica set.
#
# Usage:
#   scripts/run-specs.sh              # offline + live UTF
#   scripts/run-specs.sh offline      # no mongod
#   scripts/run-specs.sh live         # unified runner only (needs a replica set)
#   scripts/run-specs.sh bson         # lib/bson specs only
#   scripts/run-specs.sh status       # replica-set readiness
#
# Live mode writes tmp/utf-timing.log. Watch it with: tail -f tmp/utf-timing.log

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

need_shards() {
  if [[ ! -d "$ROOT/lib/bson" ]]; then
    echo "shards are not installed. Run: shards install" >&2
    exit 1
  fi
}

offline() {
  need_shards
  echo "==> URI options (no mongod)"
  crystal spec spec/options_spec.cr
  echo "==> compression (no mongod)"
  crystal spec spec/compression_spec.cr
  echo "==> driver BSON helpers (no mongod)"
  crystal spec spec/driver_bson_spec.cr
  echo "==> handshake metadata (no mongod)"
  crystal spec spec/handshake_spec.cr
  echo "==> command redaction (no mongod)"
  crystal spec spec/redaction_spec.cr
  echo "==> RTT EWMA (no mongod)"
  crystal spec spec/rtt_spec.cr
  echo "==> server selection (no mongod)"
  crystal spec spec/server_selection_spec.cr
  echo "==> max staleness (no mongod)"
  crystal spec spec/max_staleness_spec.cr
  echo "==> auth connection-string (no mongod)"
  crystal spec spec/auth_connection_string_spec.cr
  echo "==> legacy SDAM (no mongod)"
  crystal spec spec/sdam_runner_spec.cr
}

bson() {
  if [[ ! -d "$ROOT/lib/bson" ]]; then
    echo "shards are not installed. Run: shards install" >&2
    exit 1
  fi
  echo "==> bson.cr specs (no mongod)"
  (cd "$ROOT/lib/bson" && crystal spec)
}

live() {
  need_shards
  if ! "$ROOT/scripts/mongo-rs.sh" status >/dev/null; then
    echo "mongod is not a ready replica set on 127.0.0.1:27017." >&2
    echo "Run one of:" >&2
    echo "  sudo $ROOT/scripts/mongo-rs.sh configure-systemd" >&2
    echo "  $ROOT/scripts/mongo-rs.sh start-local" >&2
    exit 1
  fi
  local timing="${UTF_TIMING_LOG:-$ROOT/tmp/utf-timing.log}"
  mkdir -p "$(dirname "$timing")"
  : > "$timing"
  echo "==> unified runner (live replica set)"
  echo "    timing log: $timing  (tail -f that file while it runs)"
  UTF_TIMING_LOG="$timing" crystal spec spec/unified_runner_spec.cr
}

cmd="${1:-all}"
case "$cmd" in
  status) "$ROOT/scripts/mongo-rs.sh" status ;;
  offline) offline ;;
  live) live ;;
  bson) bson ;;
  all)
    offline
    live
    ;;
  *)
    echo "usage: $0 [all|offline|live|bson|status]" >&2
    exit 2
    ;;
esac
