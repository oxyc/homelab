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
import json, os, sys, urllib.request, urllib.error

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
        # A gateway or WAF error body is HTML, not JSON; json.load would raise here and lose the
        # status code, which is the only useful thing about it.
        try:
            return json.load(e)
        except ValueError:
            return {"success": False, "errors": [{"message": f"HTTP {e.code} (non-JSON body)"}]}
    except urllib.error.URLError as e:
        return {"success": False, "errors": [{"message": f"network: {e.reason}"}]}

errors = 0

def ok(d, what):
    global errors
    if d.get("success"):
        return d.get("result")
    errors += 1
    msgs = [e.get("message") or e.get("error") for e in d.get("errors", [])]
    # auth.forbidden here almost always means one missing token scope, not a wrong account.
    print(f"  ! {what}: {msgs}", file=sys.stderr)
    return None

def must(d, what):
    """For LIST calls only. Every decision below is 'does X already exist?', so a failed read is
    indistinguishable from 'nothing exists' and converts into a confident, wrong 'ok'. Concretely:
    if listing Access apps fails on a missing token scope, bydom is empty and every protected
    hostname reports `ok … bypassed (no access app)` — a clean bill of health derived from having
    read nothing. Reads are cheap; guessing is not."""
    r = ok(d, what)
    if r is None:
        print(f"  ! cannot continue without {what} — refusing to report on state it could not read",
              file=sys.stderr)
        sys.exit(1)
    return r

def paged(path, what):
    """The API caps per_page (100 for DNS) and pages silently. Unpaginated, a zone past one page
    makes an existing record look absent and this script tries to create a duplicate."""
    out, page = [], 1
    while True:
        sep = "&" if "?" in path else "?"
        d = must(call("GET", f"{path}{sep}page={page}&per_page=100"), what)
        out.extend(d)
        if len(d) < 100:
            return out
        page += 1

c    = cfg_load(os.environ["CFG"])
acct = c["account_id"]; zone = c["zone"]; zid = c["zone_id"]
verb = "creating" if APPLY else "would create"
changes = 0

unresolved = 0   # MISMATCH / UNEXPECTED / WARN: --apply cannot fix these, a human must

def note(action, what):
    global changes, unresolved
    changes += 1
    if action in ("MISMATCH", "UNEXPECTED", "WARN"):
        unresolved += 1
    print(f"  {action:<14} {what}")

# ── tunnel ──────────────────────────────────────────────────────────────────────────────────────
tuns = must(call("GET", f"/accounts/{acct}/cfd_tunnel?is_deleted=false"), "list tunnels")
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
# DELIBERATELY RUN LAST. Creating the record first means that between the DNS write and the Access
# write the hostname resolves and routes to the origin with nothing in front of it — and an --apply
# that dies in between (a missing scope, Ctrl-C, a network blip) leaves it that way with no error
# loud enough to notice. Access first, DNS last, fails closed: an interrupted run leaves a protected
# app nobody can reach yet, which is the harmless direction.
def ensure_dns():
    if not tun:
        return
    target  = f"{tun['id']}.cfargotunnel.com"
    have    = {r["name"]: r for r in paged(f"/zones/{zid}/dns_records", "list dns")}
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
existing = must(call("GET", f"/accounts/{acct}/access/service_tokens"), "list service tokens")
for st in c.get("service_tokens", []):
    found = next((s for s in existing if s["name"] == st["name"]), None)
    if found:
        svc_ids[st["name"]] = found["id"]
        # The expiry is the failure nobody sees coming: the TVs simply start getting 403 and this
        # script, matching on name alone, would still print "ok" on the day after. Tokens are not
        # renewable — an expired one is replaced, and the new secret has to reach the TVs.
        exp = (found.get("expires_at") or "")[:10]
        left = None
        if exp:
            from datetime import date
            try:
                y, m, d = (int(x) for x in exp.split("-"))
                left = (date(y, m, d) - date.today()).days
            except ValueError:
                pass
        if left is not None and left < 0:
            note("MISMATCH", f"service token {st['name']} EXPIRED {exp} — TVs are locked out")
        elif left is not None and left < 60:
            note("WARN", f"service token {st['name']} expires {exp} ({left}d) — rotate before then")
        else:
            print(f"  ok             service token {st['name']}"
                  + (f" (expires {exp})" if exp else ""))
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
idps = must(call("GET", f"/accounts/{acct}/access/identity_providers"), "list identity providers")
if any(i.get("type") == "onetimepin" for i in idps):
    print("  ok             login method one-time PIN")
else:
    note(verb, "login method one-time PIN")
    if APPLY:
        ok(call("POST", f"/accounts/{acct}/access/identity_providers",
                {"name": "One-time PIN", "type": "onetimepin", "config": {}}),
           "one-time PIN login method")

# ── Access applications ─────────────────────────────────────────────────────────────────────────
apps  = must(call("GET", f"/accounts/{acct}/access/apps"), "list access apps")
bydom = {a.get("domain"): a for a in apps}

