# Cloudflare — the private tunnel

Everything that reaches den (and later Home Assistant) from outside the tailnet, behind a login.
Designed in [oxyc/den#15](https://github.com/oxyc/den/issues/15); this directory is the homelab half.

Gondola's **public** tunnel is not described here — it belongs to `grocery-tracker` and is managed by
its own Terraform. Two `cloudflared` total, deliberately, and no per-app tunnels.

## Files

| | |
|---|---|
| `access.example.json` → `access.json` *(gitignored)* | desired state: hostnames, who may pass Access, rate limits |
| `ingress.example.yml` → `ingress.yml` *(gitignored)* | cloudflared's own config: which hostname reaches which LAN service |
| `apply.sh` | converges Cloudflare on `access.json` |
| `homelab-private.json` *(gitignored)* | the tunnel's credential — also keep a copy in your password manager |

The tunnel itself is installed on the **host** by `ansible/roles/cloudflare_tunnel` (`--tags tunnel`).
The box has no podman and no docker, so it is a pinned binary plus a systemd unit, not a Quadlet.

```bash
CF_TOKEN_FILE=~/.cf-token cloudflare/apply.sh            # show differences, change nothing
CF_TOKEN_FILE=~/.cf-token cloudflare/apply.sh --apply    # create what is missing
```

`apply.sh` never deletes. `MISMATCH` and `UNEXPECTED` are reported for a human, because the blast
radius of a wrong delete here is "a service is silently public" or "nobody can log in".

## Why this exists

The first time this was set up it was a pile of `curl` calls in a shell, recorded nowhere. That is
the same failure that left den's nightly export timer, its systemd units and the `tailscale serve`
routes existing only on the box — each found months later by accident. Six months from now the
question will be *"why does one of these hostnames skip the login?"*, and the answer needs to be in
git rather than in someone's memory.

## The rules worth keeping

**One label under the zone.** Cloudflare's free Universal SSL covers the apex and one level only, so
`x.y.example.com` fails TLS at the edge without Advanced Certificate Manager. Deep names are fine for
LAN-only services behind Caddy, since Let's Encrypt DNS-01 does not care. That gives a rule with a
useful side effect: **the name tells you whether something is exposed.**

**The Access boundary is a hostname, never a path.** A path-prefix bypass fails *open* — add a route
later and it silently lands on the wrong side of a glob, or a trailing slash or percent-encoding edge
case moves it. A hostname cannot drift like that. The one path rule in `ingress.yml` (`^/p/…` on the
play host) is the opposite shape: it *allowlists*, so getting it wrong denies a ticket rather than
exposing scout.

**Default-deny per hostname.** Every hostname in `ingress.yml` ends in `http_status:404`, and so does
the file. A request reaches a backend only because a rule says so.

**Before adding a hostname, ask: what is its own authority, and does it survive being public?**
Only two bypass Access today, and each carries authorisation in every request — den-edge's device API
authorises itself, and a play ticket is good for one release for 24 hours. An addon's JSON API has no
such property: bypassed, scout becomes a free public aggregator whose scraping leaves from the home
IP, so the indexers rate-limit and blocklist *you*. That is an availability bug, not a hosting cost.

**The service token lives only on the TVs.** It reaches them through den-edge's library log, so it
rotates without an app release. No server-side component holds a copy — which is why den-remux and
den-subtitles alias public names to LAN addresses rather than talking to each other through
Cloudflare. Two services on the same box should not need the WAN to reach each other.

**An allow policy is not a login.** Access ships with no identity provider, and one-time PIN is not
added automatically. Without one, the login page offers only "Login with Cloudflare" — a Cloudflare
*dashboard* account — so an allowed address that is an ordinary mailbox is told "That account does
not have access", and the app is unreachable by the exact person it allows. `apply.sh` now converges
the one-time PIN login method for this reason.

**Video never goes through the tunnel.** den-reel and den-remux are absent on purpose: Cloudflare's
terms restrict serving video through the CDN/Tunnel outside Stream/R2, and it would spend home upload
bandwidth. Both stay LAN + tailnet; a remote TV falls back to YouTube trailers. Do not "fix" this.

## Free-plan limits, learned by hitting them

- Rate limiting: `period` and `mitigation_timeout` must both be **10**, and there is **one rule per
  zone**. The API rejects anything else with `not entitled`.
- Universal SSL: apex and one subdomain level, as above.

## Token scopes

`apply.sh` needs an API token with:

```
Account | Cloudflare Tunnel         : Edit
Account | Access: Apps and Policies : Edit
Account | Access: Service Tokens    : Edit     <- separate permission; easy to miss
Account | Access: Organizations, Identity Providers, and Groups : Edit
Zone    | DNS                       : Edit
Zone    | Zone                      : Read
Zone    | Zone WAF                  : Edit
```

Scope it to the one account and the one zone. It can rewrite your DNS, so treat it as a credential
with a short life: create it for a change, delete it after.
