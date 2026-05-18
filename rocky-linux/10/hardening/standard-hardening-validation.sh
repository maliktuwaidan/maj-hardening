#!/usr/bin/env bash
# =============================================================================
# Rocky Linux 10 - Hardening Validation Script
# Validates all controls applied by standard-hardening.sh
# Run as root. Read-only — makes no changes.
# =============================================================================

set -uo pipefail

# ── Colors & counters ─────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

PASS=0; FAIL=0; WARN=0

pass() { echo -e "  ${GREEN}✔ PASS${NC}  $*"; ((PASS++)); }
fail() { echo -e "  ${RED}✘ FAIL${NC}  $*"; ((FAIL++)); }
warn() { echo -e "  ${YELLOW}⚠ WARN${NC}  $*"; ((WARN++)); }
section() { echo -e "\n${CYAN}${BOLD}══ $* ══${NC}"; }

[[ $EUID -ne 0 ]] && { echo -e "${RED}Must be run as root${NC}"; exit 1; }

echo -e "${BOLD}"
echo "============================================="
echo " Rocky Linux 10 Hardening Validation"
echo " $(date)"
echo "============================================="
echo -e "${NC}"

# =============================================================================
# 1. SELinux
# =============================================================================
section "SELinux"

mode=$(getenforce 2>/dev/null || echo "unknown")
if [[ "$mode" == "Enforcing" ]]; then
  pass "SELinux is Enforcing (runtime)"
else
  fail "SELinux is NOT enforcing — current: $mode"
fi

cfg=$(grep "^SELINUX=" /etc/selinux/config 2>/dev/null | cut -d= -f2)
if [[ "$cfg" == "enforcing" ]]; then
  pass "SELinux config persists across reboot (enforcing)"
else
  fail "SELinux config not set to enforcing — /etc/selinux/config: $cfg"
fi

if semanage port -l 2>/dev/null | grep -q "ssh_port_t.*10022"; then
  pass "SELinux allows SSH on port 10022"
else
  fail "SELinux has no ssh_port_t entry for port 10022"
fi

# =============================================================================
# 2. Sysctl
# =============================================================================
section "Kernel sysctl"

check_sysctl() {
  local key="$1" expected="$2"
  local val
  val=$(sysctl -n "$key" 2>/dev/null)
  if [[ "$val" == "$expected" ]]; then
    pass "$key = $val"
  else
    fail "$key = ${val:-unset} (expected $expected)"
  fi
}

check_sysctl kernel.randomize_va_space        2
check_sysctl kernel.dmesg_restrict            1
check_sysctl kernel.kptr_restrict             2
check_sysctl kernel.yama.ptrace_scope         1
check_sysctl kernel.sysrq                     0
check_sysctl fs.suid_dumpable                 0
check_sysctl fs.protected_hardlinks           1
check_sysctl fs.protected_symlinks            1
check_sysctl net.ipv4.tcp_syncookies          1
check_sysctl net.ipv4.conf.all.rp_filter      1
check_sysctl net.ipv4.conf.all.accept_redirects 0
check_sysctl net.ipv4.conf.all.send_redirects 0
check_sysctl net.ipv4.conf.all.log_martians   1
check_sysctl net.ipv4.ip_forward              0
check_sysctl net.ipv4.icmp_echo_ignore_broadcasts 1

# =============================================================================
# 3. SSH
# =============================================================================
section "SSH Hardening"

SSHD_CFG=/etc/ssh/sshd_config

check_sshd() {
  local key="$1" expected="$2"
  local val
  val=$(grep -iE "^${key}\s" "$SSHD_CFG" 2>/dev/null | awk '{print $2}')
  if [[ "${val,,}" == "${expected,,}" ]]; then
    pass "sshd: $key = $val"
  else
    fail "sshd: $key = '${val:-unset}' (expected '$expected')"
  fi
}

check_sshd Port                  10022
check_sshd PermitRootLogin       no
check_sshd PasswordAuthentication no
check_sshd PermitEmptyPasswords  no
check_sshd X11Forwarding         no
check_sshd MaxAuthTries          3
check_sshd AllowTcpForwarding    no
check_sshd PermitUserEnvironment no
check_sshd LoginGraceTime        30

if systemctl is-active --quiet sshd; then
  pass "sshd service is running"
else
  fail "sshd service is NOT running"
fi

if [[ -f /etc/issue.net ]] && grep -q "AUTHORIZED ACCESS ONLY" /etc/issue.net; then
  pass "SSH warning banner (/etc/issue.net) present"
else
  warn "SSH warning banner missing or not configured"
fi

# =============================================================================
# 4. Firewalld
# =============================================================================
section "Firewalld"

if systemctl is-active --quiet firewalld; then
  pass "firewalld is running"
else
  fail "firewalld is NOT running"
fi

default_zone=$(firewall-cmd --get-default-zone 2>/dev/null)
if [[ "$default_zone" == "drop" ]]; then
  pass "Default firewall zone = drop"
else
  fail "Default firewall zone = $default_zone (expected drop)"
fi

if firewall-cmd --zone=drop --list-ports 2>/dev/null | grep -q "10022/tcp"; then
  pass "Port 10022/tcp open in drop zone"
else
  fail "Port 10022/tcp NOT found in drop zone"
fi

# =============================================================================
# 5. Fail2ban
# =============================================================================
section "Fail2ban"

if systemctl is-active --quiet fail2ban; then
  pass "fail2ban is running"
else
  fail "fail2ban is NOT running"
fi

if fail2ban-client status sshd &>/dev/null; then
  banned=$(fail2ban-client status sshd | grep "Currently banned" | awk '{print $NF}')
  pass "fail2ban sshd jail active (currently banned: $banned)"
