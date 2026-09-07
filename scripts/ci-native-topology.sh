#!/usr/bin/env bash
# Start MongoDB 8.0 topologies on GitHub macOS using native Community binaries.
# Do not call scripts/docker-topology.sh here (Linux images do not run on macOS).
#
# Usage (GitHub macOS arm64):
#   scripts/download-mongodb-community.sh
#   export PATH="${PWD}/tmp/mongodb/bin:$PATH"
#   scripts/ci-native-topology.sh standalone|replicaset|sharded|load-balanced
#   scripts/ci-native-topology.sh stop
#
# Same layout and test parameters as scripts/mongo-topology.sh (enableTestCommands,
# loadBalancerPort, bob/pwd123). No systemd, no sudo, no --fork assumptions beyond
# macOS mongod. WiredTiger cache defaults to 0.5 GiB per mongod (GitHub macOS RAM).
#
# Linux: refuse (workbench / GitHub Linux use docker-topology.sh or mongo-topology.sh).
# Windows: leftover — the driver does not compile (see WAVES.md Wave 29).

set -euo pipefail

if [[ "$(uname -s 2>/dev/null || echo unknown)" != "Darwin" ]]; then
  echo "scripts/ci-native-topology.sh is for GitHub macOS." >&2
  echo "Linux CI uses scripts/docker-topology.sh." >&2
  echo "Windows GitHub is leftover (the driver does not compile)." >&2
  exit 2
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DATA="${ROOT}/data"
BIN="${MONGODB_BIN:-${ROOT}/tmp/mongodb/bin}"
export PATH="${BIN}:${PATH}"
WT_CACHE_GB="${WT_CACHE_GB:-0.5}"

MONGOD_PARAMS=(--setParameter enableTestCommands=1 --setParameter acceptApiVersion2=1 --setParameter transactionLifetimeLimitSeconds=20 --setParameter minWaitForStreamingHelloMillis=0)
MONGOS_PARAMS=(--setParameter enableTestCommands=1 --setParameter acceptApiVersion2=1 --setParameter minWaitForStreamingHelloMillis=0)

need_bins() {
  local missing=0
  local name
  for name in mongod mongos mongosh; do
    if ! command -v "$name" >/dev/null 2>&1; then
      echo "missing ${name} (PATH=${PATH})" >&2
      missing=1
    fi
  done
  if [[ "$missing" == "1" ]]; then
    echo "Run scripts/download-mongodb-community.sh first." >&2
    exit 1
  fi
}

status() {
  if mongosh --quiet --eval 'db.hello().ok' >/dev/null 2>&1; then
    mongosh --quiet --eval '
      const h = db.hello();
      print("ok=" + h.ok);
      print("msg=" + (h.msg || ""));
      print("setName=" + (h.setName || "(none)"));
      print("isWritablePrimary=" + h.isWritablePrimary);
    '
  else
    echo "mongod/mongos is not reachable on 127.0.0.1:27017"
    return 1
  fi
}

stop_all() {
  "$ROOT/scripts/run-load-balancer.sh" stop 2>/dev/null || true
  pkill -f "mongos --configdb" || true
  pkill -f "mongod --configsvr" || true
  pkill -f "mongod --shardsvr" || true
  if [[ -f "${DATA}/mongod.pid" ]]; then
    kill "$(cat "${DATA}/mongod.pid")" || true
    rm -f "${DATA}/mongod.pid"
  fi
  pkill -f "mongod --replSet rs0" || true
  sleep 1
  pkill -9 -f "mongos --configdb" || true
  pkill -9 -f "mongod --configsvr" || true
  pkill -9 -f "mongod --shardsvr" || true
  pkill -9 -f "mongod --replSet rs0" || true
  rm -f /tmp/mongodb-27016.sock /tmp/mongodb-27017.sock /tmp/mongodb-27018.sock \
    /tmp/mongodb-27019.sock /tmp/mongodb-27050.sock /tmp/mongodb-27051.sock
}

wait_port() {
  local port="$1"
  for _ in $(seq 1 40); do
    if mongosh --port "$port" --quiet --eval 'db.runCommand({ping:1}).ok' >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  echo "timed out waiting for port $port" >&2
  return 1
}

TEST_USER="${TEST_USER:-bob}"
TEST_PWD="${TEST_PWD:-pwd123}"
TEST_AUTH_DB="${TEST_AUTH_DB:-admin}"

