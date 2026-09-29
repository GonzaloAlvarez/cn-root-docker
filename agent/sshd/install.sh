#!/usr/bin/env bash
# cn-root-docker/agent/sshd/install.sh — install or refresh the forwarding-only
# `agent` sshd pinhole on the VPS. Idempotent. Run as root from /opt/cloudnet:
#
#   sudo agent/sshd/install.sh              # install/refresh; arms a revert timer if sshd config changed
#   sudo agent/sshd/install.sh --disarm     # stop the revert timer after a NEW operator login succeeded
#   sudo agent/sshd/install.sh --check      # validate + print effective config, change nothing
#   sudo agent/sshd/install.sh --no-timer   # VM/test use only: never arm the revert timer
#
# What it installs (see agent/README.md):
#   * system user `agent` (nologin, no home, password locked)
#   * /etc/ssh/authorized_keys.d/agent  root:root 0644 — every registered client key,
#     each prefixed with restrict,port-forwarding,permitopen="127.0.0.1:8093"
#   * /etc/ssh/sshd_config.match.d/50-agent.conf — the `Match User agent` block
#   * a fenced `Include /etc/ssh/sshd_config.match.d/*.conf` appended at the END
#     of /etc/ssh/sshd_config — Match blocks live in their own directory, apart
#     from Debian's global drop-ins (sshd_config.d, Included at line 12). On
#     OpenSSH 9.2 a Match inside an Included file is scoped to that file, so
#     this is hygiene; the guards below still refuse any pre-existing Match for
#     the agent account and prove the operator's effective config is unchanged.
#
# Safety without SSM: the operator's effective sshd settings (`sshd -T -C
# user=<operator>`) are snapshotted before and after and MUST be identical; the
# new main file is validated with `sshd -t -f` before it is installed; and any
# sshd config change arms a transient systemd timer that restores the previous
# config after TIMER_MINUTES (default 10) unless `--disarm` is run — which the
# operator does only after a fresh login from a NEW terminal succeeded.
set -euo pipefail
cd "$(dirname "$0")"

ACCOUNT=agent
OPERATOR="${OPERATOR_USER:-${SUDO_USER:-gonzalo}}"
FORWARD_DST="127.0.0.1:8093"
KEY_OPTS="restrict,port-forwarding,permitopen=\"${FORWARD_DST}\""
KEYS_SRC="./authorized_keys"
DROPIN_SRC="./50-agent.conf"
KEYS_DIR=/etc/ssh/authorized_keys.d
KEYS_DST="${KEYS_DIR}/${ACCOUNT}"
MATCH_DIR=/etc/ssh/sshd_config.match.d
DROPIN_DST="${MATCH_DIR}/50-agent.conf"
SSHD_CONFIG=/etc/ssh/sshd_config
FENCE_BEGIN='# BEGIN agent-tunnel (cn-root-docker/agent/sshd/install.sh) -- keep at END of file'
FENCE_END='# END agent-tunnel'
INCLUDE_LINE="Include ${MATCH_DIR}/*.conf"
REVERT_UNIT=sshd-agent-revert
TIMER_MINUTES="${TIMER_MINUTES:-10}"
SSH_UNIT="${SSH_UNIT:-ssh}"
PROBE_HOST=hs.gn.al
PROBE_ADDR=203.0.113.1

MODE=install
ARM_TIMER=1
for a in "$@"; do
  case "$a" in
    --disarm)   MODE=disarm ;;
    --check)    MODE=check ;;
    --no-timer) ARM_TIMER=0 ;;
    -h|--help)  sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "unknown arg: $a" >&2; exit 2 ;;
  esac
done

