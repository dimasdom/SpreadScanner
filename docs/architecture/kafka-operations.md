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

## Shadow mode runbook (Phase 2)

Everything ships **off**. Defaults reproduce today's behaviour exactly: the scanner publishes to RabbitMQ only, both consumers read RabbitMQ only, and Kafka is idle.

### Enable (in this order; each step is reversible by unsetting the variable and recreating that one service)

| # | Set (in `.env`) | Recreate | What it does |
|---|---|---|---|
| 1 | `MESSAGING_PUBLISH_KAFKA=true` | `arbitrage-scanner` | Scanner also publishes every event to Kafka after RabbitMQ succeeded. Never awaited, never throws. |
| 2 | `MESSAGING_CONSUMER_MODE_WEB=Shadow` | `web` | Adds consumer group `webapp-spreads-shadow` (decode + verify key + record, **no** Mongo/Postgres/SignalR writes) and the parity comparer. RabbitMQ consumption is untouched. |
| 3 | `MESSAGING_CONSUMER_MODE_TELEGRAM=Shadow` | `telegram-notifier` | Same for `telegram-spreads-shadow` (**no** Telegram messages). |

`kafka`/`kafka-init` are `required: false` dependencies of these services, so a Kafka problem can never stop them from starting while RabbitMQ is live. No Kafka health check is registered in shadow mode for the same reason.

### What to watch

- **Grafana → ArbiScanner → Kafka**: produce rate on `spreads` should track the RabbitMQ rate; lag for `*-shadow` groups should sit near 0 (those groups are excluded from the lag alert on purpose — they are diagnostic).
- **Service logs**: `Kafka partitions assigned`, `Shadow: would apply …`, and once per minute `Parity OK for …` (or `Parity MISMATCH …` listing spread keys).
- **Prometheus alerts** (`/prometheus/alerts`): `MessagingParityMismatch`, `MessagingKafkaKeyMismatch`, `KafkaShadowPublishFailing`, `KafkaDeadLetterMessages`.

Ignore the first ~3 minutes after each step: only minutes that begin after a service starts are compared, and the comparer waits 2 minutes for a minute to close.

### Cutover criteria (Phase 3 starts only when all hold)

1. At least 48 hours of shadow on both consumers with `MessagingParityMismatch` never firing and `missing_in_*` counters flat.
2. `KafkaDeadLetterMessages` and `KafkaShadowPublishFailing` quiet.
3. A deliberate restart of the scanner, of Kafka, and of each consumer during the soak, each followed by a clean parity result.

### How parity works

The scanner stamps each event with one `message-id` and one producer timestamp (seconds precision) on **both** brokers. Each consumer records `{message-id}|{key}` into a Redis set per `(service, backend, minute-of-producer-timestamp)`; the comparer diffs the RabbitMQ and Kafka sets for every closed minute and exports `arbiscanner_messaging_parity_{matched,missing_in_kafka,missing_in_rabbitmq,key_mismatch}_total{service=…}`. Sets are exact and redelivery-proof, expire after 3 hours, and cost a few hundred small members per minute at today's ~100 events/min.

Events published before the scanner was upgraded carry no message-id: they are processed through the legacy content-hash path and are not part of the parity data.

### Known behaviours

- A message the shadow consumer cannot process is retried, then dead-lettered to the shared `spreads.dlq`. That is intentional (a poison message would also fail the live consumer) but the DLQ cannot tell shadow and live groups apart yet.
- The RabbitMQ consumers now dedupe messages that carry a message-id with the same two-state Redis store the Kafka consumer will use (`spread-dedupe:{service}:{message-id}`). A crash mid-handler therefore retries the message after at most 60 s instead of skipping it as a duplicate for 15 minutes.
