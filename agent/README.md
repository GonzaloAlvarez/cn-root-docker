# `agent/` — forwarding-only API pinhole for external agents

External AI agents (any implementation, not on the tailnet, dynamic IPs) read and
write **one private Outline collection, `Memories`**, and nothing else, through
the already-public `hs.gn.al:22`. Nothing here is named after a specific agent:
the SSH account is `agent`, the gateway is `agent-api-gw`, the Outline identity
is `agent`; a *client* is just a label on a key line. Swapping the memory backend
later means replacing `gateway/backend-*.conf` and the identity steps in
`provision.sh` — the SSH side, the port and the client tunnel command never change.

**The client holds no credential.** Its only secret is the SSH key that opens the
tunnel; the gateway injects the Outline token server-side. This is deliberate: the
first client (muse) runs on a platform whose vault never exposes the raw token and
only injects it for public HTTPS hosts, so a client-supplied bearer is impossible.
Making the SSH key the sole client factor (the `clouddevbox tun` trust model) keeps
everything on loopback with nothing public.

```
client ── ssh -N -L 127.0.0.1:8093:127.0.0.1:8093 agent@hs.gn.al ──▶ sshd Match User agent
   host key pinned · SSH key IS the auth                              │ MaxSessions 0 · PermitOpen 127.0.0.1:8093 only
                                                                      ▼
   POST http://127.0.0.1:8093/api/<method>   (NO Authorization) ──▶ agent-api-gw (nginx, bridge 172.18.0.6, loopback publish)
                                                                      │ POST+JSON only · exact allowlist · 512 KB · 10 r/s
                                                                      │ (files.create: multipart, 25 MB — the upload bytes)
                                                                      │ injects Authorization: Bearer <server-side token>
                                                                      ▼ https://ts-infra:443  (Host/SNI outline.lab.gn.al, LE verified)
                                                                traefik-lab → 10.1.1.92:443 → Outline
                                                                      user `agent` = Member, read_write in `Memories` only
```

Independent layers, each alone stopping a shell, a lateral move or an out-of-scope
write: (1) sshd Match + key options → one `direct-tcpip` to `127.0.0.1:8093`;
(2) gateway method allowlist; (3) Outline **Member** role; (4) the injected token's
scope = the same allowlist + 90-day expiry; (5) explicit `Memories`-only membership.

## Layout

