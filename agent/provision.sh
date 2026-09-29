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
#   provision.sh identity ensure                # Authentik user + Outline Guest user + Memories collection (needs OUTLINE_ADMIN_TOKEN)
#   provision.sh token issue --client <label> [--expires-days 90]   # prints the client bundle ONCE
#   provision.sh token list | token revoke (<id> | --client <label> | --all)
#   provision.sh bundle [--client <label>]      # reprint host key + tunnel command + URL + allowlist (no token)
#   provision.sh test --client <label> --key <private-key> [--token <ol_api_…> | --token-file <f>]
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

HTTP=""
pcurl() { curl -sS --socks5-hostname "$PROXY" --max-time 60 "$@"; }
# outline_call <bearer> <method> <json> → prints body, sets HTTP
outline_call() {
  local out
  out=$(pcurl -w $'\n%{http_code}' -X POST -H "Authorization: Bearer $1" -H 'Content-Type: application/json' \
        --data "${3:-{\}}" "${OUTLINE}/api/$2") || { HTTP=000; return 1; }
  HTTP=${out##*$'\n'}; printf '%s' "${out%$'\n'*}"
}
ADMIN_TOKEN="${OUTLINE_ADMIN_TOKEN:-}"
require_admin() {
  [[ -n "$ADMIN_TOKEN" ]] || die "OUTLINE_ADMIN_TOKEN not set (or --admin-token-file). Mint one in Outline → Settings → API & Apps (scope: users.* collections.* apiKeys.* auth.info, short expiry)."
  local me; me=$(outline_call "$ADMIN_TOKEN" auth.info) || true
  [[ "$HTTP" == 200 ]] || die "admin token rejected by Outline (HTTP ${HTTP}): $(head -c 200 <<<"$me")"
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

# ak_call <METHOD> <path> [json] → prints body, sets HTTP. Runs ON neptune with the
# bootstrap token from ~/cn-authentik/.env (the token never leaves neptune).
ak_call() {
  local method="$1" path="$2" body="${3:-}" dflag="" out
  [[ -n "$body" ]] && dflag="-d @-"
  out=$(printf '%s' "$body" | neptune_ssh "cd ~/cn-authentik && T=\$(grep -E '^AUTHENTIK_BOOTSTRAP_TOKEN=' .env | cut -d= -f2-) && curl -sS -k --max-time 60 -w '\n%{http_code}' -H \"Authorization: Bearer \$T\" -H 'Content-Type: application/json' -H 'Accept: application/json' -X '$method' 'http://127.0.0.1:9000/api/v3$path' $dflag") || { HTTP=000; return 1; }
  HTTP=${out##*$'\n'}; printf '%s' "${out%$'\n'*}"
}
ak_user_pk() { ak_call GET "/core/users/?username=${IDENTITY}&page_size=50" | jq -r --arg u "$IDENTITY" '[.results[] | select(.username==$u)] | first | .pk // empty'; }
ak_set_active() {  # <pk> <true|false>
  ak_call PATCH "/core/users/$1/" "{\"is_active\": $2}" >/dev/null; [[ "$HTTP" == 200 ]] || die "Authentik: could not set is_active=$2 (HTTP $HTTP)"
}
ak_set_password() {  # <pk> <password>
  jq -cn --arg p "$2" '{password:$p}' | { read -r j; ak_call POST "/core/users/$1/set_password/" "$j" >/dev/null; }
  [[ "$HTTP" == 204 ]] || die "Authentik: set_password failed (HTTP $HTTP)"
}
gen_pw() { openssl rand -base64 30 | tr -d '\n=/+' | head -c 32; }
iso_plus_days() { date -u -v+"$1"d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "+$1 days" +%Y-%m-%dT%H:%M:%SZ; }
iso_to_epoch() { date -u -j -f %Y-%m-%dT%H:%M:%SZ "$1" +%s 2>/dev/null || date -u -d "$1" +%s; }
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
          summary: "agent token for client '${c}' expires ${ex}"
          description: "Token ${tn} expires on ${ex}. Rotate: agent/provision.sh token issue --client ${c}, hand the new bundle to the client, then token revoke the old one."
RULE
    done < <(grep -E '^\| ' "$LEDGER" 2>/dev/null || true)
    [[ $any -eq 1 ]] || echo '    rules: []'
  } >"$RULES_FILE"
}
git_commit_push() {  # <message>
  ( cd "$REPO" && git add -A agent tailnet/prometheus/agent-rules.yml && { git diff --cached --quiet && ok "nothing to commit" || { git commit -q -m "$1" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>" && git push -q origin HEAD && chg "committed + pushed: $1"; }; } )
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
      [[ -n "$client" ]] && ledger_set "$client" "" - - -
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
  if [[ "$HTTP" != 200 ]]; then
    admin_call users.demote "$(jq -cn --arg id "$1" --arg r "$2" '{id:$id,to:$r}')" >/dev/null
    [[ "$HTTP" == 200 ]] || die "could not set role ${2} (users.update_role and users.demote both failed, HTTP $HTTP)"
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
  me=$(outline_call "$jwt" auth.info); [[ "$HTTP" == 200 ]] || die "auth.info with the session failed (HTTP $HTTP)"
  uid=$(jq -r .data.user.id <<<"$me"); ok "Outline user $(jq -r .data.user.name <<<"$me") (${uid}, role $(jq -r .data.user.role <<<"$me"))"
  log "3/6 collection ${COLLECTION} (private, no public sharing)"
  local cid; cid=$(ol_collection_id "$COLLECTION")
  if [[ -z "$cid" ]]; then
    cid=$(admin_call collections.create "$(jq -cn --arg n "$COLLECTION" '{name:$n, permission:null, sharing:false, description:"Memory store for external agents (agent/ pinhole). Private: explicit membership only."}')" | jq -r '.data.id // empty')
    [[ "$HTTP" == 200 && -n "$cid" ]] || die "collections.create failed (HTTP $HTTP)"; chg "created ${COLLECTION} (${cid})"
  else ok "exists (${cid})"; fi
  local cinfo; cinfo=$(admin_call collections.info "$(jq -cn --arg id "$cid" '{id:$id}')")
  if [[ "$(jq -r '.data.permission' <<<"$cinfo")" != null || "$(jq -r '.data.sharing' <<<"$cinfo")" != false ]]; then
    admin_call collections.update "$(jq -cn --arg id "$cid" '{id:$id, permission:null, sharing:false}')" >/dev/null; [[ "$HTTP" == 200 ]] || die "collections.update failed (HTTP $HTTP)"
    chg "default access → none, sharing → off"
  else ok "default access none, sharing off"; fi
  admin_call collections.add_user "$(jq -cn --arg id "$cid" --arg u "$uid" '{id:$id, userId:$u, permission:"read_write"}')" >/dev/null
  [[ "$HTTP" == 200 ]] || die "collections.add_user failed (HTTP $HTTP)"; ok "${IDENTITY} is read_write member of ${COLLECTION}"
  log "4/6 role → guest"
  ol_set_role "$uid" guest; ok "role guest"
  log "5/6 verification as ${IDENTITY}"
  local names; names=$(outline_call "$jwt" collections.list '{"limit":100}' | jq -r '[.data[].name] | sort | join(",")')
  [[ "$names" == "$COLLECTION" ]] && ok "collections.list → only ${COLLECTION}" || die "collections.list returned: '${names}' (expected only ${COLLECTION}). Make the others private or fix the role."
  local doc did
  doc=$(outline_call "$jwt" documents.create "$(jq -cn --arg c "$cid" '{collectionId:$c, title:"agent provisioning smoke test", text:"created by agent/provision.sh identity ensure — safe to delete", publish:true}')")
  [[ "$HTTP" == 200 ]] && ok "documents.create in ${COLLECTION} → 200 (guest + read_write can write)" || die "documents.create in ${COLLECTION} failed (HTTP $HTTP): $(head -c 200 <<<"$doc") — Guest may not be allowed to write; see README fallback"
  did=$(jq -r .data.id <<<"$doc")
  outline_call "$jwt" documents.delete "$(jq -cn --arg id "$did" '{id:$id, permanent:true}')" >/dev/null; [[ "$HTTP" == 200 ]] && ok "smoke document deleted" || warn "could not delete smoke document ${did} (HTTP $HTTP) — delete by hand"
  local other; other=$(admin_call collections.list '{"limit":100}' | jq -r --arg n "$COLLECTION" '[.data[] | select(.name!=$n)][0].id // empty')
  if [[ -n "$other" ]]; then
    outline_call "$jwt" documents.list "$(jq -cn --arg c "$other" '{collectionId:$c}')" >/dev/null
    [[ "$HTTP" == 403 ]] && ok "documents.list on another collection → 403" || die "expected 403 on another collection, got HTTP $HTTP"
  fi
  log "6/6 deactivate Authentik user"
  authentik_deactivate
  echo; echo "  identity ready: Outline user ${IDENTITY} (guest) · collection ${COLLECTION} (${cid}) · Authentik user deactivated"
}

cmd_token() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    issue)
      local client="" days=90
      while (( $# )); do case "$1" in --client) client="$2"; shift 2 ;; --expires-days) days="$2"; shift 2 ;; *) die "unknown arg $1" ;; esac; done
      [[ -n "$client" ]] || die "usage: token issue --client <label> [--expires-days N]"
      grep -qE " client=${client}( |$)" "$KEYS_FILE" || warn "no ssh key registered for client=${client} yet (ssh-key add)"
      cmd_preflight; require_admin
      log "login as ${IDENTITY}"
      local jwt me uid role; jwt=$(authentik_login_session) || die "headless OIDC login failed"
      me=$(outline_call "$jwt" auth.info); uid=$(jq -r .data.user.id <<<"$me"); role=$(jq -r .data.user.role <<<"$me"); ok "session for ${uid} (role ${role})"
      local name exp payload resp secret
      name="agent-${client}-$(date -u +%Y%m%d)"; exp=$(iso_plus_days "$days")
      payload=$(jq -cn --arg n "$name" --arg e "$exp" --argjson s "$(printf '%s\n' "${SCOPES[@]}" | jq -R . | jq -sc .)" '{name:$n, expiresAt:$e, scope:$s}')
      log "apiKeys.create ${name} (expires ${exp})"
      resp=$(outline_call "$jwt" apiKeys.create "$payload")
      if [[ "$HTTP" != 200 ]]; then
        warn "apiKeys.create refused as ${role} (HTTP $HTTP) — temporarily promoting to member"
        ol_set_role "$uid" member
        resp=$(outline_call "$jwt" apiKeys.create "$payload")
        ol_set_role "$uid" guest; ok "role restored to guest"
        [[ "$HTTP" == 200 ]] || die "apiKeys.create still failing (HTTP $HTTP): $(head -c 300 <<<"$resp")"
      fi
      secret=$(jq -r '.data.secret // .data.value // empty' <<<"$resp"); [[ -n "$secret" ]] || die "no secret in apiKeys.create response: $(head -c 300 <<<"$resp")"
      log "verifying the new token"
      me=$(outline_call "$secret" auth.info); [[ "$HTTP" == 200 && "$(jq -r .data.user.role <<<"$me")" == guest ]] && ok "token works, role guest" || die "token verification failed (HTTP $HTTP, role $(jq -r '.data.user.role // "?"' <<<"$me"))"
      authentik_deactivate
      local cid; cid=$(ol_collection_id "$COLLECTION")
      ledger_set "$client" - "$name" "$(today)" "${exp%%T*}"
      git_commit_push "agent: token ${name} issued (metadata + expiry rule)"
      print_bundle "$client" "$secret" "$exp" "$cid" ;;
    list)
      require_admin; local u; u=$(ol_user); [[ -n "$u" ]] || die "Outline user ${IDENTITY} not found"
      admin_call apiKeys.list "$(jq -cn --arg u "$(jq -r .id <<<"$u")" '{userId:$u, limit:100}')" | jq -r '.data[] | [.id, .name, (.expiresAt // "never"), (.lastActiveAt // "unused")] | @tsv' | column -t ;;
    revoke)
      require_admin; local u ids sel="${1:-}"; u=$(ol_user); [[ -n "$u" ]] || die "Outline user ${IDENTITY} not found"
      local all; all=$(admin_call apiKeys.list "$(jq -cn --arg u "$(jq -r .id <<<"$u")" '{userId:$u, limit:100}')")
      case "$sel" in
        --all) ids=$(jq -r '.data[].id' <<<"$all") ;;
        --client) ids=$(jq -r --arg p "agent-${2:-}-" '.data[] | select(.name|startswith($p)) | .id' <<<"$all"); ledger_set "${2:-}" - "" "" "" ;;
        "") die "usage: token revoke (<id> | --client <label> | --all)" ;;
        *) ids="$sel" ;;
      esac
      for id in $ids; do admin_call apiKeys.delete "$(jq -cn --arg id "$id" '{id:$id}')" >/dev/null; [[ "$HTTP" == 200 ]] && chg "revoked ${id}" || warn "delete ${id} → HTTP $HTTP"; done
      [[ "$sel" == --all ]] && { while read -r c; do [[ -n "$c" ]] && ledger_set "$c" - "" "" ""; done < <(grep -E '^\| ' "$LEDGER" | awk -F'|' 'NR>2{print $2}' | xargs -n1 2>/dev/null || true); }
      git_commit_push "agent: token(s) revoked ${sel} ${2:-}" ;;
    *) die "usage: token issue|list|revoke" ;;
  esac
}

