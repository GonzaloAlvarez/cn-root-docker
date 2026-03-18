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
docker exec -it cloudnet-headscale-1 headscale preauthkeys create --user 1 --reusable --expiration 1h
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
docker exec ts-infra tailscale ip -4
```

Add that IP to `.env` as `VPS_TAILNET_IP`, then re-run setup to regenerate the config files that reference it:

```sh
./setup.sh
docker compose restart headscale coredns
```

At this point all services are running. Verify with `docker compose ps`.
