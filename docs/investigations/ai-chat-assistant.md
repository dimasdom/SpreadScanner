# Investigation: AI chat assistant for ArbiScannerWebApp

**Status:** investigation / not yet started
**Owner:** Dmytro Bartash
**Scope:** a small chat feature in the web app's React SPA that can answer questions about a user's settings and currently-open arbitrage opportunities, and give an opinion ("judge") on a specific one. Backed by an MCP server that proxies the existing `ArbiScannerWeb.API`, an agent process that drives the LLM, and OpenRouter free-tier models for inference. **The MCP server must also be reachable directly by external MCP clients (Claude Desktop and others), not only by the in-app agent** — this is a confirmed requirement (2026-08-03), not a future maybe, and it changes the transport and auth design in §3/§5 below versus an internal-only server. See also [`oauth-oidc-migration.md`](oauth-oidc-migration.md), whose trigger #3 this decision activates.

This doc exists to work through the four problems named up front — frontend↔chatbot communication, authentication, memory efficiency of the agent/MCP server, and model choice — against what's *actually* in the codebase today, not a generic chatbot writeup. It ends with open decisions and a suggested phased rollout, in the same spirit as [`ArbiScannerUpd.md`](../../ArbiScannerUpd.md).

---

## 1. The gap that shapes everything else: there is no "position"

The request says the assistant should "judge position" and discuss "positions." Today, **`ArbiScannerWebApp` has no domain concept of a user-owned position** — nothing tracks "user X opened trade Y at price Z."

What exists instead:
- `TradeOpportunityModel` — a scanner-detected arbitrage spread, shared across all users, not owned by anyone.
- `TradeOpportunityController.GetSpreadsForUser` (`ArbiScannerWeb.API/Controllers/TradeOpportunityController.cs:24-41`) — returns the currently-open spreads that match a user's *settings filters* (`FuturesSpread`/`FundingSpread`/`SpotSpread`, exchange list, size thresholds). Every subscribed user with the same filters sees the same list. It's a filtered view of the market, not a personal ledger.
- `UserSettingsModel.PositionSize` (`ArbiScannerWeb.Domain/Models/UserSettingsModel.cs:18`) — just a numeric filter used to hide opportunities whose book volume is too thin for the user's intended trade size, not a record of a trade.
- `MarketPositionAction` enum (`Open`/`Update`/`Close`) — describes the *opportunity's* lifecycle (has this spread just appeared, is it still live, has it closed), not a user's position in it.

**This means "judge my position" has to mean one of two different things, and the doc treats them as separate scope decisions (see §7):**

- **(a) Judge an opportunity** — "is this currently-open arbitrage spread, given my settings, worth taking?" Fully supportable today with zero schema changes — everything the assistant needs already exists behind `GetSpreadsForUser` / `GetSpreadInfo/{id}`.
- **(b) Judge a position I actually opened** — requires a new `UserPositionModel` (entry price, size, opened-at, which opportunity it was, status), a new controller/endpoints, EF migration, tests. Real feature work, not a chat-layer concern.

Recommendation: **build (a) first.** It's the same conversational surface, ships without touching persistence, and if it lands well, (b) is a natural, well-scoped follow-on once there's a real reason for users to log positions (rather than inventing that ledger just to give the chatbot something to talk about).

---

## 2. What already exists that the MCP server would wrap

| Controller | Relevant for the assistant |
|---|---|
| `AccountController` | `GET /Account/GetUserData` (settings + account, Redis-cached), `POST /Account/UpdateDetails` (write settings) — if the assistant should be able to *change* settings via chat, not just explain them, this is the write path it would call |
| `TradeOpportunityController` | `GetSpreadsForUser` (list of currently-matching opportunities), `GetSpreadInfo/{id}` (detail + ticker history for one) — this is "the positions" per §1 |
| `SubscriptionController` | plan/payment status — plausible read-only context ("is my subscription active") but not core to the MVP |
| `TelegramLinkController` | not relevant |
| `ClientLogController` | not relevant |

No dedicated settings controller exists — settings ride inside `AccountController`. The MCP server's tool surface should mirror this rather than inventing new REST endpoints on the main API: `get_user_settings`, `get_open_opportunities`, `get_opportunity_detail(id)`, and optionally `update_user_settings(...)`.

---

## 3. Authentication — recommend delegated short-lived JWTs, not a new auth system

Today's auth (`ArbiScannerWeb.Infrastructure/StartupSetup.cs:115-150`, `AccountController.cs:151-176`): login sets an **httpOnly cookie** (`arbiscanner.access_token`) carrying a JWT whose only claim is the user's id (`ClaimsIdentity.DefaultNameClaimType`), plus a rotating refresh token with reuse detection. The React client never touches the raw token — RTK Query just sends `credentials: 'include'`.

