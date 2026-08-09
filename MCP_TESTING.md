# Testing ArbiScanner.McpServer locally

Local notes for exercising the MCP server end to end (token generation → MCP
tool calls → data from `ArbiScannerWeb.API`) against your local Docker stack.
Assumes you already have Postgres/RabbitMQ/Redis/MongoDB/Keycloak running per
the root `README.md`'s "Local Development" section
(`docker compose -f docker-compose.yml -f docker-compose.local.yml up -d
postgres rabbitmq redis mongodb keycloak`).

---

## 1. One-time local Keycloak setup

If you haven't already, provision the fixed local-dev client secrets (also
patches `arbiscanner-mcp`'s Standard Token Exchange config — this is
everything a fresh local Keycloak container is missing beyond what
`--import-realm` gives it):

```bash
set -a && source .env && set +a
./keycloak/configure-local-dev.sh
```

**If your local Keycloak container was created before this repo's
`keycloak/realm-export/arbiscanner-web-realm.json` picked up the
`arbiscanner-mcp` client** (i.e. it was already running before that file
changed), `--import-realm` won't retroactively add it — `configure-local-dev.sh`
only *sets secrets on clients that already exist*, it doesn't create them.
Check first:

```bash
set -a && source .env && set +a
docker exec -i arbiscanner-keycloak /opt/keycloak/bin/kcadm.sh config credentials \
  --server http://localhost:8080 --realm master \
  --user "$KEYCLOAK_ADMIN_USER" --password "$KEYCLOAK_ADMIN_PASSWORD"
docker exec -i arbiscanner-keycloak /opt/keycloak/bin/kcadm.sh get clients \
  -r arbiscanner-web -q "clientId=arbiscanner-mcp" --fields id
```

If that returns `[ ]` (empty), the client doesn't exist yet — recreate it
manually the same way `keycloak/README.md` step 9 documents for the VPS (the
exact `kcadm create clients` / audience-mapper commands), then re-run
`configure-local-dev.sh` to set its secret. Simplest alternative: drop the
Keycloak container's volume and let it re-import from scratch.

Sanity-check the result:

```bash
MCP_ID=$(docker exec -i arbiscanner-keycloak /opt/keycloak/bin/kcadm.sh get clients \
  -r arbiscanner-web -q "clientId=arbiscanner-mcp" --fields id \
  | grep -o '"id"[^,}]*' | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
docker exec -i arbiscanner-keycloak /opt/keycloak/bin/kcadm.sh get "clients/$MCP_ID" -r arbiscanner-web \
  | grep -A6 '"attributes"'
# expect: "standard.token.exchange.enabled": "true", "access.token.lifespan": "2592000"
docker exec -i arbiscanner-keycloak /opt/keycloak/bin/kcadm.sh get "clients/$MCP_ID/protocol-mappers/models" \
  -r arbiscanner-web --fields name
# expect both audience-arbiscanner-mcp and audience-arbiscanner-web-spa
```

---

## 2. Local config files (real, gitignored — not the `.template.json` ones)

