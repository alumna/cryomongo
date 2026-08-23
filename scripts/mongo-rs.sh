#!/usr/bin/env bash
# Status / one-node systemd helper, or a 3-member local replica set:
#   mongod --replSet rs0 --setParameter enableTestCommands=1
#
# Usage:
#   scripts/mongo-rs.sh status
#   sudo scripts/mongo-rs.sh configure-systemd   # one systemd member (legacy)
#   scripts/mongo-rs.sh initiate
#   scripts/mongo-rs.sh start-local              # 3 members in project ./data
#   scripts/mongo-rs.sh stop-local
#
# Prefer sudo scripts/mongo-topology.sh replicaset (3 members on 27017/27018/27019).
# configure-systemd sets replSetName rs0, enableTestCommands, acceptApiVersion2,
# and transactionLifetimeLimitSeconds=20 (keeps failCommand WC tests shorter).
# A one-member set cannot pass rediscover-quickly-after-step-down (3.7).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

status() {
  if mongosh --quiet --eval 'db.hello().me' >/dev/null 2>&1; then
    mongosh --quiet --eval '
      const h = db.hello();
      print("ok=" + h.ok);
      print("version=" + db.version());
      print("setName=" + (h.setName || "(none)"));
      print("isWritablePrimary=" + h.isWritablePrimary);
      print("maxWireVersion=" + h.maxWireVersion);
      print("hosts=" + ((h.hosts || []).join(",") || "(none)"));
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
  "$ROOT/scripts/mongo-topology.sh" replicaset
}

stop_local() {
  "$ROOT/scripts/mongo-topology.sh" stop
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