The chat feature crosses three trust boundaries, and each should be handled differently rather than inventing one blanket auth scheme:

1. **Browser → `ArbiScannerWeb.API`**: reuse what's there. Add the chat endpoint(s) to the existing API project as an `[Authorize]`-gated controller, same as everything else. Zero new auth code — the existing cookie/refresh middleware already covers this hop.
2. **`ArbiScannerWeb.API` → Agent**: this is an internal, same-Docker-network hop (agent container isn't publicly exposed — no nginx route for it). Have the API mint a **short-lived, purpose-scoped JWT** for the current user (reuse the existing signing key / `JwtSecurityToken` construction already in `AccountService.cs:90-107`, but with e.g. a 2–5 minute expiry and a distinguishing claim like `scope=agent`) and pass it to the agent as a normal `Authorization: Bearer` header. Don't forward the user's real long-lived session token to a second process — minimize blast radius if the agent/MCP server is ever compromised or logs a request.
3. **MCP server → `ArbiScannerWeb.API`**: the MCP server's tools just call the *existing* REST endpoints, attaching that same delegated bearer token. This is the key simplification — **the MCP server needs no bespoke auth logic at all**, because every tool call is a normal authenticated request to code that already enforces per-user scoping (`User.Identity.Name` → account id, same as today). The alternative — a shared internal API key plus an explicit `userId` parameter — would require new "trusted internal" endpoints that bypass the existing per-user authorization checks, which is more new surface area and easier to get wrong.
4. **Agent → OpenRouter**: one server-side API key, not per-user. Store it the same way other secrets end up getting handled once [Phase 6 of `ArbiScannerUpd.md`](../../ArbiScannerUpd.md) lands — don't invent a separate secrets story just for this key.
5. **External MCP client (Claude Desktop, etc.) → MCP server**: this hop is fundamentally different from 1-3 above and the delegated-JWT trick doesn't apply — there's no existing authenticated session to delegate from, since the "client" here is a third-party app on the user's own machine, not a request already flowing through `ArbiScannerWeb.API`. The [MCP authorization spec](https://modelcontextprotocol.io) expects the MCP server to act as an OAuth 2.1 **resource server**, pointing external clients at a real Authorization Server (discovery via `.well-known/oauth-protected-resource` / `.well-known/oauth-authorization-server`), typically with Dynamic Client Registration so Claude Desktop can self-register without the user manually creating an OAuth client first. **Update (2026-08-03):** this is no longer a scoped one-off — `ArbiScannerWebApp` and `ArbiScannerAdminPannel` are both migrating to a real Authorization Server (**Keycloak**, self-hosted), per [`oauth-oidc-migration.md`](oauth-oidc-migration.md). Once that lands, hop 5 is just another OAuth client (`arbiscanner-mcp`) registered in the same `arbiscanner-web` Keycloak realm the SPA already uses — no bespoke infrastructure of its own.

Net effect: hops 1-4 need no new auth code at all; hop 5 rides on the platform-wide Keycloak migration rather than needing its own standalone AS — see the OAuth doc for sequencing (standing up the `arbiscanner-web` realm first serves this need before the `ArbiScannerAdminPannel` side of that migration is even done).

---

## 4. Frontend ↔ chatbot communication

Two constraints from the existing code shape this:

- RTK Query's `fetchBaseQuery` (`ArbiScannerWeb.Client/src/store/services/baseQuery.ts:6-12`) is not built for streaming responses — it's request/response with a 401-retry wrapper (`baseQueryWithReauth`).
- The one existing realtime channel, `TradeOpportunityHub` (`ArbiScannerWeb.API/Hubs/TradeOpportunityHub.cs`), has **no `[Authorize]`** today — group membership is just whatever group name a connected client asks to join. It works for public spread broadcasts; it is not currently a pattern you'd want to inherit as-is for a user-scoped chat feed.

**Recommendation: plain authenticated REST endpoint streaming Server-Sent Events**, e.g. `POST /api/Chat/Message` returning `text/event-stream`, token-by-token. ASP.NET Core controllers can stream this directly (`Response.WriteAsync` per chunk under `[Authorize]`); ships in the same API project, same auth, no new hub. On the client, this one call bypasses RTK Query and uses a plain `fetch()` with `credentials: 'include'` and a `ReadableStream` reader — worth calling out explicitly since it's a different pattern from every other API call in the client today (`spread.ts`-style RTK Query slices won't fit this one).

Alternative considered: a new `ChatHub` on SignalR. Viable — and if `[Authorize]` were added, `Context.User.Identity.Name` would actually work out of the box for group naming (`ClaimsIdentity.DefaultNameClaimType` is the `Name` claim, matching what `AccountController`/`TradeOpportunityController` already read — no custom `IUserIdProvider` needed). But it means adding auth to a hub that has deliberately not needed it so far, and building a second streaming transport pattern for one feature. Only worth it if the goal is to unify all realtime features under SignalR later; not recommended for the MVP.

