#!/usr/bin/env bash
# =============================================================================
# Rocky Linux 10 - General Purpose Hardening Script
# Coverage: SSH, firewalld, fail2ban, unused services, auditd, sysctl, SELinux
# Run as root. Idempotent - safe to re-run.
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
die()  { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }

[[ $EUID -ne 0 ]] && die "Must be run as root"

# ── Backup helper ─────────────────────────────────────────────────────────────
backup() {
  local f="$1"
  [[ -f "$f" && ! -f "${f}.bak.$(date +%F)" ]] && cp "$f" "${f}.bak.$(date +%F)" || true
}

echo "============================================="
echo " Rocky Linux 10 Hardening Script"
echo " $(date)"
echo "============================================="

# =============================================================================
# 1. SELinux Enforcement
# =============================================================================
log "SELinux: enforcing mode"
backup /etc/selinux/config
sed -i 's/^SELINUX=.*/SELINUX=enforcing/' /etc/selinux/config
if command -v setenforce &>/dev/null; then
  setenforce 1 || warn "setenforce 1 failed (may already be enforcing)"
fi

# Allow SSH on custom port via SELinux
log "SELinux: allowing SSH on port 10022"
dnf install -y policycoreutils-python-utils &>/dev/null
semanage port -a -t ssh_port_t -p tcp 10022 2>/dev/null || \
  semanage port -m -t ssh_port_t -p tcp 10022 2>/dev/null || \
  warn "semanage: port 10022 may already be defined"

sestatus | grep -E "^SELinux status|mode"

# =============================================================================
# 2. Kernel sysctl Hardening
# =============================================================================
log "Applying sysctl hardening"
cat > /etc/sysctl.d/99-harden.conf << 'EOF'
# --- Network: IP spoofing & redirect protection ---
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0

# --- Network: SYN flood protection ---
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 5

# --- Network: Misc ---
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.ip_forward = 0
net.ipv6.conf.all.forwarding = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1

# --- Kernel: ASLR & hardening ---
kernel.randomize_va_space = 2
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
kernel.yama.ptrace_scope = 1
kernel.perf_event_paranoid = 3
kernel.sysrq = 0
kernel.core_uses_pid = 1

# --- File system ---
fs.suid_dumpable = 0
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
EOF
sysctl --system -q
log "sysctl rules applied"

# =============================================================================
# 3. SSH Hardening
# =============================================================================
log "Hardening SSH"
backup /etc/ssh/sshd_config

# Apply settings (add if missing, replace if present)
sshd_set() {
  local key="$1" val="$2"
  if grep -qE "^#?${key}" /etc/ssh/sshd_config; then
    sed -i "s|^#\?${key}.*|${key} ${val}|" /etc/ssh/sshd_config
  else
    echo "${key} ${val}" >> /etc/ssh/sshd_config
  fi
}

sshd_set Port                  10022
sshd_set Protocol              2
sshd_set PermitRootLogin       no
sshd_set PasswordAuthentication no
sshd_set PermitEmptyPasswords  no
sshd_set ChallengeResponseAuthentication no
sshd_set UsePAM                yes
sshd_set X11Forwarding         no
sshd_set MaxAuthTries          3
sshd_set MaxSessions           5
sshd_set LoginGraceTime        30
sshd_set ClientAliveInterval   300
sshd_set ClientAliveCountMax   2
sshd_set AllowTcpForwarding    no
sshd_set AllowAgentForwarding  no
sshd_set PermitUserEnvironment no
sshd_set Banner                /etc/issue.net
sshd_set LogLevel              VERBOSE
sshd_set Ciphers               "aes256-gcm@openssh.com,chacha20-poly1305@openssh.com,aes128-gcm@openssh.com"
sshd_set MACs                  "hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com"
sshd_set KexAlgorithms         "curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group18-sha512"

# Warning banner
cat > /etc/issue.net << 'EOF'
*******************************************************************************
  AUTHORIZED ACCESS ONLY. All activity is monitored and logged.
  Unauthorized access is prohibited and will be prosecuted.
*******************************************************************************
EOF

sshd -t && systemctl restart sshd && log "sshd restarted OK"

# =============================================================================
# 4. Firewalld
# =============================================================================
log "Configuring firewalld"
dnf install -y firewalld &>/dev/null
systemctl enable --now firewalld

# Default: drop everything, allow SSH only
firewall-cmd --set-default-zone=drop
firewall-cmd --zone=drop --add-port=10022/tcp --permanent

# Remove common risky services if accidentally in public
for svc in telnet ftp rsh rlogin; do
  firewall-cmd --zone=public --remove-service="$svc" --permanent 2>/dev/null || true
done

firewall-cmd --reload
log "firewalld: default-zone=drop, port 10022 allowed"
warn "Add app-specific ports: firewall-cmd --zone=drop --add-port=443/tcp --permanent && firewall-cmd --reload"

# =============================================================================
# 5. Fail2ban
# =============================================================================
log "Installing and configuring fail2ban"
dnf install -y epel-release &>/dev/null
dnf install -y fail2ban &>/dev/null

cat > /etc/fail2ban/jail.d/sshd.local << 'EOF'
[sshd]
enabled   = true
port      = 10022
filter    = sshd
backend   = systemd
logpath   = /var/log/auth.log
maxretry  = 5
findtime  = 600
bantime   = 3600
ignoreip  = 127.0.0.1/8
EOF

systemctl enable --now fail2ban
log "fail2ban enabled (SSH: 5 retries / 10min → 1h ban)"

# =============================================================================
# 6. Auditd / Logging
# =============================================================================
log "Configuring auditd"
dnf install -y audit &>/dev/null

