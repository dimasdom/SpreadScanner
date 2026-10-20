# AI Assistant & MCP — how it works, and why

A complete walkthrough of `ArbiScanner.McpServer` and `ArbiScanner.AiAssistant`: what each
service does, how a request actually flows end to end (including the token gymnastics), and
the reasoning behind the choices — most of which is recoverable from `git log`, the two
services' own READMEs, and one design doc (`docs/investigations/ai-chat-assistant.md`), pulled
together here in one place with source references.

---

## 1. The one-paragraph version

Two thin, stateless .NET services sit alongside the existing `ArbiScannerWeb.API`.
**`ArbiScanner.McpServer`** exposes three read-only tools (open spreads, spread detail,
recommended spreads) over the [Model Context Protocol](https://modelcontextprotocol.io) — it
owns no data and mints no tokens, it just validates a bearer token and forwards it unchanged to
`ArbiScannerWeb.API`. **`ArbiScanner.AiAssistant`** is a SignalR chat backend for the React
SPA's chat widget: on each message it asks an LLM (via OpenRouter) whether to call one of those
MCP tools or answer directly from a small embedded knowledge base, and streams the result back
token-by-token. Neither service has a database. Both piggyback entirely on Keycloak
infrastructure and API endpoints that already existed for other reasons — this is the through-line
that explains almost every design choice below: **build the smallest possible new surface area
on top of what's already there.**

```
                     ┌─────────────────────────┐
   Browser  ───────▶ │   ArbiScanner.AiAssistant │  (SignalR /ai-hub/chat)
  (ChatWidget)        └───────────┬──────────────┘
                                   │ MCP (Streamable HTTP)
                                   ▼
                     ┌─────────────────────────┐
                     │    ArbiScanner.McpServer  │  (also reachable directly
                     └───────────┬──────────────┘   by Claude Desktop etc.)
                                   │ HTTP (bearer forwarded as-is)
                                   ▼
                     ┌─────────────────────────┐
                     │      ArbiScannerWeb.API   │  ← owns all the real data
                     └─────────────────────────┘
```

---

## 2. Why an MCP server exists at all

The trigger is in [`docs/investigations/ai-chat-assistant.md`](../investigations/ai-chat-assistant.md):
the original ask was just an in-app chat feature, but partway through scoping it, a **confirmed
requirement landed that the tool server had to be reachable directly by third-party MCP clients
(Claude Desktop and friends), not only by the in-app agent** (§0 of that doc, dated 2026-08-03).
That single requirement is why this isn't "the AI assistant calls `ArbiScannerWeb.API`
directly" — instead there's a standalone resource server in front of it, and the in-app
assistant is just *one more client* of that same server, alongside anyone's personal Claude
Desktop.

Consequences of that decision, all visible in the code:

- **Streamable HTTP, not stdio.** An external client needs a network-reachable endpoint, so the
  MCP server had to speak HTTP either way. Given that, the in-app AI Assistant also just calls
  it over HTTP on the internal Docker network (`http://mcp-server:8080/mcp`) instead of getting
  its own private stdio-spawned instance — one container, two ingress paths (`ArbiScanner.McpServer/README.md`, `docker-compose.yml`'s `mcp-server` block).
- **A real OAuth resource server, not a shared internal API key.** Because *any* MCP client the
  user personally chooses can now connect, the server can't rely on "trusted internal caller"
  shortcuts — it has to be a standards-compliant bearer-token validator, multi-tenant by
  pass-through (§3.5 of the investigation doc). This is also the concrete trigger (#3) that
  pulled forward the whole Keycloak migration described in
  [`oauth-oidc-migration.md`](../investigations/oauth-oidc-migration.md).
- **Read-only tool set.** The investigation doc's own open question (§7) — "read-only for
  external clients, at least at first?" — was resolved in favor of read-only: nothing exposed
  today (`get_spreads_for_current_user`, `get_spread_by_id`, `get_recommended_spreads`) can
  mutate anything. A `Claude Desktop` user connecting their own token can only ever *read* their
  own spread data.

---

## 3. `ArbiScanner.McpServer` — the resource server

### 3.1 What it is

A .NET 10 ASP.NET Core host with **no `Application` layer** (Clean Architecture: Domain →
Abstractions → Infrastructure → Host) — both tools are thin pass-throughs with no use-case
orchestration, the same reasoning `ArbitrageScanner` uses to skip that layer. It:

- Validates an incoming JWT (standard `AddJwtBearer`, Keycloak `arbiscanner-web` realm,
  audience `arbiscanner-mcp`) — no local user store, no signing key of its own.
- Forwards that *exact same token, unmodified* to `ArbiScannerWeb.API` when calling a tool.
- Maps `ArbiScannerWeb.API`'s JSON responses into MCP tool results.

That's the entire service. It "owns" nothing — no database, no business logic, no client
secret.

### 3.2 The tools

| Tool (`[McpServerTool(Name=...)]`) | Wraps | Notes |
|---|---|---|
| `get_spreads_for_current_user` | `GET /api/TradeOpportunity/GetSpreadsForUser` | All currently-open spreads matching the caller's settings filters. |
| `get_spread_by_id` | `GET /api/TradeOpportunity/GetSpreadInfo/{id}` | Full detail + ticker history for one spread. |
| `get_recommended_spreads` | `GET /api/TradeOpportunity/GetRecommendedSpreads` | Top 2 per category (Futures/Funding/Spot), pre-ranked server-side by lowest funding+slippage cost among spreads ≥1%. |

Source: [`ArbiScanner.McpServer.Host/Tools/SpreadTools.cs`](../../ArbiScanner.McpServer/ArbiScanner.McpServer.Host/Tools/SpreadTools.cs).
`[McpServerToolType]` + `[McpServerTool]`/`[Description(...)]` attributes are how the official
`ModelContextProtocol` SDK auto-discovers and schemas these — `WithToolsFromAssembly()` in
`Program.cs` scans for them, no manual tool registry to maintain.

> **Note:** `ArbiScanner.McpServer/README.md`'s "MCP Tools" table currently lists only the first
> two — `get_recommended_spreads` was added after that table was last updated but is fully
> live, tested, and wired into the AI Assistant's system prompt and the chat widget's UI
> (`SpreadRecommendationBox.tsx`, `ChatStreamChunkKind.RecommendedSpreads`). The README's
> narrative sections (auth, architecture) are otherwise accurate.

Each tool returns a `string`: JSON (camelCase, matching `ArbiScannerWeb.API`'s own MVC output
convention) on success, or a plain-text `"Error retrieving ...: {message}"` string on failure —
**not** an MCP protocol-level error. That choice matters downstream (see §4.5).

### 3.3 Authentication — one token, forwarded, never minted

This is the one genuinely non-obvious piece of the whole feature, and it's worth walking
through slowly because both services depend on it.

**The problem:** an MCP client like Claude Desktop stores one static bearer value in its config
file and never does an OAuth refresh dance. A normal Keycloak access token lives minutes. So
somehow a *user-scoped, long-lived* credential has to come out of an OAuth server that normally
only issues short-lived ones — without building a second auth system.

**The trick — two settings that only work together:**

1. The `arbiscanner-mcp` Keycloak client has `access.token.lifespan` overridden to `2592000`
   seconds (30 days) — see `keycloak/realm-export/arbiscanner-web-realm.json`.
2. Minting the token uses **RFC 8693 Standard Token Exchange**: the user's own already-logged-in
   `arbiscanner-web-spa` session token is exchanged for a new one audienced to
   `arbiscanner-mcp` (and still `arbiscanner-web-spa`, via a second audience mapper on the same
   client — see line 179-188 of the realm export). The exchange request also asks for
   `scope=offline_access`.

The subtlety: `offline_access` here does **not** yield a usable `refresh_token` (Keycloak 26.4's
Standard Token Exchange doesn't issue one — confirmed against a real container, `refresh_expires_in`
comes back `0` either way). What it *does* do is upgrade the exchange's underlying session to an
**offline session**, which isn't capped by the realm's ~10-hour SSO Session Max the way a normal
session is. Drop that scope and the 30-day `access.token.lifespan` override silently gets
truncated back down to the session-bound lifetime anyway. This exact failure mode is what
`ArbiScannerWeb.IntegrationTests`' `McpTokenControllerTests` asserts against — by decoding the
real JWT's own `exp` claim, not trusting the token endpoint's `expires_in` field, which would
have hidden the bug.

**Where this lives in code:**

- `ArbiScannerWeb.Infrastructure/Services/McpTokenService.cs` — does the actual Keycloak call
  (`grant_type=urn:ietf:params:oauth:grant-type:token-exchange`), holds the `arbiscanner-mcp`
  client id/secret (the *only* place in the whole system that does).
- `ArbiScannerWeb.API/Controllers/McpTokenController.cs` — `POST /api/McpToken/Generate`,
  `[Authorize]`-gated, just calls the service above.
- This endpoint was **originally built for the "connect Claude Desktop to your account" flow**
  (the web app's "MCP Access" page) and is **reused as-is** by `ArbiScanner.AiAssistant` for a
  completely different purpose (see §4.3) — no new Keycloak client, no new endpoint, no
  duplicated exchange logic.

```
User's browser session (arbiscanner-web-spa token, already logged in)
        │
        ▼
POST /api/McpToken/Generate  (ArbiScannerWeb.API, McpTokenController → McpTokenService)
        │  Standard Token Exchange, scope=openid offline_access
        ▼
Keycloak (arbiscanner-web realm, arbiscanner-mcp client:
          access.token.lifespan=2592000s, offline session)
        │
        ▼
One 30-day access token, audience = [arbiscanner-mcp, arbiscanner-web-spa]
        │
        ├── (MCP Access page) user copies it into Claude Desktop's config ──▶ ArbiScanner.McpServer
        └── (AI Assistant)   ChatHub exchanges it itself, per SignalR connection ──▶ ArbiScanner.McpServer
```

Once that token reaches `ArbiScanner.McpServer`, everything is standard resource-server
behavior: `AddJwtBearer` validates it against Keycloak's JWKS (no round-trip to Keycloak per
request — local signature/expiry check only), and `SpreadsApiClient` reads that same validated
token straight off the current `HttpContext` (`BearerTokenReader`) and forwards it verbatim to
`ArbiScannerWeb.API`, which resolves "current user" from the token's own `sub` claim. **No
service in this whole chain, other than `ArbiScannerWeb.API` itself, ever holds a Keycloak
client secret or mints a token** — `ArbiScanner.McpServer` validates; `ArbiScanner.AiAssistant`
only ever forwards a token it asked `ArbiScannerWeb.API` to make on its behalf.

### 3.4 Layer-by-layer code map

```
ArbiScanner.McpServer/
├── ArbiScanner.McpServer.Domain/           DTOs mirroring ArbiScannerWeb.API's wire shape
│   ├── Dtos/  SpreadDetailsDto, RecommendedSpreadDto, ApiEnvelopeDto<T> (= SerializableResult<T>), …
│   └── Settings/  KeycloakOptions, WebApiOptions
├── ArbiScanner.McpServer.Abstractions/
│   └── Interfaces/ISpreadsApiClient.cs      3 methods, FluentResults Result<T>
├── ArbiScanner.McpServer.Infrastructure/
│   ├── Services/SpreadsApiClient.cs         typed HttpClient, forwards inbound bearer token
│   ├── Authentication/BearerTokenReader.cs  the one place that reads Authorization: Bearer
│   └── StartupSetup.cs                      AddAuthenticationJwt (copy of WebApp's own), DI
└── ArbiScanner.McpServer.Host/
    ├── Tools/SpreadTools.cs                 [McpServerToolType] — the 3 tools
    └── Program.cs                           AddMcpServer().WithHttpTransport()…
                                              MapMcp("/mcp").RequireAuthorization()
```

Why DTOs are duplicated instead of referencing `ArbiScannerWeb.*` assemblies directly: this
service (like `ArbiScanner.AiAssistant`) only ever talks to `ArbiScannerWeb.API` over plain
HTTP, never as a project reference — see the monorepo root `CLAUDE.md`'s note that both of
these are the two submodules *without* cross-submodule project references, which is exactly why
each one's Docker build context is its own submodule root, not the monorepo root.

### 3.5 Testing

Two Docker-free test projects (unlike `ArbiScannerWeb.*`'s Testcontainers-backed integration
tests):

- **Unit** (`SpreadsApiClientTests`) — stubbed `HttpMessageHandler`, checks token forwarding,
  URL/id-escaping, envelope mapping, 401-doesn't-retry, missing-token handling.
- **Integration** (`McpEndpointTests`) — real `WebApplicationFactory<Program>`, real MCP
  protocol round-trip via the **actual MCP client SDK** (`ModelContextProtocol.Client`), only
  the downstream `ArbiScannerWeb.API` HTTP call stubbed. Proves unauthenticated/expired-token
  calls never reach the stub, and that a real Streamable-HTTP tool call forwards the caller's
  exact token.

The 30-day-token-actually-works claim is proven once, with a real Testcontainers Keycloak, in
`ArbiScannerWeb.IntegrationTests`' `McpTokenControllerTests` — not re-proven here, since that
would just be slower without adding correctness.

---

## 4. `ArbiScanner.AiAssistant` — the chat backend

### 4.1 What it does (and deliberately doesn't)

- Answers three kinds of question: live-spread-data questions (routed to an MCP tool),
  "how does ArbiScanner work / how do I do X" questions (answered from a built-in knowledge
  base), and everything else (a short decline — see §4.4).
- **No conversation history, anywhere.** Every SignalR call is one self-contained turn; the
  browser doesn't resend prior turns and the server keeps none. The React widget's `messages`
  array is purely local UI state.
- **Read-only**, because it can only ever call the same three MCP tools described above.
- **Passes tool output straight through.** For a tool-backed answer, what the browser gets back
  is literally the tool's JSON, tagged with which tool produced it — not an LLM-written summary
  of it. The system prompt explicitly instructs the model *not* to recompute or restate any
  numbers the tool already returned (see the prompt text in `OpenRouterChatModel.cs`) — the
  server-computed figures are the source of truth, the model's job is just deciding which tool
  answers the question, not doing arithmetic on the result.

### 4.2 Layering

Clean Architecture, same convention as the rest of the monorepo, this time *with* an
`Application` layer (there's a real use case to orchestrate: get-a-token → list-tools →
stream-a-decision → maybe-call-a-tool):

```
Domain           DTOs + options POCOs (ChatRequestDto, ChatStreamChunkDto, AiChatStreamEvent, McpToolDescriptor, McpToolNames)
Abstractions     IAiChatModel, IChatOrchestrationService, IConnectionTokenCache, IKnowledgeBaseProvider, IMcpTokenExchangeClient, IMcpToolClient
Infrastructure   OpenRouterChatModel, McpToolClient, McpTokenExchangeClient, ConnectionTokenCache,
                 StaticKnowledgeBaseProvider, JWT bearer auth wiring
Application      ChatOrchestrationService — the one use case
Api              composition root, ChatHub (SignalR)
```

No database, no cross-submodule references — same reasoning as `ArbiScanner.McpServer` (§3.4).

### 4.3 Authentication — two hops, zero new Keycloak configuration

```
Browser  ──(arbiscanner-web-spa JWT — the SAME token used for every other API call)──▶  ChatHub
ChatHub  ──(same token, forwarded)──▶  POST ArbiScannerWeb.API/api/McpToken/Generate  ──▶  arbiscanner-mcp JWT
ChatHub  ──(that arbiscanner-mcp JWT)──▶  ArbiScanner.McpServer
```

`ChatHub` validates the *exact same* `arbiscanner-web-spa`-audienced token the browser already
carries for every REST call — identical `Authority`/`Audience` setup to
`ArbiScannerWeb.API`'s own `TradeOpportunityHub`, including the `access_token` query-string
carve-out (`HubBearerTokenReader`), because a browser can't set an `Authorization` header on a
WebSocket handshake — SignalR's `accessTokenFactory` puts it in the query string instead, and
the JWT bearer handler is configured to also accept it from there for hub paths.

Getting from that token to one `ArbiScanner.McpServer` will accept reuses the *exact same*
`McpTokenController`/`McpTokenService` described in §3.3 — the one originally built for the
"MCP Access" page. `ArbiScanner.AiAssistant` never talks to Keycloak directly and never sees a
client secret; it just calls that endpoint like any other authenticated client would
(`McpTokenExchangeClient`).

**Why cache the exchanged token per connection** (`ConnectionTokenCache`, an in-memory
`ConcurrentDictionary<connectionId, (token, expiresAt)>`, 1-hour fixed TTL, cleared in
`ChatHub.OnDisconnectedAsync`): the exchanged token is actually valid 30 days, but re-deriving
that from the JWT would mean parsing it here too — unnecessary, since this cache only needs to
outlive one widget session, not the token's real lifetime. Without it, every single chat message
in a session would round-trip to Keycloak for no reason. This is explicitly *not* a conversation
store — it holds a credential, not messages, which is why it doesn't conflict with the
"no conversation history" design goal above.

### 4.4 The model boundary — `IAiChatModel`

```csharp
public interface IAiChatModel
{
    IAsyncEnumerable<AiChatStreamEvent> StreamDecisionAsync(
        string userPrompt, string? pageContext,
        IReadOnlyList<McpToolDescriptor> availableTools,
        CancellationToken cancellationToken);
}
```

This is the only seam `ChatOrchestrationService` depends on for inference — swapping providers
later (a different OpenRouter model, direct Anthropic/OpenAI, a local model) means one new
`Infrastructure` class plus a DI line, nothing in `Application`/`Api` changes. `AiChatStreamEvent`
is deliberately *not* wrapped in this codebase's usual `FluentResults` `Result<T>`: a mid-stream
failure has to surface as just another event in the sequence (`IsError`), not a wrapper around
the whole stream, because you can't retroactively wrap an `IAsyncEnumerable` that's already
partway delivered to the browser.

**`OpenRouterChatModel`** (the only implementation today) calls OpenRouter's OpenAI-compatible
`/chat/completions` with `"stream": true` and a `tools` array built directly from the MCP tool
schemas `McpToolClient.ListToolsAsync` returned (so the *live* tool list drives the model's
available actions — add a fourth MCP tool and the model sees it with zero AiAssistant code
changes). The model decides, per message:

1. **Call a tool** — for live-spread-data questions. The system prompt spells out exactly when
   to use which of the three tools (e.g. "recommend a spread" → `get_recommended_spreads`,
   don't re-rank the result yourself).
2. **Answer directly from the knowledge base** — for product/how-to questions, using *only* the
   embedded knowledge base content, explicitly told to say "I don't have that information"
   rather than guess (e.g. exact pricing) and to point to support email.
3. **Decline in its own words** — for anything unrelated to ArbiScanner. **There is no separate
   classifier and no fixed canned rejection string** — the model always writes its own reply;
   the prompt just tells it what the boundaries are.

This is a real design choice worth naming: the "routing" is entirely prompt-driven, not a
keyword filter or an intent-classification step in front of the LLM. Simpler to build, but it
also means answer quality/boundary-adherence is only as good as the model's instruction-following
— see §5 for why a free-tier model was judged sufficient for this.

**SSE parsing details worth knowing if you touch this file:** tool-call arguments arrive as
incremental string fragments across many SSE chunks (`ToolCallAccumulator` concatenates them) and
are only ever surfaced as one complete `AiChatStreamEvent.ToolCall` — never streamed piecemeal,
because a tool call can't be *acted on* until its JSON arguments are whole. Text deltas, by
contrast, are yielded the instant they arrive. There's a structural C# constraint baked into the
method split between `OpenStreamAsync` and `ReadEventsAsync`: a `yield return` can't appear
inside a `try` block that has a `catch` — so per-line read errors are caught into a local
variable first, and only turned into a yielded `Error` event once outside that inner try/catch
(see the doc comments in `OpenRouterChatModel.cs` if this trips you up while editing it).

### 4.5 The knowledge base — a point-in-time copy, not RAG

`StaticKnowledgeBaseProvider.GetContent()` returns a ~1,000-word, English-only, hand-curated
snapshot of the web client's FAQ/onboarding i18n content, embedded in the system prompt on
*every single request*. No vector store, no chunking, no retrieval step. This is a deliberate
choice, not an oversight: the whole corpus comfortably fits inside any model's context window
at that size, so RAG's usual justification (too much content to fit) doesn't apply, and RAG
would add real complexity (embeddings, a vector DB, a retrieval pipeline) for zero benefit at
this scale.

The tradeoff this accepts: it's a **manual sync problem**. If `ArbiScannerWeb.Client`'s FAQ or
onboarding guide changes materially, this file needs a matching manual update — nothing
automated keeps them in sync, and there's no live fetch (this service can't reach the client's
static assets at runtime anyway, by design — it has no cross-submodule access).

### 4.6 One request, a stream of chunks — `ChatOrchestrationService`

`ChatOrchestrationService.StreamMessageAsync` is the entire use case, and its shape is worth
internalizing because it's the same shape `ChatHub` and the frontend both mirror:

```
0. yield ConversationStart                         (always first)
1. get-or-exchange MCP token (ConnectionTokenCache) — auth failure → Error, ConversationEnd, done
2. list tools from ArbiScanner.McpServer (McpToolClient) — unreachable → Error, ConversationEnd, done
3. stream IAiChatModel.StreamDecisionAsync(prompt, pageContext, tools)
     each text delta   → yield AnswerDelta          (as they arrive)
     a tool call event → break out, remember it
     a model error     → yield Error, ConversationEnd, done
4. if a tool call was captured:
     call it via McpToolClient.CallToolAsync
     yield ToolResult (or Error if the call failed)
5. yield ConversationEnd                            (always last, however it got here)
```

Every expected failure mode is a yielded `Error` chunk, never a thrown exception — which is also
a structural necessity, not just a style preference: a `yield return` can't live inside a
try/catch, so this method has *no* try/catch of its own; every awaited call underneath it
already returns a checked `Result<T>` or an `IsError`-flagged event instead of throwing.
`ConversationStart`/`ConversationEnd` bracket **every** path unconditionally, including the
empty-prompt short-circuit — this is what lets the frontend reliably clear its "thinking"
indicator regardless of which other chunk kind happened to show up (or not show up at all, e.g.
an empty answer).

### 4.7 Transport — SignalR streaming, not REST/SSE

`ChatHub` is mapped at `/ai-hub/chat`, mirroring `ArbiScannerWeb.API`'s existing
`TradeOpportunityHub` pattern and reusing the `@microsoft/signalr` client the SPA already
depends on. There's exactly one hub method:

```csharp
IAsyncEnumerable<ChatStreamChunkDto> StreamMessage(ChatRequestDto request, CancellationToken ct)
```

— a SignalR **streaming** invocation (`connection.stream(...)`, not `.invoke(...)`). Interesting
history here: the *original* investigation doc (§4) actually recommended **REST + Server-Sent
Events** over a new SignalR hub, specifically to avoid "building a second streaming transport
pattern for one feature." The shipped implementation went the other way — SignalR — most likely
because it let the browser reuse the exact same connection/auth patterns
(`accessTokenFactory`, the query-string token carve-out) `TradeOpportunityHub` already
established, rather than hand-rolling a new `fetch()` + `ReadableStream` reader pattern the
investigation doc flagged as "a different pattern from every other API call in the client
today." Both were reasonable; this is a place where you can see the plan and the shipped code
genuinely diverged, and it's worth knowing that if you're wondering why there's no
`/api/Chat/...` REST controller anywhere.

`ChatStreamChunkKind` is a real C# enum (`ConversationStart | AnswerDelta | SpreadsData |
SpreadData | RecommendedSpreads | ToolResult | Error | ConversationEnd`), and `Program.cs`
registers a `JsonStringEnumConverter` on the hub's JSON protocol so it serializes as its string
name — without that, it'd serialize as a bare int and every one of the browser's string
comparisons (`'AnswerDelta'`, etc.) would silently never match, leaving the UI stuck in its
"thinking" state forever. Any other .NET SignalR client (including this service's own
integration tests) has to register the identical converter on its own `HubConnectionBuilder`, or
deserialization breaks after the first chunk.

### 4.8 The frontend side

`aiAssistantSignalrService.ts` is a small dedicated wrapper — deliberately **not** merged into
the app's existing `signalrService` (which talks to `TradeOpportunityHub`), because this hub
lives in a different backend container with its own connection lifecycle and isn't a good fit
for that service's group-join-oriented API. It translates each `ChatStreamChunkDto.kind` into
one of eight callbacks (`onStart`, `onDelta`, `onSpreadsData`, `onSpreadData`,
`onRecommendedSpreads`, `onToolResult`, `onError`, `onFinish`) so `ChatWidget.tsx` never
branches on the raw chunk shape itself.

`ChatWidget.tsx` (mounted once at the app root, same pattern as `CookieConsentModal`, so it
survives route navigation) renders tool results as **rich structured components** —
`SpreadRecommendationBox`, `SpreadsPreviewBox`, `SpreadAnalysisBox` — keyed off which callback
fired, with the generic `onToolResult` fallback (pretty-printed JSON) reserved for any future
MCP tool that doesn't have a dedicated box yet.

> **Note:** `ArbiScanner.AiAssistant/README.md`'s "Transport" section says
> `onSpreadsData`/`onSpreadData` "currently just render their payload as pretty-printed JSON…
> a richer spreads-table/spread-card view… is future work." That's no longer accurate — the rich
> boxes above are already implemented and shipped in `ChatWidget.tsx`. The README is stale on
> this one point; everything else in it checks out against the code.

A leading text delta and a structured payload are **additive, not exclusive** — the model can
stream a short sentence before its tool-call decision resolves, and the widget keeps both
(`renderMessageContent` in `ChatWidget.tsx`). The floating widget also has a mobile-specific
behavior: on screens <640px the panel is full-screen, so clicking a link inside a chat message
closes the widget first so the resulting navigation is actually visible.

### 4.9 Testing

- **Unit** (`ChatOrchestrationServiceTests`) — every branch (auth failure, MCP unreachable, a
  multi-chunk product answer, a decline, a successful/failing tool call, page-context
  pass-through, a mid-stream model error) with `IAiChatModel`/`IMcpToolClient`/
  `IConnectionTokenCache` mocked. Every test asserts the *entire* chunk sequence, not just the
  interesting middle chunk — specifically so a change that breaks the
  `ConversationStart`/`ConversationEnd` bracketing fails loudly instead of silently.
- **Unit** (`OpenRouterChatModelTests`) — SSE parsing against a stubbed HTTP handler with
  hand-built `data: {...}` frames: content deltas as they arrive, a tool call's name/arguments
  accumulated across chunks, the knowledge base landing in the system prompt.
- **Integration** (`ChatHubTests`) — real SignalR streaming invocation end to end, real JWT
  auth, an in-process fake MCP server, OpenRouter stubbed at the HTTP layer. No live OpenRouter
  or MCP calls in any test.
- **`ArbiScanner.AiAssistant.Evaluation`** — a separate console project (not part of the normal
  `dotnet test` run) that runs a fixed set of prompts against a real deployment and uses a
  second OpenRouter call as an LLM judge to score answer quality, persisting results to Mongo.
  This is offline quality evaluation, distinct from the correctness-focused unit/integration
  suites above.

---

## 5. Why these specific technology choices

Pulling together the reasoning scattered across the READMEs and the investigation doc, since
none of it is obvious just from reading the code:

| Choice | Why (not the obvious alternative) |
|---|---|
| **MCP instead of a bespoke internal API** | Once "must work with external clients like Claude Desktop" was a confirmed requirement, MCP's standard tool-calling interface is the thing external clients already speak — a bespoke API would need a bespoke integration per client. |
| **OpenRouter, not a direct provider SDK / local model** | Remote inference means the AI Assistant process never loads model weights — memory cost is "how many containers," not "how much RAM per model." Provider-agnostic via one OpenAI-compatible endpoint; free-tier catalog covers a task (route a question, don't recompute numbers) that doesn't need frontier reasoning. |
| **No agent framework (LangChain/LlamaIndex/etc.)** | Those pull large dependency trees and idle RAM for capabilities (multi-provider abstraction, vector stores, chains) this feature doesn't use. A hand-rolled loop against one HTTP endpoint is a few hundred lines with no framework tax — directly stated as a memory-efficiency goal for a small VPS deployment. |
| **Model decides tool-vs-answer, not a keyword classifier** | Simpler to build and extend (a new tool just needs a schema + a prompt line, not new classifier training/rules), at the cost of boundary-adherence depending on instruction-following quality — judged acceptable for a small, well-scoped task. |
| **Static knowledge base, not RAG** | The whole corpus is small enough to fit in a single system-prompt message on every request. RAG's complexity (embeddings, vector DB, chunking, retrieval) buys nothing at this size — the entire justification for RAG (too much content to fit in context) doesn't hold here. |
| **Raw tool output passed through, not LLM-summarized** | The tools already return server-computed final figures (percentages, rankings). Having the model restate them in prose risks it silently altering a number. Rich rendering (§4.8) solves the "raw JSON is ugly" problem on the frontend instead, without touching the number itself. |
| **No conversation history / stateless per turn** | Sidesteps an entire class of "who cleans up idle sessions" problems on a memory-constrained box, and keeps both services trivially horizontally scalable (any instance can handle any turn). |
| **Token exchange reusing an existing endpoint, not a new auth path** | `McpTokenController`/`McpTokenService` already existed for the "MCP Access" page. Standard Token Exchange centralizes the one Keycloak client secret this whole feature needs in the one service (`ArbiScannerWeb.API`) that already had a reason to hold Keycloak credentials — neither `McpServer` nor `AiAssistant` needs one. |
| **SignalR over REST/SSE for the chat transport** | Diverged from the original plan (§4.7) — likely chosen to reuse the SPA's existing SignalR connection/auth conventions (`accessTokenFactory`, the `access_token` query-string carve-out) rather than build a second streaming pattern (`fetch` + `ReadableStream`) from scratch. |
| **Separate `ArbiScanner.McpServer`/`ArbiScanner.AiAssistant` containers, no cross-submodule references** | Both only ever talk to `ArbiScannerWeb.API` over HTTP with their own copied DTOs — this is *why* (per the monorepo root `CLAUDE.md`) they're the two submodules that build from their own root instead of the monorepo root, unlike `AdminPannel`/`TelegramNotifierApp`. |

---

## 6. Full end-to-end trace: "what should I look at?" typed into the chat widget

Concrete walk of every hop, useful when debugging:

1. **Browser** — `ChatWidget.send()` optimistically appends a pending assistant message, calls
   `aiAssistantSignalrService.streamMessage({ prompt, spreadContextId }, handlers)`.
2. **SignalR connect** (first message only, or after a drop) — `accessTokenFactory` fetches the
   current `arbiscanner-web-spa` access token and SignalR appends it as `?access_token=...` on
   the `/ai-hub/chat` handshake (browsers can't set `Authorization` on a WebSocket upgrade).
3. **nginx** — `location /ai-hub/` proxies straight through to `http://ai-assistant:8080/ai-hub/`
   with `Upgrade`/`Connection: upgrade` headers and a 3600s read timeout (long-lived streaming
   connection).
4. **`ChatHub.StreamMessage`** — `[Authorize]` already validated the token by the time this
   method runs; `HubBearerTokenReader.Read` pulls the raw token back out for forwarding, and
   delegates to `ChatOrchestrationService.StreamMessageAsync`.
5. **`ConnectionTokenCache.GetOrExchangeAsync`** — cache miss on a fresh connection →
   `McpTokenExchangeClient.ExchangeAsync` → `POST ArbiScannerWeb.API/api/McpToken/Generate` →
   `McpTokenService` does the RFC 8693 exchange against Keycloak → a 30-day
   `arbiscanner-mcp`-audienced token comes back and is cached against this SignalR connection ID.
6. **`McpToolClient.ListToolsAsync`** — opens an MCP Streamable HTTP session to
   `http://mcp-server:8080/mcp` with that token, lists the 3 tools and their JSON schemas.
7. **`OpenRouterChatModel.StreamDecisionAsync`** — builds the system prompt (boundary
   instructions + the embedded knowledge base) + the 3 tool schemas + the user's message, POSTs
   to OpenRouter with `stream: true`. For "what should I look at", the model emits a tool-call
   delta sequence naming `get_recommended_spreads` with no arguments — accumulated into one
   `AiChatStreamEvent.ToolCall`.
8. **`ChatOrchestrationService`** sees the tool-call event, breaks out of the delta loop, calls
   **`McpToolClient.CallToolAsync`** — a fresh MCP connection (see the tradeoff note in
   `McpToolClient`'s doc comment: no session reuse across calls in this pass), same bearer
   token.
9. **`ArbiScanner.McpServer`** — `AddJwtBearer` validates the token, `SpreadTools.GetRecommendedSpreads`
   calls `ISpreadsApiClient.GetRecommendedSpreadsAsync`, which forwards the *exact inbound
   token* to `GET ArbiScannerWeb.API/api/TradeOpportunity/GetRecommendedSpreads`.
10. **`ArbiScannerWeb.API`** resolves the current user from the token's `sub` claim, computes
    the ranked top-2-per-category list, returns it wrapped in the standard
    `SerializableResult<T>` envelope.
11. Response threads back up: `SpreadsApiClient` unwraps the envelope → `SpreadTools` serializes
    it (camelCase) as the tool's string result → `McpToolClient` parses that string back into a
    `JsonElement` → `ChatOrchestrationService` yields `ChatStreamChunkDto.ToolResult(...)`,
    which `ToolResult(...)`'s own switch maps to `Kind = RecommendedSpreads` specifically
    (because the tool name matched `McpToolNames.GetRecommendedSpreads`).
12. Finally `ConversationEnd`. The browser's `onRecommendedSpreads` handler fires, patches the
    pending message with a `SpreadRecommendationBox` payload; `onFinish` clears the pending/
    "thinking" state regardless of what else happened.

---

## 7. Known rough edges (accurate as of this writing)

- **`ArbiScanner.McpServer/README.md`'s tool table is one tool behind the code** — see §3.2.
- **`ArbiScanner.AiAssistant/README.md`'s "Transport" section describes tool results as plain
  JSON** — the rich `SpreadRecommendationBox`/`SpreadsPreviewBox`/`SpreadAnalysisBox` rendering
  already shipped; see §4.8.
- **No MCP personal-access-token revocation.** Generating a new one (MCP Access page) doesn't
  invalidate previously-issued ones — treat it like a password (`ArbiScanner.McpServer/README.md`).
- **No natural-language synthesis of tool results** — by design (§4.1/§5), not a gap, but worth
  knowing if you're asked "why doesn't the assistant just explain the spread in a sentence."
- **Single tool call per turn.** Both `ChatOrchestrationService` and `OpenRouterChatModel`'s
  `ToolCallAccumulator` assume/enforce exactly one tool call per model turn — a model that tried
  to request two tools in parallel would have the second one's arguments silently dropped.

---

## 8. Where to go deeper

- [`ArbiScanner.McpServer/README.md`](../../ArbiScanner.McpServer/README.md) — full env var
  reference, local-dev steps, CI/CD.
- [`ArbiScanner.AiAssistant/README.md`](../../ArbiScanner.AiAssistant/README.md) — same, plus
  the `OpenRouter:Model` free-tier-selection guidance.
- [`MCP_TESTING.md`](../../MCP_TESTING.md) / [`AI_ASSISTANT_TESTING.md`](../../AI_ASSISTANT_TESTING.md)
  (monorepo root) — full local end-to-end walkthroughs, including obtaining a token by hand.
- [`docs/investigations/ai-chat-assistant.md`](../investigations/ai-chat-assistant.md) — the
  original design investigation; §1–§7 are the "why," §8 is the phased rollout plan this was
  built against.
- [`docs/investigations/oauth-oidc-migration.md`](../investigations/oauth-oidc-migration.md) /
  [`docs/architecture/webapp-oauth-oidc-flow.md`](webapp-oauth-oidc-flow.md) — the Keycloak
  migration this whole feature's auth model depends on.
- `keycloak/realm-export/arbiscanner-web-realm.json` — the actual `arbiscanner-mcp` client
  config (search for `"clientId": "arbiscanner-mcp"`).
