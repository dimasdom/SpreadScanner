#!/usr/bin/env bash
#
# configure-admin-users.sh — provision the arbiscanner-admin realm's staff
# accounts and service-account role after import.
#
# Run this ONCE, after `docker compose up keycloak` has imported the realm from
# realm-export/arbiscanner-admin-realm.json. The realm export deliberately ships
# with no users — registrationAllowed is false (staff-only, no self-service
# signup), so the two initial accounts are created here from real credentials
# that never sit in a file checked into git (same rationale as configure-smtp.sh).
#
# Creates:
#   - one Administrator account (ADMIN_USERNAME/ADMIN_PASSWORD)
#   - one Manager account (MANAGER_USERNAME/MANAGER_PASSWORD)
#     both with a temporary password, forcing a reset via Keycloak's built-in
#     UPDATE_PASSWORD required action on first login.
#   - assigns the Manager realm role to the arbiscanner-admin-service client's
#     service account, so ArbiScannerWeb.Infrastructure's AdminService (Client
#     Credentials grant) reaches the same [Authorize] (any role) endpoints the
#     old Manager-password login reached, without touching Administrator-only
#     ones.
#
# Usage (from the monorepo root, with the same .env used by docker compose):
#   set -a && source .env && set +a && ./keycloak/configure-admin-users.sh
#
set -euo pipefail

: "${ADMIN_USERNAME:?ADMIN_USERNAME is not set}"
: "${ADMIN_PASSWORD:?ADMIN_PASSWORD is not set}"
: "${MANAGER_USERNAME:?MANAGER_USERNAME is not set}"
: "${MANAGER_PASSWORD:?MANAGER_PASSWORD is not set}"
: "${KEYCLOAK_ADMIN_USER:?KEYCLOAK_ADMIN_USER is not set}"
: "${KEYCLOAK_ADMIN_PASSWORD:?KEYCLOAK_ADMIN_PASSWORD is not set}"

KC_CONTAINER="arbiscanner-keycloak"
KCADM="/opt/keycloak/bin/kcadm.sh"
REALM="arbiscanner-admin"

kcadm() {
  docker exec "$KC_CONTAINER" "$KCADM" "$@"
}

kcadm config credentials \
  --server http://localhost:8080 \
  --realm master \
  --user "$KEYCLOAK_ADMIN_USER" \
  --password "$KEYCLOAK_ADMIN_PASSWORD"

create_staff_user() {
  local username="$1" password="$2" role="$3"

  # kcadm's -q username=X filter is a substring match, not exact (e.g. "admin"
  # also matches "service-account-arbiscanner-admin-service") — re-check the
  # exact field in the result instead of trusting a non-empty response.
  if kcadm get "users" -r "$REALM" -q "username=$username" --fields id,username \
      | grep -q "\"username\" : \"$username\""; then
    echo "User '$username' already exists, skipping creation."
  else
    kcadm create users -r "$REALM" -s "username=$username" -s "enabled=true"
    kcadm set-password -r "$REALM" --username "$username" --new-password "$password" --temporary
  fi

  kcadm add-roles -r "$REALM" --uusername "$username" --rolename "$role"
}

create_staff_user "$ADMIN_USERNAME" "$ADMIN_PASSWORD" "Administrator"
create_staff_user "$MANAGER_USERNAME" "$MANAGER_PASSWORD" "Manager"

# Client Credentials service accounts get a synthetic username of the form
# service-account-<clientId> — created automatically once serviceAccountsEnabled
# is true on the client, no explicit user-creation step needed here.
kcadm add-roles -r "$REALM" \
  --uusername "service-account-arbiscanner-admin-service" \
  --rolename "Manager"

echo "arbiscanner-admin realm: staff accounts and service-account role provisioned."