backup /etc/audit/auditd.conf
# Tune auditd
sed -i 's/^max_log_file_action.*/max_log_file_action = ROTATE/' /etc/audit/auditd.conf
sed -i 's/^num_logs.*/num_logs = 10/'                           /etc/audit/auditd.conf
sed -i 's/^max_log_file .*/max_log_file = 50/'                  /etc/audit/auditd.conf
sed -i 's/^space_left_action.*/space_left_action = email/'      /etc/audit/auditd.conf
sed -i 's/^admin_space_left_action.*/admin_space_left_action = halt/' /etc/audit/auditd.conf

# Audit rules
cat > /etc/audit/rules.d/99-harden.rules << 'EOF'
## Delete all existing rules
-D

## Increase buffer
-b 8192

## Failure mode: 1=log, 2=panic
-f 1

## Identity / auth
-w /etc/passwd        -p wa -k identity
-w /etc/shadow        -p wa -k identity
-w /etc/group         -p wa -k identity
-w /etc/gshadow       -p wa -k identity
-w /etc/sudoers       -p wa -k sudoers
-w /etc/sudoers.d/    -p wa -k sudoers

## Privilege escalation
-a always,exit -F arch=b64 -S setuid  -F a0=0 -F exe=/usr/bin/su  -k priv_esc
-a always,exit -F arch=b64 -S execve  -C uid!=euid -F euid=0       -k priv_esc

## sudo usage
-w /usr/bin/sudo      -p x  -k sudo_usage

## SSH config
-w /etc/ssh/sshd_config -p wa -k sshd_config

## Login / logout
-w /var/log/lastlog   -p wa -k logins
-w /var/run/faillock/ -p wa -k logins

## Network config changes
-w /etc/hosts         -p wa -k network
-w /etc/sysconfig/network -p wa -k network

## Kernel modules
-w /sbin/insmod       -p x  -k modules
-w /sbin/rmmod        -p x  -k modules
-w /sbin/modprobe     -p x  -k modules
-a always,exit -F arch=b64 -S init_module -S delete_module -k modules

## Immutable (comment out if you need to update rules without reboot)
# -e 2
EOF

augenrules --load 2>/dev/null || auditctl -R /etc/audit/rules.d/99-harden.rules || true
systemctl enable --now auditd
log "auditd configured and enabled"

# =============================================================================
# 7. Disable Unused Services
# =============================================================================
log "Disabling unused / risky services"

DISABLE_SVCS=(
  avahi-daemon     # mDNS/Bonjour - unnecessary on servers
  cups             # printing
  bluetooth        # Bluetooth
  rpcbind          # NFS (disable unless needed)
  nfs-server
  nfs-client.target
  rsh.socket
  rlogin.socket
  rexec.socket
  telnet.socket
  tftp
  xinetd
  postfix          # comment out if you need local mail relay
)

for svc in "${DISABLE_SVCS[@]}"; do
  if systemctl list-unit-files "${svc}.service" &>/dev/null || \
     systemctl list-unit-files "${svc}.socket" &>/dev/null || \
     systemctl list-unit-files "${svc}" &>/dev/null; then
    systemctl disable --now "$svc" 2>/dev/null && log "  disabled: $svc" || true
  fi
done

# =============================================================================
# 8. Misc Hardening
# =============================================================================
log "Misc: file permissions, core dumps, CTRL+ALT+DEL"

# Disable core dumps
cat > /etc/security/limits.d/99-nodumps.conf << 'EOF'
*    hard    core    0
EOF
echo "fs.suid_dumpable = 0" >> /etc/sysctl.d/99-harden.conf

# Disable CTRL+ALT+DEL reboot
systemctl mask ctrl-alt-del.target 2>/dev/null || true

# Secure /tmp with noexec if not already a separate mount
if ! grep -q "^[^ ]* /tmp " /proc/mounts; then
  warn "/tmp is not on a separate partition. Consider adding to /etc/fstab:"
  warn "  tmpfs /tmp tmpfs defaults,noexec,nosuid,nodev 0 0"
fi

# Restrict cron
chmod 700 /etc/cron.{d,daily,hourly,monthly,weekly} 2>/dev/null || true
chmod 600 /etc/crontab 2>/dev/null || true
echo "" > /etc/cron.deny 2>/dev/null || true

# Remove .rhosts and hosts.equiv
rm -f /etc/hosts.equiv
find /root /home -name ".rhosts" -delete 2>/dev/null || true

# Ensure DNF auto-updates security patches
dnf install -y dnf-automatic &>/dev/null
sed -i 's/^apply_updates.*/apply_updates = yes/' /etc/dnf/automatic.conf
sed -i 's/^upgrade_type.*/upgrade_type = security/' /etc/dnf/automatic.conf
systemctl enable --now dnf-automatic.timer

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "============================================="
echo " Hardening Complete"
echo "============================================="
echo " ✔ SELinux       → enforcing"
echo " ✔ sysctl        → /etc/sysctl.d/99-harden.conf"
echo " ✔ SSH           → key-auth only, root login disabled, port 10022"
echo " ✔ firewalld     → default-zone=drop, port 10022 open"
echo " ✔ fail2ban      → SSH jail active"
echo " ✔ auditd        → rules loaded, rotate 10×50MB"
echo " ✔ Unused svcs   → disabled"
echo " ✔ DNF auto-sec  → enabled"
echo ""
warn "ACTION REQUIRED: Ensure at least one SSH public key is in"
warn "  ~/.ssh/authorized_keys before logging out — PasswordAuth is now OFF."
warn "Review firewall rules for any app ports you need open."
echo "============================================="
