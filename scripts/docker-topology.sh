#!/usr/bin/env bash
# Start MongoDB 8.0 in Docker. Same layouts as GitHub Actions.
#
# Usage:
#   sudo scripts/docker-topology.sh standalone
#   sudo scripts/docker-topology.sh replicaset
#   sudo scripts/docker-topology.sh sharded
#   sudo scripts/docker-topology.sh load-balanced
#   sudo scripts/docker-topology.sh stop
#
# Needs Docker. Host ports: 27017 (and 27018/27019 for a 3-member replica set; 27016 for a second mongos).
# load-balanced also maps mongos load-balancer ports 27050 and 27051.
# After load-balanced: spec/support/run-load-balancer.sh start && source tmp/lb-uri.env
#
# Optional: MONGO_IMAGE (default mongo:8.0).

set -euo pipefail

IMAGE="${MONGO_IMAGE:-mongo:8.0}"
# minWaitForStreamingHelloMillis=0: mongod 8.0 default is 1000ms, which ignores
# maxAwaitTimeMS 200–750 and breaks hello-timeout / interruptInUse UTF.
MONGOD_PARAMS="--setParameter enableTestCommands=1 --setParameter acceptApiVersion2=1 --setParameter transactionLifetimeLimitSeconds=20 --setParameter minWaitForStreamingHelloMillis=0"
# mongos rejects mongod-only parameters such as transactionLifetimeLimitSeconds.
# minWaitForStreamingHelloMillis is accepted on mongos 8.0.
MONGOS_PARAMS="--setParameter enableTestCommands=1 --setParameter acceptApiVersion2=1 --setParameter minWaitForStreamingHelloMillis=0"

dump_logs() {
  local name="$1"
  echo "----- docker logs: $name -----" >&2
  docker logs "$name" >&2 || true
}

wait_running() {
  local name="$1"
  local extra=()
  if [ -n "${2:-}" ]; then
    extra=(--port "$2")
  fi
  for _ in $(seq 1 40); do
    if docker exec "$name" mongosh "${extra[@]}" --quiet --eval 'db.runCommand({ping:1}).ok' >/dev/null 2>&1; then
      return 0
    fi
    if [ "$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null || echo false)" != "true" ]; then
      echo "$name is not running" >&2
      dump_logs "$name"
      return 1
    fi
    sleep 1
  done
  echo "timed out waiting for $name" >&2
  dump_logs "$name"
  return 1
}

# Application URI user. Do not enable --auth. SASL still runs when the URI has
# userinfo, so failCommand on saslContinue and auth: true UTF can run.
TEST_USER="${TEST_USER:-bob}"
TEST_PWD="${TEST_PWD:-pwd123}"
TEST_AUTH_DB="${TEST_AUTH_DB:-admin}"

create_test_user() {
  local name="${1:-mongo}"
  local extra=()
  if [ -n "${2:-}" ]; then
    extra=(--port "$2")
  fi
  docker exec "$name" mongosh "${extra[@]}" --quiet --eval "
    try {
      db.getSiblingDB('${TEST_AUTH_DB}').createUser({
        user: '${TEST_USER}',
        pwd: '${TEST_PWD}',
        roles: [ { role: 'root', db: 'admin' } ]
      });
    } catch (e) {
      const m = e.message || String(e);
      if (m.indexOf('already exists') === -1) {
        print('createUser failed: ' + m);
        throw e;
      }
    }
  "
}

wait_primary() {
  local name="$1" port="$2"
  for _ in $(seq 1 40); do
    if docker exec "$name" mongosh --port "$port" --quiet --eval 'quit(db.hello().isWritablePrimary ? 0 : 1)' >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  echo "$name did not become primary" >&2
  dump_logs "$name"
  return 1
}

wait_rs_members() {
  local name="$1"
  for _ in $(seq 1 40); do
    # print/grep: mongosh quit() does not always set the process exit code.
    if docker exec "$name" mongosh --quiet --eval '
      const s = rs.status();
      if (!s.ok) { print("no"); }
      else {
        const members = s.members || [];
        const up = members.filter(m => m.stateStr === "PRIMARY" || m.stateStr === "SECONDARY").length;
        const hasPrimary = members.some(m => m.stateStr === "PRIMARY");
        print(up >= 3 && hasPrimary ? "yes" : "no");
      }
    ' 2>/dev/null | grep -qx 'yes'; then
      return 0
    fi
    sleep 1
  done
  echo "$name replica set members are not all up" >&2
  dump_logs "$name"
  return 1
}

# 27017 is often a secondary. Do not use mongosh quit() under set -e: a missing
# hello.primary exits 1 with no log, which is what GitHub replica set CI hit.
wait_any_primary() {
  local name="$1"
  local port
  for _ in $(seq 1 40); do
    for port in 27017 27018 27019; do
      if docker exec "$name" mongosh --port "$port" --quiet --eval 'print(db.runCommand({hello:1}).isWritablePrimary === true ? "PRIMARY" : "OTHER")' 2>/dev/null | grep -qx 'PRIMARY'; then
        echo "$port"
        return 0
      fi
    done
    sleep 1
  done
  echo "$name has no writable primary" >&2
  dump_logs "$name"
  return 1
}

