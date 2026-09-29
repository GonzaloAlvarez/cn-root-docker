# `agent/` — forwarding-only API pinhole for external agents

External AI agents (any implementation, not on the tailnet, dynamic IPs) read and
write **one private Outline collection, `Memories`**, and nothing else, through
the already-public `hs.gn.al:22`. Nothing here is named after a specific agent:
the SSH account is `agent`, the gateway is `agent-api-gw`, the Outline identity
is `agent`; a *client* is just a label on a key line and a token name. Swapping
the memory backend later means replacing `gateway/backend-*.conf` and the
identity steps in `provision.sh` — the SSH side, the port and the client tunnel
command never change.

```
client ── ssh -N -L 127.0.0.1:8093:127.0.0.1:8093 agent@hs.gn.al ──▶ sshd Match User agent
   host key pinned                                                    │ MaxSessions 0 · PermitOpen 127.0.0.1:8093 only
                                                                      ▼
   POST http://127.0.0.1:8093/api/<method>  Bearer ol_api_… ──▶ agent-api-gw (nginx, bridge 172.18.0.6, loopback publish)
                                                                      │ POST+JSON only · exact allowlist · bearer shape · 512 KB · 10 r/s
                                                                      ▼ https://ts-infra:443  (Host/SNI outline.lab.gn.al, LE verified)
                                                                traefik-lab → 10.1.1.92:443 → Outline
                                                                      user `agent` = GUEST, read_write member of `Memories` only
```

Five independent layers; each alone stops a shell, a lateral move or an
out-of-scope write: (1) sshd Match + key options → one `direct-tcpip` to
`127.0.0.1:8093`; (2) gateway allowlist; (3) Outline Guest role; (4) API-key
scope = the same allowlist + 90-day expiry; (5) explicit collection membership.

## Layout

| Path | What |
|---|---|
| `provision.sh` | operator-side orchestrator (Mac, via the cn-socksnode SOCKS proxy) — see below |
| `lib/oidc-login.sh` | headless Outline login for `agent` through Authentik's flow-executor API |
| `gateway/nginx.conf` | backend-agnostic frame (limits, JSON-only, logging without secrets) |
| `gateway/backend-outline.conf` | **swap seam**: bearer shape (`ol_api_…`) + the exact-match method allowlist |
| `gateway/backend-outline-upstream.conf` | **swap seam**: Host/SNI/TLS towards traefik-lab |
| `gateway/api-endpoint.conf` | per-location guard: source IP, method, bearer, content-type, `proxy_pass $uri` |
| `sshd/50-agent.conf` | the `Match User agent` block |
| `sshd/authorized_keys` | registered client public keys (`ssh-ed25519 … client=<label>`) — public material |
| `sshd/install.sh` / `uninstall.sh` | root-level installer on the VPS with operator-lockout guards + auto-revert timer |
| `clients.md` | ledger: client, key fingerprint, token name, dates (never token values) |
| `../tailnet/prometheus/agent-rules.yml` | generated `AgentTokenExpiringSoon` rules (one per issued token) |

## Allowlist ≡ API-key scope (Outline backend)

`auth.info collections.list collections.info collections.documents documents.list
documents.info documents.search documents.create documents.update documents.archive
documents.restore documents.delete`

Excluded on purpose: `documents.move` (cross-collection), `documents.import`,
`documents.export`, `attachments.*` (uploads), `shares.*`, `apiKeys.*`, `users.*`,
`groups.*`, `team.*`, `events.*`, `revisions.*`, `views.*`, `/realtime`, all UI paths.
The gateway also refuses GET (405), missing/JWT-shaped bearers (401), non-JSON
(415), bodies > 512 KB (413), > 10 r/s (429), and any source other than the host
loopback publish (403). Traversal / `//` / `%2e` are normalised before matching
and only the normalised `$uri` is ever forwarded.

## Operator workflow (hand-off protocol)

Prerequisite for identity/token/revoke: an Outline **admin** API key
(Settings → API & Apps, scope `users.* collections.* apiKeys.* auth.info`,
1-day expiry) exported as `OUTLINE_ADMIN_TOKEN` (or `--admin-token-file`).
Delete it when done.

