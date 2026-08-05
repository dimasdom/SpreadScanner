# Keycloak — `arbiscanner-web` / `arbiscanner-admin` realms

Self-hosted Keycloak backing OIDC/OAuth2 auth for both `ArbiScannerWebApp` and
`ArbiScannerAdminPannel`, one instance, one realm per service (see
`docs/investigations/oauth-oidc-migration.md`). Two realms, `arbiscanner-web`
and `arbiscanner-admin`, imported automatically from
`realm-export/arbiscanner-web-realm.json` and
`realm-export/arbiscanner-admin-realm.json` on container start
(`--import-realm` imports every file under the mounted import directory).

## One-time setup (in order)

1. **Create the `keycloak` Postgres database** on the existing shared `postgres`
   service (same precedent as `ArbiScannerAdminPanelDb` — no init script, manual
   `createdb`, run once):
   ```bash
   docker compose exec postgres psql -U postgres -c "CREATE DATABASE keycloak;"
   ```

2. **DNS**: point `auth.<your-domain>` (e.g. `auth.arbiscannerwebapp.site`) at
   this host — same target as the existing `www.` record.

3. **TLS cert**: `nginx/nginx.conf`'s new `auth.` server block reuses the same
   cert directory as the primary domain (`init-letsencrypt.sh` only pre-seeds a
   dummy cert for the primary domain, so a second `live/auth.../` path would be
   empty and nginx would fail to boot). Re-run the bootstrap script requesting
   one SAN cert covering both hostnames:
   ```bash
   ./init-letsencrypt.sh -d www.arbiscannerwebapp.site -d auth.arbiscannerwebapp.site --force
   ```

4. **Start Keycloak**: `docker compose up -d keycloak` (after step 1). Verify:
   ```bash
   curl https://auth.arbiscannerwebapp.site/realms/arbiscanner-web/.well-known/openid-configuration
   curl https://auth.arbiscannerwebapp.site/realms/arbiscanner-admin/.well-known/openid-configuration
   ```

5. **SMTP**: both realm exports ship with empty SMTP fields on purpose (no
   secrets in git). Patch them in from this repo's existing SMTP account:
   ```bash
   set -a && source .env && set +a && ./keycloak/configure-smtp.sh
   ```
   (`arbiscanner-admin` only needs SMTP for password-reset emails — it has no
   self-registration/verify-email flow, unlike `arbiscanner-web`.)

6. **EULA copy** (`arbiscanner-web` only): the "Terms and Conditions" required
   action needs real text — set it via the admin console (Realm settings →
   Localization → add a `termsText` message override) or `kcadm.sh` once real
   EULA content exists. Placeholder text ships until this is done.
   `arbiscanner-admin` has no self-registration and no equivalent required
   action.

7. **`arbiscanner-admin` staff accounts**: this realm ships with
   `registrationAllowed: false` and no users — provision the initial
   `Administrator`/`Manager` accounts and the `arbiscanner-admin-service`
   client's service-account role from this repo's existing
   `ADMIN_USERNAME`/`ADMIN_PASSWORD`/`MANAGER_USERNAME`/`MANAGER_PASSWORD`:
   ```bash
   set -a && source .env && set +a && ./keycloak/configure-admin-users.sh
   ```
   Both accounts are created with a temporary password, forcing a reset via
   Keycloak's `UPDATE_PASSWORD` required action on first login. Also set the
   `arbiscanner-admin-service` client's secret (Keycloak admin console →
   Clients → `arbiscanner-admin-service` → Credentials, or `kcadm.sh get
   clients/<id>/client-secret`) into `KEYCLOAK_ADMIN_SERVICE_CLIENT_SECRET` for
   `ArbiScannerWebApp`'s `web` service — that's the Client Credentials secret
   its `AdminService` uses to call `ArbiScannerAdminPannel`'s API.

8. **`arbiscanner-web-admin-ops` secret**: same pattern, other direction —
   `arbiscanner-web` realm's `arbiscanner-web-admin-ops` client (Keycloak
   admin console → Clients → `arbiscanner-web-admin-ops` → Credentials) into
   `KEYCLOAK_WEB_ADMIN_OPS_CLIENT_SECRET` for `admin-api`. This is what lets
   `ArbiScannerAdminPannel`'s "delete user" actually delete the Keycloak
   identity, not just the local shadow row (see the `manage-users` note
   below).

