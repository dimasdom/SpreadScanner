# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository shape

This is the **monorepo root** for ArbiScanner, a cryptocurrency arbitrage scanning platform. It contains no application code itself — only `docker-compose.yml`, `ArbiScanner.slnx` (cross-project solution), and four **git submodules**, each an independently-versioned repo with its own remote, `.sln`/`.slnx`, Dockerfile, and `docker-compose.yml`:

| Submodule directory | Purpose | Runtime |
|---|---|---|
| `ArbitrageScanner` | Core scanning engine — scans 12+ exchanges via ccxt, detects spreads, publishes to RabbitMQ | .NET 9 Worker |
| `ArbiScannerWebApp` | User-facing API + React SPA — consumes spreads, serves them via REST/SignalR | .NET 10 + React 19 |
| `ArbiScannerAdminPannel` | Admin/manager API + React SPA — users, subscriptions, OxaPay payments | .NET 10 + React 19 |
| `ArbiScanner.TelegramNotifierApp` | Telegram bot + notification worker | .NET 10 Worker |

**Note the naming quirk:** the `ArbiScannerAdminPannel` folder keeps the double-n typo (renaming would require re-registering the git submodule), but all internal namespaces/projects use the corrected `ArbiScannerAdminPanel` (single-n).

Since each submodule is its own git repo, always check `git status`/`git -C <submodule> status` for the specific submodule you're editing — commits inside a submodule and the parent repo's pinned submodule reference are independent and must be committed separately.

### Cross-submodule references (important, non-obvious)

Several submodules reference project files in *sibling* submodules directly (not via NuGet):
- `ArbiScannerAdminPannel` reads the shared `ArbiScannerBot` Postgres DB via `ArbiScannerWebApp.Infrastructure`'s `AppDbContext` (read-only; it does not own or migrate that schema).
- `ArbiScanner.TelegramNotifierApp.Worker` references `ArbiScannerAdminPanel.Infrastructure`, `ArbiScannerWeb.Abstractions`, and `ArbiScannerWeb.Domain` (for the shared `TradeOpportunityModel` and Telegram-link tables).

This means the Docker build context for `ArbiScannerAdminPannel`'s API and for `ArbiScanner.TelegramNotifierApp` **must be the monorepo root**, not the submodule directory — their Dockerfiles `COPY` sibling submodule source. `ArbiScannerWebApp`'s API Dockerfile also needs repo-root context for the same reason. Building any of these images from inside the submodule directory alone will fail.

## Data flow / architecture

```
ArbitrageScanner (ccxt, 12+ exchanges)
   -> protobuf TradeOpportunityModel -> RabbitMQ "spread_fanout_exchange" (fanout)
        -> queue "spread_api"      -> ArbiScannerWebApp (Mongo + SignalR push to React SPA)
        -> queue "spread_telegram" -> TelegramNotifierApp (filters per-user criteria, sends via Telegram Bot API)

ArbiScannerAdminPannel: separate API/SPA, talks to ArbiScannerWebApp's Postgres DB (read) + its own admin-only Postgres DB (owned), OxaPay for payments.
```

- **Two Postgres databases**: `ArbiScannerBot` (shared — owned/migrated by `ArbiScannerWebApp`; users, Telegram links, accounts) and `ArbiScannerAdminPanelDb` (owned/migrated by `ArbiScannerAdminPannel`; admin users, subscriptions, payments). Never create EF migrations for `AppDbContext` from the AdminPanel project, and never create migrations for `AdminPanelAppDbContext` from the WebApp project.
- **MongoDB** is used by both `ArbitrageScanner` (found-spreads only) and `ArbiScannerWebApp` (spreads + historical ticker data) — separate databases/collections, not shared.
- All four services export OpenTelemetry traces via OTLP gRPC to Grafana Tempo, and expose Prometheus metrics (`/metrics` on the web APIs, a standalone listener on port 8085 for the two worker services). Logs go through Serilog to Grafana Loki. If you touch tracing/logging config in one service, check whether the same pattern needs mirroring in the others — it's duplicated per-submodule, not shared.
- `ArbitrageScanner`'s worker process is designed to be killed and restarted every 4 hours in production (`timeout 14400 dotnet ...` + `restart: unless-stopped`) to clear stale ccxt/exchange state — this is intentional, not a bug if you see the container cycling.
- `ArbitrageScanner` supports horizontal sharding via `NODE_TOTAL`/`NODE_INDEX` env vars, partitioning the symbol universe by index modulo — all nodes still write to the same Mongo/RabbitMQ.

