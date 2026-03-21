# cn-root-docker

Docker Compose stack for the VPS control plane. Runs on an EC2 instance provisioned by `cn-root` (AWS CDK).

## Services

| Service | Description |
|---|---|
| `traefik-public` | Public TLS termination for Headscale (port 443) |
| `headscale` | Tailscale-compatible control plane |
| `ts-infra` | Tailscale sidecar providing the private tailnet network namespace |
| `traefik-lab` | Private ingress (Consul-driven), bound to tailnet only |
| `coredns` | Authoritative DNS for `<LAB_DOMAIN>`, bound to tailnet only |
| `consul` | Service registry, bound to tailnet only |
| `prometheus` | Metrics scraper, bound to tailnet only |
| `grafana` | Dashboards, bound to tailnet only |

## Configuration

### 1. Create `.env`

Run the interactive setup script — it will prompt for each variable and generate the config files from templates:

```sh
./setup.sh
```

Or copy manually and fill in the values:

```sh
cp .env.example .env
```

### 2. Variable reference

The four domain variables are related — here is an example using `example.com` as the apex domain:

| Variable | Example value | What it controls |
|---|---|---|
| `ROOT_DOMAIN` | `example.com` | Apex domain. All other domains are subdomains of this. |
| `LAB_DOMAIN` | `lab.example.com` | Internal lab services accessible on the tailnet: `grafana.lab.example.com`, `consul.lab.example.com`, etc. Must be `lab.<ROOT_DOMAIN>` — the config files hardcode the `lab.` prefix. |
| `HEADSCALE_DOMAIN` | `hs.example.com` | Public hostname for the Headscale control plane. Must be `hs.<ROOT_DOMAIN>` — the Headscale config hardcodes the `hs.` prefix when building its `server_url`. |
| `TAILNET_DOMAIN` | `ts.example.com` | MagicDNS base domain assigned to tailnet machines (e.g. `my-laptop.ts.example.com`). Must be `ts.<ROOT_DOMAIN>` — the Headscale config hardcodes the `ts.` prefix for `base_domain`. |

| Variable | Where to get it |
|---|---|
| `ADMIN_EMAIL` | Your email — used by Let's Encrypt for certificate expiry notices. |
| `CF_DNS_API_TOKEN` | A Cloudflare **API Token** with DNS edit permissions — create one at My Profile → API Tokens → Create Token, using the "Edit zone DNS" template. |
| `VPS_PUBLIC_IP` | The Elastic IP assigned to the EC2 instance after `cn-root` CDK deploy. |
| `INFRA_AUTHKEY` | A Headscale pre-auth key. Generated during bring-up (see below). |
| `VPS_TAILNET_IP` | The tailnet IP of the VPS. Discovered after `ts-infra` starts (see below). |
| `GF_ADMIN_PASSWORD` | Password for the Grafana `admin` user. Choose any strong password. |
| `GOOGLE_OIDC_CLIENT_ID` | OAuth 2.0 Client ID from Google Cloud Console (used for Headscale login). |
| `GOOGLE_OIDC_CLIENT_SECRET` | OAuth 2.0 Client Secret from Google Cloud Console. |
| `GOOGLE_OIDC_ALLOWED_USERS` | Comma-separated list of Google account emails allowed to log in (e.g. `alice@gmail.com,bob@gmail.com`). |

---

## Bring-up sequence

Bring-up happens in two passes because `ts-infra` needs a Headscale auth key, which can only be created after Headscale is running — and several services need the VPS tailnet IP, which only exists after `ts-infra` has joined the network.

### Before you start — create the DNS A record

Traefik only handles TLS certificates — it does **not** create DNS records. You must manually create an A record in Cloudflare pointing `HEADSCALE_DOMAIN` to your VPS public IP before starting the stack, otherwise the certificate challenge will succeed but the domain will be unreachable.

In the Cloudflare dashboard for your domain, add:

| Type | Name | Content | Proxy status |
|---|---|---|---|
| A | `hs` (or whatever `HEADSCALE_DOMAIN` is) | `VPS_PUBLIC_IP` | DNS only (grey cloud) |

Proxy must be **DNS only** — Cloudflare's proxy (orange cloud) intercepts port 443 and will break Headscale's gRPC and DERP traffic.

### Pass 1 — public plane

**On the VPS** (after CDK deploy):

```sh
git clone https://github.com/<ORG>/cn-root-docker /opt/cloudnet
cd /opt/cloudnet
./setup.sh   # fill in everything except INFRA_AUTHKEY and VPS_TAILNET_IP
docker compose up -d traefik-public headscale
```

Wait for Traefik to obtain a TLS certificate (check `docker compose logs traefik-public`), then create a Headscale user and generate a pre-auth key for `ts-infra`:

```sh
docker exec -it cloudnet-headscale-1 headscale users create admin
docker exec -it cloudnet-headscale-1 headscale preauthkeys create --user 1 --tags tag:infra --reusable --expiration 1h
```

Copy the key that's printed, then add it to `.env`:

```
INFRA_AUTHKEY=<paste key here>
```

