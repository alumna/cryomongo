#!/usr/bin/env bash
# HAProxy PROXY v2 in front of mongos load-balancer ports.
#
# Official load-balancer UTF talks to one HAProxy host with loadBalanced=true.
# SINGLE_MONGOS_LB_URI (:8000) has one mongos behind it.
# MULTI_MONGOS_LB_URI (:8001) has two mongos behind it. The URI still has one
# host; loadBalanced=true cannot list two hosts.
#
# This matches drivers-evergreen-tools/.evergreen/run-load-balancer.sh
# (backends 27050/27051, frontends 8000/8001, send-proxy-v2).
#
# mongos 8.0 must listen on those backends with:
#   --setParameter loadBalancerPort=27050
# not --loadBalancerPort (that flag does not exist on 8.0.29).
#
# GitHub Actions: .github/workflows/specs.yml starts a sharded cluster with
# those ports, installs haproxy, then runs this script.
#
# Local:
#   sudo scripts/mongo-topology.sh load-balanced
#   source tmp/lb-uri.env
#   crystal spec
#
# Usage:
#   spec/support/run-load-balancer.sh start
#   spec/support/run-load-balancer.sh stop
#
# Optional env: LB_BACKEND_1, LB_BACKEND_2, LB_FRONT_1, LB_FRONT_2.

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
# Health-check the normal mongos ports. The load-balancer ports need PROXY v2,
# so a plain TCP check there marks the backend down.
CHECK1="${LB_CHECK_PORT_1:-27017}"
CHECK2="${LB_CHECK_PORT_2:-27016}"

need_haproxy() {
  if ! command -v haproxy >/dev/null 2>&1; then
    echo "haproxy is not installed. Linux: sudo apt-get install -y haproxy. macOS: brew install haproxy." >&2
    exit 1
  fi
}

remove_sock() {
  # A leftover sock owned by root (prior sudo start) blocks bind.
  local sock="${TMP}/haproxy.sock"
  rm -f "$sock" 2>/dev/null || sudo rm -f "$sock" 2>/dev/null || true
}

wait_backends_up() {
  local sock="${TMP}/haproxy.sock"
  python3 - "$sock" <<'PY'
import socket, sys, time
path = sys.argv[1]
for _ in range(50):
    data = b""
    try:
        s = socket.socket(socket.AF_UNIX)
        s.settimeout(1)
        s.connect(path)
        s.sendall(b"show stat\n")
        while True:
            chunk = s.recv(4096)
            if not chunk:
                break
            data += chunk
        s.close()
    except Exception:
        time.sleep(0.1)
        continue
    up = 0
    for line in data.decode("utf-8", "replace").splitlines():
        if line.startswith("mongoses_backend,mongos_"):
            parts = line.split(",")
            if len(parts) > 17 and parts[17] == "UP":
                up += 1
    if up >= 2:
        sys.exit(0)
    time.sleep(0.1)
print("HAProxy mongoses backends are not both UP", file=sys.stderr)
sys.exit(1)
PY
}

start() {
  need_haproxy
  mkdir -p "$TMP"
  stop >/dev/null 2>&1 || true
  remove_sock

  cat > "$CONF" <<EOF
global
    stats socket ${TMP}/haproxy.sock mode 666 level admin

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
    # Do not health-check the load-balancer port. mongos expects PROXY v2
    # on that port, so a plain TCP check fails and HAProxy marks the server down.
    server mongos ${LB1} send-proxy-v2

backend mongoses_backend
    mode tcp
    # roundrobin so two sequential sockets go to different mongos (leastconn
    # can send both to one mongos when they start with the same idle count).
    balance roundrobin
    retries 0
    option redispatch
    server mongos_one ${LB1} send-proxy-v2 check port ${CHECK1}
    server mongos_two ${LB2} send-proxy-v2 check port ${CHECK2}
EOF

  haproxy -D -f "$CONF" -p "$PIDFILE"
  wait_backends_up
  AUTH_USER="${AUTH_USER:-bob}"
  AUTH_PASS="${AUTH_PASS:-pwd123}"
  AUTH_DB="${AUTH_DB:-admin}"
  SINGLE="mongodb://${AUTH_USER}:${AUTH_PASS}@127.0.0.1:${FRONT1}/?loadBalanced=true&authSource=${AUTH_DB}"
  MULTI="mongodb://${AUTH_USER}:${AUTH_PASS}@127.0.0.1:${FRONT2}/?loadBalanced=true&authSource=${AUTH_DB}"
  cat > "$ENVFILE" <<EOF
export SINGLE_MONGOS_LB_URI='${SINGLE}'
export MULTI_MONGOS_LB_URI='${MULTI}'
export MONGODB_URI='${SINGLE}'
export TOPOLOGY=load-balanced
export UTF_RUN_TWO_MONGOS=1
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
  remove_sock
}

case "${1:-}" in
  start) start ;;
  stop) stop ;;
  *)
    echo "usage: $0 start|stop" >&2
    exit 2
    ;;
esac