print_bundle() {  # <client> <token|""> <expires|""> <collectionId|"">
  local client="$1" token="${2:-}" exp="${3:-}" cid="${4:-}" hk fp
  hk=$(ssh-keyscan -t ed25519 -T 10 "$VPS" 2>/dev/null | grep -v '^#' | head -1); fp=$(ssh-keygen -lf /dev/stdin <<<"$hk" | awk '{print $2}')
  cat <<B

== agent client bundle · client=${client} · issued $(today)${exp:+ · token expires ${exp%%T*}} ==
SSH endpoint : ${IDENTITY}@${VPS}:22   (ed25519 host key ${fp})
known_hosts  : ${hk}
Tunnel       : ssh -N -o BatchMode=yes -o ExitOnForwardFailure=yes -o StrictHostKeyChecking=yes \\
                 -o UserKnownHostsFile=~/.ssh/known_hosts_hs -o HostKeyAlgorithms=ssh-ed25519 \\
                 -o IdentitiesOnly=yes -i <client private key> -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \\
                 -L 127.0.0.1:${API_PORT}:127.0.0.1:${API_PORT} ${IDENTITY}@${VPS}
               (autossh: autossh -M 0 -N <same options>)
API base URL : http://127.0.0.1:${API_PORT}/api      (POST only, Content-Type: application/json)   backend: outline
Token        : ${token:-<not shown — use: token issue --client ${client}>}${token:+   (shown ONCE — not stored on the homelab side)}
Collection   : ${COLLECTION}${cid:+  id=${cid}}   (the only collection this identity can see or write)
Allowed      : ${SCOPES[*]}
Limits       : 512 KB body · 10 r/s · gateway errors are {"ok":false,"error":...}; Outline errors are Outline JSON
Smoke test   : curl -sS -X POST http://127.0.0.1:${API_PORT}/api/auth.info -H "Authorization: Bearer \$TOKEN" \\
                 -H 'Content-Type: application/json' -d '{}'
B
}
cmd_bundle() { local client="${2:-<client>}"; local cid=""; [[ -n "$ADMIN_TOKEN" ]] && cid=$(ol_collection_id "$COLLECTION" 2>/dev/null || true); print_bundle "$client" "" "" "$cid"; }

