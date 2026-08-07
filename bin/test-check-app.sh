#!/usr/bin/env bash
#
# Self-test for check-app.sh.
#
# A linter nobody has watched reject anything is decoration: it passes, and you
# learn nothing about whether it *can* fail. Each case takes a known-good app,
# breaks exactly one rule, and asserts the checker catches that rule — plus a
# final case asserting the unbroken original still passes, so the checker cannot
# score green by rejecting everything.
#
#     ./bin/test-check-app.sh [dir-with-compose.yml-and-app.conf]
#
# Defaults to template/, which keeps this runnable in CI with no other repo
# checked out — and doubles as proof the template still satisfies the contract
# it is supposed to teach. Point it at a real app to check that one:
#
#     ./bin/test-check-app.sh ../cors-proxy/deploy
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REF="${1:-$HERE/../template}"
CHECK="$HERE/check-app.sh"

# The reference may be a template (compose.yml + app.conf) or a real app's
# deploy/ (compose.yml + <app>.conf); find whichever conf is there.
SRC_COMPOSE="$REF/compose.yml"
SRC_CONF=$(ls "$REF"/*.conf 2>/dev/null | head -1)
[ -f "$SRC_COMPOSE" ] || { echo "no compose.yml in $REF" >&2; exit 2; }
[ -n "$SRC_CONF" ]    || { echo "no *.conf in $REF" >&2; exit 2; }

# The app name is whatever the aliases are prefixed with.
APP=$(python3 -c "
import yaml,sys
d=yaml.safe_load(open('$SRC_COMPOSE'))
for s in (d.get('services') or {}).values():
    for a in (((s.get('networks') or {}).get('edge') or {}).get('aliases') or []):
        print(a.split('-')[0]); sys.exit()
" 2>/dev/null)
[ -n "$APP" ] || { echo "could not infer app name from aliases in $SRC_COMPOSE" >&2; exit 2; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

# run_case <name> <reject|accept> <needle> <mutator run inside $TMP>
run_case() {
  local name="$1" expect="$2" needle="$3" mutator="$4" out rc why=""
  cp "$SRC_COMPOSE" "$TMP/compose.yml"; cp "$SRC_CONF" "$TMP/app.conf"
  ( cd "$TMP" && eval "$mutator" ) || { printf '  \033[31mFAIL\033[0m %s — mutator errored\n' "$name"; FAIL=$((FAIL+1)); return; }
  out=$("$CHECK" --app "$APP" --compose "$TMP/compose.yml" --conf "$TMP/app.conf" 2>&1); rc=$?

  if [ "$expect" = reject ]; then
    [ "$rc" -eq 0 ] && why="accepted a broken app"
    [ -z "$why" ] && [ -n "$needle" ] && ! grep -qF "$needle" <<< "$out" && why="rejected, but not for '$needle'"
  else
    [ "$rc" -ne 0 ] && why="rejected a valid app"
  fi

  if [ -z "$why" ]; then
    printf '  \033[32mok\033[0m   %s\n' "$name"; PASS=$((PASS+1))
  else
    printf '  \033[31mFAIL\033[0m %s — %s\n' "$name" "$why"
    sed 's/^/         /' <<< "$out" | head -14; FAIL=$((FAIL+1))
  fi
}

py() { printf "python3 -c \"%s\"" "$1"; }

printf '\033[1mcheck-app.sh self-test\033[0m  (reference: %s, app: %s)\n' "$REF" "$APP"

run_case "published ports are rejected" reject "publishes ports" \
  "$(py "
import yaml
d=yaml.safe_load(open('compose.yml'))
next(iter(d['services'].values()))['ports']=['8080:80']
yaml.safe_dump(d, open('compose.yml','w'))")"

run_case "non-external edge network is rejected" reject "not external" \
  "$(py "
import yaml
d=yaml.safe_load(open('compose.yml'))
d['networks']['edge']={'name':'edge'}
yaml.safe_dump(d, open('compose.yml','w'))")"

run_case "wrongly-named edge network is rejected" reject "expected 'edge'" \
  "$(py "
import yaml
d=yaml.safe_load(open('compose.yml'))
d['networks']['edge']={'name':'shared','external':True}
yaml.safe_dump(d, open('compose.yml','w'))")"

run_case "missing app-prefixed alias is rejected" reject "app-prefixed alias" \
  "$(py "
import yaml
d=yaml.safe_load(open('compose.yml'))
for s in d['services'].values():
    e=(s.get('networks') or {}).get('edge')
    if isinstance(e,dict) and e.get('aliases'):
        e['aliases']=['backend']; break
yaml.safe_dump(d, open('compose.yml','w'))")"

run_case "missing healthcheck on the gated service is rejected" reject "no healthcheck" \
  "$(py "
import yaml
d=yaml.safe_load(open('compose.yml'))
d['services']['backend'].pop('healthcheck',None)
yaml.safe_dump(d, open('compose.yml','w'))")"

run_case "floating image tag is rejected" reject "IMAGE_TAG" \
  "$(py "
import yaml
d=yaml.safe_load(open('compose.yml'))
next(iter(d['services'].values()))['image']='ghcr.io/x/y:latest'
yaml.safe_dump(d, open('compose.yml','w'))")"

run_case "literal proxy_pass is rejected" reject "literal host" \
  "sed -i '0,/proxy_pass \\\$/s//proxy_pass http:\\/\\/some-backend:8000; #/' app.conf"

run_case "certificate not matching server_name is rejected" reject "does not match server_name" \
  "sed -i 's#/live/[^/]*/#/live/somewhere-else/#g' app.conf"

run_case "missing security headers is rejected" reject "security-headers" \
  "sed -i '/security-headers.inc/d' app.conf"

run_case "missing exact-match sibling warns but does not block" accept "" \
  "sed -i '/^\\s*location = /,/^\\s*}/d' app.conf"

run_case "the unmodified reference passes" accept "" "true"

# The flag, not the file, is what is wrong here — nothing to mutate.
out=$("$CHECK" --app "$APP" --compose "$SRC_COMPOSE" --health-service nope 2>&1)
if [ $? -ne 0 ] && grep -qF "not a service" <<< "$out"; then
  printf '  \033[32mok\033[0m   unknown health_service is rejected\n'; PASS=$((PASS+1))
else
  printf '  \033[31mFAIL\033[0m unknown health_service was accepted\n'; FAIL=$((FAIL+1))
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
