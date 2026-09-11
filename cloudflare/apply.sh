#!/usr/bin/env bash
# Converge Cloudflare (DNS + Access + rate limits) on cloudflare/access.json.
#
#   cloudflare/apply.sh --check    # print what differs, change nothing  (DEFAULT)
#   cloudflare/apply.sh --apply    # create what is missing
#
# Idempotent and additive: it creates what is absent and leaves what matches. It deliberately does
# NOT delete — an unexpected Access application is reported, not removed, because the blast radius of
# a wrong delete here is "a service is silently public" or "nobody can log in".
#
# Reads CLOUDFLARE_API_TOKEN from the environment, or from the path in CF_TOKEN_FILE. The token needs:
#   Account | Cloudflare Tunnel        : Edit
#   Account | Access: Apps and Policies: Edit
#   Account | Access: Service Tokens   : Edit     <- separate from Apps and Policies; easy to miss
#   Account | Access: Organizations, Identity Providers, and Groups : Edit   <- the login method
#   Zone    | DNS                      : Edit
#   Zone    | Zone                     : Read
#   Zone    | Zone WAF                 : Edit
#
# Secrets this prints and you must store OUT of band, in the password manager:
#   - the tunnel credentials JSON (also written to ./homelab-private.json, 0600)
#   - a service token's client_secret, which Cloudflare shows exactly once
set -euo pipefail

cd "$(dirname "$0")"
MODE="${1:---check}"
CFG="${CF_ACCESS_CONFIG:-access.json}"
[ -f "$CFG" ] || { echo "missing $CFG — copy access.example.json and fill it in" >&2; exit 1; }

if [ -z "${CLOUDFLARE_API_TOKEN:-}" ] && [ -n "${CF_TOKEN_FILE:-}" ]; then
  CLOUDFLARE_API_TOKEN="$(cat "$CF_TOKEN_FILE")"
fi
[ -n "${CLOUDFLARE_API_TOKEN:-}" ] || { echo "set CLOUDFLARE_API_TOKEN or CF_TOKEN_FILE" >&2; exit 1; }
export CLOUDFLARE_API_TOKEN MODE CFG

python3 - <<'PY'
import json, os, subprocess, sys, urllib.request, urllib.error

TOKEN = os.environ["CLOUDFLARE_API_TOKEN"]
APPLY = os.environ["MODE"] == "--apply"
API   = "https://api.cloudflare.com/client/v4"

def cfg_load(path):
    """JSON, deliberately. No python reachable from the admin box or the host has PyYAML (checked:
    neither the nix python3 nor ansible's), and this script is not worth a dependency. Keys starting
    with "_" and every "why" field are documentation and are ignored here."""
    return json.load(open(path))

def call(method, path, body=None):
    req = urllib.request.Request(API + path, method=method,
        headers={"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"},
        data=json.dumps(body).encode() if body is not None else None)
    try:
        with urllib.request.urlopen(req) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        return json.load(e)

def ok(d, what):
    if d.get("success"):
        return d.get("result")
    msgs = [e.get("message") or e.get("error") for e in d.get("errors", [])]
    # auth.forbidden here almost always means one missing token scope, not a wrong account.
    print(f"  ! {what}: {msgs}", file=sys.stderr)
    return None

c    = cfg_load(os.environ["CFG"])
acct = c["account_id"]; zone = c["zone"]; zid = c["zone_id"]
verb = "creating" if APPLY else "would create"
changes = 0

def note(action, what):
    global changes
    changes += 1
    print(f"  {action:<14} {what}")

# ── tunnel ──────────────────────────────────────────────────────────────────────────────────────
tuns = ok(call("GET", f"/accounts/{acct}/cfd_tunnel?is_deleted=false"), "list tunnels") or []
tun  = next((t for t in tuns if t["name"] == c["tunnel"]["name"]), None)
if tun:
    print(f"  ok             tunnel {tun['name']} ({tun.get('config_src')})")
    if tun.get("config_src") != c["tunnel"].get("config_src"):
        note("MISMATCH", f"tunnel config_src is {tun.get('config_src')}, want {c['tunnel']['config_src']}")