### Pass 2 — tailnet plane

```sh
docker compose up -d ts-infra consul traefik-lab coredns prometheus grafana
```

Once `ts-infra` is up, get its tailnet IP:

```sh
docker exec cloudnet-ts-infra-1 tailscale ip -4
```

Add that IP to `.env` as `VPS_TAILNET_IP`, then re-run setup to regenerate the config files that reference it:

```sh
./setup.sh
docker compose restart headscale coredns
```

At this point all services are running. Verify with `docker compose ps`.

---

## Troubleshooting

### Tailscale running in userspace mode (no `tailscale0` interface)

Services in the shared ts-infra namespace (traefik-lab, consul, coredns) need Tailscale in kernel mode to make outbound tailnet connections and to receive inbound traffic on arbitrary ports. If `tailscale0` is missing, the networking won't work:

```sh
docker exec cloudnet-ts-infra-1 ip addr show tailscale0
# "Device does not exist" → userspace mode
```

Fix: ensure `ts-infra` has both of these env vars in `docker-compose.yml`:

```yaml
- TS_USERSPACE=false
- TS_TAILSCALED_EXTRA_ARGS=--tun=tailscale0
```

Newer versions of the Tailscale container image ignore `TS_USERSPACE=false` alone — the extra arg is needed to override the hardcoded `--tun=userspace-networking` flag that containerboot passes.

---

### Services stuck in stale network namespace after ts-infra restart

When `ts-infra` restarts (new container = new network namespace), services that use `network_mode: "service:ts-infra"` keep running but are attached to the old, orphaned namespace. Symptoms: `ip addr` inside the service shows only `lo`, no `eth0` or `tailscale0`:

```sh
docker exec cloudnet-consul-1 ip addr
# Only lo → stale namespace
```

Fix: restart all dependent services so they re-attach to the current ts-infra namespace:

```sh
docker compose up -d consul traefik-lab coredns prometheus grafana
```

---

### Split DNS not pushed to clients (`lab.<ROOT_DOMAIN>` doesn't resolve)

The `split` key in `headscale/config.yaml.tmpl` must be **inside** `nameservers`, not alongside it. If it is a sibling of `nameservers`, Headscale silently ignores it and clients only get the global resolvers:

```yaml
# Wrong
dns:
  nameservers:
    global: [...]
  split:             # ← sibling of nameservers
    "lab.x.com": [...]

# Correct
dns:
  nameservers:
    global: [...]
    split:           # ← nested inside nameservers
      "lab.x.com": [...]
```

After fixing the template, re-run `./setup.sh` and restart headscale.

---

### `infra-vps` node not tagged — tailnet traffic blocked

The ACL only opens ports 53 and 443 to nodes with `tag:infra`. If the VPS node has no tags, all tailnet traffic (DNS and HTTPS) is silently dropped. Check:

```sh
docker exec cloudnet-headscale-1 headscale nodes list
# Tags column should show tag:infra for infra-vps
```

Fix — apply the tag manually if it is missing:

```sh
docker exec cloudnet-headscale-1 headscale nodes tag --identifier 1 --tags tag:infra
```

To avoid this on future bring-ups, create the pre-auth key with `--tags tag:infra` (already documented in the bring-up sequence above).

---

### iOS DNS caching causes apparent resolution failures

After fixing DNS or changing tailnet configuration, iOS aggressively caches old results. Reconnecting Tailscale does not always flush the DNS cache. Symptoms: CoreDNS logs show `NOERROR` for queries from the iPhone, but Safari says the site can't be reached.

Fix: force-quit the Tailscale app on the iPhone, reopen it, then try again. As a last resort, toggle Airplane Mode on and off.

---

### Headscale ACL: `autogroup:member` not supported

Headscale does not support Tailscale's built-in `autogroup:member`. Tag owners must be explicit email addresses (matching your OIDC identity), and ACL sources must use `"*"` for "any node":

```json
// Wrong
"tagOwners": { "tag:infra": ["autogroup:member"] }

// Correct
"tagOwners": { "tag:infra": ["you@example.com"] }
```

---

### `headscale preauthkeys create --user` requires a numeric ID

Newer Headscale versions changed `--user` to accept a numeric ID, not a name:

```sh
docker exec cloudnet-headscale-1 headscale users list   # get the ID
docker exec cloudnet-headscale-1 headscale preauthkeys create --user <ID> --tags tag:infra --reusable --expiration 1h
```

---

### traefik-lab has no routes despite services being in Consul

If `docker logs cloudnet-traefik-lab-1` is empty and the API shows no routes, first confirm the service is actually running and its API is reachable (the Traefik container image does not include `curl`):

```sh
docker exec cloudnet-ts-infra-1 wget -qO- http://127.0.0.1:8080/api/overview
```

If the API responds with providers showing `ConsulCatalog` but routes are still missing, check that Consul itself has the services registered:

```sh
docker exec cloudnet-consul-1 curl -s http://127.0.0.1:8500/v1/catalog/services
```

If Consul is empty, the `vps-services.json` config file may not have been generated — re-run `./setup.sh`.
