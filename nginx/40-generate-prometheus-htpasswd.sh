#!/bin/sh
# Generates the basic-auth file for the gateway's /prometheus/ route from
# PROMETHEUS_BASIC_AUTH_USER / PROMETHEUS_BASIC_AUTH_PASSWORD (see sample.env).
# Placed in /docker-entrypoint.d/, so the official nginx image runs it
# automatically before nginx starts.
set -e

HTPASSWD_FILE=/etc/nginx/prometheus.htpasswd

if [ -n "$PROMETHEUS_BASIC_AUTH_USER" ] && [ -n "$PROMETHEUS_BASIC_AUTH_PASSWORD" ]; then
    htpasswd -Bbc "$HTPASSWD_FILE" "$PROMETHEUS_BASIC_AUTH_USER" "$PROMETHEUS_BASIC_AUTH_PASSWORD"
else
    echo "40-generate-prometheus-htpasswd.sh: PROMETHEUS_BASIC_AUTH_USER/PASSWORD not set — /prometheus/ will reject all requests" >&2
    : > "$HTPASSWD_FILE"
fi
