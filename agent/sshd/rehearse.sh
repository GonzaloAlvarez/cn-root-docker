#!/usr/bin/env bash
# cn-root-docker/agent/sshd/rehearse.sh — L1 rehearsal of the agent sshd pinhole
# against a DISPOSABLE kora VM (never a real fleet host — homelab CLAUDE.md §14.1).
#
#   KORA_HOME=/tmp/kora-agent kora new debian        # Debian 12 = the VPS's OpenSSH 9.2
#   KORA_HOME=/tmp/kora-agent agent/sshd/rehearse.sh
#
# What it proves: install.sh converges + is idempotent, the operator keeps
# access (fresh login through the revert-timer window, then --disarm), the agent
# account can ONLY forward to 127.0.0.1:8093 (stub http.server), every other
# capability is refused, uninstall.sh restores the pre-state byte-for-byte.
set -euo pipefail
cd "$(dirname "$0")"
: "${KORA_HOME:?set KORA_HOME to the isolated kora home holding the rehearsal VM}"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  \033[1;31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
log()  { printf '\n\033[1;36m[rehearse]\033[0m %s\n' "$*"; }
check() { local label="$1" want="$2" got="$3"; if [[ "$got" == "$want" ]]; then ok "$label → $got"; else bad "$label → '$got' (expected '$want')"; fi; }

SSH_TARGET=$(kora status | awk '/^ssh:/{print $2}')          # e.g. admin@192.168.64.19:22
VM_USER=${SSH_TARGET%%@*}; VM_IP=${SSH_TARGET#*@}; VM_IP=${VM_IP%%:*}
[[ -n "$VM_USER" && -n "$VM_IP" ]] || { echo "no running kora VM (kora status)"; exit 1; }
log "VM ${VM_USER}@${VM_IP} · $(kora cmd '/usr/sbin/sshd -V 2>&1 | head -1')"
START=$(kora cmd 'date "+%Y-%m-%d %H:%M:%S"' | tail -1)

# stage: repo copy + a rehearsal client key
ssh-keygen -q -t ed25519 -N '' -f "$WORK/client" -C client=rehearsal
ssh-keygen -q -t rsa -b 2048 -N '' -f "$WORK/rsa" -C client=rehearsal-rsa
cp 50-agent.conf install.sh uninstall.sh "$WORK/"
{ cat authorized_keys; awk '{print $1, $2, "client=rehearsal"}' "$WORK/client.pub"; } >"$WORK/authorized_keys"
kora cmd 'rm -rf /tmp/agent-sshd && mkdir -p /tmp/agent-sshd' >/dev/null
for f in 50-agent.conf install.sh uninstall.sh authorized_keys; do kora copy "$WORK/$f" "vm:/tmp/agent-sshd/$f" >/dev/null; done
kora cmd 'chmod +x /tmp/agent-sshd/*.sh; sudo cp /etc/ssh/sshd_config /tmp/sshd_config.orig; (nohup python3 -m http.server 8093 --bind 127.0.0.1 >/tmp/stub.log 2>&1 &) ; sleep 1; curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8093/' | tail -1 | grep -q 200 && ok "stub gateway on the VM loopback :8093" || bad "stub gateway not answering"

S=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o IdentitiesOnly=yes)
A=(-l agent "$VM_IP")

log "install (first run: arms the revert timer)"
OUT=$(kora cmd "cd /tmp/agent-sshd && sudo OPERATOR_USER=${VM_USER} ./install.sh" 2>&1) || { echo "$OUT"; bad "install.sh failed"; }
echo "$OUT" | sed 's/^/    /' | tail -30
grep -q 'revert timer armed' <<<"$OUT" && ok "revert timer armed" || bad "revert timer not armed"
check "fresh operator login during the window" "OK" "$(kora cmd 'echo OK' 2>/dev/null | tail -1)"
kora cmd 'sudo /tmp/agent-sshd/install.sh --disarm' >/dev/null 2>&1 || true
check "timer gone after --disarm" none "$(kora cmd 'systemctl list-timers --all 2>/dev/null | grep -c sshd-agent-revert || true' | tail -1 | sed 's/^0$/none/')"

log "positive: the one allowed forward"
ssh "${S[@]}" -i "$WORK/client" -N -f -M -S "$WORK/ctl" -o ExitOnForwardFailure=yes -L 127.0.0.1:18093:127.0.0.1:8093 "${A[@]}" 2>/dev/null && ok "tunnel established" || bad "tunnel failed"
check "curl through the tunnel (stub answers 200)" 200 "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:18093/ || echo 000)"
ssh -S "$WORK/ctl" -O exit "${A[@]}" 2>/dev/null || true

log "negative matrix"
fails() { if "$@" >/dev/null 2>&1; then echo ok; else echo fail; fi; }
check "shell (ssh agent@vm)"                 fail "$(fails ssh "${S[@]}" -i "$WORK/client" "${A[@]}")"
check "command (ssh agent@vm true)"          fail "$(fails ssh "${S[@]}" -i "$WORK/client" "${A[@]}" true)"
check "pty (-t)"                             fail "$(fails ssh "${S[@]}" -tt -i "$WORK/client" "${A[@]}")"
check "sftp"                                 fail "$(fails timeout 20 sftp "${S[@]}" -i "$WORK/client" -b /dev/null "agent@${VM_IP}")"
check "scp"                                  fail "$(fails timeout 20 scp "${S[@]}" -i "$WORK/client" "$WORK/client.pub" "agent@${VM_IP}:/tmp/x")"
neg_fwd() { ssh "${S[@]}" -i "$WORK/client" -N -f -M -S "$WORK/ctl2" -o ExitOnForwardFailure=yes "$@" "${A[@]}" 2>/dev/null; local rc; rc=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:18094/" || true); ssh -S "$WORK/ctl2" -O exit "${A[@]}" 2>/dev/null || true; echo "${rc:-000}"; }
check "-L to 127.0.0.1:22 (PermitOpen)"      000 "$(neg_fwd -L 127.0.0.1:18094:127.0.0.1:22)"
check "-L to localhost:8093 (string match)"  000 "$(neg_fwd -L 127.0.0.1:18094:localhost:8093)"
check "-L to 10.1.1.92:443"                  000 "$(neg_fwd -L 127.0.0.1:18094:10.1.1.92:443)"
check "-R remote forward"                    fail "$(fails ssh "${S[@]}" -i "$WORK/client" -N -o ExitOnForwardFailure=yes -R 18095:127.0.0.1:22 "${A[@]}")"
check "-D SOCKS (direct-tcpip to arbitrary)" 000 "$( ssh "${S[@]}" -i "$WORK/client" -N -f -M -S "$WORK/ctl3" -D 127.0.0.1:18096 "${A[@]}" 2>/dev/null; rc=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --socks5 127.0.0.1:18096 http://127.0.0.1:22/ || true); ssh -S "$WORK/ctl3" -O exit "${A[@]}" 2>/dev/null || true; echo "${rc:-000}")"
check "unix-socket forward (streamlocal)"    000  "$( ssh "${S[@]}" -i "$WORK/client" -N -f -M -S "$WORK/ctl4" -L "$WORK/s.sock:/var/run/docker.sock" "${A[@]}" 2>/dev/null; rc=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --unix-socket "$WORK/s.sock" http://x/_ping || true); ssh -S "$WORK/ctl4" -O exit "${A[@]}" 2>/dev/null || true; echo "${rc:-000}")"
check "tun (-w)"                             fail "$(fails ssh "${S[@]}" -i "$WORK/client" -N -o ExitOnForwardFailure=yes -w 0:0 "${A[@]}")"
check "RSA key for agent"                    fail "$(fails ssh "${S[@]}" -i "$WORK/rsa" "${A[@]}" true)"
check "password auth offered"                fail "$(fails ssh "${S[@]}" -o PreferredAuthentications=password -o PubkeyAuthentication=no "${A[@]}" true)"
check "operator still normal"                OK   "$(kora cmd 'echo OK' 2>/dev/null | tail -1)"

log "journal message templates since the run started (for the promtail regexes)"
kora cmd "sudo journalctl -u ssh --since '${START}' --no-pager -o cat 2>/dev/null | grep -vE 'pam_|Postponed|Connection (closed|reset)|Disconnected|Received disconnect|session (opened|closed)|Starting Session|Accepted key ED25519' | sed -E 's/[0-9]{1,3}(\\.[0-9]{1,3}){3}/<ip>/g; s/port [0-9]+/port <p>/g; s/SHA256:[A-Za-z0-9+\\/=]+/<fp>/g' | sort | uniq -c | sort -rn" | sed 's/^/    /'

log "idempotence"
OUT2=$(kora cmd "cd /tmp/agent-sshd && sudo OPERATOR_USER=${VM_USER} ./install.sh" 2>&1)
grep -q 'nothing to do' <<<"$OUT2" && ! grep -q 'revert timer armed' <<<"$OUT2" && ok "second run: no changes, no timer, no reload" || { echo "$OUT2" | tail -5; bad "second run not idempotent"; }
OUT3=$(kora cmd "cd /tmp/agent-sshd && sudo OPERATOR_USER=${VM_USER} ./install.sh --check" 2>&1); grep -q 'permitopen 127.0.0.1:8093' <<<"$OUT3" && ok "--check prints effective agent settings" || bad "--check output unexpected"

log "uninstall"
OUT4=$(kora cmd "cd /tmp/agent-sshd && sudo OPERATOR_USER=${VM_USER} ./uninstall.sh --no-timer" 2>&1) || { echo "$OUT4"; bad "uninstall failed"; }
check "sshd_config byte-identical to the original" identical "$(kora cmd 'sudo cmp -s /tmp/sshd_config.orig /etc/ssh/sshd_config && echo identical || echo differs' | tail -1)"
check "agent user gone"                             gone      "$(kora cmd 'id agent >/dev/null 2>&1 && echo present || echo gone' | tail -1)"
check "drop-in gone"                                gone      "$(kora cmd 'test -e /etc/ssh/sshd_config.match.d/50-agent.conf && echo present || echo gone' | tail -1)"
check "operator still normal after uninstall"       OK        "$(kora cmd 'echo OK' 2>/dev/null | tail -1)"

echo; echo "  PASS ${PASS}  FAIL ${FAIL}"; [[ $FAIL -eq 0 ]]
