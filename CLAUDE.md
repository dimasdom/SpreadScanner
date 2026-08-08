# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository shape

This is the **monorepo root** for ArbiScanner, a cryptocurrency arbitrage scanning platform. It contains no application code of its own — `docker-compose.yml` (+ `docker-compose.local.yml` local-dev override), `ArbiScanner.slnx` (cross-project solution), a self-hosted `keycloak/` (Dockerfile, realm exports, one-time setup scripts — see [Authentication](#authentication--self-hosted-keycloak-oidc) below), and `nginx/`/`observability/` config — plus six **git submodules**, each an independently-versioned repo with its own remote, `.sln`/`.slnx`, Dockerfile, and `docker-compose.yml`:

| Submodule directory | Purpose | Runtime |
|---|---|---|
| `ArbitrageScanner` | Core scanning engine — scans 12+ exchanges via ccxt, detects spreads, publishes to RabbitMQ | .NET 10 Worker |
| `ArbiScannerWebApp` | User-facing API + React SPA — consumes spreads, serves them via REST/SignalR | .NET 10 + React 19 |
| `ArbiScannerAdminPannel` | Admin/manager API + React SPA — users, subscriptions, OxaPay payments | .NET 10 + React 19 |
| `ArbiScanner.TelegramNotifierApp` | Telegram bot + notification worker | .NET 10 Worker |
| `ArbiScanner.McpServer` | MCP (Model Context Protocol) server — read-only spread-query tools for MCP clients (Claude Desktop, etc.) | .NET 10 ASP.NET Core |
| `ArbiScanner.AiAssistant` | AI chat assistant backend — SignalR hub for `ArbiScannerWeb.Client`'s chat widget | .NET 10 ASP.NET Core |

**Note the naming quirk:** the `ArbiScannerAdminPannel` folder keeps the double-n typo (renaming would require re-registering the git submodule), but all internal namespaces/projects use the corrected `ArbiScannerAdminPanel` (single-n).

Since each submodule is its own git repo, always check `git status`/`git -C <submodule> status` for the specific submodule you're editing — commits inside a submodule and the parent repo's pinned submodule reference are independent and must be committed separately.

### Cross-submodule references (important, non-obvious)

Several submodules reference project files in *sibling* submodules directly (not via NuGet):
- `ArbiScannerAdminPannel` reads the shared `ArbiScannerBot` Postgres DB via `ArbiScannerWebApp.Infrastructure`'s `AppDbContext` (read-only; it does not own or migrate that schema).
- `ArbiScanner.TelegramNotifierApp.Worker` references `ArbiScannerAdminPanel.Infrastructure`, `ArbiScannerWeb.Abstractions`, and `ArbiScannerWeb.Domain` (for the shared `TradeOpportunityModel` and Telegram-link tables).

This means the Docker build context for `ArbiScannerAdminPannel`'s API and for `ArbiScanner.TelegramNotifierApp` **must be the monorepo root**, not the submodule directory — their Dockerfiles `COPY` sibling submodule source. `ArbiScannerWebApp`'s API Dockerfile also needs repo-root context for the same reason. Building any of these images from inside the submodule directory alone will fail.

`ArbiScanner.McpServer` and `ArbiScanner.AiAssistant` are the exception: neither has any cross-submodule project reference (both only ever talk to `ArbiScannerWeb.API` over HTTP, keeping their own copies of the small set of DTOs they need), so each builds from its own submodule root as the Docker context.

## Data flow / architecture

```
ArbitrageScanner (ccxt, 12+ exchanges)
   -> protobuf TradeOpportunityModel -> RabbitMQ "spread_fanout_exchange" (fanout)
        -> queue "spread_api"      -> ArbiScannerWebApp (Postgres + Mongo + SignalR push to React SPA)
        -> queue "spread_telegram" -> TelegramNotifierApp (filters per-user criteria, sends via Telegram Bot API)

ArbiScannerAdminPannel: separate API/SPA, talks to ArbiScannerWebApp's Postgres DB (read) + its own admin-only Postgres DB (owned), OxaPay for payments.

ArbiScanner.McpServer: pure resource server, forwards the caller's own bearer token unchanged to ArbiScannerWeb.API — owns no data, mints no tokens.
ArbiScanner.AiAssistant: SignalR chat backend for ArbiScannerWeb.Client; on a spread-data question it calls ArbiScanner.McpServer's tools (exchanging the caller's own token first), otherwise answers from a built-in knowledge base or OpenRouter directly.
```

- **Three Postgres databases**: `ArbiScannerBot` (shared — owned/migrated by `ArbiScannerWebApp`; users, Telegram links, accounts), `ArbiScannerAdminPanelDb` (owned/migrated by `ArbiScannerAdminPannel`; admin users, subscriptions, payments), and `keycloak` (owned by Keycloak itself — created once by hand, see [Authentication](#authentication--self-hosted-keycloak-oidc)). Never create EF migrations for `AppDbContext` from the AdminPanel project, and never create migrations for `AdminPanelAppDbContext` from the WebApp project.
- **MongoDB** is used by both `ArbitrageScanner` (found-spreads only) and `ArbiScannerWebApp` (spreads + historical ticker data) — separate databases/collections, not shared.
- All six services (the four original ones plus `ArbiScanner.McpServer`/`ArbiScanner.AiAssistant`) export OpenTelemetry traces via OTLP gRPC to Grafana Tempo, and expose Prometheus metrics (`/metrics` on the web APIs, a standalone listener on port 8085 for worker services). Logs go through Serilog to Grafana Loki. If you touch tracing/logging config in one service, check whether the same pattern needs mirroring in the others — it's duplicated per-submodule, not shared.
- `ArbitrageScanner`'s worker no longer force-restarts every 4 hours — that `timeout 14400` wrapper was removed after a leak investigation (`docs/completed-work-summary.md`, "Phase C") fixed a concrete `ProxyService` issue (a new `HttpClient` was created on every proxy rotation instead of being reused), though the investigation didn't conclusively prove that was the original cause of the degradation. If you see unbounded memory/handle growth over a multi-hour run, that doc's negative-result section is the place to continue from — don't just reintroduce the restart hack as a shortcut.
- `ArbitrageScanner` supports horizontal sharding via `NODE_TOTAL`/`NODE_INDEX` env vars, partitioning the symbol universe by index modulo — all nodes still write to the same Mongo/RabbitMQ.

## Authentication — self-hosted Keycloak (OIDC)

Auth was migrated from self-issued JWTs to a self-hosted Keycloak (`keycloak/`, its own Dockerfile — must be built with `--features=token-exchange`). There is no `JWT_SIGNING_KEY_*` config left anywhere; look for `OIDC_*`/`KEYCLOAK_*`/`VITE_OIDC_*` in `sample.env` instead. Background: `docs/investigations/oauth-oidc-migration.md`. The WebApp SPA's login/silent-renewal/logout sequence in detail: `docs/architecture/webapp-oauth-oidc-flow.md`.

One Keycloak instance, two realms, both auto-imported from `keycloak/realm-export/*.json` on container start:
- **`arbiscanner-web`** — backs `ArbiScannerWebApp` (`arbiscanner-web-spa` public client) and, via token exchange, the two newer services:
  - **MCP access**: a user's own `arbiscanner-web-spa` session token is exchanged (RFC 8693 Standard Token Exchange, via `ArbiScannerWeb.API`'s `McpTokenService` / `POST /api/McpToken/Generate`) for a token scoped to the confidential `arbiscanner-mcp` client. That client's `access.token.lifespan` is overridden to 30 days, and the exchange requests `scope=offline_access` purely to upgrade the underlying session to an *offline* one so the override isn't capped by the realm's ~10h SSO session max (it does **not** yield a usable `refresh_token`). `ArbiScanner.McpServer` is a pure resource server — it validates and forwards that token unchanged, and holds no client secret. Full mechanics: `ArbiScanner.McpServer/README.md`.
  - **AI Assistant chat** reuses the *same* `arbiscanner-web-spa` token the browser already holds and calls the same `McpTokenService` endpoint — no new Keycloak client, no new secret. Full mechanics: `ArbiScanner.AiAssistant/README.md`.
- **`arbiscanner-admin`** — backs `ArbiScannerAdminPannel` (`arbiscanner-admin-spa` client). No self-registration; the `Administrator`/`Manager` staff accounts are provisioned once via `keycloak/configure-admin-users.sh`.
- Two service-to-service clients cross realms in opposite directions: `arbiscanner-admin-service` (Client Credentials — `ArbiScannerWebApp`'s `AdminService` calling `ArbiScannerAdminPannel`'s API) and `arbiscanner-web-admin-ops` (`admin-api` deleting a user's *Keycloak* identity in the `arbiscanner-web` realm on account deletion, not just the local shadow row).

One-time setup (Keycloak's own Postgres db, DNS/TLS, SMTP, staff accounts, and — on an already-deployed realm only — the `arbiscanner-mcp` client + Standard Token Exchange config that a fresh realm import gets for free) is scripted under `keycloak/*.sh`; follow `keycloak/README.md` in order, don't skip steps.

For local dev, `docker-compose.local.yml` is an **opt-in** override (not auto-loaded — the root `docker-compose.yml` doubles as the real production deploy command, so an auto-merged override would silently change prod behavior):
```bash
docker compose -f docker-compose.yml -f docker-compose.local.yml up -d postgres rabbitmq redis mongodb keycloak
./keycloak/configure-local-dev.sh   # patches fixed local-dev client secrets, arbiscanner-mcp token exchange
```
It exposes Keycloak on a plain-HTTP host port (`localhost:8082`) and points `mcp-server`/`ai-assistant` at it plus a locally-`dotnet run` `ArbiScannerWeb.API`. See root-level [`MCP_TESTING.md`](MCP_TESTING.md) and [`AI_ASSISTANT_TESTING.md`](AI_ASSISTANT_TESTING.md) for full local walkthroughs of those two services end to end.

## Common commands

Run these from inside the relevant submodule directory unless noted.

### Build / run a .NET service
```bash
dotnet build <Submodule>.sln            # or .slnx
cd <Project>.Worker (or .API / .Host)   # e.g. ArbiScanner.McpServer.Host, ArbiScanner.AiAssistant.Api
dotnet run
```

### Tests
```bash
dotnet test <Submodule>.sln             # runs all test projects (xunit + FluentAssertions + Moq)
dotnet test path/to/One.Tests.csproj --filter "FullyQualifiedName~ClassName.MethodName"   # single test
```
`*.IntegrationTests` in `ArbiScannerWebApp`, `ArbiScannerAdminPannel`, and `ArbitrageScanner` use **Testcontainers** — real Postgres/RabbitMQ/Mongo containers, so Docker must be running locally and these tests are slower. `ArbiScanner.McpServer`'s and `ArbiScanner.AiAssistant`'s `*.IntegrationTests` are Docker-free by contrast — `WebApplicationFactory` against the real app with only the downstream HTTP call stubbed, no Testcontainers needed. `ArbiScannerWeb.LoadTests` and `ArbiScannerAdminPanel.LoadTests` are separate load-testing projects, not part of the normal test run.

### React clients (`ArbiScannerWeb.Client`, `ArbiScannerAdminPanel.Client`)
```bash
npm install
npm run dev        # Vite dev server, proxies /api and /hubs to the local API
npm run build       # tsc -b && vite build
npm run lint        # eslint .
```
Only `ArbiScannerWeb.Client` has a `test`/`test:coverage` script (`vitest`); the admin client has no test script. The AI chat widget (`ChatWidget.tsx`) lives inside `ArbiScannerWeb.Client` itself — it's not a separate SPA — and talks to `ArbiScanner.AiAssistant`'s SignalR hub (`/ai-hub/chat`) directly.

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
Keycloak's `keycloak` database is managed by Keycloak itself — never migrated from an EF project.

### Docker
```bash
# Full stack, from the monorepo root — this is also the real production deploy command
docker compose up --build

# Infra only (fast path for local .NET/npm dev)
docker compose up postgres rabbitmq redis mongodb -d

# Infra + local Keycloak, opt-in override (see Authentication above)
docker compose -f docker-compose.yml -f docker-compose.local.yml up -d postgres rabbitmq redis mongodb keycloak
```
Submodules also ship their own standalone `docker-compose.yml` for developing one service in isolation — but remember the AdminPanel API and TelegramNotifierApp images need repo-root build context (see above), so building via `docker compose up` from inside those submodule directories alone won't work for the API image; use the compose file at the monorepo root or pass an explicit `-f`/context.

## Solution-wide layering convention

All submodules follow the same Clean Architecture layering, in strict dependency order:

```
Domain  <-  Abstractions  <-  Infrastructure  <-  (Application  <-)  API / Worker
```

- `Domain`: POCOs, enums, DTOs — zero external package deps.
- `Abstractions`: interfaces only; all service interfaces return `FluentResults`' `Result`/`Result<T>` rather than throwing, so error handling stays explicit across layer boundaries — follow this convention for new services rather than introducing exceptions-as-control-flow.
- `Infrastructure`: EF Core/Mongo/Redis/RabbitMQ/HTTP implementations of the Abstractions interfaces.
- `Application` (WebApp, AdminPanel, TelegramNotifierApp, AiAssistant — `ArbitrageScanner` and `ArbiScanner.McpServer` skip this layer, since both are thin pass-throughs with no use-case orchestration to speak of): business logic/use-case orchestration.
- `API`/`Worker`/`Host`: composition root (DI wiring in `Program.cs` / `StartupSetup.cs`), controllers, hosted services, or MCP tool/hub endpoints.

When adding a feature, define the interface in `Abstractions`, implement it in `Infrastructure` (or `Application`), and wire it up in the host project's DI setup — don't reach across layers in the wrong direction.