Session state: keep the server **stateless per turn**. Have the client hold the visible transcript (component state, optionally `localStorage`) and resend the last N turns (e.g. last 10, or a token budget) with each message. No server-side session dictionary to leak memory or need expiry logic — trivial at ~10 users, and it sidesteps a whole class of "who cleans up idle sessions" problems on a memory-constrained box.

Local dev: `ArbiScannerWeb.Client`'s Vite dev server already proxies `/api` and `/hubs` to the local API, so a new `/api/Chat/...` route needs no new proxy config.

---

## 5. Memory efficiency — the actual constraint

Per the existing `ArbiScannerUpd.md`, this targets a small/cheap VPS at real scale ~10 users. Worth noting: **no service in either `docker-compose.yml` has a memory limit configured today** (checked root and `ArbiScannerWebApp/docker-compose.yml` — no `mem_limit`/`deploy.resources.limits` anywhere across ~13 already-running containers). So "be memory efficient" here isn't about fitting under a cgroup limit that doesn't exist yet — it's about not meaningfully growing the box's footprint on top of an already-unbounded baseline. Concretely:

- **No local model weights.** OpenRouter is remote inference — the agent process itself never loads a model, so this isn't a factor. The memory cost is entirely "how many processes/containers, how heavy is each idle."
- **Skip heavyweight agent frameworks.** LangChain/LlamaIndex/AutoGen-style frameworks pull large dependency trees and idle RAM for capabilities (multi-provider abstraction, vector stores, chains) this feature doesn't need. A hand-rolled loop against OpenRouter's OpenAI-compatible `/chat/completions` endpoint with `tools` is a few hundred lines and has no framework tax.
- **One MCP server process, HTTP-based (Streamable HTTP), two ingress paths — not two separate MCP servers.** Because external clients (Claude Desktop, etc.) need a network-reachable endpoint, stdio-only is no longer an option for this server (unlike the pure-internal design this doc originally sized) — it has to speak Streamable HTTP either way. Given that, there's no reason to *also* run a separate stdio instance for the in-app agent: have the agent call the same HTTP server over the internal Docker network (`http://mcp-server:PORT/mcp`, using the delegated JWT from §3.3) instead of spawning it as a child process. This still nets to **one new container**, just bound to a port instead of stdio — the memory cost is the same as originally sized, only the transport changed. The external path is the same container, reached instead through a new nginx route (see `nginx/nginx.conf`'s existing `location /api/` / `location /admin/` pattern) with TLS from the existing certbot setup, protected by the OAuth flow from §3.5.
- **Consider Native AOT for this specific service.** Unlike the existing API/Worker projects (which carry EF Core, MongoDB drivers, SignalR, RabbitMQ clients — not all trivially AOT-compatible), a from-scratch chat agent has no legacy dependency baggage, making it a realistic AOT target. AOT-published .NET console/minimal services routinely idle in the 20-30MB range vs 80-120MB JIT, and start faster. Worth prototyping; not a blocker for the MVP if it turns out something in the MCP SDK or OpenRouter client doesn't AOT-compile cleanly — fall back to normal JIT publish rather than losing time fighting trimming warnings.
- **Bound the tool-call loop.** Cap agentic round-trips (e.g., 2: one pass where the model sees settings + the opportunity list and optionally asks for one detail lookup, one pass to answer) rather than an open-ended ReAct-style loop. This bounds worst-case latency, open connections, and per-request memory identically — and see §6, it also sidesteps a real free-model limitation.
- **Rate-limit the endpoint.** A single shared OpenRouter API key means one user hammering the chat can exhaust the whole app's free-tier quota. Reuse whatever rate limiter lands from [Phase 6](../../ArbiScannerUpd.md) (`AddRateLimiter`) rather than building a bespoke one for this endpoint.

---

## 6. Model choice — OpenRouter free tier

Agreed a small model with a well-written system prompt is the right call here — the task (summarize settings, list/compare a handful of spreads, give a bounded opinion) doesn't need frontier reasoning.

Two things worth flagging rather than assuming away:

