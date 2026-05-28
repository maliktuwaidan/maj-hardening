#!/usr/bin/env bash
# deploy.sh — sync source → build release → restart service.
#
# Run AS your sudo login user. Workflow B:
#   You edit in $SOURCE_DIR (with git). This script syncs to $DEPLOY_DIR
#   (owned by $SVC_USER), builds in place, restarts systemd.
#
# Idempotent. Safe to re-run.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${HERE}/install.conf"

# ---- preflight -------------------------------------------------------------
[[ $EUID -eq 0 ]] && { echo "ERROR: run as a sudo user, not root."; exit 1; }
sudo -v || { echo "ERROR: sudo required."; exit 1; }
[[ -d "$SOURCE_DIR" ]] || { echo "ERROR: source dir $SOURCE_DIR missing."; exit 1; }
id "$SVC_USER" &>/dev/null || { echo "ERROR: $SVC_USER missing — run bootstrap.sh first."; exit 1; }

# Flag: --no-restart to build only
RESTART=1
[[ "${1:-}" == "--no-restart" ]] && RESTART=0

# ---- 1. sync source → deploy dir ------------------------------------------
echo "==> Syncing $SOURCE_DIR → $DEPLOY_DIR"
sudo mkdir -p "$DEPLOY_DIR"
sudo rsync -a --delete \
    --exclude '_build' --exclude 'deps' --exclude '.git' \
    --exclude 'node_modules' --exclude 'priv/static/assets' \
    --exclude '.claude' --exclude '.elixir_ls' \
    --chown="${SVC_USER}:${SVC_USER}" \
    "${SOURCE_DIR}/" "${DEPLOY_DIR}/"

# ---- 2. build + release (as service user) ---------------------------------
echo "==> Building release as $SVC_USER"
# -lc → login shell, sources .bashrc, gets asdf shims on PATH
sudo -iu "$SVC_USER" bash -lc "
    set -euo pipefail
    cd '$DEPLOY_DIR'
    mix deps.get --only prod
    npm --prefix assets ci
    MIX_ENV=prod mix compile
    MIX_ENV=prod mix assets.deploy
    MIX_ENV=prod mix release --overwrite
"

# ---- 3. restart -----------------------------------------------------------
# DB migrations: run manually when needed:
#   sudo -iu galasin-svc bash -lc "$RELEASE_BIN eval 'GalasinServices.Release.migrate'"
if [[ "$RESTART" == "1" ]]; then
    echo "==> Restarting galasin.service"
    sudo systemctl restart galasin
    sleep 2
    sudo systemctl status galasin --no-pager | head -15
else
    echo "==> --no-restart given; not restarting"
fi

echo
echo "==> Deploy done."
echo "    Tail logs:  sudo journalctl -u galasin -f"
echo "    Direct hit: curl -I http://127.0.0.1:${APP_PORT}"