## Common commands

Run these from inside the relevant submodule directory unless noted.

### Build / run a .NET service
```bash
dotnet build <Submodule>.sln            # or .slnx
cd <Project>.Worker (or .API) && dotnet run
```

### Tests
```bash
dotnet test <Submodule>.sln             # runs all test projects (xunit + FluentAssertions + Moq)
dotnet test path/to/One.Tests.csproj --filter "FullyQualifiedName~ClassName.MethodName"   # single test
```
`*.IntegrationTests` projects (in `ArbiScannerWebApp` and `ArbitrageScanner`) use **Testcontainers** — they spin up real Postgres/RabbitMQ/Mongo containers, so Docker must be running locally and these tests are slower. `ArbiScannerWeb.LoadTests` is a separate load-testing project, not part of the normal test run.

### React clients (`ArbiScannerWeb.Client`, `ArbiScannerAdminPanel.Client`)
```bash
npm install
npm run dev        # Vite dev server, proxies /api and /hubs to the local API
npm run build       # tsc -b && vite build
npm run lint        # eslint .
```
Only `ArbiScannerWeb.Client` has a `test`/`test:coverage` script (`vitest`); the admin client has no test script.

### EF Core migrations
Each service targets a specific `DbContext` — always pass `--context` explicitly since some solutions contain multiple contexts:
```bash
# ArbiScannerWebApp (AppDbContext, owns ArbiScannerBot db)
cd ArbiScannerWeb.API && dotnet ef database update

# ArbiScannerAdminPannel (AdminPanelAppDbContext, owns ArbiScannerAdminPanelDb)
cd ArbiScannerAdminPanel.API
dotnet ef database update --context AdminPanelAppDbContext
dotnet ef migrations add <Name> --context AdminPanelAppDbContext --project ../ArbiScannerAdminPanel.Infrastructure --startup-project .
```

### Docker
```bash
# Full stack, from the monorepo root
docker compose up --build

# Infra only (fast path for local .NET/npm dev)
docker compose up postgres rabbitmq redis mongodb -d
```
Submodules also ship their own standalone `docker-compose.yml` for developing one service in isolation — but remember the AdminPanel API and TelegramNotifierApp images need repo-root build context (see above), so building via `docker compose up` from inside those submodule directories alone won't work for the API image; use the compose file at the monorepo root or pass an explicit `-f`/context.

## Solution-wide layering convention

All four submodules follow the same Clean Architecture layering, in strict dependency order:

```
Domain  <-  Abstractions  <-  Infrastructure  <-  (Application  <-)  API / Worker
```

- `Domain`: POCOs, enums, DTOs — zero external package deps.
- `Abstractions`: interfaces only; all service interfaces return `FluentResults`' `Result`/`Result<T>` rather than throwing, so error handling stays explicit across layer boundaries — follow this convention for new services rather than introducing exceptions-as-control-flow.
- `Infrastructure`: EF Core/Mongo/Redis/RabbitMQ implementations of the Abstractions interfaces.
- `Application` (WebApp, AdminPanel, TelegramNotifierApp only — ArbitrageScanner and its Worker skip this layer): business logic/use-case orchestration.
- `API`/`Worker`: composition root (DI wiring in `Program.cs` / `StartupSetup.cs`), controllers or hosted services.

When adding a feature, define the interface in `Abstractions`, implement it in `Infrastructure` (or `Application`), and wire it up in the host project's DI setup — don't reach across layers in the wrong direction.
