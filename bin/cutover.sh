#!/usr/bin/env bash
#
# One-time migration from the single-app stack (~/opt/silence, nginx bundled
# with the app, certbot standalone) to the shared edge.
#
# Run it ON THE HOST, from a checkout of this repo:
#
#     rsync -av --exclude .git ~/docker/tezcat-edge/ user@tezcat.fr:opt/edge-src/
#     ssh user@tezcat.fr
#     cd ~/opt/edge-src && ./bin/cutover.sh preflight
#
# Phases are invoked one at a time and never chain. Everything before `swap` is
# reversible and leaves the running site untouched; `swap` is the only step with
# an outage, and `rollback` undoes it.
#
#   preflight   check every assumption, change nothing
#   backup      copy the live users.db off the volume
#   prepare     network, directories, edge config  (no downtime)
#   stage       confirm the new images are pullable (no downtime)
#   swap        THE OUTAGE: old stack down, edge + app up, ludo cert, fragment in
#   verify      prove the result
#   rollback    put the old stack back
#
set -euo pipefail

APP=silence
DOMAIN=ludo.tezcat.fr
APEX=tezcat.fr
APP_DIR="$HOME/opt/$APP"
EDGE_DIR="$HOME/opt/edge"
BACKUP_DIR="$HOME/backups"
OLD_COMPOSE="$APP_DIR/docker-compose.prod.yml"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ok()   { printf '  \033[32mok\033[0m   %s\n' "$*"; }
warn() { printf '  \033[33mwarn\033[0m %s\n' "$*"; }
die()  { printf '  \033[31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1m%s\033[0m\n' "$*"; }

need() { command -v "$1" >/dev/null || die "$1 is not installed"; }

phase_preflight() {
  step "Preflight — nothing is modified"
  need docker; need certbot; need openssl; ok "docker, certbot, openssl present"

  [ -d "$SRC/conf.d" ] || die "run this from a checkout of tezcat-edge (no conf.d/ at $SRC)"
  ls "$SRC"/conf.d/0*.conf >/dev/null 2>&1 || die "no 0*.conf in $SRC/conf.d"
  ok "edge config found at $SRC"

  # The old stack must still be the thing serving, or we are not in the state
  # this script was written for.
  [ -f "$OLD_COMPOSE" ] || die "no $OLD_COMPOSE — is the old stack already gone?"
  docker compose -f "$OLD_COMPOSE" ps --status running -q | grep -q . \
    || warn "old stack is not running"
  ok "old stack at $OLD_COMPOSE"

  # Data continuity depends on this exact volume name surviving. It is derived
  # from the compose project, which is the directory basename.
  docker volume inspect "${APP}_backend_data" >/dev/null 2>&1 \
    || die "volume ${APP}_backend_data missing — the project name is not '$APP'"
  ok "volume ${APP}_backend_data present"

  [ -f "$APP_DIR/backend_secrets.env" ] || die "no $APP_DIR/backend_secrets.env"
  grep -q "^RESET_BASE_URL=https://$DOMAIN" "$APP_DIR/backend_secrets.env" \
    || warn "RESET_BASE_URL is not https://$DOMAIN — invite and reset links will point at the old origin"
  ok "backend_secrets.env present"

  # The apex certificate is the one the edge needs in order to start at all:
  # 02-apex.conf references it, and nginx will not start with a missing path.
  [ -r "/etc/letsencrypt/live/$APEX/fullchain.pem" ] \
    || sudo test -r "/etc/letsencrypt/live/$APEX/fullchain.pem" \
    || die "no certificate for $APEX"
  ok "certificate for $APEX"

  getent hosts "$DOMAIN" >/dev/null || die "$DOMAIN does not resolve"
  ok "$DOMAIN resolves"

  if sudo test -r "/etc/letsencrypt/live/$DOMAIN/fullchain.pem"; then
    ok "certificate for $DOMAIN already issued"
  else
    warn "no certificate for $DOMAIN yet — 'swap' issues it by webroot"
  fi

  step "Preflight passed. Next: ./bin/cutover.sh backup"
}

phase_backup() {
  step "Backup"
  mkdir -p "$BACKUP_DIR"
  local out="$BACKUP_DIR/users.db.$(date +%Y%m%d-%H%M%S)"
  docker run --rm -v "${APP}_backend_data:/data:ro" -v "$BACKUP_DIR:/out" \
    busybox cp /data/users.db "/out/$(basename "$out")"
  [ -s "$out" ] || die "backup is empty"
  ok "$(du -h "$out" | cut -f1) -> $out"
  step "Next: ./bin/cutover.sh prepare"
}

