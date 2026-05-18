#!/usr/bin/env bash
# Install Phoenix toolchain on Rocky Linux 10 (asdf, no DB).
# Run as a normal user with sudo privileges. Not idempotent-safe to re-run blindly.
set -euo pipefail

ASDF_VER="0.18.0"          # https://github.com/asdf-vm/asdf/releases
ERLANG_VER="27.3.4"
ELIXIR_VER="1.18.4-otp-27"

echo "==> Enabling CRB + EPEL"
sudo dnf install -y dnf-plugins-core
sudo dnf config-manager --set-enabled crb
sudo dnf install -y epel-release

echo "==> Installing build deps"
sudo dnf groupinstall -y "Development Tools"
sudo dnf install -y \
    autoconf ncurses-devel openssl-devel unixODBC-devel \
    libxslt-devel libxml2-devel libtool glibc-devel \
    java-21-openjdk-devel \
    wxGTK-devel wxBase \
    git curl

echo "==> Installing asdf v${ASDF_VER}"
mkdir -p "$HOME/bin"
curl -fsSL "https://github.com/asdf-vm/asdf/releases/download/v${ASDF_VER}/asdf-v${ASDF_VER}-linux-amd64.tar.gz" \
    -o /tmp/asdf.tar.gz
tar -xzf /tmp/asdf.tar.gz -C "$HOME/bin" asdf
rm /tmp/asdf.tar.gz
chmod +x "$HOME/bin/asdf"

echo "==> Configuring shell (~/.bashrc)"
if ! grep -q 'ASDF_DATA_DIR' "$HOME/.bashrc" 2>/dev/null; then
cat >> "$HOME/.bashrc" <<'EOF'

# asdf
export PATH="$HOME/bin:$PATH"
export ASDF_DATA_DIR="$HOME/.asdf"
export PATH="$ASDF_DATA_DIR/shims:$PATH"
EOF
fi

# Make asdf usable in this script session
export PATH="$HOME/bin:$PATH"
export ASDF_DATA_DIR="$HOME/.asdf"
export PATH="$ASDF_DATA_DIR/shims:$PATH"

asdf --version

echo "==> Adding plugins"
asdf plugin add erlang  || true
asdf plugin add elixir  || true

echo "==> Installing Erlang ${ERLANG_VER} (takes ~10-20 min)"
asdf install erlang "${ERLANG_VER}"

echo "==> Installing Elixir ${ELIXIR_VER}"
asdf install elixir "${ELIXIR_VER}"

echo "==> Setting versions globally"
asdf set -u erlang "${ERLANG_VER}"
asdf set -u elixir "${ELIXIR_VER}"

echo "==> Hex, rebar, phx_new"
mix local.hex --force
mix local.rebar --force
mix archive.install hex phx_new --force

echo
echo "==> Done. Open a new shell, then:"
echo "    mix phx.new myapp --no-ecto"