**`ArbiScannerWebApp/ArbiScannerWeb.API/appsettings.Development.json`** needs
a `Keycloak:McpExchange` section (this is what mints tokens on the "MCP
Access" page):

```json
"Keycloak": {
  "AdminService": { "...": "..." },
  "McpExchange": {
    "Authority": "http://localhost:8082/realms/arbiscanner-web",
    "ClientId": "arbiscanner-mcp",
    "ClientSecret": "local-dev-mcp-secret"
  }
}
```

**`ArbiScanner.McpServer/ArbiScanner.McpServer.Host/appsettings.Development.json`**
doesn't exist until you create it — copy the template. The template's
`WebApi:BaseUrl` already points at `https://localhost:7274`
(`ArbiScannerWeb.API`'s fixed `https` launch profile port) — leave it as the
`https` URL, not `http://localhost:5267`: `ArbiScannerWeb.API` runs
`UseHttpsRedirection()` locally, so a plain-`http` request there comes back
as a `307` to the `https` port, and `HttpClient` drops the `Authorization`
header when it auto-follows a redirect across scheme/port. The tool call
(or the curl in §4 below) ends up authenticating as nobody and gets a
silent `401`/empty response instead of an error that points at the cause.

```bash
cp ArbiScanner.McpServer/ArbiScanner.McpServer.Host/appsettings.Development.template.json \
   ArbiScanner.McpServer/ArbiScanner.McpServer.Host/appsettings.Development.json
```

It needs no secret — `ArbiScanner.McpServer` never talks to Keycloak itself,
it only validates tokens against `Keycloak:Authority`/`Keycloak:Audience`.

---

## 3. Run the services

```bash
# Terminal 1
cd ArbiScannerWebApp/ArbiScannerWeb.API && dotnet run

# Terminal 2 (only if testing via the "MCP Access" page rather than curl)
cd ArbiScannerWebApp/ArbiScannerWeb.Client && npm run dev

# Terminal 3
cd ArbiScanner.McpServer/ArbiScanner.McpServer.Host && dotnet run
# note the port it prints ("Now listening on: http://localhost:XXXX") —
# there's no launchSettings.json yet, so it's whatever Kestrel picks by
# default. Set ASPNETCORE_URLS=http://localhost:5271 first if you want it fixed.
```

---

## 4. Get a token

**Via the UI** (exercises the real flow): log into the web client, go to
`/mcp-token` ("MCP Access" in the nav), click **Generate token**, copy it.

**Via curl** (faster for repeated manual testing — logs in as a real user via
ROPC, then walks the same two-step flow the UI triggers):

```bash
# 1. Get that user's own session token (arbiscanner-web-spa)
SPA_TOKEN=$(curl -s http://localhost:8082/realms/arbiscanner-web/protocol/openid-connect/token \
  -d grant_type=password \
  -d client_id=arbiscanner-web-spa \
  -d username=<your-test-account-email> \
  -d password=<your-test-account-password> \
  | jq -r .access_token)

# 2. Call the API the same way the "MCP Access" page does
MCP_TOKEN=$(curl -sk -X POST https://localhost:7274/api/McpToken/Generate \
  -H "Authorization: Bearer $SPA_TOKEN" \
  | jq -r .value)

echo "$MCP_TOKEN"
```

(`arbiscanner-web-spa` is a public client — no secret needed for the ROPC
call in step 1. Requires `directAccessGrantsEnabled` on it, which the realm
export already sets.)

Sanity-check the token is actually long-lived:

```bash
echo "$MCP_TOKEN" | cut -d. -f2 | base64 -d 2>/dev/null | jq '.exp, (.exp - now)'
# the second number should be close to 2592000 (30 days, in seconds)
```

---

## 5. Exercise the MCP server

### Option A — MCP Inspector (recommended for manual testing)

```bash
npx @modelcontextprotocol/inspector
```

Open the printed local URL, choose **Streamable HTTP** transport, set the URL
to `http://localhost:<mcp-server-port>/mcp`, add a header
`Authorization: Bearer <MCP_TOKEN>`, connect, then call
`get_spreads_for_current_user` / `get_spread_by_id` from the Tools tab.

### Option B — raw curl (no extra tooling)

MCP's Streamable HTTP transport is JSON-RPC 2.0 over POST; a full manual
handshake is fiddly (initialize → notifications/initialized → tools/call),
so Option A or the automated tests below are usually less friction. If you
need it anyway, capture requests from the Inspector's network tab as a
reference for the exact envelope shape.

### Option C — Claude Desktop

Claude Desktop's `mcpServers` config only launches local (stdio) processes —
it can't be pointed at a remote Streamable HTTP URL with a custom
`Authorization` header directly. And since `ArbiScanner.McpServer` doesn't
implement an OAuth discovery/dynamic-client-registration flow (the token
comes from the "MCP Access" page, not an in-app OAuth prompt — see this
repo's `README.md`), Claude Desktop's built-in **Settings → Connectors →
Add custom connector** UI won't work either — it has nothing to authenticate
with.

Bridge through [`mcp-remote`](https://www.npmjs.com/package/mcp-remote)
instead — a small stdio↔HTTP proxy that Claude Desktop launches as a normal
local process, which then forwards a static header you give it to the real
server. Edit `~/Library/Application Support/Claude/claude_desktop_config.json`
(macOS):

```json
{
  "mcpServers": {
    "arbiscanner": {
      "command": "npx",
      "args": [
        "-y", "mcp-remote",
        "http://localhost:<mcp-server-port>/mcp",
        "--header", "Authorization:Bearer ${MCP_TOKEN}"
      ],
      "env": {
        "MCP_TOKEN": "<paste the token from §4>"
      }
    }
  }
}
```

(Check `npx mcp-remote --help` for the current exact header-flag syntax — it
isn't pinned to a specific `mcp-remote` version in this repo and has shifted
across releases.) Against the deployed stack instead of local, swap the URL
for `https://<domain>/mcp` — matches `nginx/nginx.conf`'s `location = /mcp`
block.

**Fully quit and restart** Claude Desktop (not just close the window) after
editing the config — it only reads it on launch. Then start a new chat; the
tools icon should list `get_spreads_for_current_user` and `get_spread_by_id`,
and asking something like "what arbitrage spreads do I currently have open?"
should trigger a real tool call end to end.

### Option D — automated test suites (fastest, no live services needed)

These don't need any of the above running — they use forged JWTs and a
stubbed `ArbiScannerWeb.API`:

```bash
cd ArbiScanner.McpServer
dotnet test ArbiScanner.McpServer.Tests/ArbiScanner.McpServer.Tests.csproj
dotnet test ArbiScanner.McpServer.IntegrationTests/ArbiScanner.McpServer.IntegrationTests.csproj
```

And the token-minting side, against a real Testcontainers Keycloak (Docker
required, no local Keycloak container needed — it spins up its own):

```bash
cd ArbiScannerWebApp
dotnet test ArbiScannerWeb.IntegrationTests/ArbiScannerWeb.IntegrationTests.csproj \
  --filter "FullyQualifiedName~McpTokenControllerTests"
```

---

## Troubleshooting log (errors actually hit while setting this up)

| Symptom | Cause | Fix |
|---|---|---|
| `500` on `POST /api/McpToken/Generate`, log shows `Keycloak:McpExchange:Authority configuration is required` | Real `appsettings.Development.json` never had the `McpExchange` section added (only the `.template.json` did) | Add it — see §2 above |
| `500` on `POST /api/McpToken/Generate`, log shows `invalid_client` / `Invalid client or Invalid client credentials` | `arbiscanner-mcp` doesn't exist on your local Keycloak yet, or its secret doesn't match `ClientSecret` in `appsettings.Development.json` | See §1 — create the client and/or re-run `configure-local-dev.sh` |
| MCP client connection fails immediately, no request ever reaches `ArbiScannerWeb.API` | Missing/expired bearer token, or `Keycloak:Audience` in McpServer's config doesn't match the token's `aud` | Regenerate a token (§4); confirm `ArbiScanner.McpServer`'s `appsettings.Development.json` has `Audience: arbiscanner-mcp` |
| Token's real `exp` claim is only ~10h out despite `access.token.lifespan` being 30 days | `scope=openid offline_access` missing from the exchange request — required to make the underlying session offline (not capped by `ssoSessionMaxLifespan`) | Not something you configure directly — `McpTokenService` already sends this; if you're hand-rolling the exchange call yourself for debugging, don't drop that scope |
