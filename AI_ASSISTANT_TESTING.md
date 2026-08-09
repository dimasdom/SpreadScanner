# Testing ArbiScanner.AiAssistant locally

Local notes for setting up OpenRouter and exercising the AI chat assistant
end to end (browser widget → `ArbiScanner.AiAssistant` SignalR hub →
OpenRouter decides to call a tool or answer directly → either
`ArbiScanner.McpServer` → data from `ArbiScannerWeb.API`, or a direct
answer grounded in the assistant's built-in ArbiScanner knowledge base).
`ChatHub.StreamMessage` is a SignalR *streaming* method: every response is
bracketed by a `ConversationStart` chunk and a `ConversationEnd` chunk, with
free-text answers arriving as a sequence of `AnswerDelta` chunks in between
that render incrementally, and tool results arriving as one `SpreadsData` /
`SpreadData` / `ToolResult` chunk. A "thinking" indicator shows from the
moment a message is sent until `ConversationEnd` (or any other chunk)
arrives - see the AiAssistant `README.md` → "Transport".

Assumes you already have Postgres/RabbitMQ/Redis/MongoDB/Keycloak running and
`ArbiScanner.McpServer` reachable — see this repo's root `README.md` and
[`MCP_TESTING.md`](MCP_TESTING.md) if that part isn't set up yet.
`ArbiScanner.AiAssistant` reuses the exact same Keycloak client
(`arbiscanner-web-spa`) and the same `POST /api/McpToken/Generate` endpoint —
no separate Keycloak setup is needed beyond what `MCP_TESTING.md` §1
already covers.

---

## 1. Get an OpenRouter API key

1. Sign up at [openrouter.ai](https://openrouter.ai).
2. Create a key at [openrouter.ai/keys](https://openrouter.ai/keys) — this is
   `OPENROUTER_API_KEY`.
3. Pick a model that supports **tool/function calling**. `OpenRouterChatModel`
   sends the MCP tool schemas on every request via the `tools` parameter,
   and calling one is still how the assistant fetches live spread data (see
   `ArbiScanner.AiAssistant/README.md` → "Architecture"). A model that
   ignores `tools` will still produce a plain-text reply to every message
   (it always answers, never crashes), but spread-data questions will get a
   made-up or unhelpful text answer instead of real `SpreadsData`/`SpreadData` —
   general "how does ArbiScanner work?" questions aren't affected either
   way, since those are answered directly from the knowledge base embedded
   in the system prompt, not via a tool call.

   **This deployment uses `OPENROUTER_MODEL=openrouter/free`** — OpenRouter's
   own auto-router alias (not a specific model) that picks among free-tier
   models on each request and, per OpenRouter's docs, filters for the
   features the request actually needs (tool calling included). That makes
   it the simplest choice here: no manual catalog-browsing, and it keeps
   working as OpenRouter's free-tier lineup changes underneath it.

   If you'd rather pin a specific, deterministic model instead (e.g. to
   reproduce a bug, or because `openrouter/free` picked something flaky),
   browse [openrouter.ai/models](https://openrouter.ai/models) filtered to
   free + tool-calling-capable and set `OPENROUTER_MODEL` to that model's id
   directly (e.g. `meta-llama/llama-3.3-70b-instruct:free`) — see the doc
   comment on `OpenRouterOptions.Model`
   (`ArbiScanner.AiAssistant.Domain/Settings/OpenRouterOptions.cs`).

   Free-tier models (routed or pinned) are rate-limited and occasionally
   deprioritized/removed from OpenRouter's catalog — if the assistant starts
   timing out or returning 4xx from OpenRouter after previously working,
   that's usually a free-tier capacity/availability issue, not a config
   regression; retry, or temporarily pin a specific model to isolate it.

---

## 2. Local config files (real, gitignored — not the `.template.json` ones)

```bash
cd ArbiScanner.AiAssistant/ArbiScanner.AiAssistant.Api
cp appsettings.template.json appsettings.json
cp appsettings.Development.template.json appsettings.Development.json
```

Edit `appsettings.json`'s `OpenRouter` section (the `Development` template
has no such section — it inherits it from the base file):

```json
"OpenRouter": {
  "BaseUrl": "https://openrouter.ai/api/v1/",
  "ApiKey": "sk-or-v1-...",
  "Model": "meta-llama/llama-3.3-70b-instruct:free"
}
```

Everything else in the templates already points at the right places for
local dev (`Jwt:Authority` → `http://localhost:8082/realms/arbiscanner-web`
in `.Development.json`, `WebApi:BaseUrl` → `https://localhost:7274`,
`McpServer:BaseUrl` → `http://localhost:8087/mcp`) — only adjust those if
your local `ArbiScannerWeb.API`/`ArbiScanner.McpServer` listen elsewhere.

**`WebApi:BaseUrl` must be the HTTPS origin (`https://localhost:7274`,
`ArbiScannerWeb.API`'s fixed `https` launch profile port), not
`http://localhost:5267`.** `ArbiScannerWeb.API` runs `UseHttpsRedirection()`
locally, so a request to the `http` port comes back as a `307` to the
`https` one — and .NET's `HttpClient` strips the `Authorization` header
when it auto-follows a redirect across scheme/port. The token-exchange call
silently becomes anonymous on the redirected request and gets a `401`, even
though the original bearer token was completely valid (see the
"`McpToken/Generate` returns `401`" row in the troubleshooting table below —
this is exactly what produces it).

### If running via Docker Compose instead

Set the same two values in your root `.env` (copy `sample.env` → `.env` if
you haven't already):

```bash
OPENROUTER_API_KEY=sk-or-v1-...
OPENROUTER_MODEL=meta-llama/llama-3.3-70b-instruct:free
```

`docker-compose.yml` wires these into the `ai-assistant` service as
`OpenRouter__ApiKey`/`OpenRouter__Model`; `docker-compose.local.yml`
overrides `Jwt__Authority`/`WebApi__BaseUrl`/`McpServer__BaseUrl` to point at
your local Keycloak/host services the same way `mcp-server`'s override does.

---

## 3. Launch

### Option A — all four pieces via `dotnet run` (fastest inner loop)

```bash
# infra only, from the monorepo root
docker compose -f docker-compose.yml -f docker-compose.local.yml up -d postgres rabbitmq redis mongodb keycloak

# Terminal 1
cd ArbiScannerWebApp/ArbiScannerWeb.API && dotnet run
# listens on both https://localhost:7274 and http://localhost:5267 — other
# local services must call the https one (see §2's WebApi:BaseUrl note)

# Terminal 2
cd ArbiScanner.McpServer/ArbiScanner.McpServer.Host && dotnet run
# note the port it prints — no launchSettings.json yet, so it's whatever
# Kestrel picks by default unless you set ASPNETCORE_URLS first

# Terminal 3
cd ArbiScanner.AiAssistant/ArbiScanner.AiAssistant.Api && dotnet run
# listens on http://localhost:5272 (Properties/launchSettings.json)

# Terminal 4
cd ArbiScannerWebApp/ArbiScannerWeb.Client && npm run dev
```

If `ArbiScanner.McpServer` ended up on a port other than `8087`, update
`McpServer:BaseUrl` in `ArbiScanner.AiAssistant.Api/appsettings.Development.json`
to match.

The client's Vite dev server proxies `/ai-hub` to
`AI_ASSISTANT_URL` (default `http://localhost:5272`, see
`ArbiScannerWeb.Client/vite.config.ts`) — no extra config needed if the AI
assistant is running on its default port.

### Option B — full stack via Docker Compose

```bash
docker compose -f docker-compose.yml -f docker-compose.local.yml up --build ai-assistant mcp-server web postgres rabbitmq redis mongodb keycloak
```

Confirm it's healthy:

```bash
curl -f http://localhost:8088/health
```

---

## 4. Test

### Option A — automated test suites (fastest, no live services or OpenRouter key needed)

Both the unit and integration suites use mocked/stubbed OpenRouter and MCP
calls (a real in-process fake MCP server for the integration tests, a
`StubHttpMessageHandler` for OpenRouter) — no network access or API key
required:

```bash
cd ArbiScanner.AiAssistant
dotnet test ArbiScanner.AiAssistant.slnx
```

This runs `ArbiScanner.AiAssistant.Tests` (orchestration branching,
`OpenRouterChatModel`'s request/response parsing, `McpTokenExchangeClient`,
`ConnectionTokenCache`) and `ArbiScanner.AiAssistant.IntegrationTests`
(`ChatHub` over a real SignalR + forged-JWT + real MCP wire protocol, but a
fake tool-providing MCP server and a stubbed OpenRouter endpoint).

Run a single test class while iterating:

```bash
dotnet test ArbiScanner.AiAssistant.Tests/ArbiScanner.AiAssistant.Tests.csproj \
  --filter "FullyQualifiedName~OpenRouterChatModelTests"
```

### Option B — manual, through the browser widget (exercises the real OpenRouter call)

This is the only way to confirm your actual `OPENROUTER_API_KEY`/`OPENROUTER_MODEL`
choice really supports tool calling end to end — the automated tests
deliberately never call the real OpenRouter API.

1. Launch everything per §3 (Option A or B).
2. Sign into the web client.
3. Click the chat icon in the bottom-right corner.
4. Ask a spread-data question, e.g. *"what spreads are available for me?"* —
   expect the thinking indicator (three bouncing dots) while the model
   decides and the tool call runs, then the bubble replaces it in one go
   with a `SpreadsData` chunk (raw JSON from `get_spreads_for_current_user`,
   rendered as text for now). Tool calls are never streamed piecemeal, so
   there's no partial-text phase for this path — just the indicator, then
   the complete result.
5. Open a spread's detail page, open the widget, use the suggested
   "analyze this spread" prompt — expect `get_spread_by_id` called with that
   spread's id (check the JSON's `id` field, or `ArbiScanner.AiAssistant`'s
   console/Loki logs for which tool was invoked).
6. Ask a general product/how-to question, e.g. *"what does the Spread Size
   Threshold mean?"* or *"how do I connect Claude Desktop to my account?"* —
   expect the thinking indicator briefly, then a real, grounded explanation
   that visibly streams in piece by piece (not a generic "I can't help"
   reply, and no MCP tool call in the logs). This exercises the knowledge
   base embedded in the system prompt (`StaticKnowledgeBaseProvider`) — if
   the answer is vague, made up, or just declines, the model likely isn't
   using the knowledge base properly (see the troubleshooting table below).
7. Ask something genuinely unrelated, e.g. *"what's the weather today?"* —
   expect a streamed reply where the model politely says it can only help
   with ArbiScanner-related questions, and confirm (via logs/Tempo) no MCP
   tool call was made. There's no fixed rejection string anymore — the
   exact wording is the model's own, so check that it declines in
   substance, not for an exact match.

### Option C — manual, health/connectivity only (no tool-calling exercised)

Useful for confirming the hub itself is reachable and JWT auth is wired up
correctly before worrying about OpenRouter at all:

```bash
curl -f http://localhost:5272/health        # dotnet run
curl -f http://localhost:8088/health        # docker compose
```

A SignalR hub handshake isn't practical to drive by hand with curl (it's a
negotiate step + WebSocket upgrade, not a single request/response) — for
anything beyond a bare health check, use Option A or B above.

---

## Troubleshooting log

| Symptom | Cause | Fix |
|---|---|---|
| Spread-data questions ("what are my spreads?") get a made-up or generic text answer instead of `SpreadsData`/`SpreadData` | With a pinned model id: it doesn't actually honor the `tools` parameter (some free models silently ignore it and just answer in prose). With `openrouter/free`: the router picked a model that mishandled `tools` on that particular request | Retry (routed model choice varies per request); if it persists, temporarily pin a specific tool-calling-capable model from [openrouter.ai/models](https://openrouter.ai/models) to isolate whether it's the router or something else; re-check `OpenRouterChatModelTests` for the exact response shape (`tool_calls[0].function.{name,arguments}`) the parser expects |
| Widget stays on the thinking indicator forever even though a chunk visibly arrived (check the browser's WebSocket/LongPolling frames in devtools) | `ChatStreamChunkDto.Kind` is a C# enum - if `Program.cs`'s `AddSignalR()` doesn't have `.AddJsonProtocol(...)` registering a `JsonStringEnumConverter`, it serializes as a bare number (`"kind":0`) instead of its name (`"kind":"AnswerDelta"`), and `aiAssistantSignalrService.ts`'s `switch (chunk.kind)` never matches any case | Confirm `Program.cs` still has the `AddJsonProtocol` call; if writing a new .NET SignalR client against this hub (not the browser), it needs the same converter registered on its own `HubConnectionBuilder.AddJsonProtocol(...)` too - see the AiAssistant `README.md` → "Transport" |
| General "how does X work?" questions get a vague answer, a decline, or invented (wrong) details instead of the real curated answer | The model isn't grounding itself in the system prompt's embedded knowledge base (weaker free models sometimes ignore parts of a long system prompt), or `StaticKnowledgeBaseProvider`'s content genuinely doesn't cover that topic | Check whether the topic is actually in `ArbiScanner.AiAssistant.Infrastructure/Knowledge/StaticKnowledgeBaseProvider.cs` first; if it is, try a different/pinned model — this is a model-following-instructions problem, not a code bug |
| OpenRouter call returns `401` | Bad/missing `OPENROUTER_API_KEY`, or it wasn't picked up (e.g. edited `appsettings.json` but the process was started before the edit) | Regenerate the key at [openrouter.ai/keys](https://openrouter.ai/keys); restart `dotnet run`/the container after changing config |
| OpenRouter call returns `429` or the widget hangs then errors | Free-tier model rate limit / temporary unavailability | Wait and retry, or switch `OPENROUTER_MODEL` to a different free tool-calling model |
| Widget shows a generic connection error immediately, hub never receives the message | Vite proxy not reaching the AI assistant (wrong `AI_ASSISTANT_URL`, or the AI assistant process isn't actually running) | Confirm `curl http://localhost:5272/health` succeeds first; check `vite.config.ts`'s `aiAssistantTarget` |
| Hub connection rejected right away (before any message is sent) | `Jwt:Authority`/`Jwt:Audience` mismatch, or the SPA's access token isn't `arbiscanner-web-spa`-audienced | Same `Authority`/`Audience` as `ArbiScannerWeb.API`'s `TradeOpportunityHub` — compare configs; confirm you're actually signed in in the browser tab |
| `AiAssistant` logs `McpToken/Generate returned Unauthorized:` (empty body) on every message, even with a fresh/valid token | `WebApi:BaseUrl` is `http://localhost:5267` instead of `https://localhost:7274` — `ArbiScannerWeb.API`'s `UseHttpsRedirection()` 307s the http request to https, and `HttpClient` drops the `Authorization` header across that scheme/port redirect, so the retried request is anonymous | Set `WebApi:BaseUrl` to `https://localhost:7274` (see §2) and restart `ArbiScanner.AiAssistant.Api` |
| Tool call fails with an MCP/auth-looking error, even though the OpenRouter decision step worked and token exchange succeeded | `ArbiScanner.McpServer` isn't running, or `McpServer:BaseUrl` points at the wrong port | Walk through `MCP_TESTING.md` §1/§4 to confirm the token-exchange path works in isolation first |
| Thinking indicator shows but no text ever streams in, then (after up to ~30s) an error appears | The `"OpenRouter"` `HttpClient`'s `Timeout` (30s, set in `Infrastructure/StartupSetup.AddOpenRouterHttpClient`) covers the *entire* streamed read, not just headers - it's bounded, not an infinite hang, but a genuinely slow/stalled generation will eventually time out this way | Retry (transient with free-tier models); if it's consistently slow, that model/route is a poor fit for this deployment - switch `OPENROUTER_MODEL` |
