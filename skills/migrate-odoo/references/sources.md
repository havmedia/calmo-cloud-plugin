# Sources: how to look, get the data out, and freeze

Read the section for the old setup. Each covers where the facts of phase 1 are,
how the final data comes out in phase 4, how to freeze, and what rollback means.

## Docker / docker compose

**Find it.** `docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}'`; the
Odoo container runs `odoo` / `odoo-bin`, the database is a `postgres` container
or a Postgres on the host or elsewhere (`db_host` in `odoo.conf` or the
`HOST` environment variable of the official image). The compose project is in
`docker inspect <container> --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}'`.

- Config: `docker exec <odoo> sh -c 'cat "${ODOO_RC:-/etc/odoo/odoo.conf}"'`.
- Filestore: `<data_dir>/filestore/<db>`; the official image uses
  `/var/lib/odoo`. Map it to the host with
  `docker inspect <odoo> --format '{{json .Mounts}}'`.
- Addons: `addons_path` in the config, mapped through the mounts as above.
  Code baked into a custom image (`docker history`, the Dockerfile) has to go
  into Git.
- Hostnames: the reverse proxy — Traefik labels (`docker inspect` → `Labels`,
  `Host(`/`HostRegexp(` rules, file-provider configs), an nginx/Caddy container's
  config, or a proxy on the host.

**Get the data out.** With the Odoo container stopped and the database running:
`docker exec <db> pg_dump -U <user> --no-owner -Fp <db> > dump.sql`; the
filestore from the host path of the mount. Or, while Odoo still runs, Odoo's own
`/web/database/backup` (zip with filestore) if the database manager is enabled.

**Freeze.** `docker compose stop <odoo services>` (keep the database container
up), and `docker update --restart=no <containers>` so a Docker restart does not
bring them back. **Rollback:** `docker update --restart=<old policy>` and
`docker compose start`.

## Bare-metal / package / source install

**Find it.** `systemctl list-units --all | grep -i odoo`,
`ps -eo pid,user,args | grep -E '[o]doo(-bin)?'`; the `-c` argument or
`/etc/odoo/odoo.conf` (Debian package) is the config.

- Filestore: `data_dir` from the config, default `~<odoo user>/.local/share/Odoo`
  → `filestore/<db>`.
- Database: `db_host` (empty = local socket), `db_user`;
  `sudo -u postgres psql -l` lists the databases.
- Addons: `addons_path`; enterprise code may sit in its own directory.
- Hostnames: nginx (`grep -R server_name /etc/nginx`), Apache
  (`grep -R -E 'Server(Name|Alias)' /etc/apache2 /etc/httpd`), Caddy
  (`/etc/caddy/Caddyfile`), HAProxy.
- Python packages installed for the addons: `pip freeze` in the Odoo venv;
  compare with the manifests' `external_dependencies`.

**Get the data out.** Stop the Odoo service, then
`sudo -u postgres pg_dump --no-owner -Fp <db> > dump.sql` and the filestore
directory. **Freeze:** `systemctl stop odoo` and `systemctl disable odoo` for
the time of the move (re-enable on rollback); also stop cron jobs on the host
that write into Odoo.

## Odoo.sh

**Find it.** The project's settings (custom domains, Odoo version, branches),
the GitHub repository it deploys from (`.gitmodules` for addon repos pulled in as
submodules), and a downloaded production backup. The web shell (or SSH) of the
production build gives `odoo.conf`-style facts and `psql`, but no root.

**Get the data out.** Backups tab → production → create a manual backup → download
it **with filestore**. That zip is the standard Odoo archive calmo.cloud imports.

**Freeze.** Production cannot be stopped from outside. The user tells their team
the time from which nothing is entered any more; the final backup is taken after
it. Remove the custom domains on Odoo.sh only after DNS points at calmo.cloud.

**Specifics.** Branches are named after environments (`production`, `staging`):
pass the branch to `create_repository` and to `attach_repository`. Each submodule repository is
connected on its own. The Enterprise subscription has to be switched to
self-hosting. Odoo.sh sends mail through Odoo's servers; check outgoing mail
settings on calmo.cloud. **Rollback:** point DNS back to Odoo.sh while the
project still exists.

## Odoo Online (SaaS)

**Find it.** Settings → About shows the version: an intermediate `saas~x.y`
version has to be upgraded to the next major version (upgrade.odoo.com) before it
can be restored. There is no custom code; Studio changes live in the database.

**Get the data out.** odoo.com/my/databases → the database's menu → **Download**
(zip with filestore). Only the database owner can.

**Freeze.** As for Odoo.sh: the team stops working at an agreed time, then the
download. **Specifics.** Odoo Online sends mail for the customer; a self-hosted
Odoo needs its own outgoing mail server and correct SPF/DKIM for the sender
domain. Users of a `*.odoo.com` address need the new one. The subscription needs
the self-hosting plan. **Rollback:** the Online database stays until Odoo deletes
it; keep it until the new system has run for a while.

## Managed hoster without root

Ask the hoster for: a backup **with filestore** in Odoo's zip format (or
`pg_dump` plus a tarball of the filestore), the Odoo version and `odoo.conf`, the
list of domains, and the source of every custom addon. Freeze as for Odoo.sh.
If they only offer a database dump, the attachments are missing: do not go ahead
without the filestore.

## Several databases on one host

Each database (live, staging, demo) becomes its own calmo.cloud service and goes
through the steps side by side. Only `live` services may be indexed by search
engines; staging becomes type `test`, or better a fresh `copy_service` of the
migrated live service with `neutralize: true`.