| Path | What |
|---|---|
| `provision.sh` | operator-side orchestrator (Mac, via the cn-socksnode SOCKS proxy) — see below |
| `lib/oidc-login.sh` | headless Outline login for `agent` through Authentik's flow-executor API |
| `gateway/nginx.conf` | backend-agnostic frame (limits, JSON-only, logging without secrets) |
| `gateway/backend-outline.conf` | **swap seam**: the exact-match method allowlist (server block) |
| `gateway/backend-outline-upstream.conf` | **swap seam**: Host/SNI/TLS to traefik-lab + `include /tmp/agent-token.conf` (server-side token injection) |
| `gateway/api-endpoint.conf` | per-location guard: source IP, POST-only, JSON-only, `proxy_pass $uri` |
| `gateway/api-upload-endpoint.conf` | the `files.create` variant of that guard: multipart/form-data body up to 25 MB (Outline's own `FILE_STORAGE_UPLOAD_MAX_SIZE`), everything else identical |
| `sshd/50-agent.conf` | the `Match User agent` block |
| `sshd/authorized_keys` | registered client public keys (`ssh-ed25519 … client=<label>`) — public material |
| `sshd/install.sh` / `uninstall.sh` | root-level installer on the VPS with operator-lockout guards + auto-revert timer |
| `clients.md` | ledger: SSH clients (fingerprints), the active injected token (name/dates) and `local-<label>` rows for per-machine skill keys — never secret values |
| `../tailnet/prometheus/agent-rules.yml` | generated `AgentTokenExpiringSoon` rules — one per token row (gateway + each local key), with the matching rotation instruction |

The token itself lives only in the VPS `/opt/cloudnet/.env` as `AGENT_OUTLINE_TOKEN`;
the container command renders it into `/tmp/agent-token.conf` (tmpfs) at start and
nginx sets `Authorization: Bearer <token>` from there on every upstream call.

## Allowlist ≡ injected-token scope (Outline backend)

`auth.info collections.list collections.info collections.documents documents.list
documents.info documents.search documents.create documents.update documents.archive
documents.restore documents.delete attachments.create files.create`

Outline stores these as route scopes (`/api/<method>`; `apiKeys.create` adds the
prefix) and enforces them on every `/api/*` call, plugin routes included — so a key
without `files.create` cannot upload even when `attachments.create` is allowed.

**Uploads (added 2026-10-04)** are two calls because Outline splits "register a
file" from "send its bytes" (local file storage on cn-outline):

1. `POST /api/attachments.create` `{"name","contentType","size"[,"documentId"]}` — JSON,
   512 KB like everything else. Returns `data.uploadUrl` (`/api/files.create`, a
   **relative** path the client must call on the same gateway base URL), `data.form`
   (the fields to echo back) and `data.attachment.{id,url}`.
2. `POST /api/files.create` as `multipart/form-data`: every `data.form` field plus
   `file=<bytes>`. Up to 25 MB (Outline's `FILE_STORAGE_UPLOAD_MAX_SIZE`; the gateway
   enforces the same number, JSON `413` above it). Outline writes the bytes only to an
   attachment the **same user** registered, and only up to the declared `size`.
3. Embed as `![name](data.attachment.url)` (= `/api/attachments.redirect?id=<id>`).
   Pass `documentId` in step 1 (then `documents.update` the page) to tie the file to the
   page's lifecycle; without it the attachment stays team-scoped and is not removed when
   the page is deleted. Reading files back (`files.get`, `attachments.redirect`) is not
   allowlisted: the agent writes images, humans view them in Outline.

Excluded on purpose: `documents.move` (cross-collection), `documents.import`,
`documents.export`, `attachments.list/delete/redirect/createFromUrl`, `files.get`
(downloads), `shares.*`, `apiKeys.*`, `users.*`, `groups.*`, `team.*`, `events.*`,
`revisions.*`, `views.*`, `/realtime`, all UI paths.
The gateway also refuses GET (405), the wrong body type (415: JSON everywhere,
multipart only on `files.create`), bodies over the cap (413: 512 KB, 25 MB for
`files.create`), > 10 r/s (429), and any source other than the host loopback publish
(403). Traversal / `//` / `%2e` are normalised before matching and only the normalised
`$uri` is forwarded. Any `Authorization` the client sends is overwritten by the
injected token.

## Operator workflow

Prerequisite for identity/token/revoke: an Outline **admin** API key
(Settings → API & Apps, scope `users.* collections.* apiKeys.* auth.info`,
1-day expiry) exported as `OUTLINE_ADMIN_TOKEN` (or `--admin-token-file`).
Delete it when done.

```sh
agent/provision.sh preflight                                  # proxy, neptune, VPS, Outline, Authentik, admin key
agent/provision.sh identity ensure                            # once: Authentik user → Outline Member → Memories → verify → deactivate
agent/provision.sh token issue                                # mint the Outline token + install it INTO the gateway; rotate out the old
agent/provision.sh ssh-key add ./client.pub --client <label>  # commit+push, install on the VPS, verify a NEW operator login, print host key
agent/provision.sh bundle --client <label>                    # the client bundle (host key + tunnel cmd + URL) — NO token
agent/provision.sh test --client <label> --key ./client_key   # full matrix from the Mac (client sends no credential)
agent/provision.sh token list | token revoke                  # list keys / delete ALL keys (incl. local) + blank the gateway
agent/provision.sh ssh-key remove --client <label>
agent/provision.sh revoke --client <label> | --all
agent/provision.sh token issue --local <label> --write ~/.outline-token   # per-machine key for the outlinememory skill (no admin token)
agent/provision.sh token revoke --local <label>               # delete one machine's local keys only
```

**Hand-off:** the client sends its `ssh-ed25519` **public** key → you `ssh-key add`
it → give the client the `bundle` output (host key + tunnel command + URL). There is
**no token to hand over** — the client authenticates by its SSH key and the gateway
injects the token. Confirm in VPS Grafana (`Agent API Pinhole`) that
`agent_ssh_accepted_total` and `agent_gw_requests_total` moved.

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
     -H 'Content-Type: application/json' -d '{"query":"…"}'      # NO Authorization header — the gateway injects it

# Upload an image (two calls), then embed it in a page:
att=$(curl -sS -X POST http://127.0.0.1:8093/api/attachments.create -H 'Content-Type: application/json' \
     -d "{\"name\":\"shot.png\",\"contentType\":\"image/png\",\"size\":$(wc -c < shot.png)}")
curl -sS -X POST "http://127.0.0.1:8093$(jq -r .data.uploadUrl <<<"$att")" \
     $(jq -r '.data.form | to_entries[] | "--form-string \(.key)=\(.value)"' <<<"$att") \
     -F 'file=@shot.png;type=image/png'                           # multipart, ≤ 25 MB → {"success":true}
echo "![shot]($(jq -r .data.attachment.url <<<"$att"))"            # → ![shot](/api/attachments.redirect?id=…) for documents.create/update
```

* Send **no** `Authorization` header. The SSH key is the credential; the gateway attaches the Outline token.
* Forward destination **must** be `127.0.0.1` (sshd's `PermitOpen` is a string match; `localhost` is refused).
* The SSH channel is the only transport security → pin the host key.
* Responses may contain absolute `https://outline.lab.gn.al/…` URLs the client cannot fetch.
* Gateway errors are `{"ok":false,"error":…}` with 403/405/413/415/429; Outline errors arrive as Outline JSON.
* Idle tunnels stay up (`ClientAlive 30×3`, no `UnusedConnectionTimeout`); a forward idle > 15 min is closed (`ChannelTimeout`) — reconnect.
* Uploads: `attachments.create` (JSON) then `files.create` (multipart, every `form` field + `file`, ≤ 25 MB) — the `uploadUrl` is relative to the gateway base URL. Shell quoting of the form fields is the usual trap; `--form-string` (not `-F`) for the returned fields, `-F file=@…` for the bytes.

## How the automation works (verified 2026-09-29)

* **Authentik (2024.12.5):** `cn-authentik/setup-user.sh` creates/updates the `agent`
  user (group `knowledge`) **on neptune** with the bootstrap token; reached by IP over
  the SOCKS proxy (`.lan` names don't resolve through the proxy in default mode). The
  user is **deactivated between token issues**; `token issue` reactivates it with a
  throwaway password only long enough to mint a key.
* **Headless OIDC (`lib/oidc-login.sh`):** Outline `/auth/oidc` → Authentik
  `/application/o/authorize/` → flow executor `default-authentication-flow`
  (identification → password → MFA auto-skips → login) → follow the executor's
  internal 302 chain to `xak-flow-redirect` → authorize → consent flow → Outline
  callback → `accessToken` cookie. Match the callback by URL **prefix**
  (`${OUTLINE}/auth/oidc.callback`), not a loose glob (the consent page's
  `redirect_uri=` param contains that string).
* **Outline (1.8.1):** `agent` is a **Member** (Guests are read-only; write needs
  Member), confined to `Memories` by making every other collection private
  (default access "no access"). `token issue` mints an API key, writes it to the VPS
  `.env` as `AGENT_OUTLINE_TOKEN`, force-recreates `agent-api-gw`, verifies a
  credential-less call now returns the `agent` user, then deletes the previous keys.
* **Magic-link fallback** if the executor dance breaks: Outline advertises the email
  provider. `curl --socks5-hostname 127.0.0.1:1055 -X POST
  https://outline.lab.gn.al/auth/email -d 'email=gonzaloab+agent@gmail.com'`, open
  the emailed link with the same cookie jar, read `accessToken`, continue by hand.

## Local per-machine keys (outlinememory skill)

The operator's own Claude Code / Codex sessions write memories into the same `Memories`
collection through the **`outlinememory` skill** (`~/dev/skill-outlinememory`, public repo
`GonzaloAlvarez/skill-outlinememory` — it contains no instance data; the Outline URL lives
in `~/.outline-memory.yml` on each machine). Those machines talk to Outline directly (tailnet)
or through the SOCKS proxy, never through the gateway, so each one needs its own key:

- `provision.sh token issue --local <label> [--expires-days 365] [--write ~/.outline-token]`
  mints `agent-local-<label>-<ts>` on the same `agent` user with the minimal
  `LOCAL_SCOPES` (`auth.info collections.list collections.documents documents.create
  documents.info attachments.create files.create` — read the tree, add pages, upload the
  images a page embeds via `outline-memory attach` / `create --attach`; no update/delete).
  A key minted before 2026-10-04 lacks the two upload scopes: re-issue it. Label = lowercase
  `hostname -s`. No admin token is needed (self-service inside the agent's OIDC session,
  which is reactivated and deactivated like for the gateway key). The secret is printed
  once or written 0600 to `--write`; it is never stored in git or the ledger.
- Re-issuing with the same label rotates (new key, then the old `agent-local-<label>-*`
  are deleted). `token revoke --local <label>` deletes one machine's keys and drops its
  ledger row; plain `token revoke` deletes everything, local keys included, and says so.
- Gateway rotation (`token issue`) filters by the `agent-injected-` prefix, so local keys
  survive it. The ledger gets a `local-<label>` row (token name, issued, expires) and
  `agent-rules.yml` a matching `AgentTokenExpiringSoon` rule whose description names the
  machine and the local rotation command (deploy: VPS `git pull` + `docker compose up -d
  --force-recreate --no-deps prometheus`).
- Pages land at `Memories › dev › <project> › YYYY-MM-DD <topic>` (containers created
  empty, like muse's `personal / travel / …` tree) and are authored by `agent`; muse can
  browse them because `collections.documents` is on the gateway allowlist.

## Runbooks

**Revoke one client (< 1 min):** `provision.sh revoke --client <label>` removes that
client's SSH key (commit, push, reinstall) and drops live sessions — no key, no
tunnel, no reach. Other clients keep working; the shared token is untouched. If that
key may have leaked, rotate the token too: `provision.sh token issue`. The fastest
manual kill: `ssh hs.gn.al 'sudo rm -f /etc/ssh/authorized_keys.d/agent; sudo pkill -u agent'`.

**Revoke everything:** `provision.sh revoke --all` = delete every Outline key + blank
the gateway token + stop `agent-api-gw` + remove the key file + kill sessions.

**Rotate:**
- *Token (in place, no client change):* `provision.sh token issue` mints a new key,
  installs it into the gateway, verifies injection, then deletes the old keys. Clients
  are unaffected — they hold no token. The `AgentTokenExpiringSoon` alert fires 14 days
  before the 90-day expiry.
- *Client SSH key:* `ssh-key add` the new one, client switches, `ssh-key remove` the old.
- *Local skill key (one machine):* on that machine, `provision.sh token issue --local <label>
  --write ~/.outline-token` mints the new key and deletes the previous `agent-local-<label>-*`.
  Its own `AgentTokenExpiringSoon` rule (label `local-<label>`) fires 14 days before the
  1-year expiry. Gateway `token issue` never touches these keys.
- *VPS host key* (only on a rebuild): new `known_hosts` line to every client first.

> Note: Outline's `apiKeys.delete` is **self-only** — an admin token cannot delete
> another user's key. `token issue`/`revoke` open a short-lived agent session
> (reactivate → OIDC login → delete → deactivate) to manage keys. The token lives
> only in the VPS gateway; the SSH-key layer is the per-client authority.

**sshd rollout / rollback:** `sshd/install.sh` snapshots the operator's effective
config (`sshd -T -C user=gonzalo`) before and after and aborts on any diff, validates
the candidate with `sshd -t -f`, appends the fence at the END of `sshd_config` (Match
blocks live in their own `sshd_config.match.d/`, apart from Debian's global drop-ins —
verified on OpenSSH 9.2 that an Included Match is scoped to its file), and arms
`sshd-agent-revert.timer` (10 min) whenever sshd config changed. `ssh-key add` then
opens a NEW operator connection and only on success runs `install.sh --disarm`; if
that login fails the timer restores the backup in `/etc/ssh/agent-tunnel-backup.<epoch>/`.

**Backend swap (future):** write `gateway/backend-<new>.conf` + `backend-<new>-upstream.conf`
(the latter still `include /tmp/agent-token.conf` if the new backend is bearer-based),
switch the include in `nginx.conf`, adapt `identity`/`token` in `provision.sh`.

**Observability:** promtail derives `agent_gw_requests_total`, `agent_gw_denied_total`,
`agent_ssh_accepted_total`, `agent_ssh_failed_total` (job `promtail`; OpenSSH 9.2 logs
nothing for a refused forward/session, so there is deliberately no "forward denied"
counter). blackbox probes `http://172.18.0.6:8080/healthz{,/upstream}` (job
`blackbox-agent-gw`); alert group `agent-access` + generated `agent-token-expiry`;
dashboard `Agent API Pinhole` (uid `agent-access`) on grafana.lab.gn.al. Logs:
`{service="agent-api-gw"}` and `{unit="ssh.service"} |~ "agent"` in VPS Loki. No
request bodies, page text, cookies, or tokens are ever logged.

## Future transport switch (documented, not built)

Once SSM Session Manager exists on the VPS: `AllowUsers gonzalo agent`, retire public
`:22` for operators, restrict the SG source if a client ever has a static IP, or let a
client that can hold AWS credentials use `aws ssm start-session --document-name
AWS-StartPortForwardingSession` instead of SSH. The gateway and Outline identity stay
as they are.
