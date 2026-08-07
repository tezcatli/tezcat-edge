#!/usr/bin/env bash
#
# Lints an app's compose file and nginx fragment against the edge contract.
#
#     ./bin/check-app.sh --app silence \
#         --compose ../cors-proxy/deploy/compose.yml \
#         --conf    ../cors-proxy/deploy/silence.conf \
#         --health-service backend
#
# Static only — no host, no Docker, no network — so it runs in CI before
# anything is shipped. deploy-app.yml runs it on every deploy.
#
# Every rule here exists because breaking it fails *in production, later, in a
# way that does not point at the cause*: an alias collision looks like random
# cross-app 502s; a literal proxy_pass takes down every app on the next edge
# restart, possibly weeks later; a missing exact-match location answers an API
# call with HTML and a 200. Mistakes that fail loudly and immediately are
# deliberately not checked here — nginx and compose already catch those.
#
# ERROR is a contract violation with no legitimate exception. WARN is a
# heuristic that is usually-but-not-always wrong; a linter that blocks on
# judgement calls is one people learn to route around.
set -uo pipefail

APP=""; COMPOSE=""; CONF=""; HEALTH_SERVICE="backend"
while [ $# -gt 0 ]; do
  case "$1" in
    --app)            APP="$2"; shift 2 ;;
    --compose)        COMPOSE="$2"; shift 2 ;;
    --conf)           CONF="$2"; shift 2 ;;
    --health-service) HEALTH_SERVICE="$2"; shift 2 ;;
    -h|--help)        sed -n '2,22p' "$0" | sed 's/^#//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$APP" ]     || { echo "--app is required" >&2; exit 2; }
[ -n "$COMPOSE" ] || { echo "--compose is required" >&2; exit 2; }
[ -f "$COMPOSE" ] || { echo "no such file: $COMPOSE" >&2; exit 2; }

ERRORS=0; WARNINGS=0
err()   { printf '  \033[31mFAIL\033[0m %s\n       ↳ %s\n' "$1" "$2"; ERRORS=$((ERRORS+1)); }
warn()  { printf '  \033[33mwarn\033[0m %s\n       ↳ %s\n' "$1" "$2"; WARNINGS=$((WARNINGS+1)); }
ok()    { printf '  \033[32mok\033[0m   %s\n' "$1"; }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

emit() {  # LEVEL|rule|detail  ->  err/warn
  local line level rule detail
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    level=${line%%|*}; line=${line#*|}
    rule=${line%%|*};  detail=${line#*|}
    case "$level" in E) err "$rule" "$detail" ;; *) warn "$rule" "$detail" ;; esac
  done
}

# ── compose ──────────────────────────────────────────────────────────────────
head_ "compose — $COMPOSE"

COMPOSE_OUT=$(python3 - "$COMPOSE" "$APP" "$HEALTH_SERVICE" <<'PY'
import sys
try:
    import yaml
except ImportError:
    print("pyyaml is required (pip install pyyaml)", file=sys.stderr); sys.exit(2)

path, app, health_service = sys.argv[1], sys.argv[2], sys.argv[3]
doc = yaml.safe_load(open(path)) or {}
services = doc.get("services") or {}
networks = doc.get("networks") or {}
out = []

# Published ports let the app answer on the host directly, racing the edge for
# :443 and bypassing TLS, headers and routing entirely.
for name, svc in services.items():
    if (svc or {}).get("ports"):
        out.append(("E", f"service '{name}' publishes ports",
                    "apps are reached only through the edge; drop the ports: block"))

# A non-external network of the same name is a *different* network the edge
# cannot see. The symptom is a 502 with nothing in any log to explain it.
if "edge" not in networks:
    out.append(("E", "no 'edge' network declared",
                "add   networks: { edge: { name: edge, external: true } }"))
else:
    edge = networks.get("edge") or {}
    if not edge.get("external"):
        out.append(("E", "'edge' network is not external: true",
                    "compose would silently create a second, isolated network of its own"))
    if edge.get("name") != "edge":
        out.append(("E", f"'edge' network name is {edge.get('name')!r}, expected 'edge'",
                    "the shared network is named exactly 'edge'"))

# The one that bites silently. Compose publishes the bare service name as an
# alias on every network it joins, so two apps each having a 'backend' both
# answer to 'backend' and Docker round-robins between them — one app's requests
# land in the other, intermittently.
for name, svc in services.items():
    nets = (svc or {}).get("networks")
    if not isinstance(nets, dict) or "edge" not in nets:
        continue
    aliases = ((nets.get("edge") or {}).get("aliases")) or []
    if not any(str(a).startswith(f"{app}-") for a in aliases):
        out.append(("E", f"service '{name}' joins 'edge' without an app-prefixed alias",
                    f"add   edge: {{ aliases: [{app}-{name}] }}   — otherwise '{name}' "
                    f"collides with every other app's '{name}'"))

# Without a healthcheck the deploy gate has nothing to wait on and reports
# success as soon as the container is created.
svc = services.get(health_service)
if svc is None:
    out.append(("E", f"health_service '{health_service}' is not a service in this file",
                f"the deploy gates on it; services here are: {', '.join(services) or '(none)'}"))
elif not (svc or {}).get("healthcheck"):
    out.append(("E", f"service '{health_service}' has no healthcheck",
                "the deploy gate would pass on a container that never serves a request"))

# A floating tag cannot be rolled back to, which is the entire point of .env.
for name, svc in services.items():
    image = (svc or {}).get("image", "")
    if image and "${IMAGE_TAG" not in image:
        out.append(("E", f"service '{name}' image does not use ${{IMAGE_TAG}}",
                    f"got {image!r}; rollback works by re-pinning IMAGE_TAG in .env"))

for level, rule, detail in out:
    print(f"{level}|{rule}|{detail}")
PY
) || exit 2

