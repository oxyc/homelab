# Caddy with the Cloudflare DNS module (needed for DNS-01 wildcard certs on *.h.oxy.fi).
# Used only when you switch off `tls internal`. Build via the `build:` block in compose.yml.
ARG CADDY_VERSION=2
FROM caddy:${CADDY_VERSION}-builder AS builder
RUN xcaddy build --with github.com/caddy-dns/cloudflare

FROM caddy:${CADDY_VERSION}
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