## Updating an already-deployed realm (VPS)

`--import-realm` only imports a realm the **first** time it sees that realm
name — once `arbiscanner-web`/`arbiscanner-admin` exist in Postgres (true on
the VPS after the one-time setup above), a plain `git pull` +
`docker compose build keycloak && docker compose up -d keycloak` picks up new
**files** (theme CSS/`.ftl`, Dockerfile changes) but silently ignores any
edits to `realm-export/*.json` itself (a new `loginTheme`, a `components`/User
Profile tweak, a new client, etc.) — the container just keeps whatever's
already in the database.

Run the one bundled script instead, from the monorepo root on the VPS:
```bash
set -a && source .env && set +a && ./keycloak/deploy-vps.sh
```
This builds the image, recreates the container, waits for it to come back up,
then runs `apply-realm-updates.sh` to push the realm-export settings that
`--import-realm` can't retroactively apply (currently just `loginTheme` for
both realms — see that script's header comment to extend it when another
setting needs the same treatment). Keycloak has no CI pipeline pushing its
image to GHCR like the other services do, so this always builds from source
directly on the VPS, same as local dev — there's no `docker compose pull`
step to reach for here.

If you only need to re-sync realm settings without rebuilding the image (e.g.
you changed `loginTheme` but not the Dockerfile), `apply-realm-updates.sh`
alone is enough:
```bash
set -a && source .env && set +a && ./keycloak/apply-realm-updates.sh
```

## Local development

Testing the OIDC changes on your own machine — no domain, no TLS, no nginx.
The full stack (`web`, `admin-api`) isn't meant to be run this way; use the
documented fast path instead — infra in Docker, apps via `dotnet run`/`npm run
dev` (`ASPNETCORE_ENVIRONMENT=Development` from `launchSettings.json`), which
is what makes `AddAuthenticationJwt`'s `RequireHttpsMetadata =
!environment.IsDevelopment()` carve-out apply.

1. **Start Postgres + Keycloak** (`docker-compose.local.yml` is an explicit,
   opt-in overlay — never auto-loaded, so it can't affect a real deploy run
   with plain `docker compose up`):
   ```bash
   docker compose -f docker-compose.yml -f docker-compose.local.yml \
     up -d postgres rabbitmq redis mongodb keycloak
   ```
2. **Create the `keycloak` database** (one-time, per step 1 above) and the
   `ArbiScannerAdminPanelDb` database `dotnet ef database update` expects:
   ```bash
   docker compose exec postgres psql -U postgres -c "CREATE DATABASE keycloak;"
   docker compose exec postgres psql -U postgres -c "CREATE DATABASE \"ArbiScannerAdminPanelDb\";"
   ```
   Restart `keycloak` once (`docker compose -f docker-compose.yml -f docker-compose.local.yml restart keycloak`) so it picks up the now-existing database.
3. **Patch the realms for local testing, and wire up real SMTP** (needed for
   `arbiscanner-web`'s self-registration — `VERIFY_EMAIL` is enabled, same as
   production, so registration doesn't complete without a working mailer):
   ```bash
   set -a && source .env && set +a && ./keycloak/configure-local-dev.sh
   set -a && source .env && set +a && ./keycloak/configure-admin-users.sh
   set -a && source .env && set +a && ./keycloak/configure-smtp.sh
   ```
4. **Verify** (plain HTTP, port `8082` — see `docker-compose.local.yml`):
   ```bash
   curl http://localhost:8082/realms/arbiscanner-web/.well-known/openid-configuration
   curl http://localhost:8082/realms/arbiscanner-admin/.well-known/openid-configuration
   ```
5. **Apply EF migrations**, then run each API and client normally:
   ```bash
   cd ArbiScannerWebApp/ArbiScannerWeb.API && dotnet ef database update
   cd ArbiScannerAdminPannel/ArbiScannerAdminPanel.API && dotnet ef database update --context AdminPanelAppDbContext
   ```
   `appsettings.Development.json` in both APIs already points `Jwt:Authority`
   (and, for `ArbiScannerWeb.API`, `Keycloak:AdminService:Authority`/
   `ClientSecret`; for `ArbiScannerAdminPanel.API`,
   `Keycloak:WebRealmAdmin:Authority`/`ClientSecret`) at `http://localhost:8082`.
   Each React client's
   `.env.local` (gitignored, already created) points `VITE_OIDC_*` at the same
   place — `npm run dev` picks it up automatically.
