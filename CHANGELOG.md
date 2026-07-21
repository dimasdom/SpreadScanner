# Changelog

Notable engineering changes to the ArbiScanner monorepo (root-level orchestration, cross-submodule concerns, and Phase-tracked work from `docs/roadmap.md`). Each submodule keeps its own `CHANGELOG.md` for changes local to that service.

Format loosely follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); dates are the day the change landed.

## [Unreleased]

### Added
- `docs/roadmap.md` — fix plan for confirmed gaps (RabbitMQ resilience, OxaPay webhook verification, dev hygiene/CI, scanner leak investigation), derived from `ArbiScannerUpd.md` after direct code inspection.
- `docs/adr/` — home for upcoming architecture decision records (Phase 7).
- Root `CHANGELOG.md` (this file).
- Phase A: `.editorconfig` + `Directory.Build.props` (nullable-safe analyzers, `TreatWarningsAsErrors`) and a GitHub Actions CI workflow in each of the four submodules; a root Docker-build workflow for the three services needing repo-root build context.
- Phase B: durable `spread_api`/`spread_telegram` queues with a `spread_dlx` dead-letter exchange, RabbitMQ publisher confirms, corrected consumer ack timing (ack now waits for the handler to actually finish), Redis-based idempotency dedupe on `(queue, Guid, ActionType)`, Polly retry policies on both publish and consume, and `/health` endpoints (Postgres/Mongo/Redis/RabbitMQ) on all four services wired into `docker-compose.yml`.

### Fixed
- `ArbitrageScanner.Tests` wasn't referenced in `ArbitrageScanner.sln`, so `dotnet test` silently skipped 37 tests.
- A real `CS1998` bug (`async` method with no `await`) in `ExchangeService.Init`, only surfaced once analyzers were enabled.
- `IRabbitMqService` was registered `Scoped` in the Telegram notifier but `Singleton` in the web API — wrong for a class holding a long-lived broker connection.
- Both RabbitMQ consumer wrappers (`MessageProcessingService`, `SpreadsMessageBroker`) detached message processing via `Task.Run` and returned an already-completed `Task`, which let the broker ack a message before its DB write had actually finished.
