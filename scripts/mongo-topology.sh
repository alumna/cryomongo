#!/usr/bin/env bash
# Start a local MongoDB 8.0 topology on 127.0.0.1 (native binaries, no Docker).
#
# Usage:
#   sudo scripts/mongo-topology.sh standalone
#   sudo scripts/mongo-topology.sh replicaset
#   sudo scripts/mongo-topology.sh sharded
#   sudo scripts/mongo-topology.sh load-balanced
#   scripts/mongo-topology.sh status
#   scripts/mongo-topology.sh stop
#
# replicaset uses scripts/mongo-rs.sh (systemd or ./data).
# load-balanced starts sharded mongos with loadBalancerPort, then HAProxy.

set -euo pipefail

# Ubuntu 26.04 + newer kernels: mongod 8.0 needs this or it aborts in TCMalloc/rseq.
export GLIBC_TUNABLES="${GLIBC_TUNABLES:-glibc.pthread.rseq=1}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DATA="${ROOT}/data"
MONGOD_PARAMS=(--setParameter enableTestCommands=1 --setParameter acceptApiVersion2=1 --setParameter transactionLifetimeLimitSeconds=20)
# mongos rejects mongod-only parameters such as transactionLifetimeLimitSeconds
MONGOS_PARAMS=(--setParameter enableTestCommands=1 --setParameter acceptApiVersion2=1)

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
  sudo systemctl stop mongod 2>/dev/null || true
  # Give --fork children time to exit before a hard kill and sock unlink.
  sleep 1
  pkill -9 -f "mongos --configdb" || true
  pkill -9 -f "mongod --configsvr" || true
  pkill -9 -f "mongod --shardsvr" || true
  # mongos --fork as root leaves /tmp/mongodb-*.sock. systemd mongod (mongodb
  # user) then fails with "Failed to unlink socket file" (exit 14).
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

start_standalone() {
  stop_all
  # Sharded mongos can hold 27017 until the kernel releases the port.
  sleep 1
  mkdir -p "$DATA/standalone"
  mongod --port 27017 --bind_ip 127.0.0.1 --dbpath "$DATA/standalone" \
    --pidfilepath "$DATA/mongod.pid" --logpath "$DATA/standalone.log" --fork \
    "${MONGOD_PARAMS[@]}"
  wait_port 27017
  echo "standalone is ready on 27017"
}

start_replicaset() {
  stop_all
  # Standalone --fork can hold 27017 until the kernel releases the port.
  sleep 1
  "$ROOT/scripts/mongo-rs.sh" configure-systemd
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

# Leftover dbpath is already a replica set. Ignore that error so a second start works.
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
  mkdir -p "$DATA/cfg" "$DATA/shard"
  mongod --configsvr --replSet cfg --port 27019 --bind_ip 127.0.0.1 \
    --dbpath "$DATA/cfg" --logpath "$DATA/cfg.log" --fork "${MONGOD_PARAMS[@]}"
  mongod --shardsvr --replSet shard0 --port 27018 --bind_ip 127.0.0.1 \
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
}

start_load_balanced() {
  start_sharded
  "$ROOT/scripts/run-load-balancer.sh" start
  echo "load-balanced UTF: source ${ROOT}/tmp/lb-uri.env"
}

cmd="${1:-status}"
case "$cmd" in
  status) status ;;
  stop) stop_all ;;
  standalone) start_standalone ;;
  replicaset) start_replicaset ;;
  sharded) start_sharded ;;
  load-balanced) start_load_balanced ;;
  *)
    echo "usage: $0 status|stop|standalone|replicaset|sharded|load-balanced" >&2
    exit 2
    ;;
esac