create_test_user() {
  local seed="${1:-27017}"
  local primary_port
  primary_port=$(mongosh --port "$seed" --quiet --eval '
    const h = db.hello();
    if (h.isWritablePrimary) { print("" + (h.me || "").split(":").pop()); quit(0); }
    if (h.primary) { print("" + h.primary.split(":").pop()); quit(0); }
    quit(1);
  ')
  mongosh --port "$primary_port" --quiet --eval "
    try {
      db.getSiblingDB('${TEST_AUTH_DB}').createUser({
        user: '${TEST_USER}',
        pwd: '${TEST_PWD}',
        roles: [ { role: 'root', db: 'admin' } ]
      });
    } catch (e) {
      const m = e.message || String(e);
      if (m.indexOf('already exists') === -1) throw e;
    }
  "
}

write_uri_env() {
  local topology="$1"
  mkdir -p "$ROOT/tmp"
  local uri
  case "$topology" in
    standalone)
      uri="mongodb://${TEST_USER}:${TEST_PWD}@127.0.0.1:27017/?authSource=${TEST_AUTH_DB}"
      ;;
    replicaset)
      uri="mongodb://${TEST_USER}:${TEST_PWD}@127.0.0.1:27017/?replicaSet=rs0&authSource=${TEST_AUTH_DB}"
      ;;
    sharded)
      uri="mongodb://${TEST_USER}:${TEST_PWD}@127.0.0.1:27017,127.0.0.1:27016/?authSource=${TEST_AUTH_DB}"
      ;;
    load-balanced)
      uri="mongodb://${TEST_USER}:${TEST_PWD}@127.0.0.1:8000/?loadBalanced=true&authSource=${TEST_AUTH_DB}"
      ;;
    *)
      uri="mongodb://${TEST_USER}:${TEST_PWD}@127.0.0.1:27017/?authSource=${TEST_AUTH_DB}"
      ;;
  esac
  cat > "$ROOT/tmp/mongo-uri.env" <<EOF
export MONGODB_URI='${uri}'
export TOPOLOGY='${topology}'
EOF
  echo "UTF with auth: source ${ROOT}/tmp/mongo-uri.env"
}

start_standalone() {
  stop_all
  sleep 1
  mkdir -p "$DATA/standalone"
  mongod --port 27017 --bind_ip 127.0.0.1 --dbpath "$DATA/standalone" \
    --pidfilepath "$DATA/mongod.pid" --logpath "$DATA/standalone.log" --fork \
    --wiredTigerCacheSizeGB "$WT_CACHE_GB" \
    "${MONGOD_PARAMS[@]}"
  wait_port 27017
  create_test_user 27017
  write_uri_env standalone
  echo "standalone is ready on 27017"
}

start_rs_member() {
  local port="$1" dir="$2" log="$3"
  mkdir -p "$dir"
  mongod --replSet rs0 --port "$port" --bind_ip 127.0.0.1 \
    --wiredTigerCacheSizeGB "$WT_CACHE_GB" \
    --dbpath "$dir" --logpath "$log" --fork "${MONGOD_PARAMS[@]}"
}

wait_rs_members() {
  for _ in $(seq 1 40); do
    if mongosh --port 27017 --quiet --eval '
      const s = rs.status();
      if (!s.ok) quit(1);
      const members = s.members || [];
      const n = members.filter(m => m.stateStr === "PRIMARY" || m.stateStr === "SECONDARY").length;
      const primary = members.some(m => m.stateStr === "PRIMARY");
      quit(primary && n >= 3 ? 0 : 1);
    ' >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  echo "timed out waiting for 3 replica set members with a primary" >&2
  return 1
}

start_replicaset() {
  stop_all
  sleep 1
  rm -rf "$DATA/rs0-0" "$DATA/rs0-1" "$DATA/rs0-2"
  start_rs_member 27017 "$DATA/rs0-0" "$DATA/rs0-0.log"
  start_rs_member 27018 "$DATA/rs0-1" "$DATA/rs0-1.log"
  start_rs_member 27019 "$DATA/rs0-2" "$DATA/rs0-2.log"
  wait_port 27017
  wait_port 27018
  wait_port 27019
  initiate_rs 27017 '{_id:"rs0",members:[{_id:0,host:"127.0.0.1:27017"},{_id:1,host:"127.0.0.1:27018"},{_id:2,host:"127.0.0.1:27019"}]}'
  wait_rs_members
  for port in 27017 27018 27019; do
    mongosh --port "$port" --quiet --eval 'db.adminCommand({setParameter: 1, minWaitForStreamingHelloMillis: 0})' >/dev/null || true
  done
  create_test_user 27017
  write_uri_env replicaset
  echo "replicaset is ready on 27017 (3 members: 27017, 27018, 27019)"
}

