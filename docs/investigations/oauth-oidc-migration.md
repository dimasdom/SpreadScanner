# Investigation: is migrating to OpenID Connect / OAuth2 worth it?

**Status:** decided (2026-08-03) — proceed with a full migration for both services
**Owner:** Dmytro Bartash
**Scope:** whether `ArbiScannerWebApp` and `ArbiScannerAdminPannel` should move off their current homegrown JWT+refresh-token auth onto OpenID Connect/OAuth2, keeping each service's identity storage separate, whether it's hard, whether it helps the [AI chat / MCP investigation](ai-chat-assistant.md), and whether it's simply better practice.

**Decision:** yes, migrate both services — free/self-hosted tooling only, explicitly weighted toward the strongest "enterprise-pattern" portfolio signal rather than the minimum that solves a present pain point (see §5's updated framing). **Tool: [Keycloak](https://www.keycloak.org/)**, self-hosted, one instance, two realms (one per service) to preserve the existing identity-separation property. Chosen over Zitadel (lighter, but less interview name-recognition) and OpenIddict (leanest, but reads as "built your own AS" rather than "operated a real enterprise IdP") — the explicit ask was to optimize for the enterprise signal, and Keycloak is the most recognized answer to that, with the memory cost mitigated per §4.

---

## 0. Framing: this isn't really "JWT vs. OAuth/OIDC"

Worth untangling up front, because it changes the whole question. **OIDC access tokens are JWTs too**, and **OAuth2's refresh-token flow is exactly what's already implemented here.** The real comparison isn't "stop using JWTs," it's:

- **Today**: each service is its own first-party authorization server *and* resource server rolled into one — `AccountController` issues the JWT itself after checking a password against its own Identity store, using hand-rolled `JwtSecurityToken` construction.
- **OIDC/OAuth2**: a dedicated Authorization Server issues the tokens (via standardized flows — Authorization Code + PKCE being the current best practice), and the API becomes a pure Resource Server that just validates tokens against that AS's published metadata (`.well-known/openid-configuration`, JWKS endpoint) instead of minting them itself.

So the actual question is: **is it worth introducing a standards-compliant Authorization Server component, instead of each API being its own?** Everything below is framed around that.

---

## 1. Current state — both services, fact-checked

Both `ArbiScannerWebApp` and `ArbiScannerAdminPannel` already independently implement the same pattern: ASP.NET Core Identity + a self-issued HS256 JWT delivered via an httpOnly cookie, with a refresh-token table supporting **rotation and reuse detection** (revoking the whole token chain if an already-used refresh token is replayed — a real, non-trivial security property, and one of OAuth2's own recommended refresh-token mitigations, already present here).

| | `ArbiScannerWebApp` | `ArbiScannerAdminPannel` |
|---|---|---|
| Identity store | `AppDbContext : IdentityDbContext<...>` → `ArbiScannerBot` db | `AdminPanelAppDbContext : IdentityDbContext<AdminUserModel>` → `ArbiScannerAdminPanelDb` db |
| Cookie | `arbiscanner.access_token` | `adminpanel.access_token` (+ `adminpanel.refresh_token`) |
| Signing key / issuer / audience | own `JwtOptions` (`Issuer: TESTISSUER`/`Audience: TESTAUDIENCE` in dev template) | own `JwtOptions` (`Issuer: ArbiScannerAdminPanel`/`Audience: ArbiScannerAdminPanel.Client` in dev template) |
| Roles | **none** — token carries only the user id claim | **yes** — `IdentityRole` (`Administrator`, `Manager`), role claims added to the JWT, enforced via `[Authorize(Roles=...)]` |
| Login flow | `AccountController.Login` → `AccountService` (`ArbiScannerWeb.Infrastructure`) | `AccountController.Authenticate` → `AccountService` (`ArbiScannerAdminPanel.Application`) |

**The "keep identity storages separate" requirement is already fully satisfied today** — confirmed by tracing the one place the two services touch: `ArbiScannerAdminPannel`'s `WebAppUserRepository` reads `ArbiScannerWeb.Infrastructure.AppDbContext` directly, but only for **business data** (an admin viewing/editing a regular user's account, subscription, or payment record for support purposes) — it's never in the code path of the admin's own login/token issuance (`AccountService.cs` in AdminPanel has zero dependency on `AppDbContext`). Two separate Postgres databases, two separate `IdentityUser`-derived models (`ApplicationUser`-equivalent vs `AdminUserModel`), two separate signing keys, two separate cookies, no SSO, no shared session. So whatever the migration decision, there's no untangling work needed on that front — it's a design constraint that's free to keep.

**Nothing OIDC/OAuth-related exists in either codebase today** — no `Microsoft.Identity.Web`, `Duende.IdentityServer`, `OpenIddict`, `Microsoft.AspNetCore.Authentication.OpenIdConnect`, no social login, no `.well-known` discovery. Both are 100% first-party username+password.

---

## 2. What a real OIDC/OAuth2 setup would add

- **Standardized, PKCE-protected login flow** instead of a hand-rolled password endpoint. Reduces the amount of custom auth code that has to be gotten right (though note: the risky custom logic today — password hashing, refresh rotation, reuse detection — is all handled by ASP.NET Core Identity itself, which is already a mature, audited library; what's actually hand-rolled is comparatively small: building the `ClaimsIdentity`/`JwtSecurityToken` and the cookie-setting logic).
- **Discovery & JWKS rotation** (`.well-known/openid-configuration`, `/jwks`) instead of a static shared secret in config. Meaningful improvement — HS256 with a symmetric key means anything that can validate the token can also forge one; a real AS would let both services move to RS256/ES256 with asymmetric keys, so the API only ever needs the *public* key.
- **A real audience/scope model.** Today "audience" is a single fixed string per service; OAuth2's resource-indicator/scope machinery is built for *multiple* distinct audiences per token (e.g., a token scoped to `spreads:read` but not `settings:write`) — directly relevant to §3 below.
- **A natural place to bolt on social login later** (Google/GitHub) — trivial to add as an upstream federated IdP once there's a real Authorization Server, comparatively invasive to bolt onto the current hand-rolled password flow.
- **Third-party/partner client support** — if this ever needs to let something other than its own first-party SPA authenticate (a mobile app, a partner integration, a public API), OAuth2 is the mechanism for that; the current design assumes exactly one known first-party client per service and isn't built to extend to more.

None of these are currently missing *problems* — they're capabilities. Whether they're worth the cost below depends on whether any of them map to a real near-term need (see §5).

---

## 3. Does it help the AI/MCP integration?

Yes, and it's now a secondary benefit of the bigger decision rather than the thing driving it. The [AI chat doc](ai-chat-assistant.md) needs the MCP server reachable by external MCP clients (Claude Desktop and others), and the [MCP authorization spec](https://modelcontextprotocol.io) is explicitly built on **OAuth 2.1** — an MCP server exposed over HTTP is expected to act as an OAuth **Resource Server**, pointing clients at a separate Authorization Server via Protected Resource Metadata, with resource-indicator-bound tokens and (for public clients) Dynamic Client Registration so a client like Claude Desktop can self-register. A delegated internal JWT (the pattern the AI chat doc uses for the app's *own* agent — hops 1-4 in its §3, unchanged by any of this) doesn't work for this hop, because there's no existing authenticated request to delegate from; the "client" is a third-party desktop app initiating a fresh login.

With Keycloak in place platform-wide, this hop stops being a special case: it's just one more OAuth client (`arbiscanner-mcp`) registered in the `arbiscanner-web` realm that's being stood up anyway (§4). No bespoke AS just for MCP, no separate consent flow to build — the general-purpose migration absorbs it.

---

## 4. The plan — Keycloak, one instance, two realms

### 4a. Why Keycloak specifically, and what it costs

Keycloak is free (Apache 2.0, no paid tier gating core OAuth2/OIDC/user-federation functionality — unlike **Duende IdentityServer**, which requires a commercial license beyond very small non-commercial use, a common trap when reaching for "the .NET IdentityServer" from memory), self-hosted, and is the most widely-recognized open-source enterprise IAM product — realistically the strongest "I've operated real enterprise identity infrastructure" line for a portfolio, stronger than "I implemented OAuth2 myself with OpenIddict" (a legitimate but different, more DIY-flavored story) or Zitadel (technically comparable, less name recognition).

The honest cost, stated plainly rather than downplayed: **Keycloak will be the single heaviest container this repo runs.** It's a JVM application; even on the modern Quarkus-based distribution (current since Keycloak 17+, materially lighter than the old WildFly-based versions), a minimal non-clustered instance idles well above any of the lean .NET services in this stack — treat any specific number as something to *measure on the actual VPS*, not trust from a spec sheet, and cap it explicitly rather than letting the JVM auto-size against host memory (concrete levers below). Given none of the ~13 existing containers has a memory limit configured today (per [the AI chat doc's §5](ai-chat-assistant.md#5-memory-efficiency--the-actual-constraint)), this is the first service where actually setting one is worth doing.

**Efficiency levers, concretely:**
- **One Keycloak instance for both services, not two.** Isolation comes from realms (below), not from running separate processes — this is the single biggest efficiency decision and is what makes "enterprise-grade *and* efficient" compatible at all here.
- **Build a custom "optimized" image** via `kc.sh build` in a multi-stage Dockerfile (Keycloak's own recommended production pattern) rather than letting the default image rebuild its config on every container start — cuts both startup CPU and idle footprint versus the default dev-oriented flow.
- **Cap the JVM heap explicitly** (`JAVA_OPTS_APPEND=-Xms64m -Xmx256m` as a starting point to tune empirically against real usage — this app's real scale is ~10 web users plus a handful of admin/manager accounts, nowhere near what Keycloak's defaults assume).
- **Trim the feature set** to what's actually used (`--features=...` at build time) rather than shipping every optional provider (clustering, some federation backends, etc. that this deployment doesn't need).
- **Never run `start-dev` in production** — it uses an ephemeral in-memory H2 database and skips the optimizations above; always `kc.sh start` against a real Postgres.
- **Reuse the existing Postgres container** for Keycloak's own persistence (a new `keycloak` database on the already-running `postgres` service) — no new database engine to run, only a new schema.

### 4b. Realm design — this is where "separate identity storages" lives now

Two realms in the one Keycloak instance, mirroring the existing two-database split exactly:

| Realm | Backs | Clients in it |
|---|---|---|
| `arbiscanner-web` | `ArbiScannerWebApp` end users | `arbiscanner-web-spa` (the React app, Authorization Code + PKCE), `arbiscanner-mcp` (external MCP clients, PKCE, per §3) |
| `arbiscanner-admin` | `ArbiScannerAdminPannel` staff | `arbiscanner-admin-spa` (the admin React app) |

Keycloak realms are fully isolated by design — separate user tables, separate roles, separate signing keys, separate admin consoles per realm — even though both live in the one shared `keycloak` Postgres database. This is the same shape as today's two separate `AppDbContext`/`AdminPanelAppDbContext` databases, just expressed as realm partitioning inside one IdP instance instead of two separate database engines. No cross-realm SSO by default, matching today's "no shared session" reality exactly (§1).

`ArbiScannerAdminPannel`'s existing `Administrator`/`Manager` `IdentityRole`s (§1) map onto Keycloak realm roles in the `arbiscanner-admin` realm, surfaced in the token via Keycloak's default `realm_access.roles` claim — `[Authorize(Roles=...)]` on the API side keeps working once the claim-mapping matches what ASP.NET Core expects (Keycloak's role claim shape needs a small `ClaimsTransformation`/role-claim-type mapping in `AddJwtBearer`, since it doesn't come out natively as `ClaimsIdentity.DefaultRoleClaimType` — a concrete implementation detail to verify, not a blocker).

### 4c. Networking — give Keycloak its own subdomain, not a path under the existing nginx routes

Non-obvious but important: Keycloak's own paths (`/realms/...`, `/resources/...`, `/admin/{realm}/console/...`) would collide with the **existing** `location = /admin` / `location /admin/` nginx route (`nginx/nginx.conf:51-57`) that already proxies to `admin-client` — Keycloak's admin console also wants `/admin/...`. Rather than fight that with `KC_HTTP_RELATIVE_PATH` path rewriting, give Keycloak a dedicated subdomain (e.g. `auth.<domain>`), matching how it's normally deployed anyway. Needs: a DNS record, an extra cert from the existing `init-letsencrypt.sh`/certbot setup (already proven for the current domain, just adding one more), a new nginx `server` block proxying to the Keycloak container, and `KC_HOSTNAME` set explicitly to that subdomain (Keycloak embeds its own hostname into every issued token's `iss` claim — if this doesn't match exactly what the resource servers validate against, tokens fail issuer checks) plus `KC_PROXY_HEADERS=xforwarded` so it trusts nginx's forwarded headers.

### 4d. Migrating each API to a pure Resource Server

- `AddJwtBearer` moves from a static local `SigningKey`/`ValidIssuer` to `Authority = "https://auth.<domain>/realms/arbiscanner-web"` (or `-admin`) + the audience for that API — the middleware auto-discovers Keycloak's JWKS and handles key rotation itself, permanently retiring the static-HS256-secret weakness from §2.
- Delete the custom token-issuance code: `AccountService`'s `JwtSecurityToken` construction, the refresh-token tables and rotation/reuse-detection logic in both services — Keycloak owns all of this now, so it's deleted, not ported.
- `AccountController.Login`/`Authenticate`, `ForgotPassword`, `ResetPassword`, `ConfirmEmail`, `ChangeEmail` move to Keycloak's own account/login flows (themeable, so the look can still match the app) — real rework, but it's rework that deletes roughly as much custom code as it adds config.
- **User data migration, concretely**: don't try to port ASP.NET Core Identity's password hash format into Keycloak's hashing scheme — at this user count (~10 web users, a handful of admin/manager accounts, per `ArbiScannerUpd.md`) a one-time forced password reset on cutover is simpler and lower-risk than hash portability tooling. **Do** preserve each user's existing `AspNetUsers.Id` (GUID) as the Keycloak user's `id` on import — Keycloak allows specifying the user ID explicitly when creating/importing users — so every existing foreign key (`UserSettingsModel`, `Subscriptions`, `RefreshTokenModel`-referencing tables before they're dropped, etc.) keeps pointing at the same value with no remapping migration needed across the business-data tables.