stop_all() {
  docker rm -f mongos2 mongos shard cfg mongo 2>/dev/null || true
  docker network rm mongo-test 2>/dev/null || true
}

start_standalone() {
  stop_all
  docker run --name mongo -d -p 27017:27017 --tmpfs /data/db "$IMAGE" $MONGOD_PARAMS
  wait_running mongo
  create_test_user mongo
  echo "standalone is ready on 27017"
}

start_replicaset() {
  stop_all
  # Three mongods in one container. Hosts are 127.0.0.1 so the GitHub runner
  # can reach every member (hello.hosts) on published ports 27017-27019.
  docker run -d --name mongo --user root --entrypoint bash \
    -p 27017:27017 -p 27018:27018 -p 27019:27019 \
    --tmpfs /data/rs0 --tmpfs /data/rs1 --tmpfs /data/rs2 \
    "$IMAGE" \
    -c "mongod --replSet rs0 --port 27017 --bind_ip_all --dbpath /data/rs0 --fork --logpath /tmp/rs0.log $MONGOD_PARAMS
        mongod --replSet rs0 --port 27018 --bind_ip_all --dbpath /data/rs1 --fork --logpath /tmp/rs1.log $MONGOD_PARAMS
        mongod --replSet rs0 --port 27019 --bind_ip_all --dbpath /data/rs2 --fork --logpath /tmp/rs2.log $MONGOD_PARAMS
        exec tail -f /dev/null"
  wait_running mongo
  wait_running mongo 27018
  wait_running mongo 27019
  docker exec mongo mongosh --eval 'rs.initiate({_id:"rs0",members:[{_id:0,host:"127.0.0.1:27017"},{_id:1,host:"127.0.0.1:27018"},{_id:2,host:"127.0.0.1:27019"}]})'
  echo "waiting for replica set members and a writable primary..." >&2
  wait_rs_members mongo
  local primary_port
  primary_port=$(wait_any_primary mongo)
  echo "creating test user on primary port ${primary_port}" >&2
  create_test_user mongo "$primary_port"
  echo "replicaset is ready on 27017 (3 members: 27017, 27018, 27019; primary ${primary_port})"
}

# $1 = empty or "lb". lb maps PROXY v2 ports and sets loadBalancerPort.
start_sharded() {
  local lb="${1:-}"
  stop_all
  docker network create mongo-test
  docker run -d --name cfg --network mongo-test --network-alias cfg --tmpfs /data/db "$IMAGE" \
    mongod --configsvr --replSet cfg --port 27019 --bind_ip_all $MONGOD_PARAMS
  docker run -d --name shard --network mongo-test --network-alias shard --tmpfs /data/db "$IMAGE" \
    mongod --shardsvr --replSet shard0 --port 27018 --bind_ip_all $MONGOD_PARAMS
  wait_running cfg 27019
  wait_running shard 27018
  docker exec cfg mongosh --port 27019 --eval 'rs.initiate({_id:"cfg",configsvr:true,members:[{_id:0,host:"cfg:27019"}]})'
  docker exec shard mongosh --port 27018 --eval 'rs.initiate({_id:"shard0",members:[{_id:0,host:"shard:27018"}]})'
  wait_primary cfg 27019
  wait_primary shard 27018

  local mongos_lb="" mongos2_lb=""
  local mongos_ports="-p 27017:27017"
  local mongos2_ports="-p 27016:27017"
  if [ "$lb" = "lb" ]; then
    # mongos 8.0 uses --setParameter loadBalancerPort, not --loadBalancerPort.
    mongos_lb="--setParameter loadBalancerPort=27050"
    mongos2_lb="--setParameter loadBalancerPort=27051"
    mongos_ports="-p 27017:27017 -p 27050:27050"
    mongos2_ports="-p 27016:27017 -p 27051:27051"
  fi

  docker run -d --name mongos --network mongo-test $mongos_ports "$IMAGE" \
    mongos --configdb cfg/cfg:27019 --bind_ip_all $MONGOS_PARAMS $mongos_lb
  wait_running mongos
  docker exec mongos mongosh --eval 'sh.addShard("shard0/shard:27018")'
  docker run -d --name mongos2 --network mongo-test $mongos2_ports "$IMAGE" \
    mongos --configdb cfg/cfg:27019 --bind_ip_all $MONGOS_PARAMS $mongos2_lb
  wait_running mongos2
  create_test_user mongos
  echo "sharded cluster is ready on 27017 and 27016"
  if [ "$lb" = "lb" ]; then
    echo "load-balancer ports: 27050 (mongos 27017) and 27051 (mongos 27016)"
  fi
}

start_load_balanced() {
  start_sharded lb
  echo "Start HAProxy with: spec/support/run-load-balancer.sh start"
  echo "Then: source tmp/lb-uri.env"
}

cmd="${1:-}"
case "$cmd" in
  stop) stop_all ;;
  standalone) start_standalone ;;
  replicaset) start_replicaset ;;
  sharded) start_sharded ;;
  load-balanced) start_load_balanced ;;
  *)
    echo "usage: $0 stop|standalone|replicaset|sharded|load-balanced" >&2
    exit 2
    ;;
esac