else
  fail "fail2ban sshd jail is NOT active"
fi

jail_cfg=/etc/fail2ban/jail.d/sshd.local
if [[ -f "$jail_cfg" ]]; then
  port=$(grep "^port" "$jail_cfg" | awk '{print $3}')
  maxretry=$(grep "^maxretry" "$jail_cfg" | awk '{print $3}')
  bantime=$(grep "^bantime" "$jail_cfg" | awk '{print $3}')
  [[ "$port" == "10022" ]]  && pass "fail2ban jail port = $port"    || fail "fail2ban jail port = '${port}' (expected 10022)"
  [[ "$maxretry" == "5" ]]  && pass "fail2ban maxretry = $maxretry" || warn "fail2ban maxretry = '${maxretry}' (expected 5)"
  [[ "$bantime" == "3600" ]] && pass "fail2ban bantime = $bantime"  || warn "fail2ban bantime = '${bantime}' (expected 3600)"
else
  fail "fail2ban sshd.local config not found"
fi

# =============================================================================
# 6. Auditd
# =============================================================================
section "Auditd / Logging"

if systemctl is-active --quiet auditd; then
  pass "auditd is running"
else
  fail "auditd is NOT running"
fi

check_audit_rule() {
  local desc="$1" pattern="$2"
  if auditctl -l 2>/dev/null | grep -qE "$pattern"; then
    pass "Audit rule: $desc"
  else
    fail "Audit rule missing: $desc"
  fi
}

check_audit_rule "/etc/passwd watched"   "watch=/etc/passwd"
check_audit_rule "/etc/shadow watched"   "watch=/etc/shadow"
check_audit_rule "/etc/sudoers watched"  "watch=/etc/sudoers"
check_audit_rule "privilege escalation"  "key=priv_esc"
check_audit_rule "kernel modules"        "key=modules"
check_audit_rule "sudo usage"            "watch=/usr/bin/sudo"

max_log=$(grep "^max_log_file " /etc/audit/auditd.conf 2>/dev/null | awk '{print $3}')
num_logs=$(grep "^num_logs" /etc/audit/auditd.conf 2>/dev/null | awk '{print $3}')
[[ "$max_log" == "50" ]]  && pass "auditd max_log_file = $max_log MB" || warn "auditd max_log_file = '${max_log}' (expected 50)"
[[ "$num_logs" == "10" ]] && pass "auditd num_logs = $num_logs"       || warn "auditd num_logs = '${num_logs}' (expected 10)"

# =============================================================================
# 7. Disabled Services
# =============================================================================
section "Disabled Services"

SHOULD_BE_DISABLED=(avahi-daemon cups bluetooth rpcbind nfs-server)

for svc in "${SHOULD_BE_DISABLED[@]}"; do
  state=$(systemctl is-enabled "$svc" 2>/dev/null || echo "not-found")
  case "$state" in
    disabled|masked|not-found)
      pass "Service disabled/absent: $svc ($state)" ;;
    enabled|static)
      fail "Service still enabled: $svc" ;;
    *)
      warn "Service $svc state unknown: $state" ;;
  esac
done

# =============================================================================
# 8. Misc
# =============================================================================
section "Miscellaneous"

# CTRL+ALT+DEL
state=$(systemctl is-enabled ctrl-alt-del.target 2>/dev/null || echo "unknown")
if [[ "$state" == "masked" ]]; then
  pass "ctrl-alt-del.target is masked"
else
  fail "ctrl-alt-del.target is NOT masked (state: $state)"
fi

# Core dumps
hard_core=$(ulimit -Hc 2>/dev/null || echo "unknown")
if [[ "$hard_core" == "0" ]]; then
  pass "Core dumps disabled (ulimit -Hc = 0)"
else
  warn "Core dump hard limit = $hard_core (expected 0)"
fi

# DNF auto-updates
if systemctl is-enabled --quiet dnf-automatic.timer 2>/dev/null; then
  pass "dnf-automatic.timer enabled (auto security updates)"
else
  warn "dnf-automatic.timer not enabled"
fi

# /tmp noexec
if mount | grep -qE "on /tmp.*noexec"; then
  pass "/tmp mounted with noexec"
else
  warn "/tmp is NOT mounted with noexec (consider adding to fstab)"
fi

# crontab permissions
perm=$(stat -c "%a" /etc/crontab 2>/dev/null)
if [[ "$perm" == "600" ]]; then
  pass "/etc/crontab permissions = 600"
else
  warn "/etc/crontab permissions = $perm (expected 600)"
fi

# hosts.equiv
if [[ ! -f /etc/hosts.equiv ]]; then
  pass "/etc/hosts.equiv does not exist"
else
  fail "/etc/hosts.equiv exists — remove it"
fi

# =============================================================================
# Summary
# =============================================================================
TOTAL=$((PASS + FAIL + WARN))
echo -e "\n${BOLD}============================================="
echo " Validation Summary"
echo "=============================================${NC}"
echo -e "  Total checks : $TOTAL"
echo -e "  ${GREEN}Passed${NC}        : $PASS"
echo -e "  ${RED}Failed${NC}        : $FAIL"
echo -e "  ${YELLOW}Warnings${NC}      : $WARN"
echo "============================================="

if [[ $FAIL -eq 0 ]]; then
  echo -e "\n  ${GREEN}${BOLD}All critical checks passed.${NC}"
else
  echo -e "\n  ${RED}${BOLD}$FAIL critical check(s) failed — review above.${NC}"
fi
echo ""

exit $FAIL
