# ArbiScanner — What Was Done (Phases A–D) and Why

This is a plain-language walkthrough of the work completed against `docs/roadmap.md`, for your own reference and for explaining it to someone else. Each phase covers: the problem, what was actually changed (with file references), why that specific approach was chosen, how it was verified, and anything left unresolved or deliberately deferred.

The short version: dev hygiene + CI first (so everything after had a safety net), then the RabbitMQ pipeline's real correctness bugs, then an honest (partly inconclusive) leak investigation, then a real payment webhook to replace polling-only.

---

## Phase A — Dev hygiene & CI

**The problem:** no analyzers, no CI, no docs folder, no changelog. The repo had test projects already, but nothing enforced that they compiled cleanly or ran on every push.

**What was done:**
- Added `.editorconfig` (the standard `dotnet new editorconfig` template) and `Directory.Build.props` to all four submodules, turning on `AnalysisLevel=latest`, `AnalysisMode=Recommended`, and `TreatWarningsAsErrors`.
- Each submodule's `Directory.Build.props` also has a documented `NoWarn` list — the exact set of pre-existing warning rule IDs the codebase already violated (locale formatting, test-naming conventions, etc.), captured via a *clean, non-parallel, non-incremental* build (parallel/incremental builds were found to under-report analyzer diagnostics — a real, reproducible quirk, not flakiness). Nullable-safety warnings (`CS8xxx`) were already zero everywhere and are not in that suppression list — they fail the build if they ever appear.
- Added `.github/workflows/ci.yml` to each submodule (restore → build with analyzers → unit tests → integration tests where they exist), and a root-level `.github/workflows/docker-build.yml` for the three services whose Docker builds need repo-root context.
- Added root `docs/`, `docs/adr/`, and `CHANGELOG.md`.

**Why this order:** CI without tests is empty, and tests without CI aren't visible to anyone. Doing this first meant every phase after it had a real safety net (a red build actually blocks something) instead of relying on remembering to run tests manually.

**Two real bugs found in the process, not invented for demonstration:**
- `ArbitrageScanner.Tests.csproj` (37 unit tests) was never referenced in `ArbitrageScanner.sln` — `dotnet test ArbitrageScanner.sln` had been silently skipping all of them. Fixed with `dotnet sln add`.
- A genuine `CS1998` bug (an `async` method with no `await`, in `ExchangeService.Init`) only surfaced once analyzers were turned on inside the actual Dockerfile build — the local machine's older SDK didn't catch it, which is itself the lesson: analyzer rule activation can differ by exact SDK patch version, and Docker builds are a more trustworthy signal than a local build.
- Repo-wide Windows-path corruption (literal directories/files with backslashes baked into their names, e.g. `bin\Debug`) was silently breaking MSBuild's resource-file globbing on Linux. Untracked, gitignored junk — deleted.

**Verified:** all four submodules build clean and pass their full test suites; all four Docker images build; every CI workflow step was run locally before being trusted, not just written.

---

## Phase B — RabbitMQ resilience

**The problem:** at-least-once delivery with no idempotency, no dead-letter handling, non-durable queues, and — the load-bearing discovery — the consumer acknowledged a message to the broker *before* confirming the actual database write had succeeded.

**What was actually wrong (in order of how bad it was):**