else:
    note(verb, f"tunnel {c['tunnel']['name']}")
    if APPLY:
        import base64
        secret = base64.b64encode(os.urandom(32)).decode()
        r = ok(call("POST", f"/accounts/{acct}/cfd_tunnel",
                    {"name": c["tunnel"]["name"], "tunnel_secret": secret,
                     "config_src": c["tunnel"]["config_src"]}), "create tunnel")
        if r:
            tun = r
            cred = r["credentials_file"]
            cred = json.loads(cred) if isinstance(cred, str) else cred
            fd = os.open("homelab-private.json", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            os.write(fd, json.dumps(cred).encode()); os.close(fd)
            print("  -> wrote homelab-private.json (0600). Copy to the host and into your password "
                  "manager; it is the tunnel's only credential.")

# ── DNS ─────────────────────────────────────────────────────────────────────────────────────────
if tun:
    target  = f"{tun['id']}.cfargotunnel.com"
    records = ok(call("GET", f"/zones/{zid}/dns_records?per_page=200"), "list dns") or []
    have    = {r["name"]: r for r in records}
    for h in c["hostnames"]:
        fqdn = f"{h['name']}.{zone}"
        r = have.get(fqdn)
        if r and r["content"] == target and r.get("proxied"):
            print(f"  ok             dns {fqdn}")
        elif r:
            note("MISMATCH", f"dns {fqdn} -> {r['content']} proxied={r.get('proxied')}")
        else:
            note(verb, f"dns {fqdn} -> tunnel")
            if APPLY:
                ok(call("POST", f"/zones/{zid}/dns_records",
                        {"type": "CNAME", "name": h["name"], "content": target, "proxied": True,
                         "comment": "private tunnel (cloudflare/access.json)"}), f"dns {fqdn}")

# ── service tokens ──────────────────────────────────────────────────────────────────────────────
svc_ids = {}
existing = ok(call("GET", f"/accounts/{acct}/access/service_tokens"), "list service tokens") or []
for st in c.get("service_tokens", []):
    found = next((s for s in existing if s["name"] == st["name"]), None)
    if found:
        svc_ids[st["name"]] = found["id"]
        print(f"  ok             service token {st['name']}")
    else:
        note(verb, f"service token {st['name']}")
        if APPLY:
            r = ok(call("POST", f"/accounts/{acct}/access/service_tokens", {"name": st["name"]}),
                   f"service token {st['name']}")
            if r:
                svc_ids[st["name"]] = r["id"]
                print(f"  -> client_secret for {st['name']} is shown ONCE. Store it now:")
                print(f"     client_id: {r['client_id']}")
                print(f"     client_secret: {r['client_secret']}")

# ── login method ────────────────────────────────────────────────────────────────────────────────
# Access ships with NO identity provider, and OTP is no longer added automatically. Without one the
# login page offers only "Login with Cloudflare", which authenticates a Cloudflare DASHBOARD account
# — so every allowed address that is not itself a Cloudflare login (i.e. an ordinary mailbox) gets
# "That account does not have access", and the apps below are unreachable by the exact people their
# policies allow. One-time PIN mails a code to the address the policy already names, which is the
# identity this design wants; it is also the only login method that needs no third-party setup.
idps = ok(call("GET", f"/accounts/{acct}/access/identity_providers"), "list identity providers") or []
if any(i.get("type") == "onetimepin" for i in idps):
    print("  ok             login method one-time PIN")
else:
    note(verb, "login method one-time PIN")
    if APPLY:
        ok(call("POST", f"/accounts/{acct}/access/identity_providers",
                {"name": "One-time PIN", "type": "onetimepin", "config": {}}),
           "one-time PIN login method")

# ── Access applications ─────────────────────────────────────────────────────────────────────────
apps  = ok(call("GET", f"/accounts/{acct}/access/apps"), "list access apps") or []
bydom = {a.get("domain"): a for a in apps}
for h in c["hostnames"]:
    fqdn = f"{h['name']}.{zone}"
    want = h["access"]
    app  = bydom.get(fqdn)
    if want == "bypass":
        # An Access application on a bypassed host would lock out the TVs, so its ABSENCE is the
        # desired state and an unexpected one is worth shouting about.
        if app: note("UNEXPECTED", f"access app on {fqdn}, which must be bypassed")
        else:   print(f"  ok             {fqdn} bypassed (no access app)")
        continue
    if app:
        print(f"  ok             access app {fqdn}")
        continue
    note(verb, f"access app {fqdn} ({want})")
    if APPLY:
        pols = [{"name": "Owners", "decision": "allow", "precedence": 1,
                 "include": [{"email": {"email": e}} for e in c["access_emails"]]}]
        r = ok(call("POST", f"/accounts/{acct}/access/apps",
                    {"name": fqdn, "domain": fqdn, "type": "self_hosted",
                     "session_duration": c.get("session_duration", "720h"), "policies": pols}),
               f"access app {fqdn}")
        if r and want == "owners+tvs":
            for st in c.get("service_tokens", []):
                if h["name"] in st.get("attach_to", []) and st["name"] in svc_ids:
                    ok(call("POST", f"/accounts/{acct}/access/apps/{r['id']}/policies",
                            {"name": f"{st['name']} (service token)", "decision": "non_identity",
                             "precedence": 2,
                             "include": [{"service_token": {"token_id": svc_ids[st["name"]]}}]}),
                       f"tv policy on {fqdn}")

# ── rate limits ─────────────────────────────────────────────────────────────────────────────────
# Free plan: period and mitigation_timeout must both be 10, and one rule per zone. The API rejects
# anything else with "not entitled", so the config file carries those values explicitly.
rl = call("GET", f"/zones/{zid}/rulesets/phases/http_ratelimit/entrypoint")
cur = (rl.get("result") or {}).get("rules") or [] if rl.get("success") else []
for want in c.get("rate_limits", []):
    if any(want["description"] in (r.get("description") or "") for r in cur):
        print(f"  ok             rate limit {want['host']}{want['path_prefix']}")
        continue
    note(verb, f"rate limit {want['host']}{want['path_prefix']}")
    if APPLY:
        rule = {"action": "block", "description": want["description"],
                "expression": f'(http.host eq "{want["host"]}.{zone}" and '
                              f'starts_with(http.request.uri.path, "{want["path_prefix"]}"))',
                "ratelimit": {"characteristics": ["ip.src", "cf.colo.id"],
                              "period": want["period"],
                              "requests_per_period": want["requests_per_period"],
                              "mitigation_timeout": want["mitigation_timeout"]}}
        if rl.get("success"):
            ok(call("POST", f"/zones/{zid}/rulesets/{rl['result']['id']}/rules", rule), "rate limit")
        else:
            ok(call("POST", f"/zones/{zid}/rulesets",
                    {"name": "default", "kind": "zone", "phase": "http_ratelimit", "rules": [rule]}),
               "rate limit ruleset")

print()
if changes == 0:
    print("in sync — Cloudflare matches access.json")
elif not APPLY:
    print(f"{changes} difference(s). Re-run with --apply to create what is missing.")
    print("Nothing is ever deleted by this script; MISMATCH and UNEXPECTED are for you to resolve.")
PY
