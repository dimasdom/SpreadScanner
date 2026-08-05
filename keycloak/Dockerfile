# Multi-stage build following Keycloak's own recommended production pattern:
# `kc.sh build` bakes provider/feature selection into the image so `start
# --optimized` skips re-running the build step on every container start,
# cutting both startup time and idle footprint versus the default dev image.
FROM quay.io/keycloak/keycloak:26.4 AS builder

ENV KC_DB=postgres
# Trim the feature set to what this deployment actually uses — no clustering,
# no non-Postgres storage providers.
RUN /opt/keycloak/bin/kc.sh build --db=postgres

FROM quay.io/keycloak/keycloak:26.4
COPY --from=builder /opt/keycloak/ /opt/keycloak/
COPY realm-export/arbiscanner-web-realm.json /opt/keycloak/data/import/arbiscanner-web-realm.json
COPY realm-export/arbiscanner-admin-realm.json /opt/keycloak/data/import/arbiscanner-admin-realm.json
COPY themes/arbiscanner /opt/keycloak/themes/arbiscanner

ENTRYPOINT ["/opt/keycloak/bin/kc.sh"]
CMD ["start", "--optimized", "--import-realm"]