log()  { printf '\033[1;36m[agent-sshd]\033[0m %s\n' "$*"; }
ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
chg()  { printf '  \033[1;33m+\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run as root (sudo)"
command -v sshd >/dev/null || die "sshd not found"
command -v ssh-keygen >/dev/null || die "ssh-keygen not found"

if [[ $MODE == disarm ]]; then
  if systemctl is-active --quiet "${REVERT_UNIT}.timer" 2>/dev/null; then
    systemctl stop "${REVERT_UNIT}.timer"
    systemctl stop "${REVERT_UNIT}.service" 2>/dev/null || true
    systemctl list-timers --all 2>/dev/null | grep -q "$REVERT_UNIT" && die "timer still listed — check: systemctl status ${REVERT_UNIT}.timer"
    ok "revert timer disarmed"
  else
    ok "no revert timer armed (nothing to disarm)"
  fi
  exit 0
fi

sshd_effective() {  # sshd_effective <user>
  sshd -T -C "user=$1,host=${PROBE_HOST},addr=${PROBE_ADDR}" 2>/dev/null | sort
}

# ── 0. guards ──────────────────────────────────────────────────────────────
log "guards (sshd $(sshd -V 2>&1 | head -1 | sed 's/,.*//'), operator user ${OPERATOR})"
id "$OPERATOR" >/dev/null 2>&1 || die "operator user '${OPERATOR}' does not exist (set OPERATOR_USER)"
[[ -f "$KEYS_SRC" ]] || die "missing ${KEYS_SRC}"
[[ -f "$DROPIN_SRC" ]] || die "missing ${DROPIN_SRC}"
grep -q "^Match User ${ACCOUNT}\$" "$DROPIN_SRC" || die "${DROPIN_SRC} does not contain 'Match User ${ACCOUNT}'"
[[ -L "$KEYS_DIR" || -L "$MATCH_DIR" ]] && die "${KEYS_DIR} or ${MATCH_DIR} is a symlink — refusing"
# Any other Match that could apply to the agent account would silently win ("first
# obtained value" semantics) — refuse. Unrelated Match blocks only get a warning.
if grep -rniE "^[[:space:]]*Match[[:space:]].*\b${ACCOUNT}\b" "$SSHD_CONFIG" /etc/ssh/sshd_config.d/ 2>/dev/null | grep -v "$MATCH_DIR" >/dev/null; then
  die "a pre-existing 'Match' mentioning '${ACCOUNT}' exists in ${SSHD_CONFIG} or /etc/ssh/sshd_config.d/ — resolve by hand first"
fi
if grep -rniE '^[[:space:]]*Match[[:space:]]' "$SSHD_CONFIG" /etc/ssh/sshd_config.d/ 2>/dev/null | grep -q .; then
  echo "  ! other Match blocks exist in the main file / sshd_config.d — fine, but review them: $(grep -rlniE '^[[:space:]]*Match[[:space:]]' "$SSHD_CONFIG" /etc/ssh/sshd_config.d/ 2>/dev/null | tr '\n' ' ')"
fi
ok "no conflicting Match blocks for ${ACCOUNT}"

# Render the key file: validate every key, prefix the options, normalise comments.
RENDERED=$(mktemp); trap 'rm -f "$RENDERED" "${NEW_CONFIG:-}"' EXIT
NKEYS=0
while IFS= read -r line || [[ -n "$line" ]]; do
  [[ -z "${line// /}" || "$line" =~ ^[[:space:]]*# ]] && continue
  read -r ktype kblob kcomment <<<"$line"
  [[ "$ktype" == "ssh-ed25519" ]] || die "only ssh-ed25519 keys are accepted: ${line:0:40}…"
  fp=$(printf '%s %s\n' "$ktype" "$kblob" | ssh-keygen -lf /dev/stdin 2>/dev/null | awk '{print $2}') \
    || die "key does not parse: ${line:0:40}…"
  [[ -n "$fp" ]] || die "key does not parse: ${line:0:40}…"
  [[ "$kcomment" =~ (^|[[:space:]])client=[A-Za-z0-9._-]+ ]] || die "key ${fp} lacks a 'client=<label>' comment"
  printf '%s %s %s %s\n' "$KEY_OPTS" "$ktype" "$kblob" "$kcomment" >>"$RENDERED"
  NKEYS=$((NKEYS+1))
done <"$KEYS_SRC"
ok "${NKEYS} registered client key(s) validated"

if [[ $MODE == check ]]; then
  log "check mode — effective settings for ${ACCOUNT} (if the block is installed)"
  sshd -t && ok "sshd -t passes"
  sshd_effective "$ACCOUNT" | grep -E '^(permitopen|allowtcpforwarding|maxsessions|permittty|allowstreamlocalforwarding|permitlisten|authorizedkeysfile|pubkeyacceptedalgorithms|forcecommand|allowagentforwarding|x11forwarding|permittunnel|channeltimeout) ' || true
  exit 0
fi

# ── 1. snapshot operator effective config ─────────────────────────────────
BEFORE=$(sshd_effective "$OPERATOR")
[[ -n "$BEFORE" ]] || die "could not read effective config for ${OPERATOR}"

# ── 2. account ─────────────────────────────────────────────────────────────
log "account"
if id "$ACCOUNT" >/dev/null 2>&1; then
  ok "user ${ACCOUNT} exists (uid $(id -u "$ACCOUNT"), shell $(getent passwd "$ACCOUNT" | cut -d: -f7))"
else
  useradd --system -M --home-dir /nonexistent --shell /usr/sbin/nologin \
          --comment "external agents - forwarding-only tunnel" "$ACCOUNT"
  chg "user ${ACCOUNT} created (system, nologin, no home)"
fi
# Password stays locked ('!'). NEVER use --expiredate: an expired account blocks pubkey auth too.

# ── 3. key file (root-owned so the account can never alter its own keys) ───
log "authorized keys → ${KEYS_DST}"
install -d -m 0755 -o root -g root "$KEYS_DIR"
KEYS_CHANGED=0
if [[ -f "$KEYS_DST" ]] && cmp -s "$RENDERED" "$KEYS_DST"; then
  ok "unchanged (${NKEYS} key(s))"
else
  install -m 0644 -o root -g root "$RENDERED" "$KEYS_DST"
  KEYS_CHANGED=1
  chg "written (${NKEYS} key(s), root:root 0644)"
fi

# ── 4. drop-in ─────────────────────────────────────────────────────────────
log "match block → ${DROPIN_DST}"
install -d -m 0755 -o root -g root "$MATCH_DIR"
CONFIG_CHANGED=0
PREV_DROPIN=""
if [[ -f "$DROPIN_DST" ]] && cmp -s "$DROPIN_SRC" "$DROPIN_DST"; then
  ok "unchanged"
else
  [[ -f "$DROPIN_DST" ]] && PREV_DROPIN=$(mktemp) && cp -a "$DROPIN_DST" "$PREV_DROPIN"
  install -m 0644 -o root -g root "$DROPIN_SRC" "$DROPIN_DST"
  CONFIG_CHANGED=1
  chg "installed"
fi

# ── 5. fence in the main file (appended at the END) ────────────────────────
log "include fence in ${SSHD_CONFIG}"
if grep -qxF "$FENCE_BEGIN" "$SSHD_CONFIG" && grep -qxF "$INCLUDE_LINE" "$SSHD_CONFIG"; then
  ok "present"
else
  NEW_CONFIG=$(mktemp)
  cp -a "$SSHD_CONFIG" "$NEW_CONFIG"
  printf '\n%s\n%s\n%s\n' "$FENCE_BEGIN" "$INCLUDE_LINE" "$FENCE_END" >>"$NEW_CONFIG"
  sshd -t -f "$NEW_CONFIG" || die "candidate sshd_config failed 'sshd -t' — nothing installed"
  CONFIG_CHANGED=1
fi

# ── 6. backup + revert timer + install + validate ──────────────────────────
if [[ $CONFIG_CHANGED -eq 1 ]]; then
  STAMP=$(date +%s)
  BACKUP_DIR="/etc/ssh/agent-tunnel-backup.${STAMP}"
  install -d -m 0700 "$BACKUP_DIR"
  cp -a "$SSHD_CONFIG" "${BACKUP_DIR}/sshd_config"
  [[ -n "$PREV_DROPIN" ]] && cp -a "$PREV_DROPIN" "${BACKUP_DIR}/50-agent.conf.prev"
  cat >"${BACKUP_DIR}/restore.sh" <<RESTORE
#!/bin/sh
# Restores the sshd configuration captured before agent/sshd/install.sh ran at ${STAMP}.
set -e
cp -a "${BACKUP_DIR}/sshd_config" "${SSHD_CONFIG}"
if [ -f "${BACKUP_DIR}/50-agent.conf.prev" ]; then
  cp -a "${BACKUP_DIR}/50-agent.conf.prev" "${DROPIN_DST}"
else
  rm -f "${DROPIN_DST}"
fi
/usr/sbin/sshd -t
systemctl restart ${SSH_UNIT}
logger -t agent-tunnel "sshd configuration REVERTED from ${BACKUP_DIR}"
echo "reverted from ${BACKUP_DIR}"
RESTORE
  chmod 0700 "${BACKUP_DIR}/restore.sh"
  chg "backup + restore script at ${BACKUP_DIR}"

  [[ -n "${NEW_CONFIG:-}" ]] && install -m 0644 -o root -g root "$NEW_CONFIG" "$SSHD_CONFIG" && chg "fence appended to ${SSHD_CONFIG}"

  sshd -t || { "${BACKUP_DIR}/restore.sh"; die "sshd -t failed after install — reverted"; }
  AFTER=$(sshd_effective "$OPERATOR")
  if ! diff <(echo "$BEFORE") <(echo "$AFTER") >/dev/null; then
    diff <(echo "$BEFORE") <(echo "$AFTER") || true
    "${BACKUP_DIR}/restore.sh"
    die "effective sshd settings for ${OPERATOR} CHANGED — reverted"
  fi
  ok "operator '${OPERATOR}' effective settings identical before/after"

  if [[ $ARM_TIMER -eq 1 ]]; then
    systemctl stop "${REVERT_UNIT}.timer" "${REVERT_UNIT}.service" 2>/dev/null || true
    systemd-run --on-active="${TIMER_MINUTES}min" --unit="$REVERT_UNIT" \
      --description="revert agent sshd change (${BACKUP_DIR})" "${BACKUP_DIR}/restore.sh" >/dev/null
    chg "revert timer armed: ${TIMER_MINUTES} min (unit ${REVERT_UNIT}.timer)"
  fi
  systemctl reload "$SSH_UNIT"
  chg "sshd reloaded"
fi

# ── 7. assert the agent account's effective settings ───────────────────────
log "effective settings for ${ACCOUNT}"
EFF=$(sshd_effective "$ACCOUNT")
assert() {  # assert <keyword> <expected>
  local got; got=$(grep -E "^$1 " <<<"$EFF" | cut -d' ' -f2- || true)
  if [[ "$got" == "$2" ]]; then ok "$1 $got"; else die "expected '$1 $2', got '$1 ${got:-<unset>}'"; fi
}
assert permitopen "$FORWARD_DST"
assert allowtcpforwarding local
assert maxsessions 0
assert permittty no
assert allowstreamlocalforwarding no
assert permitlisten none
assert allowagentforwarding no
assert x11forwarding no
assert permittunnel no
assert forcecommand /bin/false
assert pubkeyacceptedalgorithms ssh-ed25519
assert authorizedkeysfile "${KEYS_DIR}/%u"
GLOBALS=$(sshd -T 2>/dev/null | grep -E '^(passwordauthentication|permitrootlogin|maxauthtries|logingracetime|maxsessions) ' | tr '\n' ';')
ok "untouched globals: ${GLOBALS}"

# ── 8. what the operator must do now ───────────────────────────────────────
echo
if [[ $CONFIG_CHANGED -eq 1 && $ARM_TIMER -eq 1 ]]; then
  cat <<MSG
================================================================================
  sshd config changed. A revert timer will restore the previous config in
  ${TIMER_MINUTES} minutes unless you disarm it.

  1. From a NEW terminal (not this session), confirm you can still log in:
       ssh -o IdentitiesOnly=yes -i ~/.ssh/gonzalo_main_private_key.pem ${OPERATOR}@${PROBE_HOST} 'echo OK'
  2. If (and only if) that printed OK:
       sudo $(pwd)/install.sh --disarm
  If it failed: do nothing — the timer restores ${BACKUP_DIR} automatically.
================================================================================
MSG
elif [[ $CONFIG_CHANGED -eq 1 ]]; then
  echo "  sshd config changed; NO revert timer armed (--no-timer). Backup: ${BACKUP_DIR}"
elif [[ $KEYS_CHANGED -eq 1 ]]; then
  echo "  key file updated; no sshd reload needed (keys are read per authentication)."
else
  echo "  nothing to do — already installed and up to date."
fi