wait_primary() {
  local port="$1"
  for _ in $(seq 1 30); do
    if mongosh --port "$port" --quiet --eval 'db.hello().isWritablePrimary' 2>/dev/null | grep -q true; then
      return 0
    fi
    sleep 1
  done
  echo "timed out waiting for primary on port $port" >&2
  return 1
}

initiate_rs() {
  local port="$1"
  local doc="$2"
  mongosh --port "$port" --quiet --eval "
    try {
      rs.initiate(${doc});
    } catch (e) {
      const m = e.message || String(e);
      if (m.indexOf('already initialized') === -1) {
        throw e;
      }
    }
  "
}

start_sharded() {
  stop_all
  sleep 1
  mkdir -p "$DATA/cfg" "$DATA/shard"
  mongod --configsvr --replSet cfg --port 27019 --bind_ip 127.0.0.1 \
    --wiredTigerCacheSizeGB "$WT_CACHE_GB" \
    --dbpath "$DATA/cfg" --logpath "$DATA/cfg.log" --fork "${MONGOD_PARAMS[@]}"
  mongod --shardsvr --replSet shard0 --port 27018 --bind_ip 127.0.0.1 \
    --wiredTigerCacheSizeGB "$WT_CACHE_GB" \
    --dbpath "$DATA/shard" --logpath "$DATA/shard.log" --fork "${MONGOD_PARAMS[@]}"
  wait_port 27019
  wait_port 27018
  initiate_rs 27019 '{_id:"cfg",configsvr:true,members:[{_id:0,host:"127.0.0.1:27019"}]}'
  initiate_rs 27018 '{_id:"shard0",members:[{_id:0,host:"127.0.0.1:27018"}]}'
  wait_primary 27019
  wait_primary 27018
  mongos --configdb cfg/127.0.0.1:27019 --port 27017 --bind_ip 127.0.0.1 --fork \
    --logpath "$DATA/mongos.log" "${MONGOS_PARAMS[@]}" --setParameter loadBalancerPort=27050
  if ! wait_port 27017; then
    echo "mongos failed to start; last log lines:" >&2
    tail -n 50 "$DATA/mongos.log" >&2 || true
    return 1
  fi
  mongosh --quiet --eval '
    try {
      sh.addShard("shard0/127.0.0.1:27018");
    } catch (e) {
      const m = e.message || String(e);
      if (m.indexOf("already exists") === -1 && m.indexOf("duplicate") === -1) {
        throw e;
      }
    }
  '
  mongos --configdb cfg/127.0.0.1:27019 --port 27016 --bind_ip 127.0.0.1 --fork \
    --logpath "$DATA/mongos2.log" "${MONGOS_PARAMS[@]}" --setParameter loadBalancerPort=27051
  if ! wait_port 27016; then
    echo "mongos2 failed to start; last log lines:" >&2
    tail -n 50 "$DATA/mongos2.log" >&2 || true
    return 1
  fi
  echo "sharded cluster is ready on 27017 and 27016"
  echo "load-balancer ports: 27050 (mongos 27017) and 27051 (mongos 27016)"
  create_test_user 27017
  write_uri_env sharded
}

start_load_balanced() {
  start_sharded
  "$ROOT/scripts/run-load-balancer.sh" start
  write_uri_env load-balanced
  echo "load-balanced UTF: source ${ROOT}/tmp/lb-uri.env and ${ROOT}/tmp/mongo-uri.env"
}

cmd="${1:-status}"
case "$cmd" in
  status)
    need_bins
    status
    ;;
  stop) stop_all ;;
  standalone | replicaset | sharded | load-balanced)
    need_bins
    "start_${cmd//-/_}"
    ;;
  *)
    echo "usage: $0 status|stop|standalone|replicaset|sharded|load-balanced" >&2
    exit 2
    ;;
esac
