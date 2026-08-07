# tezcat-edge

The shared nginx reverse proxy on `tezcat.fr`. It owns `:80` and `:443`, terminates TLS, and
routes each hostname to an application running in its own compose project.

It builds no image — the container is stock `nginx:alpine` with `conf.d/` bind-mounted, so
changing routing is editing a file and reloading, not building and shipping.

```
  :80/:443 ──▶ edge-nginx                                   ~/opt/edge/
                · conf.d/00-defaults.conf   http-level         compose.yaml
                · conf.d/01-acme.conf       :80 + ACME         conf.d/
                · conf.d/02-apex.conf       tezcat.fr          certbot/
                · conf.d/10-silence.conf    ludo.tezcat.fr  ← cors-proxy repo
                · conf.d/10-<app>.conf      <app>.tezcat.fr ← that app's repo
                        │
              docker network "edge" (external)
              ┌─────────┴──────────┬──────────────┐
              ▼                    ▼              ▼
        silence-web          silence-backend    <app>-*
```

Two audiences: **[Adding an app](#adding-an-app)** and
**[Operating the edge](#operating-the-edge)**.

---

# Adding an app

## The contract

Copy `template/` — `compose.yml`, `app.conf` and `ci.yml` are a complete working app, not
snippets. Replace `myapp` throughout. `bin/check-app.sh` enforces the rules and the deploy
runs it before shipping anything, so a violation fails the deploy rather than surfacing in
production a week later.

Check your app before you push:

```bash
./bin/check-app.sh --app myapp \
  --compose ../myapp/deploy/compose.yml \
  --conf    ../myapp/deploy/myapp.conf \
  --health-service backend
```

In short, an app provides:

1. **A subdomain** `<app>.tezcat.fr`, CNAME'd to this host, **with its own certificate**.
2. **Images** at `ghcr.io/tezcatli/<app>-<component>`, tagged with the commit SHA.
3. **A compose file** at `~/opt/<app>/compose.yml`: no published ports, joins the external
   `edge` network under an `<app>-`prefixed alias, reads `IMAGE_TAG` from `.env`.
4. **An nginx fragment** shipped to `~/opt/edge/conf.d/10-<app>.conf`.
5. **A deploy job** calling `.github/workflows/deploy-app.yml` from this repo.

## Checklist

Order matters in one place, and getting it wrong takes down every app on the host, so it is
stated once, here:

```bash
# 1. DNS
#    CNAME myapp.tezcat.fr -> main.tezcat.fr

# 2. Certificate — BEFORE the fragment ever lands.
#    nginx will not start with an ssl_certificate path that does not exist, and
#    it fails the whole edge, not just your app. No edge config change is needed:
#    01-acme.conf already serves the challenge for every hostname.
sudo certbot certonly --webroot -w /home/user/opt/edge/certbot -d myapp.tezcat.fr

# 3. Secrets — add all four to the app repo (see below).

# 4. Push to main. The pipeline checks the contract, builds, ships compose.yml
#    and 10-myapp.conf, reloads the edge, and gates on health.
```

## Secrets

Every app repo needs its own copies — `tezcatli` is a personal account, so there are no
organisation-level secrets to inherit. `deploy-app.yml` declares none of its own and reads
the caller's, which is why the calling job needs `secrets: inherit`.

| Secret | Value |
|---|---|
| `DEPLOY_HOST` | the host to ssh to |
| `DEPLOY_USER` | the ssh user |
| `DEPLOY_SSH_KEY` | private key, **with a trailing newline** — without one the key file is silently invalid and the failure looks like a permissions problem |
| `DEPLOY_KNOWN_HOSTS` | the pinned host key |

**`DEPLOY_KNOWN_HOSTS` must pin the name `DEPLOY_HOST` holds** — not your app's subdomain,
and not whichever name you happen to use interactively. This host answers to several
(`tezcat.fr`, `main.tezcat.fr`, per-app subdomains, its IPs) and they share one key, so the
safe move is to pin them all:

```bash
for h in tezcat.fr main.tezcat.fr myapp.tezcat.fr <ip>; do ssh-keyscan -t ed25519 "$h"; done
```

Getting this wrong fails at the first `scp` with `Host key verification failed`, before
anything reaches the host. It is pinned rather than `ssh-keyscan`'d at run time because
keyscan re-trusts whatever answers DNS on every run and then hands it the deploy key.

**Repo visibility**: a *private* app repo may call this public reusable workflow. The
reverse — a public caller and a private workflow repo — is refused by GitHub, whose sharing
setting reads "access is allowed only from private repositories".

## Traps, by symptom

Every one of these is invisible until production, and none of them points at its own cause.
That is why they are checked mechanically rather than only described.

| Symptom | Cause | Fix |
|---|---|---|
| Intermittent 502s, sometimes serving **another app's** response | Two apps expose the same bare service name on `edge`; compose publishes it as an alias and Docker round-robins between them | Give every service an `<app>-`prefixed alias and route only to that |
| **The whole edge won't start** — every app down, after a restart unrelated to any change | A literal `proxy_pass http://name:port`, resolved once at startup; if that container is down nginx refuses to boot | `set $up name:port; proxy_pass http://$up;` — the resolver in `00-defaults.conf` then looks it up per request |
| An API call returns **200 with HTML** | A prefix `location /api/` never matches bare `/api`, which falls through to the SPA catch-all | Add `location = /api` beside it |
| nginx refuses to start after adding an app | `ssl_certificate` points at a path that does not exist | Issue the certificate before the fragment lands |
| HSTS and friends silently missing on some routes | `add_header` does not merge across levels — a location that sets any header drops every inherited one | Include `snippets/security-headers.inc` at **server** level, and re-include it in any location that adds headers of its own |
| Deploy green, app dead | The gated service has no healthcheck, so the gate passed on container creation | Give `health_service` a real healthcheck |
| Rollback impossible | Image pinned to `:latest` | Use `${IMAGE_TAG:?}`; rollback is re-pinning `.env` |

---

# Operating the edge

## Who owns what in `conf.d/`

Two writers share this directory, so the prefix decides ownership:

| Prefix | Owner | Deployed by |
|---|---|---|
| `0*.conf`, `snippets/*.inc`, `compose.yaml` | this repo | **`deploy-edge.yml`** (`workflow_dispatch`) |
| `1*.conf` | the app it names | that app's own pipeline, on every deploy |

**Nothing may `--delete` across `conf.d/`** — it would erase every app fragment and 502 every
app until each redeployed. `deploy-edge.yml` copies its files individually and prints the
surviving `1*.conf` list afterwards as a standing assertion.

**`deploy-edge.yml` needs its own copies of the four `DEPLOY_*` secrets, in *this* repo.**
`deploy-app.yml` is reusable and therefore runs in the calling app's context, inheriting that
repo's secrets; this one is dispatched here and inherits nothing. They are the same four
values listed under [Secrets](#secrets), and the workflow fails with a named error if any is
missing rather than letting `ssh` print its usage at you.

A change to this repo is **not** picked up by an app's deploy. An app deploy reloads the
edge, but only ships its own fragment. Editing `02-apex.conf` and waiting for an app deploy
to apply it is a real mistake that has already happened once — run `deploy-edge.yml`.

## Host setup (once)

```bash
docker network create edge
mkdir -p ~/opt/edge/{conf.d,certbot}
# then run deploy-edge.yml with restart: true
```

## Certificates

`webroot`, not `standalone`. The challenge file is served by the running edge, so **renewal
never stops anything**. The previous setup stopped nginx to free `:80`
(`pre_hook = docker stop ...`), which with more than one app takes every app down on every
renewal.

```bash
sudo certbot certonly --webroot -w /home/user/opt/edge/certbot -d tezcat.fr
```

Every `/etc/letsencrypt/renewal/*.conf` needs `authenticator = webroot`, a `webroot_path`,
and **no `pre_hook` / `post_hook`**. Reloading is one shared deploy hook,
`/etc/letsencrypt/renewal-hooks/deploy/reload-edge.sh`:

```sh
#!/bin/sh
docker kill -s HUP edge-nginx
```

A reload, not a restart: if it fails, nginx keeps serving the certificate it already has
rather than the host going dark. This is the only thing that depends on the container being
named `edge-nginx` — hence the explicit `container_name` in `compose.yaml`.

`bin/cutover.sh certs` converts any lingering `standalone` renewal and installs the hook; it
is idempotent. Check with `sudo certbot renew --dry-run`.

## Migrating an existing single-app host

`bin/cutover.sh` handles the one-time move from a stack that bundled its own nginx. Phases
are invoked one at a time and never chain; everything before `swap` leaves the running site
untouched, and `rollback` restores it.

```
preflight → backup → prepare → stage → swap → certs → verify
```

Two orderings it exists to enforce: the certificate must precede the fragment, and images
must be pulled *before* the outage rather than during it — the difference between a minute
of downtime and several.

## Operations

```bash
# What is running
docker compose -f ~/opt/edge/compose.yaml ps

# Apply a config change (never restart — reload)
docker exec edge-nginx nginx -t && docker kill -s HUP edge-nginx

# Which apps are on the network
docker network inspect edge --format '{{range .Containers}}{{.Name}} {{end}}'

# What an app has deployed
ssh user@tezcat.fr 'cat ~/opt/<app>/.env'
```

## Repo layout

| Path | What |
|---|---|
| `compose.yaml`, `conf.d/0*`, `conf.d/snippets/` | the edge itself |
| `template/` | a working app to copy |
| `bin/check-app.sh` | contract linter; runs on every app deploy |
| `bin/test-check-app.sh` | proves each rule rejects; runs in CI |
| `bin/cutover.sh` | one-time single-app migration |
| `.github/workflows/deploy-app.yml` | reusable, called by each app |
| `.github/workflows/deploy-edge.yml` | deploys this repo |
| `.github/workflows/validate.yml` | `nginx -t` + the checker's self-test |