### 4e. Sizing

Bigger than the earlier scoped estimate, appropriately — this is the full migration now: standing up Keycloak + both realms + clients is **S** (mostly configuration); migrating `ArbiScannerWebApp` (delete custom auth code, resource-server config, SPA login flow rewrite to Authorization Code+PKCE via `oidc-client-ts`/`react-oidc-context`, user import with GUID preservation, forced-reset email) is **M**; migrating `ArbiScannerAdminPannel` is **M** too, but faster once the pattern's proven on WebApp (plus the small extra role-claim-mapping step from §4b). Recommended sequencing: **Keycloak + `arbiscanner-web` realm first** — it unblocks the MCP/Claude Desktop requirement (§3) as a side effect before AdminPanel's migration is even started, so the AI chat feature isn't blocked on the whole platform migration completing.

---

## 5. Is it "better practice" — updated verdict

§0-§2's original framing still holds as a factual matter: a carefully-implemented homegrown JWT + rotating/reuse-detected refresh token is a legitimate pattern for a single first-party SPA with a known, fixed client, and OAuth2/OIDC doesn't change the underlying security properties so much as standardize and centralize them. That analysis was weighing "does this solve a problem we actually have" — and on that axis alone, the honest answer was still "not urgently."

**The objective changed, and that's a legitimate reason to reach a different conclusion, not a contradiction of the earlier analysis.** The explicit goal now includes demonstrating real enterprise-identity operational experience for a portfolio/seniority narrative (consistent with `ArbiScannerUpd.md`'s existing framing — "prove you operate at a senior level," Phase 7's ADR emphasis on legible tradeoffs). Against *that* objective function, standing up and correctly operating Keycloak — realm isolation for two independently-owned user populations, resource-server conversion of two APIs, a real token-issuer migration including the data-migration judgment call in §4d — is itself the senior signal, independent of whether the previous homegrown design had a live defect. That's a coherent, defensible reason to migrate that has nothing to do with the old system being broken, and the ADR this doc feeds into (`ArbiScannerUpd.md` Phase 7) should say exactly that — lead with "the old design wasn't wrong, here's what this trades for what."

---

## 6. Recommendation

**Proceed, per §4.** Keycloak, one instance, `arbiscanner-web` and `arbiscanner-admin` realms, `arbiscanner-web` first to also unblock the MCP requirement. Concrete next steps: (1) stand up Keycloak in `docker-compose.yml` with the memory levers from §4a and the subdomain routing from §4c; (2) create the `arbiscanner-web` realm, `arbiscanner-web-spa` and `arbiscanner-mcp` clients; (3) migrate `ArbiScannerWeb.API` to resource-server validation and delete the custom token code; (4) migrate the SPA login to Authorization Code+PKCE; (5) import users preserving GUIDs, force a password reset; (6) repeat 2-5 for `arbiscanner-admin`.

Two things from the earlier analysis are still worth doing regardless, and are subsumed by this migration rather than separate work: the static-HS256-key weakness (§2) goes away automatically once each API validates against Keycloak's JWKS instead of a local secret; role-based authorization for `ArbiScannerWebApp` (currently none, §1) is a non-issue to add later since Keycloak's role/claim machinery is already there once this lands, versus being a prerequisite-free add-on before.
