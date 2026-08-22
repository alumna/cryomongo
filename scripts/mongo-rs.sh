#!/usr/bin/env bash
# Configure or start a one-node MongoDB 8.0 replica set matching CI:
#   mongod --replSet rs0 --setParameter enableTestCommands=1
#
# Usage:
#   scripts/mongo-rs.sh status
#   sudo scripts/mongo-rs.sh configure-systemd   # edit /etc/mongod.conf
#   scripts/mongo-rs.sh initiate
#   scripts/mongo-rs.sh start-local              # project ./data, no systemd
#   scripts/mongo-rs.sh stop-local
#
# configure-systemd sets replSetName rs0, enableTestCommands, acceptApiVersion2,
# and transactionLifetimeLimitSeconds=20 (keeps failCommand WC tests shorter).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DATA="${ROOT}/data"
PIDFILE="${DATA}/mongod.pid"
LOGFILE="${DATA}/mongod.log"

status() {
  if mongosh --quiet --eval 'db.hello().me' >/dev/null 2>&1; then
    mongosh --quiet --eval '
      const h = db.hello();
      print("ok=" + h.ok);
      print("version=" + db.version());
      print("setName=" + (h.setName || "(none)"));
      print("isWritablePrimary=" + h.isWritablePrimary);
      print("maxWireVersion=" + h.maxWireVersion);
      const p = db.adminCommand({getParameter: 1, enableTestCommands: 1, acceptApiVersion2: 1, transactionLifetimeLimitSeconds: 1, minWaitForStreamingHelloMillis: 1});
      print("enableTestCommands=" + p.enableTestCommands);
      print("acceptApiVersion2=" + p.acceptApiVersion2);
      print("transactionLifetimeLimitSeconds=" + p.transactionLifetimeLimitSeconds);
      print("minWaitForStreamingHelloMillis=" + p.minWaitForStreamingHelloMillis);
    '
  else
    echo "mongod is not reachable on 127.0.0.1:27017"
    return 1
  fi
}

configure_systemd() {
  local conf="/etc/mongod.conf"
  if [[ ! -f "$conf" ]]; then
    echo "missing $conf" >&2
    exit 1
  fi
  sudo python3 - <<'PY'
from pathlib import Path
p = Path("/etc/mongod.conf")
text = p.read_text()
if "replSetName:" not in text:
    text = text.replace("#replication:", "replication:\n  replSetName: rs0")
    if "replication:\n  replSetName: rs0" not in text:
        text += "\nreplication:\n  replSetName: rs0\n"
if "enableTestCommands" not in text:
    text += "\nsetParameter:\n  enableTestCommands: 1\n"
if "acceptApiVersion2" not in text:
    if "setParameter:" in text:
        text = text.replace("  enableTestCommands: 1", "  enableTestCommands: 1\n  acceptApiVersion2: 1")
    else:
        text += "\nsetParameter:\n  enableTestCommands: 1\n  acceptApiVersion2: 1\n"
# Local-only: failCommand writeConcernError code 100 on commit can wait until
# this limit (default 60s). 20s keeps those tests honest and much faster.
if "transactionLifetimeLimitSeconds" not in text:
    if "setParameter:" in text:
        text = text.replace("  acceptApiVersion2: 1", "  acceptApiVersion2: 1\n  transactionLifetimeLimitSeconds: 20")
    else:
        text += "\nsetParameter:\n  transactionLifetimeLimitSeconds: 20\n"
# mongod 8.0 default 1000ms wait ignores maxAwaitTimeMS 200–750 (hello-timeout /
# interruptInUse UTF). 0 honors the driver's maxAwaitTimeMS.
if "minWaitForStreamingHelloMillis" not in text:
    if "setParameter:" in text:
        text = text.replace("  transactionLifetimeLimitSeconds: 20", "  transactionLifetimeLimitSeconds: 20\n  minWaitForStreamingHelloMillis: 0")
    else:
        text += "\nsetParameter:\n  minWaitForStreamingHelloMillis: 0\n"
p.write_text(text)
print(p.read_text())
PY
  sudo systemctl restart mongod
  echo "waiting for mongod..."
  for _ in $(seq 1 30); do
    if mongosh --quiet --eval 'db.runCommand({ping:1}).ok' >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
  initiate
}

initiate() {
  mongosh --quiet --eval '
    const h = db.hello();
    if (h.setName) {
      print("replica set already initiated: " + h.setName);
    } else {
      printjson(rs.initiate({_id: "rs0", members: [{_id: 0, host: "127.0.0.1:27017"}]}));
    }
  '
  for _ in $(seq 1 30); do
    if mongosh --quiet --eval 'db.hello().isWritablePrimary' 2>/dev/null | grep -q true; then
      echo "primary is ready"
      mongosh --quiet --eval 'db.adminCommand({setParameter: 1, minWaitForStreamingHelloMillis: 0})' >/dev/null
      return 0
    fi
    sleep 1
  done
  echo "timed out waiting for primary" >&2
  return 1
}

start_local() {
  mkdir -p "$DATA"
  if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "already running pid=$(cat "$PIDFILE")"
    return 0
  fi
  mongod --replSet rs0 --port 27017 --bind_ip 127.0.0.1 \
    --dbpath "$DATA" --pidfilepath "$PIDFILE" --logpath "$LOGFILE" --fork \
    --setParameter enableTestCommands=1 \
    --setParameter acceptApiVersion2=1 \
    --setParameter transactionLifetimeLimitSeconds=20 \
    --setParameter minWaitForStreamingHelloMillis=0
  initiate
}

stop_local() {
  if [[ -f "$PIDFILE" ]]; then
    kill "$(cat "$PIDFILE")" || true
    rm -f "$PIDFILE"
  fi
}

cmd="${1:-status}"
case "$cmd" in
  status) status ;;
  configure-systemd) configure_systemd ;;
  initiate) initiate ;;
  start-local) start_local ;;
  stop-local) stop_local ;;
  *)
    echo "usage: $0 status|configure-systemd|initiate|start-local|stop-local" >&2
    exit 2
    ;;
esac
