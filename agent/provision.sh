#!/usr/bin/env bash
# cn-root-docker/agent/provision.sh — operator-side orchestrator for the agent
# API pinhole (agent/README.md). Runs on the operator's Mac through the
# cn-socksnode SOCKS proxy; touches the VPS over public ssh and neptune over the
# proxy by IP (.lan names do not resolve through the proxy in default mode).
#
#   provision.sh preflight
#   provision.sh ssh-key add <pubkey-file> --client <label> [--no-deploy]
#   provision.sh ssh-key remove (<fingerprint> | --client <label>) [--no-deploy]
#   provision.sh ssh-key list
#   provision.sh host-key                       # VPS ed25519 host key line for clients' known_hosts
#   provision.sh identity ensure                # Authentik user + Outline Member + Memories collection (needs OUTLINE_ADMIN_TOKEN)
#   provision.sh token issue [--expires-days 90] # mint the Outline token + install it INTO the gateway (server-side injection); clients get no token
#   provision.sh token list | token revoke       # list keys / delete all keys + blank the gateway token
#   provision.sh bundle [--client <label>]      # reprint host key + tunnel command + URL + allowlist (client needs NO token)
#   provision.sh test --client <label> --key <private-key>          # e2e: client sends no credential; gateway injects
#   provision.sh revoke [--client <label> | --all]
#
# Admin credential: OUTLINE_ADMIN_TOKEN env var or --admin-token-file <f> — an
# Outline API key minted by the operator (Settings → API & Apps) with scope
# `users.* collections.* apiKeys.* auth.info`, short expiry, deleted afterwards.
# No secret is ever written to disk by this script except the ledger METADATA
# in agent/clients.md (client, key fingerprint, token name, dates).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); cd "$HERE"; REPO=$(cd .. && pwd)