if [ -z "$COMPOSE_OUT" ]; then
  ok "no published ports; edge network external; aliases prefixed; healthcheck present; tag pinned"
else
  emit <<< "$COMPOSE_OUT"
fi

# ── nginx fragment ───────────────────────────────────────────────────────────
if [ -n "$CONF" ]; then
  head_ "nginx fragment — $CONF"
  [ -f "$CONF" ] || { echo "no such file: $CONF" >&2; exit 2; }

  # Literal upstreams are resolved once, at startup. If this app is down when
  # the edge restarts, nginx refuses to start and takes every *other* app with
  # it — long after the change that caused it.
  literal=$(grep -nE '^[[:space:]]*proxy_pass[[:space:]]' "$CONF" | grep -v '\$' || true)
  if [ -n "$literal" ]; then
    err "proxy_pass with a literal host at line(s): $(echo "$literal" | cut -d: -f1 | tr '\n' ' ')" \
        "resolve through a variable —  set \$up name:8000;  proxy_pass http://\$up;"
  else
    ok "upstreams resolve per request (variable proxy_pass)"
  fi

  # nginx will not start with an ssl_certificate path that does not exist, so a
  # mismatch here fails the whole edge on the next reload, not just this app.
  sn=$(grep -oP '^\s*server_name\s+\K[^;]+' "$CONF" | tr -d ' ' | grep -vx '_' | head -1 || true)
  cert=$(grep -oP '^\s*ssl_certificate\s+\K[^;]+' "$CONF" | head -1 || true)
  if [ -n "$sn" ] && [ -n "$cert" ]; then
    if [[ "$cert" == *"$sn"* ]]; then
      ok "certificate path matches server_name ($sn)"
    else
      err "ssl_certificate does not match server_name" \
          "server_name=$sn but ssl_certificate=$cert"
    fi
  fi

  # add_header does not merge across levels: a location that sets any header of
  # its own silently drops every inherited one.
  if grep -q 'snippets/security-headers.inc' "$CONF"; then
    ok "security headers included"
  else
    err "security-headers snippet not included" \
        "add at server level:  include /etc/nginx/conf.d/snippets/security-headers.inc;"
  fi

  # A prefix location ending in / never matches the no-slash form. Where that
  # form is a real endpoint it falls through to whatever catch-all follows —
  # typically the SPA, so the caller gets HTML and a 200 where it wanted JSON.
  # A warning, not an error: plenty of prefixes have no meaningful bare form.
  while read -r loc; do
    [ -z "$loc" ] && continue
    bare="${loc%/}"
    grep -qE "location[[:space:]]*=[[:space:]]*${bare}[[:space:]]*\{" "$CONF" && continue
    warn "no exact-match sibling for 'location $loc'" \
         "if $bare is itself an endpoint it falls through to the catch-all; add  location = $bare"
  done < <(grep -oP '^\s*location\s+\K/[^ {]*/(?=\s*\{)' "$CONF" || true)
fi

# ── verdict ──────────────────────────────────────────────────────────────────
head_ "result"
if [ "$ERRORS" -gt 0 ]; then
  printf '  \033[31m%d error(s)\033[0m, %d warning(s) — see tezcat-edge README, "Adding an app"\n' \
    "$ERRORS" "$WARNINGS"
  exit 1
fi
printf '  \033[32mcontract satisfied\033[0m (%d warning(s))\n' "$WARNINGS"
