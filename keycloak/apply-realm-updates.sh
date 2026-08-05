#!/usr/bin/env bash
#
# apply-realm-updates.sh — push realm-level settings that have changed in
# realm-export/*.json into an ALREADY-IMPORTED realm.
#
# Why this script exists: Keycloak's `--import-realm` (used by this repo's
# Dockerfile CMD) only imports a realm the FIRST time — if a realm with that
# name already exists (true for every deploy after the very first one, local
# or VPS), the exported JSON is silently ignored on subsequent container
# starts/rebuilds. A `docker compose build && up -d keycloak` alone does NOT
# pick up realm-export changes like a new `loginTheme`, User Profile
# `components` tweaks, redirect URI edits, etc. — only genuinely new files
# (Dockerfile COPY of theme resources, new .ftl/.css) apply automatically,
# since those are just files on disk, not realm data in Postgres.
#
# This script closes that gap for the specific fields known to need it,
# using the same `docker exec ... kcadm.sh update realms/<realm> -s k=v`
# pattern as configure-smtp.sh / configure-admin-users.sh / configure-local-dev.sh
# — it only ever talks to the Keycloak container's own local admin REST API
# (http://localhost:8080 *inside* the container), so it works unmodified
# whether run on a dev machine or over SSH on the VPS. Deliberately no jq
# dependency (grep/sed instead, matching configure-local-dev.sh's
# set_client_secret() helper) since it isn't installed on the VPS by default
# and nothing else here needs it.
#
# Add a new field to sync_realm() (read from the matching realm-export/*.json,
# not hardcoded) whenever a future realm-export change needs to reach an
# already-existing realm — loginTheme is the first/current case.
#
# Usage (from the monorepo root):
#   set -a && source .env && set +a && ./keycloak/apply-realm-updates.sh
#
set -euo pipefail

: "${KEYCLOAK_ADMIN_USER:?KEYCLOAK_ADMIN_USER is not set}"
: "${KEYCLOAK_ADMIN_PASSWORD:?KEYCLOAK_ADMIN_PASSWORD is not set}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KC_CONTAINER="arbiscanner-keycloak"
KCADM="/opt/keycloak/bin/kcadm.sh"

kcadm() {
  docker exec "$KC_CONTAINER" "$KCADM" "$@"
}

kcadm config credentials \
  --server http://localhost:8080 \
  --realm master \
  --user "$KEYCLOAK_ADMIN_USER" \
  --password "$KEYCLOAK_ADMIN_PASSWORD"

sync_realm() {
  local realm="$1" export_file="$2"
  local login_theme
  login_theme=$(grep -o '"loginTheme"[^,}]*' "$export_file" | head -1 | sed -E 's/.*"([^"]+)"$/\1/')

  if [ -z "$login_theme" ]; then
    echo "$realm: no loginTheme in $export_file, skipping"
    return
  fi

  kcadm update "realms/$realm" -s "loginTheme=$login_theme"
  echo "$realm: loginTheme -> $login_theme"
}

sync_realm arbiscanner-web "$SCRIPT_DIR/realm-export/arbiscanner-web-realm.json"
sync_realm arbiscanner-admin "$SCRIPT_DIR/realm-export/arbiscanner-admin-realm.json"

echo "Realm settings sync complete."