1. **Ack-timing bug.** `RabbitMqService.cs` (shared by the WebApp and Telegram-notifier consumers via a project reference) fired the message handler with `var _ = OnMessageReceived.Invoke(position)` — not awaited — then immediately acked. Worse, the consumer wrapper classes (`MessageProcessingService`, `SpreadsMessageBroker`) *also* detached their actual work via `Task.Run` and returned an already-completed `Task`. Combined, a message could be acked to the broker before the Mongo write it represented had even started, let alone succeeded. Every other resilience feature (retries, DLQ) would have been cosmetic on top of this. **Fixed first, before anything else**, by making both layers genuinely await the real work end-to-end.
2. **DI lifetime mismatch.** `IRabbitMqService` was `Singleton` in the WebApp but `Scoped` in the Telegram notifier — wrong for a class holding a long-lived broker connection. Aligned to `Singleton` in both.
3. **Non-durable queue topology.** `spread_api`/`spread_telegram` were declared `durable: false`, with no dead-letter exchange. Migrated both to `durable: true` with a new `spread_dlx` fanout exchange and per-queue `_dlq` queues (`x-dead-letter-exchange` argument). Since RabbitMQ rejects redeclaring an existing queue with different arguments, this required deleting the old queues once during a deploy window — reasonable given the project's real scale (~10 users).
4. **No publisher confirms.** `ServicesCommunicationService` published with `mandatory: false` and no confirm-mode; a publish failure was caught, logged, and silently swallowed. Enabled channel-level publisher confirmations and wrapped the publish in a Polly retry (exponential backoff + jitter); a failure now propagates to the caller instead of vanishing.
5. **No idempotency.** Added a Redis `SET NX` dedupe check keyed on `(queue, Guid, ActionType)` — not `Guid` alone, since the same event legitimately recurs across the Open/Update/Close lifecycle. The claim is deleted if processing ultimately fails, so a later DLQ replay isn't mistaken for a stale duplicate.
6. **No health checks anywhere.** Added Postgres/Mongo/Redis/RabbitMQ checks (as applicable per service) exposed at `/health`, wired into `docker-compose.yml` healthchecks — including previously-missing healthchecks on the `redis` and `mongodb` infra containers themselves.

**A side effect worth knowing about:** once acks properly wait for the handler to finish, the WebApp's `SemaphoreSlim(30)` concurrency limiter became dead weight — RabbitMQ's default sequential consumer dispatch means only one message is ever in flight now. It was removed rather than left in as inert code.

**Verified with two new Testcontainers tests** (`RabbitMqIdempotencyTests`, `RabbitMqDeadLetterTests`) that prove the actual properties, not just that the code compiles: publishing the same event twice results in exactly one database write (the second is logged as "Duplicate delivery skipped"), and a non-deserializable message lands in the dead-letter queue instead of looping forever.

**Not done:** a DLQ-depth Prometheus/Grafana metric (needs enabling the `rabbitmq_prometheus` plugin — infrastructure config, not application code) and a written trade-off note on quorum vs. classic queues. Neither was blocking.

---

## Phase C — Scanner memory-leak investigation

**The problem:** the scanner is force-restarted every 4 hours (`timeout 14400` + `restart: unless-stopped`), documented in the README as intentional — the classic tell of a leak shipped around instead of through.

**The hypothesis:** `ProxyService.SetNextProxy()` created a **brand-new `HttpClientHandler`+`HttpClient` pair per exchange** (2× per exchange — regular and observer) on every proxy rotation, disposing the old pair after a fire-and-forget 30-second delay with no cap on how many could be queued for disposal at once.

**How it was actually tested — and where this phase differs from A/B/D:** there was no real environment available with actual proxy servers, real exchange connections, or hours of runtime. Instead, an isolated, throwaway reproduction harness (not committed to the repo) replicated the exact object-creation/delayed-dispose pattern against a local fake "exchange" server, rotating far faster than production ever would, including under simulated heavy thread-pool load.

**The result was negative, and reported as such rather than forced into a tidy conclusion:** the pending-disposal backlog stabilizes at `grace_period ÷ rotation_interval` (~30 objects) and stays flat — it does not grow unboundedly, even under load. **This specific hypothesis did not reproduce.**

