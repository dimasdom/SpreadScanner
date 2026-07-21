# ArbiScanner — Fix Plan for Confirmed Gaps

**Source:** derived from `ArbiScannerUpd.md`, after direct code inspection replaced assumptions with confirmed findings.
**Scope:** the five gaps below turned out to have sharper specifics than the original doc guessed — most notably, the RabbitMQ consumer acks messages before the downstream handler (Mongo write / Telegram send) actually completes, which means adding a DLQ or retry logic on top today would be cosmetic. Fixing that ordering bug is the load-bearing part of Phase B, not an afterthought.

---

## Context

Investigation against `ArbiScannerUpd.md`'s "behind the doc" list confirmed:

1. Both `spread_api` and `spread_telegram` queues are `durable: false`, with no DLX, no publisher confirms, no idempotency dedupe, and no Polly anywhere in the codebase.
2. No inbound OxaPay webhook endpoint exists at all — payment status is confirmed purely by polling. "Verify webhook signatures" is therefore a **new feature** (add a receiver + HMAC verification), not a hardening task on an existing endpoint. Decision made: build it.
3. Zero `HealthChecks`, zero `.editorconfig`, zero `TreatWarningsAsErrors`, no root `docs/`, no root `CHANGELOG.md`, no ADRs.
4. No CI anywhere — the only `.github/workflows` path found (`ArbitrageScanner/.github/workflows`) is an empty, untracked directory.
5. The 4-hour scanner restart is documented in the README as an intentional design choice, not flagged as a known leak — investigation hasn't started, but a concrete lead was found (see Phase C).

---

## Phase A — Dev hygiene + CI foundation (do first, lowest risk)

- Add `Directory.Build.props` per submodule (none exist anywhere) enabling `.editorconfig` + `TreatWarningsAsErrors` for new code, without retroactively failing the build on pre-existing warnings (scope via `<WarningsNotAsErrors>` or a baseline pass first).
- Add root `docs/` (this file lives there now), `docs/adr/`, root `CHANGELOG.md`.
- CI: `ArbitrageScanner.Worker`'s Dockerfile builds standalone, but `ArbiScannerWebApp`, `ArbiScannerAdminPannel`, and `ArbiScanner.TelegramNotifierApp`'s Dockerfiles all require **repo-root context** (confirmed — they `COPY` sibling submodule source). Each submodule is also an independently-remoted repo. So:
  - CI for build+test lives in **each submodule's own `.github/workflows/`**.
  - One **root-level workflow** handles the cross-submodule Docker builds that need root context.
  - Start with `ArbitrageScanner` — its `.github/workflows/` dir is already scaffolded (empty) and its Dockerfile is the simplest, single-context one: restore → build → analyzers → `ArbitrageScanner.Tests` → `ArbitrageScanner.IntegrationTests` (Testcontainers work fine in Actions).
  - Replicate the pattern to the other three.
  - Root workflow: `submodule update --init --recursive`, then build the 3 repo-root-context Docker images.

## Phase B — RabbitMQ resilience (the real greenfield work)

Order matters — fix correctness-blocking bugs before adding safety nets around them:

