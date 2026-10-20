# RabbitMQ → Kafka migration plan

Status: **All five phases implemented (awaiting review/merge).** Scope: `ArbitrageScanner` (producer), `ArbiScannerWebApp` (consumer), `ArbiScanner.TelegramNotifierApp` (consumer).
Supersedes [ADR-0001](../arc42/adr/0001-rabbitmq-fanout-protobuf.md) once Phase 5 lands (ADR-0007).

## 1. Current state (investigated)

There is **one** RabbitMQ flow: the spread lifecycle event.

| | |
|---|---|
| Producer | `ArbitrageScanner` — [ServicesCommunicationService.cs](../../ArbitrageScanner/ArbitrageScanner.Infrastructure/Services/ServicesCommunicationService.cs), called by the Futures / Spot / Funding observers |
| Exchange | `spread_fanout_exchange` (fanout, durable), publisher confirms + Polly retry |
| Message | protobuf-net `TradeOpportunityModel` (no `.proto` files; members 1–5, 7–19; 6 unused) |
| Rate | ≈100 events/min documented (`ArbiScannerUpd.md`, not measured here). Structurally: one Update per open spread per second, plus one Open and one Close |
| Queue `spread_api` | WebApp `RabbitMqService` + `MessageProcessingService`: Redis `SETNX` dedupe (15 min), 3 retries, nack → `spread_dlx` → `spread_api_dlq`. Open: Mongo upsert + ticker insert + SignalR. Update: replace + ticker insert + SignalR. Close: SignalR + mark closed + delete tickers |
| Queue `spread_telegram` | Telegram worker, **reuses WebApp's `RabbitMqService`** via project reference. Open: query Postgres users, send alerts. Update/Close: log only |

Not on the broker: prices and spread detection (in-process, ccxt websockets); scanner → Telegram channel post (HTTP); AdminPanel / McpServer / AiAssistant (HTTP only).

### Findings that shaped the plan

- No `prices` flow, no separate detector / tick-writer / pusher service → a `prices` topic is **out of scope**.
- ADR-0001 rejected Kafka at this scale; throughput is not the driver. ADR-0007 must state the real ones (replay, per-key ordering, independent consumer groups).
- `ExchangeLong/Short` flip with the spread sign; `ExchangeRateA/B` are stable (`FuturesPositionCalculatorService.cs:42-43`) → key uses sorted exchange names and includes `SpreadType`.
- SignalR has **no backplane**, compose runs one `web` instance → the `webapp-spreads` group stays at one replica.
- Ticker `_id` is unmapped in Mongo (`SetIdMember(null)`), inserts are not idempotent → add a `MessageId` field + unique `(Guid, MessageId)` index instead of touching `_id`.
- The Redis dedupe claim survives a crash mid-handler, so a redelivery is skipped as a duplicate and the message is lost (same hole exists today) → two-state dedupe (`processing` ~60 s, then `done` 15 min).
- Telegram's Open handler fans out rate-limited sends inside the consume loop → raise `max.poll.interval.ms` (~10 min), short-circuit Update/Close.
- Observability gaps: Grafana dashboards dir is empty, Prometheus has no rules file and no Alertmanager.
- CI/release is per submodule (SonarCloud + CodeQL in each); PR titles need Conventional Commits prefixes for release-please.

## 2. Design

### Topics

| Topic | Key | Notes |
|---|---|---|
| `spreads` | `{type}:{exLo}:{exHi}:{pair}` — lower-cased, whitespace-collapsed, exchanges sorted ordinally | Value = unchanged protobuf. Retention 7 d, no compaction |
| `spreads.dlq` | same as source | Error, attempt count, source topic/partition/offset in headers |

- Key formats live in one helper per repo (`SpreadKey`) and are pinned by a shared **golden-vector file** (`spread-key-vectors.json`) tested in both repos. Changing a key format remaps partitions — treat as a breaking change.
- Partitions configurable via `KAFKA_TOPIC_PARTITIONS`, default 12 locally. Sizing for production: `ceil(peak events/s ÷ per-consumer throughput × headroom)`; partitions can be added, never removed, and adding them remaps keys.
- Topics are created by the `kafka-init` container; broker auto-creation disabled.
- Local RF=1. Production is a single VPS, so RF=1 there too; RF=3 + `min.insync.replicas=2` documented for a future multi-broker deployment.

