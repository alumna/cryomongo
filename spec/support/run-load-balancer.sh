#!/usr/bin/env bash
# HAProxy PROXY v2 in front of mongos load-balancer ports.
# Official UTF uses SINGLE_MONGOS_LB_URI (one mongos) and MULTI_MONGOS_LB_URI (two).
# Same idea as drivers-evergreen-tools/.evergreen/run-load-balancer.sh.
#
# Usage:
#   spec/support/run-load-balancer.sh start
#   spec/support/run-load-balancer.sh stop
#
# Default backends: 127.0.0.1:27050 (mongos1) and 127.0.0.1:27051 (mongos2).
# Frontends: 8000 (one mongos) and 8001 (two mongos).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="${ROOT}/tmp"
CONF="${TMP}/haproxy-mongo.conf"
PIDFILE="${TMP}/haproxy-mongo.pid"
ENVFILE="${TMP}/lb-uri.env"

LB1="${LB_BACKEND_1:-127.0.0.1:27050}"
LB2="${LB_BACKEND_2:-127.0.0.1:27051}"
FRONT1="${LB_FRONT_1:-8000}"
FRONT2="${LB_FRONT_2:-8001}"

need_haproxy() {
  if ! command -v haproxy >/dev/null 2>&1; then
    echo "haproxy is not installed. Run: sudo apt-get install -y haproxy" >&2
    exit 1
  fi
}

start() {
  need_haproxy
  mkdir -p "$TMP"
  stop >/dev/null 2>&1 || true

  cat > "$CONF" <<EOF
defaults
    mode tcp
    timeout connect 10s
    timeout client 30m
    timeout server 30m

frontend mongos_frontend
    bind 127.0.0.1:${FRONT1}
    use_backend mongos_backend

frontend mongoses_frontend
    bind 127.0.0.1:${FRONT2}
    use_backend mongoses_backend

backend mongos_backend
    mode tcp
    server mongos ${LB1} check send-proxy-v2

backend mongoses_backend
    mode tcp
    server mongos_one ${LB1} check send-proxy-v2
    server mongos_two ${LB2} check send-proxy-v2
EOF

  haproxy -D -f "$CONF" -p "$PIDFILE"
  SINGLE="mongodb://127.0.0.1:${FRONT1}/?loadBalanced=true"
  MULTI="mongodb://127.0.0.1:${FRONT2}/?loadBalanced=true"
  cat > "$ENVFILE" <<EOF
export SINGLE_MONGOS_LB_URI='${SINGLE}'
export MULTI_MONGOS_LB_URI='${MULTI}'
export MONGODB_URI='${SINGLE}'
export TOPOLOGY=load-balanced
EOF
  echo "SINGLE_MONGOS_LB_URI=${SINGLE}"
  echo "MULTI_MONGOS_LB_URI=${MULTI}"
  echo "source ${ENVFILE} before crystal spec"
}

stop() {
  if [[ -f "$PIDFILE" ]]; then
    kill -USR1 "$(cat "$PIDFILE")" 2>/dev/null || true
    rm -f "$PIDFILE" "$CONF"
  fi
}

case "${1:-}" in
  start) start ;;
  stop) stop ;;
  *)
    echo "usage: $0 start|stop" >&2
    exit 2
    ;;
esac
