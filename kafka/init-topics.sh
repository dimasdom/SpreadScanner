#!/bin/sh
# Creates the Kafka topics the platform uses. Idempotent: safe to run on every `docker compose up`.
#
# Broker-side auto-creation is disabled, so this is the only place topics come from.
# Partition counts are NEVER altered automatically: adding partitions remaps keys to
# different partitions and breaks per-key ordering across the change. If the live count
# differs from the requested one this script only warns - see docs/architecture/kafka-operations.md.
set -eu

BOOTSTRAP="${KAFKA_BOOTSTRAP_SERVERS:-kafka:9092}"
PARTITIONS="${KAFKA_TOPIC_PARTITIONS:-12}"
DLQ_PARTITIONS="${KAFKA_DLQ_PARTITIONS:-1}"
REPLICATION="${KAFKA_REPLICATION_FACTOR:-1}"
MIN_ISR="${KAFKA_MIN_INSYNC_REPLICAS:-1}"
RETENTION_MS="${KAFKA_SPREADS_RETENTION_MS:-604800000}"      # 7 days
DLQ_RETENTION_MS="${KAFKA_DLQ_RETENTION_MS:-2592000000}"     # 30 days
KT=/opt/kafka/bin/kafka-topics.sh

ensure_topic() {
  name="$1"; partitions="$2"; retention="$3"

  "$KT" --bootstrap-server "$BOOTSTRAP" --create --if-not-exists \
    --topic "$name" \
    --partitions "$partitions" \
    --replication-factor "$REPLICATION" \
    --config "retention.ms=$retention" \
    --config "min.insync.replicas=$MIN_ISR"

  actual="$("$KT" --bootstrap-server "$BOOTSTRAP" --describe --topic "$name" | sed -n 's/.*PartitionCount: *\([0-9][0-9]*\).*/\1/p' | head -n 1)"
  if [ -n "$actual" ] && [ "$actual" != "$partitions" ]; then
    echo "WARNING: topic '$name' has $actual partitions but $partitions were requested; leaving it unchanged (changing it remaps keys)." >&2
  fi
}

ensure_topic spreads "$PARTITIONS" "$RETENTION_MS"
ensure_topic spreads.dlq "$DLQ_PARTITIONS" "$DLQ_RETENTION_MS"

echo "Kafka topics ready:"
"$KT" --bootstrap-server "$BOOTSTRAP" --list