6. **Test**: open `https://localhost:12321` (WebApp — self-register a throwaway
   user, no email verification needed locally) and `http://localhost:5174`
   (AdminPanel — log in as the `ADMIN_USERNAME`/`MANAGER_USERNAME` accounts
   `configure-admin-users.sh` just created, temporary password, forced reset
   on first login).

## Notes

- `KC_HOSTNAME` is set to `auth.<domain>` — it's embedded in every issued
  token's `iss` claim, so it must match exactly what each API's `Jwt:Authority`
  validates against.
- Both SPA clients (`arbiscanner-web-spa`, `arbiscanner-admin-spa`) are public
  (PKCE, `directAccessGrantsEnabled: false`) with an explicit audience
  protocol mapper — Keycloak's default access-token audience is the built-in
  `account` client, not either of these, and skipping the mapper means every
  token fails `ValidateAudience` on the API side.
- `arbiscanner-admin` additionally ships a flat `role` claim protocol mapper
  (`oidc-usermodel-realm-role-mapper`) on both its clients — Keycloak's default
  role claim shape is a nested `realm_access.roles` array, which ASP.NET
  Core's `[Authorize(Roles = ...)]` can't read directly. The flat mapper
  produces individual `role` claims that .NET's JWT handler flattens into one
  `Claim` per role, so `TokenValidationParameters.RoleClaimType = "role"` on
  the API side is all that's needed — no custom `ClaimsTransformation`.
  `arbiscanner-web` doesn't need this; it has no roles.
- `arbiscanner-admin-service` is a confidential client
  (`serviceAccountsEnabled: true`) used only for server-to-server Client
  Credentials calls (`ArbiScannerWeb.Infrastructure`'s `AdminService`) — its
  service account is assigned the `Manager` realm role only (via
  `configure-admin-users.sh`), deliberately kept off Administrator-only
  endpoints, mirroring the old Manager-password-login scope.
- `arbiscanner-web-admin-ops` (in the `arbiscanner-web` realm) is the mirror
  image — a confidential client `ArbiScannerAdminPanel.Infrastructure`'s
  `KeycloakUserService` authenticates as, used only to call Keycloak's own
  Admin REST API (`DELETE /admin/realms/arbiscanner-web/users/{id}`) when an
  admin deletes a user. Its service account carries the built-in
  `realm-management` client's `manage-users` role (declared directly in the
  realm export's `users` array via `clientRoles` — this is *not* a realm
  role, `add-roles` needs `--cclientid realm-management` to see or grant it).
  Scoped to `manage-users` only, not full realm admin.
- **Custom login theme** (`themes/arbiscanner/login/`): both realms' hosted
  login/register/forgot-password pages are restyled to match the pre-Keycloak
  app's own dark UI (`loginTheme: "arbiscanner"` in both realm exports). It
  extends Keycloak's own `keycloak.v2` theme — `theme.properties` only adds
  an override stylesheet (`resources/css/arbiscanner.css`, PatternFly class
  selectors) and disables the automatic OS-light/dark toggle, while
  `login.ftl`/`register.ftl`/`login-reset-password.ftl` are copied+modified
  just to move "Forgot password?"/"Register"/"Sign in" into one link row at
  the bottom of the card (stock keycloak.v2 places them elsewhere) — no
  password-policy/WebAuthn/OTP/social-login logic is touched, so those flows
  keep whatever keycloak.v2 already does. On a Keycloak version bump, diff
  these three `.ftl` files against the new `keycloak.v2` versions (extract
  from `org.keycloak.keycloak-themes-<version>.jar` inside the image, same
  way this theme was built) in case the upstream structure changed.
  For a realm that already exists in a running Postgres (`--import-realm`
  only applies on first import), patch it live:
  `docker exec arbiscanner-keycloak /opt/keycloak/bin/kcadm.sh update realms/<realm> -s loginTheme=arbiscanner`
  after `kcadm config credentials` (same pattern as `configure-local-dev.sh`).
- Memory: `docker-compose.yml` caps this container at `mem_limit: 384m` with
  `JAVA_OPTS_APPEND=-Xms64m -Xmx256m` — the first explicit memory limit
  anywhere in this compose file. Tune empirically against real usage. One
  instance serves both realms, so no extra memory cost from adding
  `arbiscanner-admin`.