1. **The free catalog and its rate limits change over time and are outside this repo's control.** Don't hardcode a specific model id as "the" choice in implementation without checking `https://openrouter.ai/models?max_price=0` at build time — free-tier models get deprecated/replaced, and published per-model/per-day free-tier request limits (and whether they require a minimum account credit purchase to unlock higher limits) have shifted in the past. Pick a model at implementation time, and design for a fallback (a second free model, or a clear "try again later" in the chat UI) rather than a hard dependency on one specific id staying available.
2. **Not all free models support tool/function calling reliably.** This directly affects §5's "bounded 2-pass loop" design — if the chosen free model's tool-calling is flaky, the fallback is to skip agentic tool selection entirely: since the data volume per user is tiny (one settings object, at most a few dozen currently-open opportunities), the backend can just fetch everything relevant up front and stuff it into a single prompt, doing one LLM call per turn with no tool-calling required at all. That's a strictly simpler, more robust MVP path and is worth trying first — MCP still provides the internal proxy/tool interface (useful on its own, and reusable if a more capable/tool-calling model is swapped in later), it's just that the *first* version of the agent may not need the model to drive tool selection dynamically.

---

## 7. Open decisions (need your input, not guessable from the code)

- **Scope of "position":** confirm judging currently-open opportunities (§1a) is the right MVP scope, vs. wanting a real position ledger (§1b) built first.
- **Read-only vs. read-write assistant:** should chat be able to call `UpdateDetails` and actually change settings ("turn off funding spreads"), or only explain/recommend and leave changes to the existing settings UI? Changes the MCP tool surface and the confirmation-before-mutating UX.
- **Transport:** SSE-over-REST (recommended, §4) vs. a new authenticated SignalR hub — only matters if there's a longer-term plan to unify realtime features.
- **Tool-calling vs. single-shot prompt (§6):** worth deciding whether to start with the simpler single-shot context-stuffed prompt and add real tool-calling later, or build the bounded 2-pass loop from the start. Note this decision now applies only to the *internal* agent's prompting strategy — external MCP clients (Claude Desktop) always drive tool-calling themselves, that's the client's own model choice, not something this project controls.
- **AOT or not:** worth the extra iteration time up front, or ship JIT-published first and revisit if the box actually gets memory-tight.
- **Read-only for external clients, at least at first?** Given hop 5 (§3) means *any* MCP client the user chooses to connect — not just code this project wrote — can now call these tools, recommend defaulting the externally-exposed tool set to read-only (`get_user_settings`, `get_open_opportunities`, `get_opportunity_detail`) and holding back `update_user_settings` from external exposure until there's a specific reason to want Claude Desktop able to change settings, even though the in-app agent might get write access sooner (§7 above). Worth confirming this default rather than assuming it.
- **Dynamic Client Registration or a pre-registered client id?** Keycloak supports OIDC Dynamic Client Registration (RFC 7591) as a realm feature — verify it's enabled on the `arbiscanner-web` realm at implementation time; if it turns out awkward for a given MCP client, the fallback is registering that client as a fixed public client (PKCE, no secret) once, which most MCP clients also support.

---

## 8. Suggested phased rollout

**Phase A — MCP server, internal network only (S-M).** Implement `get_user_settings` / `get_open_opportunities` / `get_opportunity_detail` as MCP tools (C# MCP SDK, Streamable HTTP transport) that call the existing `ArbiScannerWeb.API` endpoints over HTTP with a delegated token (§3.1-3.4). New container, but no public route yet — only reachable from the agent over the internal Docker network. Proves the tool layer and the transport without yet taking on the OAuth work in Phase E.

**Phase B — Agent + single-shot prompt (S-M).** Hand-rolled loop: fetch settings + opportunity list via the MCP tools, format into a system prompt, one call to an OpenRouter free model, return the answer. New authenticated `ChatController` endpoint on `ArbiScannerWeb.API`, SSE response, plain-`fetch` client component. This alone delivers "ask about my settings and currently-open opportunities" end to end.

**Phase C — "Judge" this specific opportunity (S).** Add the detail-lookup tool call (`get_opportunity_detail(id)` for ticker history) triggered when the user names/selects a specific spread, bounded to the 2-pass loop from §5/§6.

**Phase D — Harden (S-M).** Rate limiting, fallback model, idle-session/transcript truncation on the client, and — if the box is actually tight by then — the AOT pass from §5.

**Phase E — External MCP access via OAuth (M, shared with the platform migration).** Depends on the `arbiscanner-web` Keycloak realm from [`oauth-oidc-migration.md`](oauth-oidc-migration.md) existing — register an `arbiscanner-mcp` client in it, point the MCP server's token validation at that realm, expose the MCP server through a new nginx route (on the same dedicated auth subdomain the OAuth doc sets up for Keycloak) with TLS, restrict the exposed tool set to read-only (§7). Because Keycloak is being stood up for both services anyway, doing the `arbiscanner-web` realm first (see the OAuth doc's sequencing) means this phase's actual new work is small — mostly the MCP server's resource-server config and the nginx route, not a new AS. Phases A-D work without it, reachable only from the app's own chat UI.

**Phase F — Real position ledger (L, separate effort).** Only if Phase B/C prove the feature earns its keep: `UserPositionModel`, CRUD endpoints, migration, and then the assistant can judge *actual* trades instead of live market opportunities.
