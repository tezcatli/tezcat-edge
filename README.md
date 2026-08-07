# tezcat-edge

The shared nginx reverse proxy on `tezcat.fr`. It owns `:80` and `:443`, terminates TLS,
and routes each hostname to an application that runs in its own compose project.

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

## Who owns what in `conf.d/`

Two writers share this directory, so the prefix decides ownership:

| Prefix | Owner | Deployed by |
|---|---|---|
| `0*.conf` | this repo | `workflow_dispatch`, rarely |
| `snippets/*.inc` | this repo | same |
| `1*.conf` | the app it names | that app's own pipeline, on every deploy |

**Deploying this repo must never `rsync --delete` across `conf.d/`** — it would erase every
app fragment. Sync the `0*` prefix and the snippets, nothing else.

## The app contract

An app that wants to sit behind this edge provides five things, and needs no change here:

1. **A subdomain** `<app>.tezcat.fr`, CNAME'd to this host, **with its own certificate**.
2. **Images** at `ghcr.io/tezcatli/<app>-<component>`, tagged with the commit SHA.
3. **A compose file** landing at `~/opt/<app>/compose.yml`: publishes **no ports**, joins the
   external `edge` network under an **app-prefixed alias**, reads `IMAGE_TAG` from `.env`.
4. **An nginx fragment** shipped to `~/opt/edge/conf.d/10-<app>.conf` — one `443` server
   block for its subdomain.
5. **A deploy job** calling `.github/workflows/deploy-app.yml` from this repo.

### Prefixed aliases are mandatory, not cosmetic

Compose publishes the bare service name as a network alias on every network a service joins.
If two apps each have a service called `backend`, both answer to `backend` on the `edge`
network and Docker resolves it **round-robin across applications** — requests for one app
land in another, intermittently. Give each service an explicit `<app>-<service>` alias and
route to that; keep the app's own `default` network for intra-app traffic.

```yaml
services:
  backend:
    networks:
      default:
      edge: { aliases: [myapp-backend] }
networks:
  default:
  edge: { name: edge, external: true }
```

### Fragments must resolve upstreams at request time

`proxy_pass http://myapp-backend:8000;` resolves the name **when nginx starts**. If that
container is down at the moment the edge restarts, nginx fails to start and *every* app goes
dark. `00-defaults.conf` provides the Docker resolver; use it through a variable:

```nginx
set $up myapp-backend:8000;
proxy_pass http://$up;
```

A missing app then 502s on its own routes only, and recovers by itself within the DNS TTL.
With a variable and no URI part, nginx forwards the original request URI unchanged.

### Security headers

`include /etc/nginx/conf.d/snippets/security-headers.inc;` at **server** level. nginx's
`add_header` does not merge across levels — a location that adds any header of its own drops
every inherited one, so either add none (the normal case) or re-include the snippet there.

## Adding an application

```bash
# 1. DNS: CNAME myapp.tezcat.fr -> main.tezcat.fr

# 2. Certificate. No edge config change is needed for this — 01-acme.conf serves
#    the challenge for every hostname. Issue it BEFORE the fragment lands:
#    nginx will not start with an ssl_certificate path that does not exist.
sudo certbot certonly --webroot -w /home/user/opt/edge/certbot -d myapp.tezcat.fr

# 3+4. The app's own pipeline ships compose.yml and 10-myapp.conf, then:
ssh user@tezcat.fr "docker exec edge-nginx nginx -t && docker kill -s HUP edge-nginx"
```

## Migrating an existing single-app host

`bin/cutover.sh` handles the one-time move from a stack that bundled its own nginx and
renewed with certbot's standalone authenticator. Phases are invoked one at a time and
never chain; everything before `swap` leaves the running site untouched.

```bash
rsync -av --exclude .git ~/docker/tezcat-edge/ user@tezcat.fr:opt/edge-src/
# the app's own compose.yml, .env and nginx fragment go next to each other:
scp deploy/compose.yml deploy/silence.conf user@tezcat.fr:opt/silence/
ssh user@tezcat.fr 'cd ~/opt/edge-src && ./bin/cutover.sh preflight'
```

It exists because two orderings are easy to get wrong and expensive to get wrong:

- **The certificate must precede the fragment.** nginx will not start with an
  `ssl_certificate` path that does not exist, so the edge comes up on the `0*` config
  alone — which needs only the apex certificate — serves the webroot challenge, and only
  then takes the app fragment.
- **Images must be pulled before the outage**, not during it. `stage` does that while the
  old stack is still serving, which is the difference between a minute of downtime and
  several.

## Host setup (once)

```bash
docker network create edge
mkdir -p ~/opt/edge/{conf.d,certbot}
# ... place compose.yaml + conf.d/0* from this repo ...
docker compose -f ~/opt/edge/compose.yaml up -d
```

### Certificates

`webroot`, not `standalone`. The challenge file is served by the running edge, so **renewal
never stops anything**. The previous setup stopped nginx to free `:80`
(`pre_hook = docker stop ...`), which with more than one app would take every app down on
every renewal.

```bash
sudo certbot certonly --webroot -w /home/user/opt/edge/certbot -d tezcat.fr
```

Each `/etc/letsencrypt/renewal/*.conf` should have `authenticator = webroot`, a
`webroot_path`, and **no `pre_hook` / `post_hook`**. Reloading is one shared deploy hook,
`/etc/letsencrypt/renewal-hooks/deploy/reload-edge.sh`:

```sh
#!/bin/sh
docker kill -s HUP edge-nginx
```

A reload, not a restart: if it fails, nginx keeps serving with the certificate it already
has rather than the host going dark. This is the only place that depends on the container
being named `edge-nginx` — hence the explicit `container_name` in `compose.yaml`.

Check it with `sudo certbot renew --dry-run`.

## Operations

```bash
# What is running
docker compose -f ~/opt/edge/compose.yaml ps

# Apply a config change (never restart — reload)
docker exec edge-nginx nginx -t && docker kill -s HUP edge-nginx

# Which apps are on the network
docker network inspect edge --format '{{range .Containers}}{{.Name}} {{end}}'
```
