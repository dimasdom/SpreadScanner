#!/usr/bin/env bash
# Runs ON THE VPS, invoked over SSH by .github/workflows/deploy-service.yml, from
# the monorepo root (same directory as docker-compose.yml).
#
# Usage: deploy-remote.sh <compose-service-name> <tag-env-var-name> <new-tag>
# Example: deploy-remote.sh web WEB_IMAGE_TAG sha-abc123...
set -euo pipefail

SERVICE="$1"      # e.g. web, web-client, admin-api, admin-client, telegram-notifier, arbitrage-scanner
TAG_VAR="$2"      # e.g. WEB_IMAGE_TAG - the compose file's ${..._IMAGE_TAG:-latest} variable
NEW_TAG="$3"      # e.g. sha-<full commit sha>

STATE_DIR="$(pwd)/.deploy-state"
mkdir -p "$STATE_DIR"
STATE_FILE="$STATE_DIR/${SERVICE}.prev"
CONTAINER_NAME="arbiscanner-${SERVICE}"

# Record the tag currently running, for rollback. "latest" is the safe fallback
# for a service's very first pipeline-driven deploy (no container yet).
PREV_TAG="latest"
if docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
  CURRENT_IMAGE="$(docker inspect --format '{{.Config.Image}}' "$CONTAINER_NAME")"
  PREV_TAG="${CURRENT_IMAGE##*:}"
fi
echo "$PREV_TAG" > "$STATE_FILE"
echo "[$SERVICE] previous tag was: $PREV_TAG"

deploy_tag() {
  local tag="$1"
  export "${TAG_VAR}=${tag}"
  echo "[$SERVICE] pulling with ${TAG_VAR}=${tag} ..."
  docker compose pull "$SERVICE"
  echo "[$SERVICE] recreating container ..."
  docker compose up -d --no-deps "$SERVICE"
}

# web-client/admin-client have no Docker HEALTHCHECK configured anywhere (no
# HEALTHCHECK instruction in their Dockerfiles, no healthcheck: key in their
# compose service blocks) - fall back to "still running, hasn't restarted"
# instead of a Health.Status that would never report anything for them.
health_check() {
  local timeout=90 waited=0
  local has_health
  has_health="$(docker inspect --format '{{if .State.Health}}yes{{else}}no{{end}}' "$CONTAINER_NAME" 2>/dev/null || echo no)"
  while [ "$waited" -lt "$timeout" ]; do
    if [ "$has_health" = "yes" ]; then
      status="$(docker inspect --format '{{.State.Health.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo unknown)"
      [ "$status" = "healthy" ] && return 0
    else
      running="$(docker inspect --format '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null || echo false)"
      restarts="$(docker inspect --format '{{.RestartCount}}' "$CONTAINER_NAME" 2>/dev/null || echo 99)"
      if [ "$running" = "true" ] && [ "$waited" -ge 10 ] && [ "$restarts" = "0" ]; then
        return 0
      fi
    fi
    sleep 5
    waited=$((waited + 5))
  done
  return 1
}

deploy_tag "$NEW_TAG"

if health_check; then
  echo "[$SERVICE] healthy on $NEW_TAG."
else
  echo "[$SERVICE] FAILED health check on $NEW_TAG - rolling back to $PREV_TAG." >&2
  deploy_tag "$PREV_TAG"
  if health_check; then
    echo "[$SERVICE] rollback to $PREV_TAG succeeded." >&2
  else
    echo "[$SERVICE] rollback to $PREV_TAG ALSO failed health check - manual intervention required." >&2
  fi
  exit 1
fi