1. **Fix the ack-timing bug first.** In `ArbiScannerWebApp/ArbiScannerWeb.Infrastructure/Services/RabbitMqService.cs` the consumer does `var _ = OnMessageReceived.Invoke(position)` (fire-and-forget) then immediately `BasicAckAsync`. This class is shared by both the WebApp and Telegram consumers (TelegramNotifier references it directly via project reference), so this one fix closes the gap in both places. Change to `await` the handler before acking; on failure, `BasicNackAsync(requeue: true)` only up to a retry cap (see Polly below), otherwise dead-letter.
2. **Fix the singleton/scoped lifetime mismatch.** `ArbiScannerWeb.API/Program.cs` registers `IRabbitMqService` as singleton; `ArbiScanner.TelegramNotifierApp.Worker/Program.cs` registers it `AddScoped` — wrong for a class holding a long-lived connection/channel. Align both to singleton.
3. **Migrate queue topology to durable + DLQ.** Both `spread_api` and `spread_telegram` are `durable: false` with no `x-dead-letter-exchange` args, declared in both `ArbitrageScanner/ArbitrageScanner.Infrastructure/Services/ServicesCommunicationService.cs` (publisher) and `RabbitMqService.cs` (consumer). RabbitMQ won't let you redeclare an existing queue with different durability/arguments (`PRECONDITION_FAILED`) — given this is a low-stakes ~10-user system, the pragmatic fix is: during a deploy window, delete the two existing queues, then redeclare both as `durable: true` with `x-dead-letter-exchange: spread_dlx` args in both files (must match exactly; consumer re-declares idempotently). Add a `spread_dlx` fanout exchange + `spread_api_dlq`/`spread_telegram_dlq` queues, and a DLQ-depth Prometheus metric.
4. **Publisher confirms.** In `ServicesCommunicationService.cs`, the publish channel currently uses `mandatory: false` with no confirm-mode at all, and publish failures are swallowed (`catch` → log → no rethrow → message silently lost). Enable confirm mode on the publish channel and await confirmation before treating a publish as successful; on failure, don't swallow — surface as an error/retry.
5. **Polly retry wrapping.** Wrap consumer message-processing (both `MessageProcessingService` in WebApp and TelegramNotifier's `SpreadsMessageBroker`, which share the same fire-and-forget `Task.Run` + catch-and-log pattern) in a Polly exponential-backoff+jitter policy before a message dead-letters, replacing the current hand-rolled "wait 5s and reconnect" loop for actual message-level retries (the reconnect loop can stay for connection failures).
6. **Idempotent consumer dedupe.** `TradeOpportunityModel.Guid` is a stable ID, but it legitimately recurs across `Open`/`Update`/`Close` lifecycle events for the same spread — so dedupe on `(Guid, ActionType)`, not `Guid` alone. Reuse the existing `IConnectionMultiplexer`/`IDatabase` pattern already used in `ArbiScannerWeb.Infrastructure/Services/UserSettingsService.cs` and `AdminService.cs` — `SET NX` with a short TTL before processing, skip if already present. This is net-new only conceptually; no new Redis dependency is needed in `ArbitrageScanner` itself since dedupe belongs on the consumer side where duplicate side effects (double Mongo write, double Telegram message) actually happen.
7. **Health checks.** Fully greenfield — add `Microsoft.Extensions.Diagnostics.HealthChecks` (broker/DB/Redis reachability) to all 4 services, wire into `docker-compose.yml` following the existing `pg_isready`/`rabbitmq-diagnostics ping` healthcheck pattern (already used for postgres/rabbitmq, missing for redis/mongodb and all 4 .NET services).

**Test to prove it:** a Testcontainers integration test (extending the existing `ArbiScannerWeb.IntegrationTests` project) that publishes the same event twice and asserts exactly one Mongo write, plus a poison-message test asserting it lands in the DLQ after N retries instead of requeue-looping forever.

## Phase C — Scanner leak investigation

A concrete lead was found, not just a blind profiling exercise: `ArbitrageScanner/ArbitrageScanner.Infrastructure/Services/ProxyService.cs` `SetNextProxy()` constructs a **brand-new `HttpClientHandler` + `HttpClient` pair per exchange** (2× per exchange — regular + observer service) on every proxy rotation (startup + every 200 symbols processed), and disposes the *old* client via a fire-and-forget `Task.Delay(30s).ContinueWith(...)` with no de-dup guard — if rotation happens faster than 30s, multiple old clients queue up for delayed disposal simultaneously, each still holding sockets/handles.

- Confirm this hypothesis first with `dotnet-counters` (handle count vs managed heap over a run) before the full gcdump/trace loop — if handle count climbs while managed heap stays flat, this is very likely the culprit and narrows the fix to: reusing `HttpClientHandler` across rotations (only rotating the actual proxy config, not the whole client), or serializing rotations so only one delayed-dispose is ever in flight.
- If handles stay flat but managed heap grows, fall back to the full gcdump-diff approach.
- Write up in `docs/investigations/scanner-memory-leak.md`, then remove the `timeout 14400` wrapper and reframe the README's "4-Hour Restart Strategy" section (currently documents it as intentional) once proven fixed.

## Phase D — OxaPay webhook receiver + HMAC verification (new feature)

- Add a `POST api/payments/webhook` (or similar) anonymous endpoint in `ArbiScannerAdminPannel/ArbiScannerAdminPanel.API/Controllers/PaymentsController.cs` — currently all payment endpoints require `[Authorize]`, so this is a genuinely new anonymous surface and needs its own scrutiny.
- Verify OxaPay's HMAC header (per their API docs) against the raw request body using the existing `OxaPay:MerchantApiKey` config value (already read via raw `IConfiguration` in `ArbiScannerAdminPannel/ArbiScannerAdminPanel.Application/Services/OxaPayService.cs` — worth promoting to a typed `IOptions<OxaPaySettings>` while touching this file, since every other secret in this codebase's pattern uses typed options).
- Add replay protection: track processed `trackId`s (the existing `AcceptPayment` already short-circuits on `Status == Completed`, confirmed by `PaymentsServiceTests.AcceptPayment_AlreadyCompleted_ReturnsOkWithoutReassigning` — this gives idempotency almost for free; add a timestamp/nonce window check for the signature itself).
- Keep the existing polling path as a fallback/reconciliation check, don't remove it.
- Tests: extend `OxaPayServiceTests.cs`/`PaymentsServiceTests.cs` with webhook signature valid/invalid/replay cases.

---

## Sequencing

**A** (CI safety net) → **B** (RabbitMQ correctness, deepest and most bug-laden) → **C** (leak, now safe to change with CI/tests as a net) → **D** (webhook, independent of the others, can slot in anywhere).
