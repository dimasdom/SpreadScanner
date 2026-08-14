#!/usr/bin/env bash
#
# deploy-vps.sh — the one command to run on the VPS after pulling Keycloak
# changes (theme edits, realm-export tweaks, Dockerfile changes).
#
# Unlike the other four services (web, web-client, admin-api, admin-client,
# telegram-notifier, arbitrage-scanner), Keycloak has no CI pipeline building
# and pushing its image to GHCR — .github/workflows/docker-build.yml only
# build-checks it on PRs, nothing pushes ghcr.io/dimasdom/arbiscanner-keycloak.
# So scripts/deploy-remote.sh (which does `docker compose pull`) doesn't apply
# here; the image is built FROM SOURCE directly on the VPS, same as local dev.
#
# What this does, in order:
#   1. docker compose build keycloak   (bakes in themes/, realm-export/ JSON)
#   2. docker compose up -d keycloak   (recreates the container)
#   3. wait for the realm to actually be serving requests
#   4. apply-realm-updates.sh          (pushes realm-export changes into the
#                                        already-existing realm — see that
#                                        script's header for why step 1 alone
#                                        isn't enough)
#
# Run from the monorepo root (same directory as docker-compose.yml), with
# the real .env already in place:
#   ./keycloak/deploy-vps.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

: "${KEYCLOAK_ADMIN_USER:?KEYCLOAK_ADMIN_USER is not set — set -a && source .env && set +a first}"
: "${KEYCLOAK_ADMIN_PASSWORD:?KEYCLOAK_ADMIN_PASSWORD is not set — set -a && source .env && set +a first}"

KC_CONTAINER="arbiscanner-keycloak"
KCADM="/opt/keycloak/bin/kcadm.sh"

echo "==> Building keycloak image"
docker compose build keycloak

echo "==> Recreating keycloak container"
docker compose up -d keycloak

echo "==> Waiting for Keycloak to come up"
# quay.io/keycloak/keycloak is a minimal UBI image with no curl/wget, so the
# probe has to be a tool guaranteed to exist in the container — kcadm.sh,
# Keycloak's own bundled admin CLI, which apply-realm-updates.sh (and every
# other script in this directory) already depends on. A previous curl-based
# version of this loop always failed with "executable file not found" and
# just silently ran out the clock, since its `>/dev/null 2>&1` redirect hid
# that error — logging in as the real admin user against the real port is
# also a more meaningful readiness signal than an anonymous GET would be:
# it proves the exact thing apply-realm-updates.sh needs next (a working
# admin login), not just that some HTTP port happens to answer.
timeout=180
waited=0
until docker exec "$KC_CONTAINER" "$KCADM" config credentials \
  --server http://localhost:8080 --realm master \
  --user "$KEYCLOAK_ADMIN_USER" --password "$KEYCLOAK_ADMIN_PASSWORD" >/dev/null 2>&1
do
  if [ "$waited" -ge "$timeout" ]; then
    echo "Keycloak did not come up within ${timeout}s — check 'docker logs $KC_CONTAINER'." >&2
    exit 1
  fi
  sleep 3
  waited=$((waited + 3))
done
echo "Keycloak is up (${waited}s)."

echo "==> Applying realm-export settings that --import-realm can't retroactively apply"
"$SCRIPT_DIR/apply-realm-updates.sh"

echo "==> Done."
