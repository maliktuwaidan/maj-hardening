#!/usr/bin/env bash
# Install Phoenix toolchain on Rocky Linux 10 (asdf, no DB).
# Run as the target user WITHOUT sudo wrapper (script self-elevates for dnf only).
#   bash -c "$(curl -fsSL <url>)"   ✅
#   sudo bash -c "..."              ❌  (installs into /root)
set -euo pipefail

ASDF_VER="0.19.0"
ERLANG_VER="29.0.2"
ELIXIR_VER="1.20.0-otp-29"

ERRORS=0

log_info() { echo "==> $1"; }
log_warn() { echo "WARN: $1"; }
log_err()  { echo "ERR:  $1"; ERRORS=$((ERRORS+1)); }

# Guard: refuse to run as root (would install into /root, not the user)
if [[ "$(id -u)" -eq 0 ]]; then
  log_err "Do not run as root / with sudo. Run as the target user; dnf steps self-elevate."
  exit 1
fi

# --- System deps ---
log_info "Enabling CRB + EPEL"
sudo dnf install -y dnf-plugins-core || true
sudo dnf config-manager --set-enabled crb || true
sudo dnf install -y epel-release || true

log_info "Installing build deps"
sudo dnf groupinstall -y "Development Tools" || true
sudo dnf install -y \
  autoconf automake libtool make gcc \
  ncurses-devel openssl-devel unixODBC-devel \
  libxslt-devel libxml2-devel glibc-devel \
  java-21-openjdk-devel \
  wxGTK-devel wxBase \
  inotify-tools \
  git curl || true

# --- asdf ---
log_info "Installing asdf v${ASDF_VER}"
mkdir -p "$HOME/bin"
if [[ ! -f "$HOME/bin/asdf" ]]; then
  curl -fsSL "https://github.com/asdf-vm/asdf/releases/download/v${ASDF_VER}/asdf-v${ASDF_VER}-linux-amd64.tar.gz" \
    -o /tmp/asdf.tar.gz
  tar -xzf /tmp/asdf.tar.gz -C "$HOME/bin" asdf
  rm -f /tmp/asdf.tar.gz
  chmod +x "$HOME/bin/asdf"
fi

# --- Shell config ---
log_info "Configuring shell (~/.bashrc)"
if ! grep -q 'ASDF_DATA_DIR' "$HOME/.bashrc" 2>/dev/null; then
cat >> "$HOME/.bashrc" <<'EOF'

# asdf
export PATH="$HOME/bin:$PATH"
export ASDF_DATA_DIR="$HOME/.asdf"
export PATH="$ASDF_DATA_DIR/shims:$PATH"
EOF
fi

# Source for this session
export PATH="$HOME/bin:$PATH"
export ASDF_DATA_DIR="$HOME/.asdf"
export PATH="$ASDF_DATA_DIR/shims:$PATH"

# --- Plugins & languages ---
log_info "Adding plugins"
asdf plugin add erlang 2>/dev/null || true
asdf plugin add elixir 2>/dev/null || true

# Install check by install-dir existence (asdf list against a fresh plugin is unreliable)
log_info "Installing Erlang ${ERLANG_VER}"
if [[ ! -d "$ASDF_DATA_DIR/installs/erlang/$ERLANG_VER" ]]; then
  # Clear any stale build lock from a previously interrupted build
  rm -rf "$ASDF_DATA_DIR/plugins/erlang/kerl-home/builds/asdf_${ERLANG_VER}" 2>/dev/null || true
  # NOTE: kerl prints a cosmetic "autoconf: error: no input file" line, then
  # builds silently for 5-15 min. Do NOT interrupt it.
  asdf install erlang "$ERLANG_VER"
else
  log_info "Erlang ${ERLANG_VER} already installed, skipping"
fi

log_info "Installing Elixir ${ELIXIR_VER}"
if [[ ! -d "$ASDF_DATA_DIR/installs/elixir/$ELIXIR_VER" ]]; then
  asdf install elixir "$ELIXIR_VER"
else
  log_info "Elixir ${ELIXIR_VER} already installed, skipping"
fi

log_info "Setting versions globally"
asdf set -u erlang "$ERLANG_VER"
asdf set -u elixir "$ELIXIR_VER"
asdf reshim

# --- Mix tooling ---
log_info "Installing Hex, Rebar, and phx_new"
mix local.hex --force
mix local.rebar --force
mix archive.install hex phx_new --force

# --- Validation ---
echo
echo "========================================"
echo "           VALIDATION REPORT            "
echo "========================================"

# 1. asdf
if command -v asdf &>/dev/null; then
  echo "[PASS] asdf: $(asdf --version)"
else
  log_err "asdf not found in PATH"
fi

# 2. Erlang
if command -v erl &>/dev/null; then
  ERL_V=$(erl -eval 'erlang:display(erlang:system_info(otp_release)), halt().' -noshell 2>/dev/null | tr -d '"')
  if [[ "$ERL_V" == "${ERLANG_VER%%.*}"* ]]; then
    echo "[PASS] Erlang: OTP $ERL_V"
  else
    log_err "Erlang version mismatch (expected $ERLANG_VER, got OTP $ERL_V)"
  fi
else
  log_err "erl not found"
fi

# 3. Elixir
if command -v elixir &>/dev/null; then
  EX_V=$(elixir --version 2>/dev/null | grep 'Elixir' | awk '{print $2}')
  if [[ "$EX_V" == "${ELIXIR_VER%%-*}" ]]; then
    echo "[PASS] Elixir: $EX_V"
  else
    log_err "Elixir version mismatch (expected ${ELIXIR_VER%%-*}, got $EX_V)"
  fi
else
  log_err "elixir not found"
fi

# 4. Mix
if command -v mix &>/dev/null; then
  MIX_V=$(mix --version 2>/dev/null | grep 'Mix' | awk '{print $2}')
  echo "[PASS] Mix: $MIX_V"
else
  log_err "mix not found"
fi

# 5. Hex
if mix hex.info &>/dev/null; then
  HEX_V=$(mix hex.info 2>/dev/null | grep 'Hex' | head -1 | awk '{print $2}')
  echo "[PASS] Hex: $HEX_V"
else
  log_err "Hex not installed"
fi

# 6. Rebar
if [[ -f "$HOME/.mix/rebar" ]] || [[ -f "$HOME/.mix/rebar3" ]] \
   || ls "$ASDF_DATA_DIR"/installs/elixir/*/.mix/elixir/*/rebar3 &>/dev/null; then
  echo "[PASS] Rebar installed"
else
  log_err "Rebar not found"
fi

# 7. phx.new
if mix help phx.new &>/dev/null; then
  echo "[PASS] phx.new archive installed"
else
  log_err "phx.new archive not found"
fi

# 8. PATH sanity
if echo "$PATH" | grep -q 'asdf/shims'; then
  echo "[PASS] asdf shims in PATH"
else
  log_warn "asdf shims not in current PATH (run: source ~/.bashrc)"
fi

echo "========================================"
if [[ $ERRORS -eq 0 ]]; then
  echo "All validations passed."
  echo "Open a new shell or run: source ~/.bashrc"
  echo "Then: mix phx.new myapp --no-ecto"
  exit 0
else
  echo "$ERRORS validation(s) failed."
  exit 1
fi