phase_prepare() {
  step "Prepare — no downtime, the old stack keeps serving"

  docker network inspect edge >/dev/null 2>&1 || docker network create edge >/dev/null
  ok "docker network 'edge'"

  mkdir -p "$EDGE_DIR/conf.d/snippets" "$EDGE_DIR/certbot"
  cp "$SRC/compose.yaml" "$EDGE_DIR/compose.yaml"
  cp "$SRC"/conf.d/0*.conf "$EDGE_DIR/conf.d/"
  cp "$SRC"/conf.d/snippets/*.inc "$EDGE_DIR/conf.d/snippets/"
  ok "edge config installed at $EDGE_DIR"

  # Deliberately NOT copying any 1*.conf: app fragments are owned and shipped by
  # each app's own pipeline. Copying one here would give it two writers.
  if ls "$EDGE_DIR"/conf.d/1*.conf >/dev/null 2>&1; then
    warn "app fragments already present: $(ls "$EDGE_DIR"/conf.d/1*.conf | xargs -n1 basename | tr '\n' ' ')"
  fi

  # Validate before it can ever matter. Only the apex cert is referenced by 0*,
  # so this passes before ludo's certificate exists.
  docker run --rm \
    -v "$EDGE_DIR/conf.d:/etc/nginx/conf.d:ro" \
    -v /etc/letsencrypt:/etc/letsencrypt:ro \
    nginx:alpine nginx -t >/dev/null 2>&1 \
    || die "edge config does not pass nginx -t"
  ok "edge config passes nginx -t"

  step "Next: ./bin/cutover.sh stage"
}

phase_stage() {
  step "Stage — confirm the new images exist, still no downtime"

  [ -f "$APP_DIR/compose.yml" ] || die "no $APP_DIR/compose.yml — run the app's CI (workflow_dispatch on the branch builds images without deploying), then scp deploy/compose.yml here"
  [ -f "$APP_DIR/.env" ] || die "no $APP_DIR/.env with IMAGE_TAG=<sha>"
  grep -q '^IMAGE_TAG=.\+' "$APP_DIR/.env" || die "IMAGE_TAG is empty in $APP_DIR/.env"
  ok "compose.yml and .env present ($(grep '^IMAGE_TAG=' "$APP_DIR/.env"))"

  docker info 2>/dev/null | grep -q 'ghcr.io' \
    || warn "not logged in to ghcr.io — run: docker login ghcr.io -u <you>"

  # Pull now, while the old stack is still up. This is the slow part, and doing
  # it inside the outage window would stretch it by minutes.
  ( cd "$APP_DIR" && docker compose -f compose.yml pull ) || die "could not pull images"
  ok "images pulled"

  step "Next: ./bin/cutover.sh swap   <- this one takes the site down briefly"
}

phase_swap() {
  step "Swap — the outage starts here"
  printf '  This stops the running site. Type SWAP to continue: '
  read -r confirm
  [ "$confirm" = SWAP ] || die "aborted"

  # 1. Free :80 and :443.
  docker compose -f "$OLD_COMPOSE" down --remove-orphans
  ok "old stack down"

  # 2. Edge up with 0* only. It has no ludo fragment yet, so it needs only the
  #    apex certificate — which is what breaks the chicken-and-egg: the edge
  #    must serve :80 for the webroot challenge that issues ludo's certificate.
  ( cd "$EDGE_DIR" && docker compose -f compose.yaml up -d )
  sleep 2
  docker ps --filter name=edge-nginx --filter status=running -q | grep -q . \
    || { docker logs --tail=50 edge-nginx; die "edge did not start"; }
  ok "edge up on :80/:443"

  # 3. Certificate for the app's subdomain, by webroot, with no further downtime.
  if ! sudo test -r "/etc/letsencrypt/live/$DOMAIN/fullchain.pem"; then
    sudo certbot certonly --webroot -w "$EDGE_DIR/certbot" -d "$DOMAIN" \
      --non-interactive --agree-tos --register-unsafely-without-email \
      || die "certbot failed for $DOMAIN"
    ok "certificate issued for $DOMAIN"
  else
    ok "certificate for $DOMAIN already present"
  fi

  # 4. App stack. No ports published — it is reached only through the edge.
  ( cd "$APP_DIR" && docker compose -f compose.yml up -d --remove-orphans )
  ok "app stack up"

  # 5. Fragment last: it references the certificate from step 3, and nginx will
  #    not start with a missing ssl_certificate path.
  cp "$APP_DIR/silence.conf" "$EDGE_DIR/conf.d/10-$APP.conf" 2>/dev/null \
    || die "expected $APP_DIR/silence.conf (scp deploy/silence.conf there first)"
  docker exec edge-nginx nginx -t || die "fragment does not pass nginx -t; site is still up on the 0* config"
  docker kill -s HUP edge-nginx >/dev/null
  ok "fragment installed, edge reloaded"

  step "Outage over. Next: ./bin/cutover.sh verify"
}

phase_verify() {
  step "Verify"
  local base="https://$DOMAIN/$APP/"

  docker ps --filter name=edge-nginx --filter status=running -q | grep -q . \
    && ok "edge running" || die "edge not running"

  ( cd "$APP_DIR" && docker compose -f compose.yml ps )

  curl -fsS -o /dev/null -w '  app          -> %{http_code}\n' "$base" \
    || die "app is not answering at $base"

  curl -fsS -o /dev/null -w '  hsts+headers -> %{http_code}\n' "$base"
  curl -sI "$base" | grep -iq strict-transport-security \
    && ok "security headers present" || warn "no HSTS header"

  curl -s -o /dev/null -w '  apex redirect-> %{http_code} -> %{redirect_url}\n' \
    "https://$APEX/$APP/"

  # The whole point of the restructure: renewal must not need a restart.
  sudo certbot renew --dry-run >/dev/null 2>&1 \
    && ok "certbot renew --dry-run passes" \
    || warn "certbot renew --dry-run FAILED — fix before the next renewal window"

  step "If all of the above is good, merge the PR: the pipeline re-applies this same state and proves itself."
}

phase_rollback() {
  step "Rollback to the old stack"
  ( cd "$EDGE_DIR" && docker compose -f compose.yaml down ) || true
  ( cd "$APP_DIR" && docker compose -f compose.yml down ) || true
  [ -f "$OLD_COMPOSE" ] || die "$OLD_COMPOSE is gone — cannot roll back this way"
  docker compose -f "$OLD_COMPOSE" up -d
  ok "old stack restored (data was never touched: ${APP}_backend_data is shared)"
}

case "${1:-}" in
  preflight|backup|prepare|stage|swap|verify|rollback) "phase_${1}" ;;
  *) sed -n '2,25p' "$0" | sed 's/^#//'; exit 1 ;;
esac
