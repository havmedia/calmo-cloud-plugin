# In place: calmo.cloud takes over the old machine

Only when the old host is a machine the user controls, it runs Odoo and nothing
that cannot live next to calmo.cloud, and the user accepts a hard cutover (in
practice 30–60 minutes for a large instance). IP address and DNS stay, so
allow-lists and DNS need no change.

## Before the cutover

- calmo.cloud's reachability check **fails on ports 80/443** while the old proxy
  runs, and `install_docker` refuses to run until they are free. Register the
  server (`create_server`, `check_server_reachability`) in preparation; Docker,
  Postgres and Traefik are installed in the cutover.
- Pre-pull the public images to save minutes in the cutover: `pgvector/pgvector:pg18`,
  `havmedia/traefik:3-latest`, `telegraf:1.40-alpine`. The Odoo image pulls after
  `install_docker` logged in to the registry.
- Check free disk: the old data stays until cleanup, and filestores are
  hardlinked (`cp -al`), not copied — same filesystem as `/data`.
- Find **everything** that listens on 80/443: `ss -ltnp | grep -E ':(80|443) '`.
  A VPN's HTTPS serve on a tailnet address (e.g. `tailscale serve`) is easy to
  miss and keeps Traefik from binding `0.0.0.0:443`; note how to turn it off and
  back on.

## Cutover order

1. Stop Odoo, keep the old database running; `docker update --restart=no` on
   every old container (or `systemctl disable`), because `install_docker`
   restarts the Docker daemon and restart policies would bring the old shop back
   while the dump runs.
2. Dump, build the archive, hardlink the filestore (see transfer.md).
3. Stop the old proxy and database. Do not remove them; they are the rollback.
4. **Old Docker clients.** `install_docker` may upgrade Docker; Docker 29 refuses
   API versions below 1.44, which old Traefik 2 and other old tools speak. For
   the rollback to work, add before the upgrade:
   ```bash
   mkdir -p /etc/systemd/system/docker.service.d
   printf '[Service]\nEnvironment=DOCKER_MIN_API_VERSION=1.24\n' > /etc/systemd/system/docker.service.d/min-api.conf
   systemctl daemon-reload
   ```
   Remove it in the cleanup.
5. Free 80/443 of anything else, then `check_server_reachability` →
   `install_docker` (on a host that already has Docker it restarts the engine and
   needs `confirm`) → `update_server` (Postgres, Traefik, monitoring) → service,
   addons, import, identity, hostnames as in the main skill.
6. Re-enable whatever you switched off on 443 on another port, or leave it off.

## Rollback

Stop the platform containers (`odoo-*`, `traefik`, `postgres`), start the old
stack and restore its restart policies. The DNS never changed, so the old system
answers at once.