```sh
agent/provision.sh preflight                                    # proxy, neptune, VPS, Outline, Authentik, admin key
agent/provision.sh identity ensure                              # once: Authentik user → Outline Guest → Memories → verify → deactivate
agent/provision.sh ssh-key add ./client.pub --client <label>    # commit+push, install on the VPS, verify a NEW operator login, print host key
agent/provision.sh token issue --client <label>                 # prints the CLIENT BUNDLE once (host key, tunnel cmd, URL, token, allowlist)
agent/provision.sh test --client <label> --key ./client_key --token ol_api_…   # full positive/negative matrix from the Mac
agent/provision.sh token list | token revoke (--client <label> | <id> | --all)
agent/provision.sh ssh-key remove --client <label>              # or by fingerprint
agent/provision.sh revoke --client <label>                      # token + key + drop live sessions
agent/provision.sh revoke --all                                 # every token, stop the gateway, remove the key file, kill sessions
```

Hand-off: the client sends its `ssh-ed25519` public key → `ssh-key add` →
`token issue` → the printed bundle goes to the client over a secure channel →
the client runs the tunnel and the smoke test → confirm in VPS Grafana
(`Agent API Pinhole` dashboard) that `agent_ssh_accepted_total` and
`agent_gw_requests_total` moved.

### Client contract (what the bundle tells the client)

```sh
ssh-keygen -t ed25519 -f ~/.ssh/agent_hs -C <client-label>      # send agent_hs.pub to the operator
printf 'hs.gn.al ssh-ed25519 AAAA…\n' > ~/.ssh/known_hosts_hs    # host-key line from the bundle — pinning is MANDATORY
ssh -N -o BatchMode=yes -o ExitOnForwardFailure=yes \
    -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$HOME/.ssh/known_hosts_hs \
    -o HostKeyAlgorithms=ssh-ed25519 -o IdentitiesOnly=yes -i ~/.ssh/agent_hs \
    -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o ConnectTimeout=10 \
    -L 127.0.0.1:8093:127.0.0.1:8093 agent@hs.gn.al
# autossh: autossh -M 0 -N <same options>   (autossh's default -M uses a remote forward, which is denied)
curl -sS -X POST http://127.0.0.1:8093/api/documents.search \
     -H "Authorization: Bearer $OUTLINE_API_KEY" -H 'Content-Type: application/json' -d '{"query":"…"}'
```

