#!/usr/bin/env bash
#
# configure-smtp.sh — patch the arbiscanner-web realm's SMTP settings after import.
#
# Run this ONCE, after `docker compose up keycloak` has imported the realm from
# realm-export/arbiscanner-web-realm.json. The realm export deliberately ships
# with empty SMTP fields — patching them here means the SMTP password never sits
# in a file checked into git, and avoids depending on Keycloak's realm-JSON
# environment-variable substitution syntax (unverified across versions).
#
# Reuses this repo's existing SMTP account (see sample.env: SMTP_SERVER,
# SMTP_PORT, SENDER_EMAIL, SENDER_PASSWORD, SENDER_NAME) — the same one
# ArbiScannerWeb.API already sends confirmation/reset emails with today.
#
# Usage (from the monorepo root, with the same .env used by docker compose):
#   set -a && source .env && set +a && ./keycloak/configure-smtp.sh
#
set -euo pipefail

: "${SMTP_SERVER:?SMTP_SERVER is not set}"
: "${SMTP_PORT:?SMTP_PORT is not set}"
: "${SENDER_EMAIL:?SENDER_EMAIL is not set}"
: "${SENDER_PASSWORD:?SENDER_PASSWORD is not set}"
: "${SENDER_NAME:=ArbiScanner}"
: "${KEYCLOAK_ADMIN_USER:?KEYCLOAK_ADMIN_USER is not set}"
: "${KEYCLOAK_ADMIN_PASSWORD:?KEYCLOAK_ADMIN_PASSWORD is not set}"

KC_CONTAINER="arbiscanner-keycloak"
KCADM="/opt/keycloak/bin/kcadm.sh"

docker exec "$KC_CONTAINER" "$KCADM" config credentials \
  --server http://localhost:8080 \
  --realm master \
  --user "$KEYCLOAK_ADMIN_USER" \
  --password "$KEYCLOAK_ADMIN_PASSWORD"

docker exec "$KC_CONTAINER" "$KCADM" update realms/arbiscanner-web \
  -s "smtpServer.host=${SMTP_SERVER}" \
  -s "smtpServer.port=${SMTP_PORT}" \
  -s "smtpServer.from=${SENDER_EMAIL}" \
  -s "smtpServer.fromDisplayName=${SENDER_NAME}" \
  -s "smtpServer.auth=true" \
  -s "smtpServer.user=${SENDER_EMAIL}" \
  -s "smtpServer.password=${SENDER_PASSWORD}" \
  -s "smtpServer.starttls=true"

echo "arbiscanner-web realm SMTP settings updated."
