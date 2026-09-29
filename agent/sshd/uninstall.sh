#!/usr/bin/env bash
# cn-root-docker/agent/sshd/uninstall.sh — remove the `agent` sshd pinhole.
# Run as root on the VPS. Reverse of install.sh, same safety net (operator
# effective-config diff, sshd -t before install, revert timer).
#
#   sudo agent/sshd/uninstall.sh [--keep-user] [--no-timer]
#
# Immediate revocation WITHOUT this script (no reload needed):
#   sudo rm -f /etc/ssh/authorized_keys.d/agent && sudo pkill -u agent
set -euo pipefail

ACCOUNT=agent
OPERATOR="${OPERATOR_USER:-${SUDO_USER:-gonzalo}}"
KEYS_DST=/etc/ssh/authorized_keys.d/${ACCOUNT}
MATCH_DIR=/etc/ssh/sshd_config.match.d
DROPIN_DST="${MATCH_DIR}/50-agent.conf"
SSHD_CONFIG=/etc/ssh/sshd_config
FENCE_BEGIN='# BEGIN agent-tunnel (cn-root-docker/agent/sshd/install.sh) -- keep at END of file'
FENCE_END='# END agent-tunnel'
REVERT_UNIT=sshd-agent-revert
TIMER_MINUTES="${TIMER_MINUTES:-10}"
SSH_UNIT="${SSH_UNIT:-ssh}"
PROBE_HOST=hs.gn.al
PROBE_ADDR=203.0.113.1
KEEP_USER=0; ARM_TIMER=1
for a in "$@"; do
  case "$a" in
    --keep-user) KEEP_USER=1 ;;
    --no-timer)  ARM_TIMER=0 ;;
    -h|--help)   sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "unknown arg: $a" >&2; exit 2 ;;
  esac
done
log()  { printf '\033[1;36m[agent-sshd]\033[0m %s\n' "$*"; }
ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
chg()  { printf '  \033[1;33m-\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "run as root (sudo)"
sshd_effective() { sshd -T -C "user=$1,host=${PROBE_HOST},addr=${PROBE_ADDR}" 2>/dev/null | sort; }

log "revoking keys + live forwards"
if [[ -f "$KEYS_DST" ]]; then rm -f "$KEYS_DST"; chg "removed ${KEYS_DST}"; else ok "no key file"; fi
if id "$ACCOUNT" >/dev/null 2>&1 && pkill -u "$ACCOUNT" 2>/dev/null; then chg "killed live ${ACCOUNT} sessions"; else ok "no live ${ACCOUNT} sessions"; fi

BEFORE=$(sshd_effective "$OPERATOR")
CHANGED=0
NEW_CONFIG=$(mktemp); trap 'rm -f "$NEW_CONFIG"' EXIT
if grep -qxF "$FENCE_BEGIN" "$SSHD_CONFIG"; then
  sed "/^$(printf '%s' "$FENCE_BEGIN" | sed 's/[][\\.*^$/]/\\&/g')\$/,/^$(printf '%s' "$FENCE_END" | sed 's/[][\\.*^$/]/\\&/g')\$/d" "$SSHD_CONFIG" >"$NEW_CONFIG"
  # drop the blank line the installer added before the fence, if it is now trailing
  sed -i -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$NEW_CONFIG"
  sshd -t -f "$NEW_CONFIG" || die "candidate sshd_config without the fence failed 'sshd -t'"
  CHANGED=1
fi
if [[ $CHANGED -eq 1 || -f "$DROPIN_DST" ]]; then
  STAMP=$(date +%s); BACKUP_DIR="/etc/ssh/agent-tunnel-backup.${STAMP}"
  install -d -m 0700 "$BACKUP_DIR"; cp -a "$SSHD_CONFIG" "${BACKUP_DIR}/sshd_config"
  [[ -f "$DROPIN_DST" ]] && cp -a "$DROPIN_DST" "${BACKUP_DIR}/50-agent.conf.prev"
  cat >"${BACKUP_DIR}/restore.sh" <<RESTORE
#!/bin/sh
set -e
cp -a "${BACKUP_DIR}/sshd_config" "${SSHD_CONFIG}"
[ -f "${BACKUP_DIR}/50-agent.conf.prev" ] && install -d -m 0755 "${MATCH_DIR}" && cp -a "${BACKUP_DIR}/50-agent.conf.prev" "${DROPIN_DST}"
/usr/sbin/sshd -t && systemctl restart ${SSH_UNIT}
logger -t agent-tunnel "sshd configuration REVERTED (uninstall) from ${BACKUP_DIR}"
RESTORE
  chmod 0700 "${BACKUP_DIR}/restore.sh"
  [[ $CHANGED -eq 1 ]] && install -m 0644 -o root -g root "$NEW_CONFIG" "$SSHD_CONFIG" && chg "fence removed from ${SSHD_CONFIG}"
  [[ -f "$DROPIN_DST" ]] && rm -f "$DROPIN_DST" && chg "removed ${DROPIN_DST}"
  sshd -t || { "${BACKUP_DIR}/restore.sh"; die "sshd -t failed — reverted"; }
  AFTER=$(sshd_effective "$OPERATOR")
  diff <(echo "$BEFORE") <(echo "$AFTER") >/dev/null || { "${BACKUP_DIR}/restore.sh"; die "operator effective settings changed — reverted"; }
  ok "operator '${OPERATOR}' effective settings identical before/after"
  if [[ $ARM_TIMER -eq 1 ]]; then
    systemctl stop "${REVERT_UNIT}.timer" "${REVERT_UNIT}.service" 2>/dev/null || true
    systemd-run --on-active="${TIMER_MINUTES}min" --unit="$REVERT_UNIT" --description="revert agent sshd uninstall" "${BACKUP_DIR}/restore.sh" >/dev/null
    chg "revert timer armed (${TIMER_MINUTES} min) — disarm with: sudo systemctl stop ${REVERT_UNIT}.timer"
  fi
  systemctl reload "$SSH_UNIT"; chg "sshd reloaded"
else
  ok "no fence / drop-in present"
fi
if [[ $KEEP_USER -eq 0 ]] && id "$ACCOUNT" >/dev/null 2>&1; then userdel "$ACCOUNT"; chg "user ${ACCOUNT} removed"; fi
ok "done"
