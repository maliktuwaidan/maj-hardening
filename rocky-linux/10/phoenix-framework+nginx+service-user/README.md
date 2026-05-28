# Galasin Services — Deploy Bundle

Everything needed to install + run the app on a fresh Rocky Linux 10 box.

## Layout

```
galasin-deploy/
├── install.conf            ← shared variables (versions, users, paths, domain)
├── galasin.env.example     ← template for /etc/galasin/galasin.env (secrets)
├── nginx/galasin.conf      ← Cloudflare-aware site config
├── systemd/galasin.service ← service unit (BEAM-hardened)
├── bootstrap.sh            ← ONE-TIME full setup
└── deploy.sh               ← REPEATED build/release/restart
```

## Order of operations on a new server

1. **Copy the bundle to the box**, place anywhere (e.g. `~/galasin-deploy`).
2. **Place your source code at** `/home/galasin/galasin-services` (workflow B).
3. **Install Postgres separately** — not handled by these scripts.
   Match the major version of the old server. Restore data, set port `15432`,
   fix ownership: `chown -R postgres:postgres /var/lib/pgsql/<ver>/data`,
   `chmod 0700 /var/lib/pgsql/<ver>/data`.
4. **Run bootstrap** as your sudo login user (not root, not the service user):
   ```bash
   chmod +x bootstrap.sh deploy.sh
   ./bootstrap.sh
   ```
5. **Fill secrets** in `/etc/galasin/galasin.env`. Generate the secret key after
   the first deploy puts the project on disk (see bootstrap's final output).
6. **First deploy**:
   ```bash
   ./deploy.sh
   ```
7. **Start the service**:
   ```bash
   sudo systemctl start galasin
   sudo journalctl -u galasin -f
   ```
8. **Verify**:
   ```bash
   curl -I http://127.0.0.1:4000                          # direct to app
   curl -I http://127.0.0.1 -H 'Host: service.galasin.com' # through nginx
   curl -I https://service.galasin.com/                    # via Cloudflare
   ```

## Daily workflow (after initial setup)

Edit code in `/home/galasin/galasin-services/`, commit, then:
```bash
./deploy.sh                # sync → build → migrate → restart
./deploy.sh --no-restart   # build only (when staging changes)
```

## Things NOT in these scripts (do separately)

- **PostgreSQL install + data restore.** Version + data-dir handling is too
  environment-specific to script blindly.
- **TLS.** Handled by Cloudflare. Set SSL/TLS mode to **Full** in CF dashboard.
- **Cloudflare IP list refresh.** The `set_real_ip_from` ranges in
  `nginx/galasin.conf` drift over time. Add a weekly cron pulling
  `https://www.cloudflare.com/ips-v4` and `ips-v6`, then `nginx -s reload`.
- **Origin firewalling.** Best practice: restrict :80 to Cloudflare IPs at the
  firewall level too. Otherwise anyone hitting the origin IP directly can spoof
  `CF-Connecting-IP`.
- **Old root asdf cleanup.** `/root/.asdf` from the previous botched install can
  be removed after this setup is verified working through a reboot.
- **Commit `.tool-versions`** to the repo (`erlang 27.3.4` / `elixir 1.18.4-otp-27`)
  so the toolchain is pinned with the code. Without this, future migrations
  repeat this whole exercise.

## Hardening already applied

- Service runs as non-login system user `galasin-svc`, never root.
- `/etc/galasin/galasin.env` is `600`, only `galasin-svc` can read secrets.
- systemd unit: `NoNewPrivileges`, `ProtectSystem=full`, `ProtectHome`,
  `PrivateTmp`, kernel/cgroup protections, SUID restrictions.
  `MemoryDenyWriteExecute` intentionally **not** set — BEAM JIT needs W^X.
- nginx trusts `CF-Connecting-IP` only from Cloudflare CIDRs (no `0.0.0.0/0`).
- SELinux: `httpd_can_network_connect` set (needed for nginx → backend).
- Firewall: only `http`/`https` services open.
