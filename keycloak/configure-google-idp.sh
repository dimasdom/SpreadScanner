#!/usr/bin/env bash
#
# configure-google-idp.sh — create or update the Google identity provider
# (social login) on the arbiscanner-web realm.
#
# Unlike configure-smtp.sh, there's no pre-existing "identityProviders" entry
# shipped in realm-export/arbiscanner-web-realm.json for this to patch values
# into — Google login wasn't part of the original realm design, and adding it
# to the JSON wouldn't help anyway once a realm already exists in Postgres
# (--import-realm only imports on a realm's first creation, same caveat as
# the arbiscanner-mcp client — see keycloak/README.md). So this script
# creates the identity provider if missing, or updates its credentials if it
# already exists — safe to (re-)run on a fresh realm, an already-deployed VPS
# realm, or to rotate the Google client secret later.
#
# Client ID/secret come from the OAuth client registered in Google Cloud
# Console (Credentials -> OAuth client ID -> Web application) for the
# "arbiscannerWeb" app. Its Authorized redirect URI must be Keycloak's
# identity-provider broker callback, not the SPA's own /auth/callback:
#   https://auth.arbiscannerwebapp.site/realms/arbiscanner-web/broker/google/endpoint
#   (local dev: http://localhost:8082/realms/arbiscanner-web/broker/google/endpoint)
#
# Usage (from the monorepo root, with the same .env used by docker compose):
#   set -a && source .env && set +a && ./keycloak/configure-google-idp.sh
#
set -euo pipefail

: "${KEYCLOAK_GOOGLE_CLIENT_ID:?KEYCLOAK_GOOGLE_CLIENT_ID is not set}"
: "${KEYCLOAK_GOOGLE_CLIENT_SECRET:?KEYCLOAK_GOOGLE_CLIENT_SECRET is not set}"
: "${KEYCLOAK_ADMIN_USER:?KEYCLOAK_ADMIN_USER is not set}"
: "${KEYCLOAK_ADMIN_PASSWORD:?KEYCLOAK_ADMIN_PASSWORD is not set}"

KC_CONTAINER="arbiscanner-keycloak"
KCADM="/opt/keycloak/bin/kcadm.sh"

kcadm() {
  docker exec -i "$KC_CONTAINER" "$KCADM" "$@"
}

kcadm config credentials \
  --server http://localhost:8080 \
  --realm master \
  --user "$KEYCLOAK_ADMIN_USER" \
  --password "$KEYCLOAK_ADMIN_PASSWORD"

if kcadm get identity-provider/instances/google -r arbiscanner-web >/dev/null 2>&1; then
  kcadm update identity-provider/instances/google -r arbiscanner-web \
    -s "config.clientId=${KEYCLOAK_GOOGLE_CLIENT_ID}" \
    -s "config.clientSecret=${KEYCLOAK_GOOGLE_CLIENT_SECRET}"
  echo "arbiscanner-web realm: Google identity provider credentials updated."
else
  kcadm create identity-provider/instances -r arbiscanner-web -f - <<EOF
{
  "alias": "google",
  "displayName": "Google",
  "providerId": "google",
  "enabled": true,
  "trustEmail": true,
  "storeToken": false,
  "addReadTokenRoleOnCreate": false,
  "authenticateByDefault": false,
  "linkOnly": false,
  "firstBrokerLoginFlowAlias": "first broker login",
  "config": {
    "clientId": "${KEYCLOAK_GOOGLE_CLIENT_ID}",
    "clientSecret": "${KEYCLOAK_GOOGLE_CLIENT_SECRET}",
    "useJwksUrl": "true",
    "syncMode": "IMPORT"
  }
}
EOF
  echo "arbiscanner-web realm: Google identity provider created."
fi