PROXY=${AGENT_PROXY:-127.0.0.1:1055}
NEPTUNE_IP=${AGENT_NEPTUNE_IP:-10.1.1.92}
VPS=${AGENT_VPS:-hs.gn.al}
VPS_USER=${AGENT_VPS_USER:-gonzalo}
VPS_REPO=${AGENT_VPS_REPO:-/opt/cloudnet}
OUTLINE=${AGENT_OUTLINE_URL:-https://outline.lab.gn.al}
AUTH=${AGENT_AUTH_URL:-https://auth.lab.gn.al}
SSH_KEY=${AGENT_OPERATOR_KEY:-$HOME/.ssh/gonzalo_main_private_key.pem}
IDENTITY=agent
IDENTITY_EMAIL=${AGENT_IDENTITY_EMAIL:-gonzaloab+agent@gmail.com}
IDENTITY_NAME="Agent (service identity)"
IDENTITY_GROUPS=knowledge
COLLECTION=${AGENT_COLLECTION:-Memories}
API_PORT=8093
LOCAL_TEST_PORT=${AGENT_LOCAL_TEST_PORT:-18093}
SCOPES=(auth.info collections.list collections.info collections.documents documents.list documents.info documents.search
        documents.create documents.update documents.archive documents.restore documents.delete)
KEYS_FILE="$HERE/sshd/authorized_keys"
LEDGER="$HERE/clients.md"
RULES_FILE="$REPO/tailnet/prometheus/agent-rules.yml"
export PROXY OUTLINE AUTH
# shellcheck source=lib/oidc-login.sh
source "$HERE/lib/oidc-login.sh"

log()  { printf '\n\033[1;36m[agent]\033[0m %s\n' "$*"; }
ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
chg()  { printf '  \033[1;33m+\033[0m %s\n' "$*"; }
warn() { printf '  \033[1;33m!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }
need() { for c in "$@"; do command -v "$c" >/dev/null || die "missing tool: $c"; done; }
need curl jq ssh ssh-keygen ssh-keyscan nc git openssl

HTTP_FILE=$(mktemp); trap 'rm -f "$HTTP_FILE"' EXIT
HTTP() { cat "$HTTP_FILE" 2>/dev/null; }      # last HTTP status of outline_call / ak_call (survives $(…) subshells)
pcurl() { curl -sS --socks5-hostname "$PROXY" --max-time 60 "$@"; }
# outline_call <bearer> <method> <json> → prints body; status via $(HTTP)
outline_call() {
  local out
  local body="${3:-"{}"}"
  out=$(pcurl -w '\n%{http_code}' -X POST -H "Authorization: Bearer $1" -H 'Content-Type: application/json' \
        --data "$body" "${OUTLINE}/api/$2") || { printf 000 >"$HTTP_FILE"; return 1; }
  tail -n1 <<<"$out" >"$HTTP_FILE"; sed '$d' <<<"$out"
}
ADMIN_TOKEN="${OUTLINE_ADMIN_TOKEN:-}"
require_admin() {
  [[ -n "$ADMIN_TOKEN" ]] || die "OUTLINE_ADMIN_TOKEN not set (or --admin-token-file). Mint one in Outline → Settings → API & Apps (scope: users.* collections.* apiKeys.* auth.info, short expiry)."
  local me; me=$(outline_call "$ADMIN_TOKEN" auth.info) || true
  [[ "$(HTTP)" == 200 ]] || die "admin token rejected by Outline (HTTP ${HTTP}): $(head -c 200 <<<"$me")"
  [[ "$(jq -r '.data.user.role' <<<"$me")" == admin ]] || die "OUTLINE_ADMIN_TOKEN belongs to a non-admin user"
  ok "admin token valid (user $(jq -r '.data.user.name' <<<"$me"))"
}
admin_call() { outline_call "$ADMIN_TOKEN" "$@"; }

SSH_COMMON=(-o BatchMode=yes -o ConnectTimeout=20 -o LogLevel=ERROR -i "$SSH_KEY")
neptune_ssh() {  # trusted LAN path over the proxy (homelab CLAUDE.md §4.2 convention)
  ssh "${SSH_COMMON[@]}" -o "ProxyCommand=nc -x ${PROXY} %h %p" -o UserKnownHostsFile=/dev/null \
      -o StrictHostKeyChecking=no -l "$VPS_USER" "$NEPTUNE_IP" "$@"
}
vps_ssh() { ssh "${SSH_COMMON[@]}" -l "$VPS_USER" "$VPS" "$@"; }

# ak_call <METHOD> <path> [json] → prints body; status via $(HTTP). Runs ON neptune with the
# bootstrap token from ~/cn-authentik/.env (the token never leaves neptune).
ak_call() {
  local method="$1" path="$2" body="${3:-}" dflag="" out
  [[ -n "$body" ]] && dflag="-d @-"
  out=$(printf '%s' "$body" | neptune_ssh "cd ~/cn-authentik && T=\$(grep -E '^AUTHENTIK_BOOTSTRAP_TOKEN=' .env | cut -d= -f2-) && curl -sS -k --max-time 60 -w '\n%{http_code}' -H \"Authorization: Bearer \$T\" -H 'Content-Type: application/json' -H 'Accept: application/json' -X '$method' 'http://127.0.0.1:9000/api/v3$path' $dflag") || { printf 000 >"$HTTP_FILE"; return 1; }
  tail -n1 <<<"$out" >"$HTTP_FILE"; sed '$d' <<<"$out"
}
ak_user_pk() { ak_call GET "/core/users/?username=${IDENTITY}&page_size=50" | jq -r --arg u "$IDENTITY" '[.results[] | select(.username==$u)] | first | .pk // empty'; }
ak_set_active() {  # <pk> <true|false>
  ak_call PATCH "/core/users/$1/" "{\"is_active\": $2}" >/dev/null; [[ "$(HTTP)" == 200 ]] || die "Authentik: could not set is_active=$2 (HTTP $(HTTP))"
}
ak_set_password() {  # <pk> <password>
  jq -cn --arg p "$2" '{password:$p}' | { read -r j; ak_call POST "/core/users/$1/set_password/" "$j" >/dev/null; }
  [[ "$(HTTP)" == 204 ]] || die "Authentik: set_password failed (HTTP $(HTTP))"
}
gen_pw() { openssl rand -base64 30 | tr -d '\n=/+' | head -c 32; }
iso_plus_days() { date -u -v+"$1"d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "+$1 days" +%Y-%m-%dT%H:%M:%SZ; }
iso_to_epoch() {  # accepts YYYY-MM-DD or full ISO-8601 Z; BSD date first, then GNU
  local d="$1"; [[ "$d" == *T* ]] || d="${d}T00:00:00Z"
  date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$d" +%s 2>/dev/null || date -u -d "$d" +%s 2>/dev/null || echo 0
}
today() { date -u +%Y-%m-%d; }

# ── ledger + generated token-expiry rules ──────────────────────────────────
ledger_init() {
  [[ -f "$LEDGER" ]] && return
  cat >"$LEDGER" <<'MD'
# Registered agent clients (METADATA ONLY — no secrets)

Maintained by `agent/provision.sh`. One row per client. Token values are never stored.

| client | ssh key fingerprint | token name | token issued | token expires |
|---|---|---|---|---|
MD
}
ledger_row() { grep -E "^\| $1 \|" "$LEDGER" 2>/dev/null || true; }
ledger_set() {  # <client> <fp|-> <token|-> <issued|-> <expires|-> ; '-' keeps the existing field, '' clears it
  ledger_init
  local c="$1" fp="$2" tn="$3" is="$4" ex="$5" old
  old=$(ledger_row "$c")
  if [[ -n "$old" ]]; then
    IFS='|' read -r _ _ ofp otn ois oex _ <<<"$old"
    [[ "$fp" == - ]] && fp=$(xargs <<<"$ofp"); [[ "$tn" == - ]] && tn=$(xargs <<<"$otn")
    [[ "$is" == - ]] && is=$(xargs <<<"$ois"); [[ "$ex" == - ]] && ex=$(xargs <<<"$oex")
    grep -vE "^\| $c \|" "$LEDGER" >"$LEDGER.tmp" && mv "$LEDGER.tmp" "$LEDGER"
  else
    for v in fp tn is ex; do [[ "${!v}" == - ]] && printf -v "$v" ''; done
  fi
  printf '| %s | %s | %s | %s | %s |\n' "$c" "$fp" "$tn" "$is" "$ex" >>"$LEDGER"
  rules_regenerate
}
ledger_remove() { ledger_init; grep -vE "^\| $1 \|" "$LEDGER" >"$LEDGER.tmp" && mv "$LEDGER.tmp" "$LEDGER"; rules_regenerate; }
rules_regenerate() {
  {
    echo '# GENERATED by agent/provision.sh (token issue / revoke) — do not edit by hand.'
    echo '# One AgentTokenExpiringSoon rule per issued client token, firing 14 days'
    echo '# before the recorded expiry so the token can be rotated in time.'
    echo 'groups:'
    echo '  - name: agent-token-expiry'
    local any=0
    while IFS='|' read -r _ c _ tn _ ex _; do
      c=$(xargs <<<"$c"); tn=$(xargs <<<"$tn"); ex=$(xargs <<<"$ex")
      [[ -n "$c" && -n "$tn" && -n "$ex" && "$c" != client ]] || continue
      [[ "$c" =~ ^-+$ ]] && continue
      if [[ $any -eq 0 ]]; then echo '    rules:'; any=1; fi
      cat <<RULE
      - alert: AgentTokenExpiringSoon
        expr: vector($(iso_to_epoch "$ex")) - time() < 14 * 86400
        labels:
          severity: info
          client: "${c}"
        annotations:
          summary: "agent Outline token (${tn}) expires ${ex}"
          description: "The gateway-injected Outline token ${tn} expires on ${ex}. Rotate in place with: agent/provision.sh token issue (mints a new one, installs it into the gateway, rotates out the old). Clients are unaffected — they hold no token."
RULE
    done < <(grep -E '^\| ' "$LEDGER" 2>/dev/null || true)
    [[ $any -eq 1 ]] || echo '    rules: []'
  } >"$RULES_FILE"
}
git_commit_push() {  # <message>
  ( cd "$REPO" && git add -A agent tailnet/prometheus/agent-rules.yml && { git diff --cached --quiet && ok "nothing to commit" || { git commit -q -m "$1" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>" && git push -q origin HEAD && chg "committed + pushed: $1"; }; } )
}

# vps_set_token <secret|""> — install (or blank) the injected Outline token in the
# VPS gateway. The secret is piped over stdin (never in argv/history); .env is
# backed up and rewritten in place (perms preserved), then only agent-api-gw is
# force-recreated so it re-reads the value. An empty secret disables the gateway
# (Outline then 401s) without removing anything.
vps_set_token() {
  local secret="$1"
  printf '%s' "$secret" | vps_ssh "cd ${VPS_REPO} && test -s .env || { echo 'FATAL: /opt/cloudnet/.env missing or empty' >&2; exit 1; } && umask 077 && cp -a .env .env.bak.agent && { grep -v '^AGENT_OUTLINE_TOKEN=' .env.bak.agent; printf 'AGENT_OUTLINE_TOKEN=%s\n' \"\$(cat)\"; } > .env && docker compose up -d --force-recreate --no-deps agent-api-gw >/dev/null 2>&1 && echo installed" \
    | grep -q installed || die "failed to install the token into the VPS gateway"
}

# ── preflight ──────────────────────────────────────────────────────────────
cmd_preflight() {
  log "preflight"
  nc -z -w 3 "${PROXY%:*}" "${PROXY#*:}" 2>/dev/null && ok "socks proxy ${PROXY} reachable" || die "socks proxy ${PROXY} down — ~/dev/cn-socksnode/run.sh"
  [[ "$(pcurl -o /dev/null -w '%{http_code}' "${OUTLINE}/_health")" == 200 ]] && ok "outline reachable via proxy" || die "outline unreachable via proxy"
  [[ "$(pcurl -o /dev/null -w '%{http_code}' "${AUTH}/-/health/live/")" == 200 ]] && ok "authentik reachable via proxy" || die "authentik unreachable via proxy"
  [[ "$(neptune_ssh hostname 2>/dev/null)" == neptune ]] && ok "neptune ssh ok (${NEPTUNE_IP} via proxy)" || die "neptune ssh failed"
  [[ "$(vps_ssh hostname 2>/dev/null)" != "" ]] && ok "vps ssh ok (${VPS})" || die "vps ssh failed"
  ( cd "$REPO" && git diff --quiet && git diff --cached --quiet ) && ok "cn-root-docker working tree clean" || warn "cn-root-docker has uncommitted changes"
  [[ -n "$ADMIN_TOKEN" ]] && require_admin || ok "no admin token given (only needed for identity/token/revoke)"
}

# ── ssh keys ───────────────────────────────────────────────────────────────
key_fp() { printf '%s %s\n' "$1" "$2" | ssh-keygen -lf /dev/stdin | awk '{print $2}'; }
deploy_keys() {  # git pull + install.sh on the VPS, verify a NEW operator login, disarm timer if armed
  log "deploying key file to ${VPS}"
  local out
  out=$(vps_ssh "cd ${VPS_REPO} && git pull -q && sudo agent/sshd/install.sh" 2>&1) || { printf '%s\n' "$out"; die "install.sh failed on the VPS"; }
  printf '%s\n' "$out" | sed 's/^/    /'
  if grep -q 'revert timer armed' <<<"$out"; then
    log "sshd config changed — verifying a FRESH operator login before disarming the revert timer"
    if [[ "$(vps_ssh 'echo OK' 2>/dev/null)" == OK ]]; then
      vps_ssh "sudo ${VPS_REPO}/agent/sshd/install.sh --disarm" && ok "fresh login OK → revert timer disarmed"
    else
      die "fresh operator login FAILED — leaving the revert timer armed (auto-restore in ≤10 min). Investigate from the existing session."
    fi
  fi
}
cmd_ssh_key() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    list)
      log "registered client keys"
      grep -vE '^\s*(#|$)' "$KEYS_FILE" | while read -r t b c; do printf '  %s  %s  %s\n' "$(key_fp "$t" "$b")" "$c" "$t"; done ;;
    add)
      local file="" client="" deploy=1
      while (( $# )); do case "$1" in --client) client="$2"; shift 2 ;; --no-deploy) deploy=0; shift ;; *) file="$1"; shift ;; esac; done
      [[ -f "$file" && -n "$client" ]] || die "usage: ssh-key add <pubkey-file> --client <label>"
      [[ "$client" =~ ^[a-z0-9][a-z0-9._-]{0,31}$ ]] || die "client label must match ^[a-z0-9][a-z0-9._-]{0,31}$"
      local line t b _c fp
      line=$(grep -vE '^\s*(#|$)' "$file" | head -1); read -r t b _c <<<"$line"
      [[ "$t" == ssh-ed25519 ]] || die "only ssh-ed25519 public keys are accepted (got '${t:-<empty>}')"
      fp=$(key_fp "$t" "$b") || die "key does not parse"
      grep -q " $b " "$KEYS_FILE" 2>/dev/null && die "this key is already registered ($fp)"
      grep -qE " client=${client}( |$)" "$KEYS_FILE" && die "client '${client}' already has a key — remove it first (ssh-key remove --client ${client})"
      printf '%s %s client=%s\n' "$t" "$b" "$client" >>"$KEYS_FILE"
      chg "registered ${fp} as client=${client}"
      ledger_set "$client" "$fp" - - -
      git_commit_push "agent: register ssh key for client=${client} (${fp})"
      (( deploy )) && deploy_keys
      cmd_host_key ;;
    remove)
      local sel="" client="" deploy=1
      while (( $# )); do case "$1" in --client) client="$2"; shift 2 ;; --no-deploy) deploy=0; shift ;; *) sel="$1"; shift ;; esac; done
      [[ -n "$sel" || -n "$client" ]] || die "usage: ssh-key remove (<fingerprint> | --client <label>)"
      local tmp; tmp=$(mktemp); local removed=0
      while IFS= read -r l || [[ -n "$l" ]]; do
        if [[ "$l" =~ ^[[:space:]]*(#|$) ]]; then printf '%s\n' "$l" >>"$tmp"; continue; fi
        read -r t b c <<<"$l"
        if [[ -n "$client" && "$c" == "client=${client}" ]] || [[ -n "$sel" && "$(key_fp "$t" "$b")" == "$sel" ]]; then removed=1; chg "removed $(key_fp "$t" "$b") ($c)"; else printf '%s\n' "$l" >>"$tmp"; fi
      done <"$KEYS_FILE"
      (( removed )) || { rm -f "$tmp"; die "no matching key"; }
      mv "$tmp" "$KEYS_FILE"
      [[ -n "$client" ]] && ledger_remove "$client"
      git_commit_push "agent: remove ssh key ${client:+client=$client}${sel}"
      (( deploy )) && deploy_keys ;;
    *) die "usage: ssh-key add|remove|list" ;;
  esac
}
cmd_host_key() {
  log "VPS host key (pin this on the client)"
  local scanned onhost
  scanned=$(ssh-keyscan -t ed25519 -T 10 "$VPS" 2>/dev/null | grep -v '^#' | head -1)
  onhost=$(vps_ssh 'ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub' 2>/dev/null | awk '{print $2}')
  [[ -n "$scanned" ]] || die "ssh-keyscan returned nothing"
  [[ "$(ssh-keygen -lf /dev/stdin <<<"$scanned" | awk '{print $2}')" == "$onhost" ]] || die "host key fingerprint mismatch between ssh-keyscan and the VPS itself — DO NOT hand out"
  echo "  fingerprint : ${onhost}"
  echo "  known_hosts : ${scanned}"
}

# ── Outline / Authentik identity ───────────────────────────────────────────
ol_collection_id() { admin_call collections.list '{"limit":100}' | jq -r --arg n "$1" '.data[] | select(.name==$n) | .id' | head -1; }
ol_user() {  # → json of the agent Outline user (by email), via admin
  admin_call users.list "$(jq -cn --arg q "$IDENTITY" '{query:$q,limit:25}')" | jq -c --arg e "$IDENTITY_EMAIL" '.data[] | select((.email|ascii_downcase)==($e|ascii_downcase))' | head -1
}
ol_set_role() {  # <userId> <role>
  admin_call users.update_role "$(jq -cn --arg id "$1" --arg r "$2" '{id:$id,role:$r}')" >/dev/null
  if [[ "$(HTTP)" != 200 ]]; then
    admin_call users.demote "$(jq -cn --arg id "$1" --arg r "$2" '{id:$id,to:$r}')" >/dev/null
    [[ "$(HTTP)" == 200 ]] || die "could not set role ${2} (users.update_role and users.demote both failed, HTTP $(HTTP))"
  fi
}
authentik_login_session() {  # → JWT ; (re)activates the Authentik user with a fresh throwaway password
  local pk pw
  pk=$(ak_user_pk); [[ -n "$pk" ]] || die "Authentik user ${IDENTITY} missing — run: identity ensure"
  pw=$(gen_pw); ak_set_active "$pk" true; ak_set_password "$pk" "$pw"
  oidc_login "$IDENTITY" "$pw"
}
authentik_deactivate() { local pk; pk=$(ak_user_pk); [[ -n "$pk" ]] && ak_set_active "$pk" false && ok "Authentik user ${IDENTITY} deactivated (no interactive login possible)"; }

cmd_identity() {
  [[ "${1:-}" == ensure ]] || die "usage: identity ensure"
  cmd_preflight; require_admin
  log "1/6 Authentik user ${IDENTITY} (${IDENTITY_EMAIL}, groups ${IDENTITY_GROUPS})"
  local pw; pw=$(gen_pw)
  printf '%s\n' "$pw" | neptune_ssh "cd ~/cn-authentik && ./setup-user.sh --username ${IDENTITY} --email ${IDENTITY_EMAIL} --name \"${IDENTITY_NAME}\" --groups ${IDENTITY_GROUPS} --password-stdin" | sed 's/^/    /'
  log "2/6 Outline login as ${IDENTITY} (headless OIDC via Authentik flow executor)"
  local jwt me uid
  jwt=$(oidc_login "$IDENTITY" "$pw") || die "headless OIDC login failed — see agent/README.md 'magic-link fallback'"
  me=$(outline_call "$jwt" auth.info); [[ "$(HTTP)" == 200 ]] || die "auth.info with the session failed (HTTP $(HTTP))"
  uid=$(jq -r .data.user.id <<<"$me"); ok "Outline user $(jq -r .data.user.name <<<"$me") (${uid}, role $(jq -r .data.user.role <<<"$me"))"
  log "3/6 collection ${COLLECTION} (private, no public sharing)"
  local cid; cid=$(ol_collection_id "$COLLECTION")
  if [[ -z "$cid" ]]; then
    cid=$(admin_call collections.create "$(jq -cn --arg n "$COLLECTION" '{name:$n, permission:null, sharing:false, description:"Memory store for external agents (agent/ pinhole). Private: explicit membership only."}')" | jq -r '.data.id // empty')
    [[ "$(HTTP)" == 200 && -n "$cid" ]] || die "collections.create failed (HTTP $(HTTP))"; chg "created ${COLLECTION} (${cid})"
  else ok "exists (${cid})"; fi
  local cinfo; cinfo=$(admin_call collections.info "$(jq -cn --arg id "$cid" '{id:$id}')")
  if [[ "$(jq -r '.data.permission' <<<"$cinfo")" != null || "$(jq -r '.data.sharing' <<<"$cinfo")" != false ]]; then
    admin_call collections.update "$(jq -cn --arg id "$cid" '{id:$id, permission:null, sharing:false}')" >/dev/null; [[ "$(HTTP)" == 200 ]] || die "collections.update failed (HTTP $(HTTP))"
    chg "default access → none, sharing → off"
  else ok "default access none, sharing off"; fi
  admin_call collections.add_user "$(jq -cn --arg id "$cid" --arg u "$uid" '{id:$id, userId:$u, permission:"read_write"}')" >/dev/null
  [[ "$(HTTP)" == 200 ]] || die "collections.add_user failed (HTTP $(HTTP))"; ok "${IDENTITY} is read_write member of ${COLLECTION}"
  log "4/6 role → member (Outline Guests are read-only; write needs Member)"
  ol_set_role "$uid" member; ok "role member"
  log "4b/6 privating every OTHER collection (Members reach team-default collections; confine to ${COLLECTION})"
  local others; others=$(admin_call collections.list '{"limit":100}' | jq -r --arg id "$cid" '.data[] | select(.id!=$id and .permission!=null) | [.id,.name] | @tsv')
  if [[ -n "$others" ]]; then
    while IFS=$'''	''' read -r oid oname; do
      [[ -n "$oid" ]] || continue
      admin_call collections.update "$(jq -cn --arg id "$oid" '{id:$id, permission:null}')" >/dev/null
      [[ "$(HTTP)" == 200 ]] && chg "collection '''${oname}''' default access → none (was team-default; explicit members only)" || die "collections.update ${oname} failed (HTTP $(HTTP))"
    done <<<"$others"
  else ok "no team-default collections to private"; fi
  log "5/6 verification as ${IDENTITY}"
  local names; names=$(outline_call "$jwt" collections.list '{"limit":100}' | jq -r '[.data[].name] | sort | join(",")')
  [[ "$names" == "$COLLECTION" ]] && ok "collections.list → only ${COLLECTION}" || die "collections.list returned: '''${names}''' (expected only ${COLLECTION})."
  local doc did
  doc=$(outline_call "$jwt" documents.create "$(jq -cn --arg c "$cid" '{collectionId:$c, title:"agent provisioning smoke test", text:"created by agent/provision.sh identity ensure — safe to delete", publish:true}')")
  [[ "$(HTTP)" == 200 ]] && ok "documents.create in ${COLLECTION} → 200 (member + read_write can write)" || die "documents.create in ${COLLECTION} failed (HTTP $(HTTP)): $(head -c 200 <<<"$doc")"
  did=$(jq -r .data.id <<<"$doc")
  # A read_write member can trash (soft-delete) its own docs; permanent purge is admin-only.
  outline_call "$jwt" documents.delete "$(jq -cn --arg id "$did" '{id:$id}')" >/dev/null
  [[ "$(HTTP)" == 200 ]] && ok "documents.delete (trash) as ${IDENTITY} → 200" || warn "agent soft-delete returned HTTP $(HTTP)"
  admin_call documents.delete "$(jq -cn --arg id "$did" '{id:$id, permanent:true}')" >/dev/null
  [[ "$(HTTP)" == 200 ]] && ok "smoke document purged (admin cleanup)" || warn "could not purge smoke document ${did} (HTTP $(HTTP)) — delete by hand"
  # An admin-only collection the agent is not a member of must be invisible/forbidden.
  local other; other=$(admin_call collections.list '{"limit":100}' | jq -r --arg n "$COLLECTION" '[.data[] | select(.name!=$n)][0].id // empty')
  if [[ -n "$other" ]]; then
    outline_call "$jwt" documents.list "$(jq -cn --arg c "$other" '{collectionId:$c}')" >/dev/null
    [[ "$(HTTP)" == 403 || "$(HTTP)" == 404 ]] && ok "documents.list on a non-member collection → $(HTTP)" || die "expected 403/404 on a non-member collection, got HTTP $(HTTP)"
  fi
  log "6/6 deactivate Authentik user"
  authentik_deactivate
  echo; echo "  identity ready: Outline user ${IDENTITY} (guest) · collection ${COLLECTION} (${cid}) · Authentik user deactivated"
}

# The token is the GATEWAY's, injected server-side; clients never hold it. `issue`
# mints a fresh Outline key, installs it into the VPS gateway, verifies injection,
# then rotates out the previous keys. `revoke` deletes every key and blanks the
# gateway. There is no per-client token and nothing to hand out.
cmd_token() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    issue)
      local days=90
      while (( $# )); do case "$1" in --expires-days) days="$2"; shift 2 ;; --client) shift 2 ;; *) die "unknown arg $1" ;; esac; done
      cmd_preflight; require_admin
      log "login as ${IDENTITY}"
      local jwt me uid role existing; jwt=$(authentik_login_session) || die "headless OIDC login failed"
      me=$(outline_call "$jwt" auth.info); uid=$(jq -r .data.user.id <<<"$me"); role=$(jq -r .data.user.role <<<"$me"); ok "session for ${uid} (role ${role})"
      existing=$(outline_call "$jwt" apiKeys.list '{"limit":100}' | jq -r '.data[].id')   # rotate these out after the new one is live
      local name exp payload resp secret
      name="agent-injected-$(date -u +%Y%m%d%H%M%S)"; exp=$(iso_plus_days "$days")
      payload=$(jq -cn --arg n "$name" --arg e "$exp" --argjson s "$(printf '%s\n' "${SCOPES[@]}" | jq -R . | jq -sc .)" '{name:$n, expiresAt:$e, scope:$s}')
      log "apiKeys.create ${name} (expires ${exp})"
      resp=$(outline_call "$jwt" apiKeys.create "$payload")
      [[ "$(HTTP)" == 200 ]] || die "apiKeys.create failed (HTTP $(HTTP)): $(head -c 300 <<<"$resp")"
      secret=$(jq -r '.data.secret // .data.value // empty' <<<"$resp"); [[ -n "$secret" ]] || die "no secret in apiKeys.create response: $(head -c 300 <<<"$resp")"
      authentik_deactivate
      log "installing the token into the gateway on ${VPS} (server-side injection)"
      vps_set_token "$secret"; ok "token installed; agent-api-gw recreated"
      log "verifying: a gateway call with NO client credential must now succeed"
      local vhttp who
      vhttp=$(vps_ssh "curl -s -o /dev/null -w '%{http_code}' --max-time 20 -X POST -H 'Content-Type: application/json' -d '{}' http://127.0.0.1:${API_PORT}/api/auth.info")
      [[ "$vhttp" == 200 ]] || die "gateway injection check failed (HTTP ${vhttp}) — token not active"
      who=$(vps_ssh "curl -s --max-time 20 -X POST -H 'Content-Type: application/json' -d '{}' http://127.0.0.1:${API_PORT}/api/auth.info" | jq -r '.data.user.name + " (" + .data.user.role + ")"')
      ok "gateway injects the token → auth.info returns ${who}"
      if [[ -n "$existing" ]]; then
        jwt=$(authentik_login_session) || die "could not reopen a session to rotate out old keys"
        for id in $existing; do outline_call "$jwt" apiKeys.delete "$(jq -cn --arg id "$id" '{id:$id}')" >/dev/null; [[ "$(HTTP)" == 200 ]] && chg "rotated out old key ${id}" || warn "delete ${id} → HTTP $(HTTP)"; done
        authentik_deactivate
      fi
      ledger_set "outline-token" - "$name" "$(today)" "${exp%%T*}"
      git_commit_push "agent: server-side Outline token ${name} installed (expiry rule)"
      echo; ok "Server-side token active. Clients need ONLY the SSH tunnel — no token to hand out." ;;
    list)
      require_admin; local u; u=$(ol_user); [[ -n "$u" ]] || die "Outline user ${IDENTITY} not found"
      echo "Outline API keys for ${IDENTITY} (the active one is injected by the gateway):"
      admin_call apiKeys.list "$(jq -cn --arg u "$(jq -r .id <<<"$u")" '{userId:$u, limit:100}')" | jq -r '.data[] | [.name, (.expiresAt // "never"), (.lastActiveAt // "unused")] | @tsv' | column -t ;;
    revoke)
      # Delete every agent key (self-only) AND blank the gateway token → fully disabled.
      cmd_preflight
      local jwt ids; jwt=$(authentik_login_session) || die "could not open an agent session to delete keys"
      ids=$(outline_call "$jwt" apiKeys.list '{"limit":100}' | jq -r '.data[].id')
      if [[ -z "$ids" ]]; then ok "no Outline keys to delete"; else
        for id in $ids; do outline_call "$jwt" apiKeys.delete "$(jq -cn --arg id "$id" '{id:$id}')" >/dev/null; [[ "$(HTTP)" == 200 ]] && chg "revoked ${id}" || warn "delete ${id} → HTTP $(HTTP)"; done
      fi
      authentik_deactivate
      log "blanking the gateway token on ${VPS}"
      vps_set_token ""; ok "gateway token blanked (API now 401s at Outline until re-issued)"
      ledger_set "outline-token" - "" "" ""
      git_commit_push "agent: server-side Outline token revoked" ;;
    *) die "usage: token issue [--expires-days N] | list | revoke" ;;
  esac
}

print_bundle() {  # [client-label] — the client bundle. NO token: the gateway injects it server-side.
  local client="${1:-<client>}" hk fp cid=""
  hk=$(ssh-keyscan -t ed25519 -T 10 "$VPS" 2>/dev/null | grep -v '^#' | head -1); fp=$(ssh-keygen -lf /dev/stdin <<<"$hk" | awk '{print $2}')
  [[ -n "$ADMIN_TOKEN" ]] && cid=$(ol_collection_id "$COLLECTION" 2>/dev/null || true)
  cat <<B

== agent client bundle · client=${client} · issued $(today) ==
SSH endpoint : ${IDENTITY}@${VPS}:22   (ed25519 host key ${fp})
known_hosts  : ${hk}
Tunnel       : ssh -N -o BatchMode=yes -o ExitOnForwardFailure=yes -o StrictHostKeyChecking=yes \\
                 -o UserKnownHostsFile=~/.ssh/known_hosts_hs -o HostKeyAlgorithms=ssh-ed25519 \\
                 -o IdentitiesOnly=yes -i <client private key> -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \\
                 -L 127.0.0.1:${API_PORT}:127.0.0.1:${API_PORT} ${IDENTITY}@${VPS}
               (autossh: autossh -M 0 -N <same options>)
API base URL : http://127.0.0.1:${API_PORT}/api      (POST only, Content-Type: application/json)   backend: outline
Credential   : NONE on the client. Authentication IS the SSH tunnel key; the gateway
               injects the Outline token server-side. Do NOT send an Authorization header.
Collection   : ${COLLECTION}${cid:+  id=${cid}}   (the only collection this identity can see or write)
Allowed      : ${SCOPES[*]}
Limits       : 512 KB body · 10 r/s · gateway errors are {"ok":false,"error":...}; Outline errors are Outline JSON
Smoke test   : curl -sS -X POST http://127.0.0.1:${API_PORT}/api/auth.info \\
                 -H 'Content-Type: application/json' -d '{}'
B
}
cmd_bundle() { print_bundle "${2:-<client>}"; }

# ── end-to-end test from the Mac acting as a client ─────────────────────────
cmd_test() {
  local client="" key=""
  while (( $# )); do case "$1" in --client) client="$2"; shift 2 ;; --key) key="$2"; shift 2 ;; --token|--token-file) shift 2 ;; *) die "unknown arg $1" ;; esac; done
  [[ -n "$client" && -f "$key" ]] || die "usage: test --client <label> --key <private-key>   (no token — the gateway injects it)"
  local pass=0 fail=0 P="127.0.0.1:${LOCAL_TEST_PORT}" B="http://127.0.0.1:${LOCAL_TEST_PORT}" ctl
  ctl=$(mktemp -u "${TMPDIR:-/tmp}/agent-test-XXXX")
  local -a S=(-o BatchMode=yes -o ConnectTimeout=15 -o IdentitiesOnly=yes -i "$key" -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR)
  check() { local label="$1" want="$2" got="$3"; if [[ "$got" == "$want" ]]; then ok "$label → $got"; pass=$((pass+1)); else printf '  \033[1;31m✗\033[0m %s → %s (expected %s)\n' "$label" "$got" "$want"; fail=$((fail+1)); fi; }
  c() { curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$@"; }
  # set -e-safe: an expected-to-fail ssh runs inside `if`, always time-boxed, stdin from /dev/null.
  denied_session() { if timeout 20 ssh "${S[@]}" "$@" -l "$IDENTITY" "$VPS" </dev/null >/dev/null 2>&1; then echo ok; else echo fail; fi; }
  # open a background forward via a control master; returns 0 if the master came up.
  open_fwd() { timeout 20 ssh "${S[@]}" -N -f -M -S "$1" -o ExitOnForwardFailure=yes "${@:2}" -l "$IDENTITY" "$VPS" >/dev/null 2>&1; }
  close_fwd() { ssh -S "$1" -O exit -l "$IDENTITY" "$VPS" >/dev/null 2>&1 || true; }

  log "negative: the agent account yields only the one forward"
  check "shell / exec (MaxSessions 0 · ForceCommand)" fail "$(denied_session)"
  check "exec 'true' (no session)"                    fail "$(denied_session true)"
  check "pty request (-tt)"                            fail "$(denied_session -tt)"
  check "sftp subsystem"                               fail "$(if timeout 20 sftp -o BatchMode=yes -o IdentitiesOnly=yes -i "$key" -o StrictHostKeyChecking=accept-new -b /dev/null "${IDENTITY}@${VPS}" >/dev/null 2>&1; then echo ok; else echo fail; fi)"
  check "-R remote forward (ExitOnForwardFailure)"     fail "$(denied_session -N -o ExitOnForwardFailure=yes -R "$((LOCAL_TEST_PORT+2)):127.0.0.1:22")"
  # denied local forward to a non-allowlisted target: the master may background OK, but the port stays dead.
  open_fwd "${ctl}.neg" -L "127.0.0.1:$((LOCAL_TEST_PORT+1)):127.0.0.1:22"; sleep 1
  check "-L to 127.0.0.1:22 (PermitOpen blocks)" 000 "$(c "http://127.0.0.1:$((LOCAL_TEST_PORT+1))/")"; close_fwd "${ctl}.neg"
  open_fwd "${ctl}.negb" -L "127.0.0.1:$((LOCAL_TEST_PORT+1)):localhost:8093"; sleep 1
  check "-L to localhost:8093 (string ≠ 127.0.0.1)" 000 "$(c "http://127.0.0.1:$((LOCAL_TEST_PORT+1))/healthz")"; close_fwd "${ctl}.negb"

  log "positive: tunnel + gateway"
  open_fwd "$ctl" -L "${P}:127.0.0.1:${API_PORT}" || die "could not open the agent tunnel"
  sleep 1
  # The client sends NO Authorization header — the gateway injects the token.
  local NOAUTH=(-X POST -H 'Content-Type: application/json' -d '{}')
  check "gw /healthz"                            200 "$(c "$B/healthz")"
  check "gw /healthz/upstream (full hop)"        200 "$(c "$B/healthz/upstream")"
  check "no client credential → injected → 200"  200 "$(c "${NOAUTH[@]}" "$B/api/auth.info")"
  check "client-sent bogus bearer is overwritten → 200" 200 "$(c -X POST -H 'Authorization: Bearer ol_api_deadbeefdeadbeefdeadbeefdeadbeefdead' -H 'Content-Type: application/json' -d '{}' "$B/api/auth.info")"
  check "GET → 405"                              405 "$(c -X GET "$B/api/documents.list")"
  check "non-JSON body → 415"                    415 "$(c -X POST -d '{}' "$B/api/documents.list")"
  check "apiKeys.create not allowlisted → 403"   403 "$(c "${NOAUTH[@]}" "$B/api/apiKeys.create")"
  check "path traversal → 403"                   403 "$(c --path-as-is "${NOAUTH[@]}" "$B/api/documents.info/../apiKeys.create")"
  # authenticated behaviour (via the injected token; client still sends nothing)
  local me names cid doc did
  me=$(curl -s --max-time 20 "${NOAUTH[@]}" "$B/api/auth.info")
  check "auth.info identity (injected)"          "$IDENTITY" "$(jq -r '.data.user.name' <<<"$me" 2>/dev/null | sed 's/Agent (service identity)/'"$IDENTITY"'/')"
  names=$(curl -s --max-time 20 -X POST -H 'Content-Type: application/json' -d '{"limit":100}' "$B/api/collections.list" | jq -r '[.data[].name]|sort|join(",")')
  check "collections.list → only ${COLLECTION}"  "$COLLECTION" "$names"
  cid=$(curl -s --max-time 20 -X POST -H 'Content-Type: application/json' -d "$(jq -cn --arg n "$COLLECTION" '{query:$n,limit:10}')" "$B/api/collections.list" | jq -r --arg n "$COLLECTION" '.data[]|select(.name==$n)|.id' | head -1)
  doc=$(curl -s --max-time 25 -X POST -H 'Content-Type: application/json' -d "$(jq -cn --arg c "$cid" '{collectionId:$c,title:"agent e2e test",text:"written through the tunnel by agent/provision.sh test — safe to delete",publish:true}')" "$B/api/documents.create")
  did=$(jq -r '.data.id // empty' <<<"$doc"); check "documents.create in ${COLLECTION}" ok "$([[ -n "$did" ]] && echo ok || echo "fail:$(jq -r '.message // .error // "?"' <<<"$doc")")"
  if [[ -n "$did" ]]; then
    check "documents.update"          200 "$(c -X POST -H 'Content-Type: application/json' -d "$(jq -cn --arg id "$did" '{id:$id,text:"appended",append:true}')" "$B/api/documents.update")"
    check "documents.info"            200 "$(c -X POST -H 'Content-Type: application/json' -d "$(jq -cn --arg id "$did" '{id:$id}')" "$B/api/documents.info")"
    check "documents.delete (trash)"  200 "$(c -X POST -H 'Content-Type: application/json' -d "$(jq -cn --arg id "$did" '{id:$id}')" "$B/api/documents.delete")"
    admin_call documents.delete "$(jq -cn --arg id "$did" '{id:$id, permanent:true}')" >/dev/null 2>&1 || true   # purge if an admin token is present
  fi
  check "documents.move not allowlisted → 403"   403 "$(c "${NOAUTH[@]}" "$B/api/documents.move")"
  check "shares.create not allowlisted → 403"    403 "$(c "${NOAUTH[@]}" "$B/api/shares.create")"
  check "users.list not allowlisted → 403"       403 "$(c "${NOAUTH[@]}" "$B/api/users.list")"
  close_fwd "$ctl"

  log "public-leak check (traefik-public must not expose the gateway)"
  check "https://${VPS}/api/auth.info (Host outline.lab.gn.al)" 404 "$(c -X POST -H 'Host: outline.lab.gn.al' "https://${VPS}/api/auth.info")"
  check "https://${VPS}/healthz/upstream"                       404 "$(c "https://${VPS}/healthz/upstream")"

  echo; echo "  PASS ${pass}  FAIL ${fail}"; [[ $fail -eq 0 ]]
}

cmd_revoke() {
  local client=""; local all=0
  while (( $# )); do case "$1" in --client) client="$2"; shift 2 ;; --all) all=1; shift ;; *) die "unknown arg $1" ;; esac; done
  [[ -n "$client" || $all -eq 1 ]] || die "usage: revoke (--client <label> | --all)"
  if (( all )); then
    require_admin
    log "1/3 deleting every Outline key + blanking the gateway token"; cmd_token revoke
    log "2/3 stopping the gateway"; vps_ssh "cd ${VPS_REPO} && docker compose -p cloudnet stop agent-api-gw" >/dev/null 2>&1 && ok "agent-api-gw stopped"
    log "3/3 removing all client keys + live sessions"; vps_ssh "sudo rm -f /etc/ssh/authorized_keys.d/${IDENTITY}; sudo pkill -u ${IDENTITY} || true" && ok "key file removed, sessions killed"
    warn "repo still lists the keys — run ssh-key remove per client (and re-issue the token + start the gateway) when re-enabling"
  else
    # Per-client: the authoritative cut-off is removing that client's SSH key (no
    # key → no tunnel → no reach). The shared server-side token is unaffected, so
    # other clients keep working. Rotate the token separately if this client's key
    # may have leaked (`token issue`).
    log "revoking client=${client} (removing its SSH key; live sessions dropped)"
    cmd_ssh_key remove --client "$client"
    vps_ssh "sudo pkill -u ${IDENTITY} || true" >/dev/null 2>&1 || true
    ok "client ${client} can no longer connect; other clients unaffected. Rotate the token with 'token issue' if the key may have leaked."
  fi
}

# ── main ───────────────────────────────────────────────────────────────────
ARGS=()
while (( $# )); do case "$1" in --admin-token-file) ADMIN_TOKEN=$(tr -d '\n' <"$2"); shift 2 ;; *) ARGS+=("$1"); shift ;; esac; done
set -- "${ARGS[@]+"${ARGS[@]}"}"
case "${1:-}" in
  preflight) cmd_preflight ;;
  ssh-key)   shift; cmd_ssh_key "$@" ;;
  host-key)  cmd_host_key ;;
  identity)  shift; cmd_identity "$@" ;;
  token)     shift; cmd_token "$@" ;;
  bundle)    cmd_bundle "$@" ;;
  test)      shift; cmd_test "$@" ;;
  revoke)    shift; cmd_revoke "$@" ;;
  -h|--help|"") sed -n '2,24p' "$0" ;;
  *) die "unknown command: $1" ;;
esac
