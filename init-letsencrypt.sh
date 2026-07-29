#!/usr/bin/env bash
#
# init-letsencrypt.sh — bootstrap Let's Encrypt certs for the gateway nginx (web-client).
#
# Run this ONCE from the monorepo root, before the first `docker compose up`, on the
# host that owns the domain(s) below (DNS A/AAAA record must already point here and
# ports 80/443 must be reachable from the internet).
#
# Why this is needed: nginx/nginx.conf hard-codes
#   ssl_certificate     /etc/letsencrypt/live/<domain>/fullchain.pem
#   ssl_certificate_key /etc/letsencrypt/live/<domain>/privkey.pem
# so the web-client container will refuse to start until something exists at that
# path. This script creates a throwaway self-signed cert so nginx can boot and serve
# the /.well-known/acme-challenge/ location, requests the real certificate from Let's
# Encrypt via the HTTP-01 webroot challenge, then reloads nginx with it. After this
# succeeds, `docker compose up -d` will bring up the rest of the stack, including the
# `certbot` service that already handles renewal (see docker-compose.yml).
#
# Usage:
#   ./init-letsencrypt.sh [-d domain]... [-e email] [--staging] [--force]
#
#   -d domain    Domain to certify. Repeatable for a SAN cert. Defaults to the
#                domain(s) baked into nginx/nginx.conf.
#   -e email     Contact email for Let's Encrypt expiry notices. Defaults to
#                $EMAIL, then to the SENDER_EMAIL set in this repo's .env.
#   --staging    Use Let's Encrypt's staging environment (untrusted certs, high
#                rate limits) — use this while testing the script itself.
#   --force      Request a new cert even if one already exists for the domain.
#
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

COMPOSE_FILE="docker-compose.yml"
GATEWAY_SERVICE="web-client"
CERTBOT_SERVICE="certbot"
RSA_KEY_SIZE=4096

domains=()
email="${EMAIL:-}"
staging=0
force=0

usage() { grep '^#' "$0" | sed '1d;s/^# \{0,1\}//'; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -d) domains+=("$2"); shift 2 ;;
    -e) email="$2"; shift 2 ;;
    --staging) staging=1; shift ;;
    --force) force=1; shift ;;
    -h|--help) usage ;;
    *) echo "Unknown argument: $1" >&2; usage ;;
  esac
done

if [[ ${#domains[@]} -eq 0 ]]; then
  domains=("www.arbiscannerwebapp.site")
fi

if [[ -z "$email" && -f .env ]]; then
  email="$(grep -m1 '^SENDER_EMAIL=' .env | cut -d= -f2- || true)"
fi
if [[ -z "$email" ]]; then
  read -rp "Contact email for Let's Encrypt (used for expiry notices): " email
fi
if [[ -z "$email" ]]; then
  echo "Error: an email address is required (Let's Encrypt rejects --register-unsafely-without-email for interactive use)." >&2
  exit 1
fi

if ! docker compose -f "$COMPOSE_FILE" version >/dev/null 2>&1; then
  echo "Error: 'docker compose' is not available. Install Docker Compose v2." >&2
  exit 1
fi

primary_domain="${domains[0]}"
domain_args=()
for d in "${domains[@]}"; do domain_args+=(-d "$d"); done

echo "==> Domains: ${domains[*]}"
echo "==> Email:   $email"
[[ $staging -eq 1 ]] && echo "==> Using Let's Encrypt STAGING environment"

# ── 1. Skip if a real cert already exists (unless --force) ─────────────────────
existing="$(docker compose -f "$COMPOSE_FILE" run --rm --entrypoint sh "$CERTBOT_SERVICE" \
  -c "[ -d /etc/letsencrypt/live/$primary_domain ] && echo yes || echo no")"
existing="$(echo "$existing" | tr -d '\r\n')"

if [[ "$existing" == "yes" && $force -eq 0 ]]; then
  echo "==> Certificate for $primary_domain already exists. Use --force to reissue."
  echo "==> Nothing to do — you can run 'docker compose up -d' now."
  exit 0
fi

# ── 2. Dummy self-signed cert so nginx has something to load at boot ───────────
echo "==> Creating temporary self-signed certificate for $primary_domain ..."
docker compose -f "$COMPOSE_FILE" run --rm --entrypoint sh "$CERTBOT_SERVICE" -c "
  mkdir -p /etc/letsencrypt/live/$primary_domain && \
  openssl req -x509 -nodes -newkey rsa:2048 -days 1 \
    -keyout '/etc/letsencrypt/live/$primary_domain/privkey.pem' \
    -out '/etc/letsencrypt/live/$primary_domain/fullchain.pem' \
    -subj '/CN=localhost'
"

# ── 3. Start the gateway so it can serve the ACME HTTP-01 challenge ────────────
echo "==> Starting $GATEWAY_SERVICE ..."
docker compose -f "$COMPOSE_FILE" up -d "$GATEWAY_SERVICE"

# ── 4. Discard the dummy cert and request the real one ─────────────────────────
echo "==> Deleting temporary certificate ..."
docker compose -f "$COMPOSE_FILE" run --rm --entrypoint sh "$CERTBOT_SERVICE" -c "
  rm -rf /etc/letsencrypt/live/$primary_domain \
         /etc/letsencrypt/archive/$primary_domain \
         /etc/letsencrypt/renewal/$primary_domain.conf
"

staging_arg=()
[[ $staging -eq 1 ]] && staging_arg=(--staging)

echo "==> Requesting Let's Encrypt certificate for ${domains[*]} ..."
docker compose -f "$COMPOSE_FILE" run --rm --entrypoint certbot "$CERTBOT_SERVICE" \
  certonly --webroot -w /var/www/certbot \
  "${staging_arg[@]}" \
  "${domain_args[@]}" \
  --email "$email" \
  --rsa-key-size "$RSA_KEY_SIZE" \
  --agree-tos \
  --non-interactive \
  --force-renewal

# ── 5. Reload nginx so it picks up the real certificate ────────────────────────
echo "==> Reloading $GATEWAY_SERVICE ..."
docker compose -f "$COMPOSE_FILE" exec "$GATEWAY_SERVICE" nginx -s reload

echo "==> Done. Certificate installed for ${domains[*]}."
echo "==> Bring up the rest of the stack with: docker compose up -d"
echo "    (the 'certbot' service in docker-compose.yml already handles renewal every 12h)"
