# Kafka operations guide

Companion to [kafka-migration-plan.md](kafka-migration-plan.md). Everything here applies to the single-node KRaft broker in `docker-compose.yml`.

## What runs

| Service | Purpose |
|---|---|
| `kafka` | `apache/kafka:3.9.1`, KRaft (broker + controller in one node). PLAINTEXT, **no host port** — compose network only. Broker-side topic auto-creation is **off**. Heap capped at 512 MB (`KAFKA_HEAP_OPTS`). |
| `kafka-init` | One-shot. Creates `spreads` and `spreads.dlq` ([kafka/init-topics.sh](../../kafka/init-topics.sh)), then exits. Idempotent. |
| `kafka-exporter` | Exposes `kafka_consumergroup_lag` (per partition per group), offsets and group membership to Prometheus (job `kafka`). |
| `kafka-ui` | Optional inspection UI, profile `tools`, bound to `127.0.0.1:8088`. Has no auth — never publish it. |

Services that need topics should declare:

```yaml
depends_on:
  kafka:      { condition: service_healthy }
  kafka-init: { condition: service_completed_successfully }
```

## Topics

| Topic | Key | Retention | Partitions | Notes |
|---|---|---|---|---|
| `spreads` | `{type}:{exLo}:{exHi}:{pair}` (see `SpreadKey`) | 7 d | `KAFKA_TOPIC_PARTITIONS` (default 12) | Value = protobuf `TradeOpportunityModel`. |
| `spreads.dlq` | same as source | 30 d | `KAFKA_DLQ_PARTITIONS` (default 1) | Headers `dlq-error`, `dlq-attempts`, `dlq-source-topic/partition/offset`, `dlq-failed-at`. |

The topic name `spreads.dlq` contains a period; kafka-exporter warns that `.` and `_` could collide in *metric* names. Harmless unless a topic named `spreads_dlq` also exists — don't create one.

## Sizing partitions

```
partitions = ceil( peak events/s ÷ sustained per-consumer events/s ) × headroom (2–3×)
```

Current load is about 100 events/min (<2/s) and each consumer group has one instance, so even 3 partitions would do. The default of 12 leaves room to run up to 12 instances of a group.

- Partitions can be **added, never removed**.
- Adding partitions **remaps keys**: a spread whose key now hashes to a different partition loses ordering relative to its earlier events. Do it only in a quiet window, after draining consumers, and treat it like a key-format change.
- `init-topics.sh` never alters an existing topic; it prints a warning if the live count differs from the requested one.
- Never change the key format casually — it has the same effect. The format is pinned by `spread-key-vectors.json` in both repos.

## Replication (production)

This deployment is a single VPS with one broker, so production runs `KAFKA_REPLICATION_FACTOR=1`. On a three-broker cluster use:

```
KAFKA_REPLICATION_FACTOR=3
KAFKA_MIN_INSYNC_REPLICAS=2
```

with producers on `acks=all` (already the default) so a write is acknowledged only once two replicas have it. The internal `__consumer_offsets` / transaction-log replication settings in the compose file must be raised to 3 as well.

Resource budget for the single broker: about 512 MB heap plus page cache; `kafka-exporter` is negligible.

## Local development

```bash
docker compose -f docker-compose.yml -f docker-compose.local.yml up -d kafka kafka-init kafka-exporter
docker compose --profile tools up -d kafka-ui            # optional, http://localhost:8088
```

The local override adds a host listener, so a `dotnet run` service connects with `Kafka__BootstrapServers=localhost:29092`. Containers use `kafka:9092`.

## Configuration (options pattern, env vars)

| Env var | Meaning | Default |
|---|---|---|
| `Kafka__BootstrapServers` | Broker address | `localhost:9092` |
| `Kafka__ClientId` | Client id shown in broker logs | per service |
| `Kafka__Consumer__GroupId` | Consumer group (required for consumers) | — |
| `Kafka__Consumer__Topic` | Topic to subscribe to | `spreads` |
| `Kafka__Consumer__AutoOffsetReset` | Start position for a group with no committed offset | `Latest` |
| `Kafka__Consumer__CommitBatchSize` / `CommitIntervalSeconds` | Commit every N messages or T seconds | 100 / 5 |
| `Kafka__Consumer__MaxHandlerAttempts` | Tries before dead-lettering | 3 |
| `Kafka__Consumer__MaxPollIntervalMs` | Longest a handler may run | 600000 |

No credentials are involved: the broker is PLAINTEXT on a private network. If it is ever exposed beyond the compose network, add SASL/TLS first and pass secrets through env vars, never the repository.

## Inspecting and replaying

```bash
# Consumer group state and lag
docker exec arbiscanner-kafka /opt/kafka/bin/kafka-consumer-groups.sh --bootstrap-server localhost:9092 --describe --group webapp-spreads

# Look at dead letters (headers explain why)
docker exec arbiscanner-kafka /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server localhost:9092 \
  --topic spreads.dlq --from-beginning --property print.headers=true --property print.key=true --timeout-ms 10000
```

Replay = re-publish the payload to `spreads` with the same key once the cause is fixed (manual for now; the headers carry the source topic/partition/offset).

**Resetting offsets replays side effects.** Rewinding `telegram-spreads` would re-send Telegram alerts, and rewinding `webapp-spreads` re-runs writes (deduplicated by `message-id` for 15 minutes only). Stop the consumers, reset deliberately, and expect duplicates.

## Alerts and dashboard

- Rules: [observability/prometheus/rules/kafka.rules.yaml](../../observability/prometheus/rules/kafka.rules.yaml), unit-tested by `kafka.test.yaml` (`promtool test rules`, also run in CI).
  - `KafkaConsumerLagGrowing` — lag > 100 **and** still rising for 10 min (a burst that drains does not fire; `*-shadow` groups are excluded).
  - `KafkaConsumerGroupHasNoMembers`, `KafkaBrokerDown`, `KafkaExporterDown`, `KafkaDeadLetterMessages`.
- There is no Alertmanager yet: firing alerts show at `/prometheus/alerts` and on the **Kafka** dashboard (Grafana → ArbiScanner folder). Add Alertmanager or Grafana alerting when push notifications are wanted.