* Forward destination **must** be `127.0.0.1` (sshd's `PermitOpen` is a string match; `localhost` is refused).
* The SSH channel is the only transport security for the plaintext HTTP and the bearer inside it → pin the host key.
* Responses may contain absolute `https://outline.lab.gn.al/…` URLs the client cannot fetch.
* Gateway errors are `{"ok":false,"error":…}` with 401/403/405/413/415/429; Outline errors arrive as Outline JSON.
* Idle tunnels stay up (`ClientAlive 30×3`, no `UnusedConnectionTimeout`); a forward idle > 15 min is closed (`ChannelTimeout`) — just reconnect.

## How the identity automation works (verified 2026-09-29)

* Authentik (2024.12.5): `cn-authentik/setup-user.sh` creates/updates the `agent`
  user (group `knowledge`) **on neptune** using the bootstrap token from its
  `.env`; `provision.sh` reaches neptune by IP over the SOCKS proxy (`.lan`
  names don't resolve through the proxy in default mode). The user is
  deactivated (`PATCH is_active:false`) after every login; `token issue`
  re-activates it with a fresh throwaway password just long enough to log in.
* Headless OIDC (`lib/oidc-login.sh`): Outline `/auth/oidc` → Authentik
  `/application/o/authorize/` → flow executor
  `/api/v3/flows/executor/default-authentication-flow/?query=next=…`
  (identification → password; the MFA stage has `not_configured_action: skip`;
  login) → authorize again → executor
  `default-provider-authorization-explicit-consent` (consent `token`) →
  Outline callback → `accessToken` cookie. CSRF: the `authentik_csrf` cookie is
  echoed as `X-authentik-CSRF` with `Referer`/`Origin` set.
* Outline (1.8.1): Guest role exists (`users.update_role`, fallback
  `users.demote`); `collections.create {permission:null, sharing:false}` is a
  private collection; `collections.add_user … read_write`; `apiKeys.create
  {name, expiresAt, scope[]}` is per-user — Outline's policy denies it to
  guests, so `token issue` promotes to member for the one call and demotes back.
* **Magic-link fallback** if the executor dance breaks: Outline advertises the
  email provider. `curl --socks5-hostname 127.0.0.1:1055 -X POST
  https://outline.lab.gn.al/auth/email -d 'email=gonzaloab+agent@gmail.com'`,
  open the emailed link with the same cookie jar (`curl -c jar -b jar <link>`),
  then read `accessToken` from the jar and continue by hand.

## Runbooks

**Revoke one client (< 1 min):** `provision.sh revoke --client <label>` = delete
its Outline token(s), remove its key line (commit, push, reinstall on the VPS),
drop live `agent` sessions. **Revoke everything:** `provision.sh revoke --all`
(tokens → `docker compose -p cloudnet stop agent-api-gw` → `rm
/etc/ssh/authorized_keys.d/agent && pkill -u agent`). The fastest kill needs no
script and no Outline call — **remove the ssh key and the client can no longer
reach the gateway at all**: `ssh hs.gn.al 'sudo rm -f
/etc/ssh/authorized_keys.d/agent; sudo pkill -u agent'`.

> Note: Outline's `apiKeys.delete` is **self-only** — an admin token cannot
> delete another user's key. `token revoke` therefore opens a short-lived agent
> session (reactivate → OIDC login → delete own keys → deactivate) to remove the
> token. The ssh-key removal above is the authoritative cut-off regardless; the
> token is defense-in-depth (and every token also carries a 90-day hard expiry).

**Rotate:** client key → `ssh-key add` the new one, client switches, `ssh-key
remove` the old. Token → `token issue` (the `AgentTokenExpiringSoon` alert fires
14 days before expiry), hand over, `token revoke` the old one. VPS host key
(only on a rebuild) → new `known_hosts` line to every client first.

**sshd rollout / rollback:** `sshd/install.sh` snapshots the operator's effective
config (`sshd -T -C user=gonzalo`) before and after and aborts on any diff,
validates the candidate file with `sshd -t -f`, appends the fence at the END of
`sshd_config` (Match blocks live in their own `sshd_config.match.d/`, apart from
Debian's global drop-ins — verified on OpenSSH 9.2 that an Included Match is
scoped to its file, so this is hygiene rather than a workaround), and arms
`sshd-agent-revert.timer` (10 min) whenever sshd config changed.
`provision.sh ssh-key add` then opens a NEW operator connection and only on
success runs `install.sh --disarm`; if that login fails the timer restores the
backup in `/etc/ssh/agent-tunnel-backup.<epoch>/` (`restore.sh` there works by
hand too). `sshd/uninstall.sh` reverses everything with the same guards.

**Backend swap (future):** write `gateway/backend-<new>.conf` (bearer map +
allowlist server block) and `backend-<new>-upstream.conf`, switch the include
in `nginx.conf`, adapt `identity`/`token` in `provision.sh`; clients only change
their API calls.

**Observability:** promtail derives `agent_gw_requests_total`,
`agent_gw_denied_total`, `agent_ssh_accepted_total`, `agent_ssh_failed_total`
(job `promtail`; OpenSSH 9.2 logs nothing for a refused forward or session, so
there is deliberately no "forward denied" counter — the client just sees
`administratively prohibited`); blackbox probes
`http://172.18.0.6:8080/healthz{,/upstream}` (job `blackbox-agent-gw`); alert
group `agent-access` + generated `agent-token-expiry`; dashboard `Agent API
Pinhole` (uid `agent-access`) on grafana.lab.gn.al. Logs: `{service="agent-api-gw"}`
and `{unit="ssh.service"} |~ "agent"` in VPS Loki.

## Future transport switch (documented, not built)

Once SSM Session Manager exists on the VPS: `AllowUsers gonzalo agent`, retire
public `:22` for operators, restrict the SG source if a client ever has a static
IP, or let a client that can hold AWS credentials use
`aws ssm start-session --document-name AWS-StartPortForwardingSession` instead of
SSH. The gateway and the Outline identity stay as they are.