**What was still fixed, and why it was worth doing anyway:** while designing a fix, it was confirmed directly (not assumed) that `HttpClientHandler` locks properties like `.Proxy`/`.UseProxy` after the first request is sent — a naive "just reuse the handler" fix throws `InvalidOperationException` at runtime. The actual fix, `RotatingWebProxy` (an `IWebProxy` whose inner target can be swapped without touching the handler's own locked configuration), eliminates the per-rotation object churn entirely. It's a legitimate improvement independent of whether it was the real cause: fewer allocations, no reliance on a timing assumption, one less moving part.

**The decision to remove the restart wrapper anyway was explicit and yours, not mine** — made after seeing the inconclusive result, not before. It's documented plainly as a deliberate call in both `docs/investigations/scanner-memory-leak.md` and `CLAUDE.md`, with the specific candidates that weren't ruled out (ccxt's own internal state, the `ExchangeMarkets` collections, real-proxy-specific behavior) listed as where to look next if the degradation resurfaces.

**Verified:** new unit tests (`RotatingWebProxyTests`) proving the wrapper's rotation semantics directly, plus a clean Docker build.

---

## Phase D — OxaPay webhook signature verification

**The problem:** payment status was confirmed purely by polling (`GetActivePaymentForUser` → `GetInvoiceStatus`) — there was no webhook receiver at all, despite the original plan assuming one existed and just needed hardening.

**Docs-first, not assumed:** OxaPay's actual webhook documentation was fetched live (via WebFetch, since the `oxapay-docs` MCP server you added needs a session restart to connect) to confirm the exact header name, algorithm, and payload shape before writing any code, rather than guessing from training knowledge.

**What was built:**
- `POST api/payments/webhook` on `PaymentsController` — genuinely new: every other payment endpoint requires `[Authorize]`, this one is intentionally anonymous (verified by signature instead).
- HMAC-SHA512 verification over the **raw** request body, read directly from `Request.Body` rather than via `[FromBody]` model binding — binding would parse then re-serialize the JSON, changing whitespace/property order and silently breaking the signature check before verification even ran. This is documented with a comment in the code since it's a non-obvious constraint.
- Constant-time comparison (`CryptographicOperations.FixedTimeEquals`) instead of the plain `==` OxaPay's own sample code uses — closes a timing-attack gap in their example.
- `OxaPay:*` config promoted from raw `IConfiguration` string indexing to a typed `IOptions<OxaPaySettings>`, matching every other secret in this codebase's pattern.
- A staleness guard (reject webhook events older than 1 hour) — the payload has no nonce field, only a Unix timestamp, so this is defense-in-depth rather than true replay protection.
- The real idempotency guarantee reuses `PaymentsService.AcceptPayment`'s existing `Status == Completed` short-circuit — a redelivered webhook for an already-completed payment is a no-op, not a re-assignment of the subscription.
- The polling path was left in place as a fallback/reconciliation check, per the plan.

**Verified:** 10 new tests, including HMAC values computed independently inside the test (using the same algorithm, different code path) and cross-checked against the implementation — not hardcoded expected strings, which would have let a bug in the implementation "pass" a test that made the same mistake.

**A production concern caught before it caused damage:** you initially proposed `https://www.arbiscannerwebapp.site/api/payments/webhook` as the OxaPay callback URL. That domain's nginx config routes `/api/` to the **WebApp** API container, which has no payments controller at all — the webhook would have silently 404'd forever, with polling masking the fact that it was never actually working. The correct URL, confirmed against `docker-compose.yml`'s actual port mapping, is `http://34.34.186.113:8081/api/payments/webhook` (AdminPanel's exposed address). You chose to use that plain-HTTP address as-is for now rather than set up a proper HTTPS route.

---

## Two things worth being upfront about if this comes up

**A live-database incident during Phase B.** While verifying the WebApp's new `/health` endpoint by running its Docker image standalone, it was pointed at the actual production Postgres database (the same one the 13-hour-running stack was already using) rather than an isolated one. A pre-existing scheduled job (`StaleSpreadCleanupJob`, not something written in this work) ran on startup and closed 3 real stale spreads. That job would likely have run on the next real restart anyway, and the action itself (closing already-stale positions) is low-risk, but the container should not have been pointed at live data for a test, and it's worth knowing this happened rather than having it surface later. No live-data testing was repeated for Phase D as a result — the AdminPanel changes were verified with unit tests and a Docker build only.

**Phase C's result is a negative finding, not a fix.** The restart wrapper is gone because you decided to remove it after seeing that the specific hypothesis didn't reproduce — not because the original 4-hour degradation was proven resolved. If it resurfaces, `docs/investigations/scanner-memory-leak.md` has the short list of what wasn't ruled out.

---

## Where things live

| Doc | What it's for |
|---|---|
| `docs/roadmap.md` | The original fix plan (Phases A–D), written before any of this work started |
| `docs/investigations/scanner-memory-leak.md` | The Phase C investigation write-up — methodology, evidence, and the honest negative result |
| `CHANGELOG.md` (root) | Terse, dated entries for all four phases |
| This file | The narrative version — what/why, for explaining the work to someone else |
