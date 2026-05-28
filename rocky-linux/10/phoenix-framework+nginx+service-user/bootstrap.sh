#!/usr/bin/env bash
# bootstrap.sh — one-time full server setup on Rocky Linux 10.
#
# Idempotent — safe to re-run; each step guarded.
# Run AS your sudo login user (not root, not the service user).
# Reads tunables from ./install.conf.
#
# Stages:
#   1. preflight + load config
#   2. system packages    (build deps, nginx, nodejs)
#   3. firewall + SELinux
#   4. service user
#   5. asdf + Erlang + Elixir  (as service user)
#   6. /etc/galasin/galasin.env  (template; you fill secrets)
#   7. nginx site config
#   8. systemd unit (installed but not started — release must exist first)
#
# Postgres: NOT handled here. Install, init, restore data, and align port
# (15432) separately. Bootstrap only sets up the app side.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${HERE}/install.conf"

# ---- 1. preflight ----------------------------------------------------------
[[ $EUID -eq 0 ]] && { echo "ERROR: run as a sudo user, not root."; exit 1; }
[[ "$(id -un)" == "$SVC_USER" ]] && { echo "ERROR: run as your login, not $SVC_USER."; exit 1; }
sudo -v || { echo "ERROR: sudo required."; exit 1; }
[[ -f "${HERE}/galasin.env.example" ]] || { echo "ERROR: galasin.env.example missing."; exit 1; }
[[ -f "${HERE}/nginx/galasin.conf"  ]] || { echo "ERROR: nginx/galasin.conf missing."; exit 1; }
[[ -f "${HERE}/systemd/galasin.service" ]] || { echo "ERROR: systemd/galasin.service missing."; exit 1; }

# ---- 2. system packages ----------------------------------------------------
echo "==> Enabling CRB + EPEL"
sudo dnf install -y dnf-plugins-core
sudo dnf config-manager --set-enabled crb
sudo dnf install -y epel-release

echo "==> Installing packages (build deps, nginx, nodejs, firewalld)"
# Erlang built --without-wx --without-javac --without-odbc → no wx/java/odbc deps
sudo dnf install -y \
    gcc gcc-c++ make automake autoconf \
    ncurses-devel openssl-devel \
    inotify-tools git curl rsync \
    nginx \
    nodejs npm \
    firewalld policycoreutils-python-utils

# ---- 3. firewall + SELinux -------------------------------------------------
echo "==> Firewall: allow HTTP/HTTPS"
sudo systemctl enable --now firewalld
sudo firewall-cmd --permanent --add-service=http
sudo firewall-cmd --permanent --add-service=https
sudo firewall-cmd --reload

echo "==> SELinux: allow nginx → backend"
# Without this, nginx → 127.0.0.1:4000 gets blocked → 502 Bad Gateway
sudo setsebool -P httpd_can_network_connect 1

# ---- 4. service user -------------------------------------------------------
if id "$SVC_USER" &>/dev/null; then
    echo "==> Service user $SVC_USER already exists"
else
    echo "==> Creating service user $SVC_USER (home: $SVC_HOME)"
    sudo useradd -r -m -d "$SVC_HOME" -s /bin/bash "$SVC_USER"
fi

# ---- 5. toolchain (as service user) ----------------------------------------
INNER="$(mktemp /tmp/bootstrap-inner.XXXXXX.sh)"
chmod 0644 "$INNER"
trap 'rm -f "$INNER"' EXIT

cat > "$INNER" <<'INNER_EOF'
#!/usr/bin/env bash
set -euo pipefail
ASDF_VER="$1"; ERLANG_VER="$2"; ELIXIR_VER="$3"

ASDF_BIN="$HOME/bin/asdf"
export PATH="$HOME/bin:$PATH"
export ASDF_DATA_DIR="$HOME/.asdf"
export PATH="$ASDF_DATA_DIR/shims:$PATH"
export KERL_CONFIGURE_OPTIONS="--without-wx --without-javac --without-odbc"

# asdf binary
if [[ -x "$ASDF_BIN" ]] && "$ASDF_BIN" --version 2>/dev/null | grep -qF "$ASDF_VER"; then
    echo "    asdf v${ASDF_VER} already present"
