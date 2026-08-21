#!/usr/bin/env bash
# Start or stop HAProxy PROXY v2 in front of mongos load-balancer ports.
# The real script is spec/support/run-load-balancer.sh (GitHub calls that path).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec "$ROOT/spec/support/run-load-balancer.sh" "$@"