### Groups

`webapp-spreads` (one replica), `telegram-spreads`; live shadow groups carry a `-shadow` suffix.

### Producer (scanner)

Confluent.Kafka, `Acks=All`, `EnableIdempotence=true`, singleton wrapper, flush on shutdown. Headers on every message: `traceparent`, `tracestate`, `message-type`, `schema-version`, `message-id`. Awaits the delivery report so failure semantics match today (throws after retries); in shadow mode Kafka failures are counted and logged, never thrown.

### Consumer (shared library in WebApp, reused by Telegram)

`BackgroundService` loop; subscribe (never `Assign`); `EnableAutoCommit=false`; commit after processing every N messages or T seconds and on partition revoke; sequential processing per loop preserves per-partition order (cross-key parallelism deliberately not built — YAGNI at this volume); bounded retry with backoff then `spreads.dlq` then commit; DI scope per message. Neither real consumer holds per-key state, so revoke/assign handlers only commit.

### Overlap-safe cutover

The scanner generates one `message-id` and sets it on both the Kafka header and the AMQP `MessageId` property. Consumers dedupe on `spread-dedupe:{service}:{message-id}` (falling back to today's content hash when absent), so a window with both backends active is safe. Live groups start at `auto.offset.reset=latest` on first cutover so the shadow-period backlog is never replayed into user-facing alerts.

### Observability

`traceparent` injected on produce and extracted on consume (manual `ActivitySource`, OTel messaging semantic conventions). Lag per partition per group from `kafka-exporter` → Prometheus → Grafana panel + alert rule. Structured logs carry trace id, topic, partition, offset, key.

## 3. Phases

Each phase ends deployable with CI green. One PR per repo (Conventional Commits title), then a submodule-pointer bump in the root.

1. **Infrastructure + building blocks — no behaviour change.**
   Root: KRaft Kafka, `kafka-init`, Kafka UI, `kafka-exporter`, Prometheus scrape + rules, Grafana dashboard provisioning, env docs.
   WebApp: `ArbiScannerWeb.Messaging.Kafka` (options, consumer loop, headers/trace, two-state dedupe, retry/DLQ decision, `SpreadKey`) + unit tests + Testcontainers tests.
   Scanner: producer wrapper, `SpreadKey`, headers + unit tests.
   Rollback: nothing consumes any of it.
2. **Dual publish + shadow.** Scanner flags `Messaging__Publish__RabbitMq` / `Messaging__Publish__Kafka`. Ship message-id dedupe in the RabbitMQ consumers first. Consumer flag `Messaging__Consumer__Mode=RabbitMq|Shadow|Kafka`. Shadow = process + log, zero side effects. Parity check: per-minute per-key counters in Redis hashes (TTL) per backend + a comparer exporting a mismatch gauge (no per-key Prometheus labels).
3. **Cutover, one flag flip each, reversible:** Telegram first (stateless), WebApp second (with idempotent ticker insert).
4. **Remove RabbitMQ** (explicit approval first — deletes exchanges/queues/volume): code, health checks, nginx `/rabbitmq/` route, compose service, `sample.env` + appsettings keys, packages, RabbitMQ tests/fixtures; Kafka health check in all three services.
5. **Docs:** ADR-0007 (supersedes 0001; alternatives: stay on RabbitMQ, RabbitMQ Streams; where schema registry / Kubernetes / Streams-ksqlDB would fit later), arc42 sections + index, READMEs, CLAUDE.md.

### Phase 2 — as built (superseded by Phase 4)

> The dual-publish and shadow machinery described here was removed again in Phase 4. It is kept as a record of how the cutover was prepared.

- Scanner: `Messaging__Publish__RabbitMq` (default `true`) / `__Kafka` (default `false`). One `message-id` + producer timestamp shared by both brokers. Shadow Kafka publish is fire-and-observe; failures are counted, not thrown. Health: `rabbitmq` check only when RabbitMQ is published, `kafka` check only when Kafka is the sole path.
- Consumers: `Messaging__Consumer__Mode` = `RabbitMq` (default) | `Shadow` | `Kafka` (rejected at startup until Phase 3) plus `Messaging__ServiceName`. `Shadow` adds consumer group `{service}-spreads-shadow` with a side-effect-free handler and the parity comparer.
- Layering adjustment: the idempotency contract, spread key helper, protobuf contract and parity recorder/comparer live in `ArbiScannerWeb.Abstractions` / `.Infrastructure`; only Kafka-specific code is in `ArbiScannerWeb.Messaging.Kafka`. `ArbiScannerWeb.Infrastructure` must not reference the Kafka project because AdminPanel depends on it.
- RabbitMQ consumers dedupe on message-id with the two-state store (legacy messages keep the content-hash path).
- Operations: see the shadow-mode runbook in [kafka-operations.md](kafka-operations.md).

### Phase 3 — as built

The project is not deployed (it only exists as a GitHub repository), so the production-safety machinery of Phases 2–3 — a multi-day shadow soak, per-service staggered flag flips, a reversible rollout — has no live system to protect. Phase 3 therefore cuts over in one step and Compose now defaults to Kafka for the scanner, the web API and the Telegram notifier. The mode flags stay until Phase 4 so the legacy path can still be exercised in tests.

- **Web API** (`Messaging__Consumer__Mode=Kafka`): `TradeOpportunityKafkaHandler` in group `webapp-spreads` applies Open/Update/Close through `ITradeOpportunityService`. RabbitMQ is neither registered nor health-checked; a Kafka health check gates health instead.
- **Telegram** (`telegram-spreads`): `TelegramSpreadKafkaHandler`. Only Open alerts users; Update ignored; Close logged.
- **Failures now surface.** `ITradeOpportunityService` returns a `Result` and never throws; the RabbitMQ consumer ignored it and acked, so a failed write lost the event silently. The Kafka handler throws on `Result.IsFailed`, so the event is retried and then dead-lettered.
- **Idempotency:** `spread-dedupe:{service}:{message-id}` in the shared two-state store. Residual window: a crash between the ticker insert and the `done` marker can add one duplicate chart point after the 60 s claim expires. Deterministic ticker ids were considered and rejected: the ticker `_id` is deliberately unmapped and the model is shared with EF.
- **Replay protection:** an Open older than `Messaging__Consumer__MaxOpenAlertAgeMinutes` (default 10) is not alerted on, so an outage or offset reset never re-alerts users.
- **Dead letters:** a missing message-id, undecodable payload or unknown action is non-retryable and goes to `spreads.dlq` after one attempt.
- **Compose:** scanner `Messaging__Publish__Kafka=true`, `__RabbitMq=false`; both consumers default to `Kafka`; Kafka and `kafka-init` are now hard dependencies and RabbitMQ no longer gates these three services.
- **Phase 4 will also delete** the shadow handler, parity recorder/comparer, parity alerts and the mode flags: they exist only to compare two brokers.
- **Operational constraint:** the web API must stay at one replica (SignalR has no backplane), otherwise a spread would be pushed from whichever instance owns its partition.

### Phase 4 — as built

RabbitMQ is gone from every service, and so is the migration scaffolding that existed only to compare the two brokers. Nothing was deployed, so there were no queues, exchanges or data to preserve and no destructive step to confirm.

- **Scanner:** `ServicesCommunicationService` publishes to Kafka only (awaited; a failure is counted in `arbiscanner_messaging_publish_kafka_failures_total` and rethrown to the observer, as RabbitMQ failures were). `PostPossiblePositionFanout`, the topology declaration, `RabbitMqConnectionFactory`, `RabbitMqHealthCheck`, `MessagingPublishOptions` and the `RabbitMQ.Client`, `Polly.Core` and `Testcontainers.RabbitMq` packages are removed. The health endpoint reports `mongo` and `kafka`.
- **Web API:** `RabbitMqService`, `IRabbitMqService`, `MessageProcessingService`, `RabbitMqHealthCheck`, `RabbitMqSettings`, the shadow handler, the parity recorder / comparer / metrics, and the `Messaging:Consumer:Mode` switch are removed. `AddSpreadMessaging<THandler>` always registers the consumer and binds lazily from configuration. Health reports `postgres`, `mongo`, `redis`, `kafka`.
- **Telegram:** `SpreadsMessageBroker`, the RabbitMQ registration / settings / trace source and the parity meter are removed.
- **Tests:** all RabbitMQ unit and integration tests and fixtures are deleted; the Kafka suites (ordering, restart, duplicates, DLQ, rebalance, full-stack cutover, publisher) remain.
- **Root:** the `rabbitmq` service, its volume and config, the nginx `/rabbitmq/` route, all `RabbitMq__*` / `RABBITMQ_*` settings and the migration switches are removed; the parity alerts are replaced by `KafkaPublishFailing`. No Grafana dashboard ever existed for RabbitMQ, so none was removed.
- **Left for Phase 5:** README, arc42 and CLAUDE.md still describe RabbitMQ; ADR-0007 supersedes ADR-0001.

### Phase 5 — as built

- **ADR:** [`docs/arc42/adr/0007-kafka-event-backbone.md`](../arc42/adr/0007-kafka-event-backbone.md) — context, decision, alternatives (stay on RabbitMQ, RabbitMQ Streams, HTTP/database polling), consequences and trade-offs (operating cost, ordering vs parallelism, replay, the one-host/RF=1 reality, the single web replica, the contract without a schema registry), and where a schema registry, Kubernetes and Kafka Streams/ksqlDB would fit later. It lives in `docs/arc42/adr/` rather than the `docs/adr/` named in the original brief, because that is where the repository's existing ADRs (0001–0006) and their index live. ADR-0001 is marked superseded; its Protobuf decision still stands.
- **Architecture documentation:** arc42 sections 1, 3, 4, 5, 6 (the spread scenario was rewritten as the Open/Update/Close lifecycle with commit-after-processing), 7, 8, 9, 10, 11 (new Kafka, schema-registry and authentication risks), 12 and ADRs 0002 / 0005 / 0006.
- **READMEs and guides:** root `README.md`, `CLAUDE.md` (a new "Messaging is Kafka only" section of conventions), `MCP_TESTING.md`, `AI_ASSISTANT_TESTING.md`, `keycloak/README.md`, and the scanner, web API, Telegram notifier and MCP server READMEs.
- **Not touched on purpose:** `CHANGELOG.md` files (release-please owns them), `docs/investigations/` (point-in-time write-ups), and the personal / career documents (`PROFILE.md`, `MASTER_EXPERIENCE.md`, `ArbiScannerUpd.md`) and the `MASTER_README.md` snapshot, which still describe RabbitMQ.

### Out of scope

`prices` topic, separate detector/tick-writer services, SignalR backplane, conflation, schema registry, Kubernetes, Kafka Streams/ksqlDB.

## 4. Test plan

- Unit: `SpreadKey` (direction independence, type, normalisation, golden vectors), header building, serialisation round-trip, retry/DLQ decision, two-state dedupe.
- Integration (Testcontainers.Kafka): same-key ordering; restart resumes from committed offset without loss; duplicate message → no duplicate side effect; poison message → DLQ and later messages still flow; two consumer instances rebalance correctly.
- Existing gates stay green every phase: xUnit, Testcontainers, SonarCloud quality gate, CodeQL.

## 5. Open assumptions

1. Consumer library lives in WebApp (Telegram already references it); scanner keeps its own producer + `SpreadKey` copy guarded by golden vectors, instead of a new repo/NuGet package.
2. Production Kafka runs single-node (RF=1) on the existing VPS; budget ≈512 MB–1 GB RAM.
3. Submodule pointers that were already ahead of the root's pins (Telegram, AdminPanel, WebApp) are intentional.