else
    mkdir -p "$HOME/bin"
    curl -fsSL "https://github.com/asdf-vm/asdf/releases/download/v${ASDF_VER}/asdf-v${ASDF_VER}-linux-amd64.tar.gz" \
        -o /tmp/asdf.tar.gz
    tar -xzf /tmp/asdf.tar.gz -C "$HOME/bin" asdf
    rm -f /tmp/asdf.tar.gz
    chmod +x "$ASDF_BIN"
fi

# shell init
if ! grep -q 'ASDF_DATA_DIR' "$HOME/.bashrc" 2>/dev/null; then
cat >> "$HOME/.bashrc" <<'BASHRC'
# asdf
export PATH="$HOME/bin:$PATH"
export ASDF_DATA_DIR="$HOME/.asdf"
export PATH="$ASDF_DATA_DIR/shims:$PATH"
BASHRC
fi

# plugins
"$ASDF_BIN" plugin add erlang 2>/dev/null || true
"$ASDF_BIN" plugin add elixir 2>/dev/null || true

# Erlang
if "$ASDF_BIN" list erlang 2>/dev/null | grep -qF "$ERLANG_VER"; then
    echo "    Erlang ${ERLANG_VER} already installed"
else
    echo "    Installing Erlang ${ERLANG_VER} (~10-20 min)"
    "$ASDF_BIN" install erlang "$ERLANG_VER"
fi

# Elixir
if "$ASDF_BIN" list elixir 2>/dev/null | grep -qF "$ELIXIR_VER"; then
    echo "    Elixir ${ELIXIR_VER} already installed"
else
    "$ASDF_BIN" install elixir "$ELIXIR_VER"
fi

"$ASDF_BIN" set -u erlang "$ERLANG_VER"
"$ASDF_BIN" set -u elixir "$ELIXIR_VER"
"$ASDF_BIN" reshim

mix local.hex --force
mix local.rebar --force
elixir --version
INNER_EOF

echo "==> Installing toolchain as $SVC_USER"
sudo -u "$SVC_USER" -H bash "$INNER" "$ASDF_VER" "$ERLANG_VER" "$ELIXIR_VER"

# ---- 6. env file (template, fill manually) ---------------------------------
echo "==> Setting up env file"
sudo mkdir -p "$(dirname "$ENV_FILE")"
if [[ -f "$ENV_FILE" ]]; then
    echo "    $ENV_FILE exists, leaving alone"
else
    sudo install -o "$SVC_USER" -g "$SVC_USER" -m 600 \
        "${HERE}/galasin.env.example" "$ENV_FILE"
    echo "    Template installed at $ENV_FILE — EDIT IT, fill secrets."
fi

# ---- 7. nginx site config --------------------------------------------------
echo "==> Installing nginx site config"
sudo install -o root -g root -m 0644 "${HERE}/nginx/galasin.conf" /etc/nginx/conf.d/galasin.conf
sudo nginx -t
sudo systemctl enable --now nginx
sudo systemctl reload nginx

# ---- 8. systemd unit -------------------------------------------------------
echo "==> Installing systemd unit (not started — release must exist first)"
sudo install -o root -g root -m 0644 "${HERE}/systemd/galasin.service" /etc/systemd/system/galasin.service
sudo systemctl daemon-reload
sudo systemctl enable galasin     # auto-start on boot once release is built

# ---- done ------------------------------------------------------------------
cat <<DONE

==> Bootstrap complete.

Next steps (in order):
  1. Edit $ENV_FILE — fill SECRET_KEY_BASE, DATABASE_URL, ADMIN_API_KEY, MAILJET_*.
     Generate SECRET_KEY_BASE:
        sudo -iu $SVC_USER bash -lc 'cd ~/galasin-services && mix phx.gen.secret'
        (works only after first deploy.sh — the project must be in $DEPLOY_DIR)

  2. Postgres: install, init, restore data, set port = 15432, fix ownership
     (chown -R postgres:postgres /var/lib/pgsql/<ver>/data; chmod 0700 data).

  3. First deploy:
        ./deploy.sh

  4. After deploy, start the service:
        sudo systemctl start galasin
        sudo journalctl -u galasin -f

  5. Verify:
        curl -i http://127.0.0.1:${APP_PORT}                          # direct to app
        curl -i http://127.0.0.1 -H 'Host: ${APP_DOMAIN}'             # through nginx
        curl -i https://${APP_DOMAIN}/                                # through Cloudflare
DONE