# ── end-to-end test from the Mac acting as a client ─────────────────────────
cmd_test() {
  local client="" key="" token="${AGENT_TEST_TOKEN:-}"
  while (( $# )); do case "$1" in --client) client="$2"; shift 2 ;; --key) key="$2"; shift 2 ;; --token) token="$2"; shift 2 ;; --token-file) token=$(tr -d '\n' <"$2"); shift 2 ;; *) die "unknown arg $1" ;; esac; done
  [[ -n "$client" && -f "$key" ]] || die "usage: test --client <label> --key <private-key> [--token ol_api_… | --token-file f]"
  local ctl pass=0 fail=0 P="127.0.0.1:${LOCAL_TEST_PORT}" B="http://127.0.0.1:${LOCAL_TEST_PORT}"
  ctl=$(mktemp -u /tmp/agent-test-XXXX.sock)
  check() { local label="$1" want="$2" got="$3"; if [[ "$got" == "$want" ]]; then ok "$label → $got"; pass=$((pass+1)); else printf '  \033[1;31m✗\033[0m %s → %s (expected %s)\n' "$label" "$got" "$want"; fail=$((fail+1)); fi; }
  csh() { ssh -o BatchMode=yes -o ConnectTimeout=15 -o IdentitiesOnly=yes -i "$key" -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR "$@"; }
  c() { curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$@"; }
  log "negative: the agent account must not yield anything but the one forward"
  csh -l "$IDENTITY" "$VPS" true >/dev/null 2>&1; check "shell/command (MaxSessions 0)" "fail" "$([[ $? -eq 0 ]] && echo ok || echo fail)"
  csh -N -o ExitOnForwardFailure=yes -L 127.0.0.1:$((LOCAL_TEST_PORT+1)):127.0.0.1:22 -l "$IDENTITY" "$VPS" -f -M -S "$ctl.neg" 2>/dev/null; sleep 1
  check "other -L destination (PermitOpen)" "000" "$(c http://127.0.0.1:$((LOCAL_TEST_PORT+1))/ 2>/dev/null || echo 000)"; ssh -S "$ctl.neg" -O exit -l "$IDENTITY" "$VPS" 2>/dev/null || true
  csh -N -o ExitOnForwardFailure=yes -R "$((LOCAL_TEST_PORT+2)):127.0.0.1:22" -l "$IDENTITY" "$VPS" >/dev/null 2>&1; check "-R remote forward" "fail" "$([[ $? -eq 0 ]] && echo ok || echo fail)"
  timeout 20 sftp -o BatchMode=yes -o IdentitiesOnly=yes -i "$key" -o StrictHostKeyChecking=accept-new "${IDENTITY}@${VPS}" </dev/null >/dev/null 2>&1; check "sftp" "fail" "$([[ $? -eq 0 ]] && echo ok || echo fail)"
  log "positive: tunnel + gateway"
  csh -N -o ExitOnForwardFailure=yes -L "${P}:127.0.0.1:${API_PORT}" -l "$IDENTITY" "$VPS" -f -M -S "$ctl" || die "could not open the tunnel"
  sleep 1
  check "gw /healthz" 200 "$(c "$B/healthz")"
  check "gw /healthz/upstream (full hop to Outline)" 200 "$(c "$B/healthz/upstream")"
  check "no bearer → 401" 401 "$(c -X POST -H 'Content-Type: application/json' -d '{}' "$B/api/documents.list")"
  check "GET → 405" 405 "$(c -X GET -H 'Authorization: Bearer ol_api_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx' "$B/api/documents.list")"
  check "apiKeys.create → 403" 403 "$(c -X POST -H 'Authorization: Bearer ol_api_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx' -H 'Content-Type: application/json' -d '{}' "$B/api/apiKeys.create")"
  check "traversal → 403" 403 "$(c --path-as-is -X POST -H 'Authorization: Bearer ol_api_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx' -H 'Content-Type: application/json' -d '{}' "$B/api/documents.info/../apiKeys.create")"
  if [[ -n "$token" ]]; then
    local me cid doc did
    me=$(curl -s --max-time 20 -X POST -H "Authorization: Bearer $token" -H 'Content-Type: application/json' -d '{}' "$B/api/auth.info")
    check "auth.info with token (role)" guest "$(jq -r '.data.user.role // "none"' <<<"$me")"
    cid=$(curl -s --max-time 20 -X POST -H "Authorization: Bearer $token" -H 'Content-Type: application/json' -d '{"limit":100}' "$B/api/collections.list" | jq -r --arg n "$COLLECTION" '[.data[].name] as $n2 | if ($n2 == [$n]) then (.data[0].id) else "WRONG:" + ($n2|join(",")) end')
    check "collections.list → only ${COLLECTION}" "ok" "$([[ "$cid" == WRONG:* || -z "$cid" ]] && echo "$cid" || echo ok)"
    doc=$(curl -s --max-time 20 -X POST -H "Authorization: Bearer $token" -H 'Content-Type: application/json' -d "$(jq -cn --arg c "$cid" '{collectionId:$c,title:"agent e2e test",text:"written through the tunnel by agent/provision.sh test",publish:true}')" "$B/api/documents.create")
    did=$(jq -r '.data.id // empty' <<<"$doc"); check "documents.create in ${COLLECTION}" "ok" "$([[ -n "$did" ]] && echo ok || echo "fail:$(jq -r '.message // .error // "?"' <<<"$doc")")"
    if [[ -n "$did" ]]; then
      check "documents.update" 200 "$(c -X POST -H "Authorization: Bearer $token" -H 'Content-Type: application/json' -d "$(jq -cn --arg id "$did" '{id:$id,text:"updated",append:true}')" "$B/api/documents.update")"
      check "documents.delete (permanent)" 200 "$(c -X POST -H "Authorization: Bearer $token" -H 'Content-Type: application/json' -d "$(jq -cn --arg id "$did" '{id:$id,permanent:true}')" "$B/api/documents.delete")"
    fi
    check "documents.move → 403 (gateway)" 403 "$(c -X POST -H "Authorization: Bearer $token" -H 'Content-Type: application/json' -d '{}' "$B/api/documents.move")"
    check "shares.create → 403 (gateway)" 403 "$(c -X POST -H "Authorization: Bearer $token" -H 'Content-Type: application/json' -d '{}' "$B/api/shares.create")"
  else
    warn "no --token given: skipping authenticated checks"
  fi
  ssh -S "$ctl" -O exit -l "$IDENTITY" "$VPS" 2>/dev/null || true
  log "public leak check (traefik-public must not know the gateway; bare /api/* on hs.gn.al is headscale's own API → 401, unrelated)"
  check "https://${VPS}/api/auth.info with Host outline.lab.gn.al" 404 "$(c -X POST -H 'Host: outline.lab.gn.al' "https://${VPS}/api/auth.info")"
  check "https://${VPS}/healthz/upstream" 404 "$(c "https://${VPS}/healthz/upstream")"
  echo; echo "  PASS ${pass}  FAIL ${fail}"; [[ $fail -eq 0 ]]
}

cmd_revoke() {
  local client=""; local all=0
  while (( $# )); do case "$1" in --client) client="$2"; shift 2 ;; --all) all=1; shift ;; *) die "unknown arg $1" ;; esac; done
  [[ -n "$client" || $all -eq 1 ]] || die "usage: revoke (--client <label> | --all)"
  require_admin
  if (( all )); then
    log "1/3 revoking every Outline token of ${IDENTITY}"; cmd_token revoke --all
    log "2/3 stopping the gateway"; vps_ssh "cd ${VPS_REPO} && docker compose -p cloudnet stop agent-api-gw" && ok "agent-api-gw stopped"
    log "3/3 removing all client keys + live sessions"; vps_ssh "sudo rm -f /etc/ssh/authorized_keys.d/${IDENTITY}; sudo pkill -u ${IDENTITY} || true" && ok "key file removed, sessions killed"
    warn "repo still lists the keys — run ssh-key remove per client (and start the gateway again) when re-enabling"
  else
    log "revoking client=${client}"; cmd_token revoke --client "$client"; cmd_ssh_key remove --client "$client"
    vps_ssh "sudo pkill -u ${IDENTITY} || true" >/dev/null 2>&1 || true; ok "live agent sessions dropped (other clients reconnect automatically)"
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