def check_policies(app, fqdn, want, h):
    """Existence used to be the whole check: if an app was on the domain, this printed ok and moved
    on. That made the script structurally unable to answer the question README.md says it exists to
    answer — "why does one of these hostnames skip the login?" — for any app that already exists,
    which after the first run is all of them. An Everyone/Bypass policy added in the dashboard while
    debugging a TV, or a deleted Owners policy, reported "in sync" forever.

    It also made the service-token attachment dead code: that POST only ever ran inside the
    app-CREATION branch, so a run where it failed could never be repaired by a later run."""
    pols = ok(call("GET", f"/accounts/{acct}/access/apps/{app['id']}/policies"),
              f"policies for {fqdn}")
    if pols is None:
        return
    want_emails = set(c["access_emails"])
    have_emails, have_tokens, loose = set(), set(), []
    for p in pols:
        dec = p.get("decision")
        inc = p.get("include") or []
        if dec in ("bypass", "non_identity") or dec == "allow":
            for rule in inc:
                if "email" in rule:
                    have_emails.add(rule["email"].get("email"))
                elif "service_token" in rule:
                    have_tokens.add(rule["service_token"].get("token_id"))
                elif "everyone" in rule or "ip" in rule or "certificate" in rule:
                    # The dangerous shape: a rule that admits someone who is on nobody's list.
                    loose.append(f"{p.get('name') or dec}:{list(rule)[0]}")
        if dec == "bypass":
            loose.append(f"{p.get('name') or 'policy'}:bypass-decision")
    for extra in sorted(have_emails - want_emails):
        note("UNEXPECTED", f"access app {fqdn} admits {extra}, which is not in access_emails")
    for missing in sorted(want_emails - have_emails):
        note("MISMATCH", f"access app {fqdn} does NOT admit {missing}")
    for l in loose:
        note("UNEXPECTED", f"access app {fqdn} has a policy admitting anyone ({l})")
    # The TV token must be attached exactly where attach_to says, and nowhere else.
    for st in c.get("service_tokens", []):
        tid = svc_ids.get(st["name"])
        if not tid:
            continue
        should = h["name"] in st.get("attach_to", [])
        if should and tid not in have_tokens:
            note("MISMATCH", f"access app {fqdn} is missing the {st['name']} service-token policy")
            if APPLY:
                ok(call("POST", f"/accounts/{acct}/access/apps/{app['id']}/policies",
                        {"name": f"{st['name']} (service token)", "decision": "non_identity",
                         "precedence": 2, "include": [{"service_token": {"token_id": tid}}]}),
                   f"tv policy on {fqdn}")
        elif not should and tid in have_tokens:
            note("UNEXPECTED", f"access app {fqdn} carries the {st['name']} token but should not")

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
        check_policies(app, fqdn, want, h)
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
    expr = (f'(http.host eq "{want["host"]}.{zone}" and '
            f'starts_with(http.request.uri.path, "{want["path_prefix"]}"))')
    found = next((r for r in cur if want["description"] in (r.get("description") or "")), None)
    if found:
        # Matching the description alone said "ok" for a rule that had been disabled, re-scoped to
        # another host, or loosened to a useless threshold. This is the only thing capping online
        # guessing against /pair, so the thresholds are the point, not the label.
        rlc = found.get("ratelimit") or {}
        bad = []
        if not found.get("enabled", True):                          bad.append("disabled")
        if (found.get("expression") or "") != expr:                 bad.append("expression")
        if rlc.get("requests_per_period") != want["requests_per_period"]: bad.append("requests")
        if rlc.get("period") != want["period"]:                     bad.append("period")
        if rlc.get("mitigation_timeout") != want["mitigation_timeout"]:   bad.append("timeout")
        if found.get("action") != "block":                          bad.append("action")
        if bad:
            note("MISMATCH", f"rate limit {want['host']}{want['path_prefix']}: {', '.join(bad)}")
        else:
            print(f"  ok             rate limit {want['host']}{want['path_prefix']}")
        continue
    note(verb, f"rate limit {want['host']}{want['path_prefix']}")
    if APPLY:
        rule = {"action": "block", "description": want["description"],
                "expression": expr,
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

# ── DNS, last (see ensure_dns) ──────────────────────────────────────────────────────────────────
ensure_dns()

# ── the bypassed hostnames actually bypass into an API, not a UI ─────────────────────────────────
# The Access boundary for these rests on something this repo does not own: the origin matching its
# own Host allowlist. d and d-api point at the SAME backend; only den-edge's API_HOSTS keeps the
# bypassed name from serving the web app and its unauthenticated /api/*. Rename a bypassed host here
# — which ingress.example.yml says will happen as Den Web lands — and the origin falls through to
# web mode, publishing the API to the internet, with every object in this file still "in sync".
# So: assert the property, cheaply, instead of trusting a string in another repo.
if c.get("verify_bypass", True):
    import urllib.request as _u
    for h in c["hostnames"]:
        if h.get("access") != "bypass" or h.get("path_allowlist"):
            continue
        fqdn = f"{h['name']}.{zone}"
        try:
            rq = _u.Request(f"https://{fqdn}/", method="GET")
            with _u.urlopen(rq, timeout=15) as r:
                code, ctype = r.status, r.headers.get("content-type", "")
        except urllib.error.HTTPError as e:
            code, ctype = e.code, e.headers.get("content-type", "")
        except Exception as e:                                    # noqa: BLE001 — report, don't crash
            note("WARN", f"could not verify {fqdn} bypasses into an API: {e}")
            continue
        if code == 404:
            print(f"  ok             {fqdn} origin is in API mode (404 at /)")
        else:
            note("UNEXPECTED",
                 f"{fqdn} bypasses Access and its origin answered {code} {ctype.split(';')[0]} at / "
                 f"— expected 404. If this is the web UI, it is now public.")

print()
if errors:
    print(f"{errors} API call(s) FAILED — state above is incomplete.", file=sys.stderr)
    print("A missing token scope is the usual cause; see the scope list at the top of this script.",
          file=sys.stderr)
    sys.exit(1)
if changes == 0:
    print("in sync — Cloudflare matches access.json")
    sys.exit(0)
if not APPLY:
    print(f"{changes} difference(s). Re-run with --apply to create what is missing.")
    print("Nothing is ever deleted by this script; MISMATCH and UNEXPECTED are for you to resolve.")
    sys.exit(2)
# --apply created what it could; anything flagged for a human is still outstanding.
sys.exit(2 if unresolved else 0)
PY
