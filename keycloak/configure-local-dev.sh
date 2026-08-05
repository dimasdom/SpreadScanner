#!/usr/bin/env bash
#
# configure-local-dev.sh — patch both realms for frictionless local testing.
#
# LOCAL DEV ONLY. Never run this against a real deployment. It intentionally
# weakens one thing that's correct and load-bearing in production:
#   - sslRequired: external -> none, so a plain-HTTP local Keycloak (reached
#     at http://localhost:8082, see docker-compose.local.yml) doesn't reject
#     login/token requests. Docker Desktop's host-port-forwarding doesn't
#     reliably get classified as "internal" by Keycloak's own policy, the
#     same issue already documented for the Testcontainers-based integration
#     tests (see ArbiScannerWeb.IntegrationTests/Fixtures/KeycloakTestFixture.cs).
#
# arbiscanner-web's VERIFY_EMAIL required action is left as shipped (enabled)
# — run configure-smtp.sh first (with real SMTP_* / SENDER_* vars in .env) so
# registration can actually complete locally. If you don't have SMTP creds
# handy and just want to click through registration without email, disable it
# yourself for your session:
#   docker exec arbiscanner-keycloak /opt/keycloak/bin/kcadm.sh update \
#     authentication/required-actions/VERIFY_EMAIL -r arbiscanner-web -s enabled=false
#
# Also sets fixed, known secrets on the two confidential Client Credentials
# clients (both ship in their realm exports without a secret, on purpose - no
# secrets in git):
#   - arbiscanner-admin-service (arbiscanner-admin realm): ArbiScannerWeb's
#     AdminService authenticates with this.
#   - arbiscanner-web-admin-ops (arbiscanner-web realm): ArbiScannerAdminPannel's
#     UsersService authenticates with this to delete Keycloak identities.
# so the corresponding appsettings.Development.json ClientSecret values can be
# real, working ones instead of randomly-generated secrets only discoverable
# via the admin console.
#
# Run this ONCE, after `docker compose -f docker-compose.yml -f
# docker-compose.local.yml up -d keycloak` has imported both realms.
#
# Usage (from the monorepo root, with the same .env used by docker compose):
#   set -a && source .env && set +a && ./keycloak/configure-local-dev.sh
#
set -euo pipefail

: "${KEYCLOAK_ADMIN_USER:?KEYCLOAK_ADMIN_USER is not set}"
: "${KEYCLOAK_ADMIN_PASSWORD:?KEYCLOAK_ADMIN_PASSWORD is not set}"

KC_CONTAINER="arbiscanner-keycloak"
KCADM="/opt/keycloak/bin/kcadm.sh"
ADMIN_SERVICE_CLIENT_SECRET="local-dev-admin-service-secret"
WEB_ADMIN_OPS_CLIENT_SECRET="local-dev-web-admin-ops-secret"

kcadm() {
  docker exec "$KC_CONTAINER" "$KCADM" "$@"
}

set_client_secret() {
  local realm="$1" client_id="$2" secret="$3"
  local internal_id
  internal_id=$(kcadm get clients -r "$realm" -q "clientId=$client_id" --fields id \
    | grep -o '"id"[^,}]*' | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
  if [ -z "$internal_id" ]; then
    echo "Could not find $client_id client in realm $realm — is the realm-export imported?" >&2
    exit 1
  fi
  kcadm update "clients/$internal_id" -r "$realm" -s "secret=$secret"
  echo "$client_id: secret set to a known local-dev value"
}

kcadm config credentials \
  --server http://localhost:8080 \
  --realm master \
  --user "$KEYCLOAK_ADMIN_USER" \
  --password "$KEYCLOAK_ADMIN_PASSWORD"

for realm in arbiscanner-web arbiscanner-admin; do
  kcadm update "realms/$realm" -s sslRequired=none
  echo "$realm: sslRequired=none"
done

set_client_secret arbiscanner-admin arbiscanner-admin-service "$ADMIN_SERVICE_CLIENT_SECRET"
set_client_secret arbiscanner-web arbiscanner-web-admin-ops "$WEB_ADMIN_OPS_CLIENT_SECRET"

echo "Local dev realm configuration complete."
