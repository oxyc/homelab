# Caddy with the Cloudflare DNS module (for wildcard DNS-01 certs on *.${CADDY_LOCAL_DOMAIN}).
# Built automatically by the `build:` block in compose.yml.
ARG CADDY_VERSION=2
FROM caddy:${CADDY_VERSION}-builder AS builder
RUN xcaddy build --with github.com/caddy-dns/cloudflare

FROM caddy:${CADDY_VERSION}
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
