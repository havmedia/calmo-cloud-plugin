---
name: migrate-odoo
description: "Use when moving an existing Odoo onto calmo.cloud, whatever runs it today: a self-hosted Docker or docker-compose setup, a bare-metal or package install, Odoo.sh, Odoo Online, or a managed hoster that only hands out backups. Drives the calmo.cloud MCP server plus SSH to the old host where there is one. Covers inventory, the decisions to put to the user, preparation without downtime, the cutover, verification, rollback and cleanup. Trigger on \"move/migrate my Odoo to calmo.cloud\", \"umziehen\", \"migrieren\", \"migrate root@<host>\", or a request for a migration plan. Do NOT use for moving a service between two calmo.cloud servers or for restoring a calmo.cloud backup."
---

# Moving an Odoo onto calmo.cloud

An assistant with the calmo.cloud MCP server, and root SSH to the old host
where one exists, can run the whole move: inventory, plan, preparation,
cutover, checks. The calmo.cloud side goes through MCP tools. SSH is for the
old host and for the few steps on the new server that have no tool (marked
**[ssh]**).

This skill's directory is `${CLAUDE_PLUGIN_ROOT}/skills/migrate-odoo`; the
`scripts/` and `references/` paths below, and `<skill dir>` in the references,
are relative to it.

Every move has the same shape, whatever the old setup was:

1. **Inventory** the old system without changing it.
2. **Decide** with the user: target server, timing, access, transfer method.
3. **Prepare** everything on calmo.cloud while the old system keeps running.
4. **Cut over**: freeze the old system, take the final data, restore, switch domains.
5. **Verify**, then **clean up** only when the user says so.

What differs per source is how you look at it, how you get the data out and
how you freeze it. Identify the source first and read its section in
[references/sources.md](references/sources.md):

| Source | Shell on old host | Data comes out as |
|--------|-------------------|-------------------|
| Docker / docker compose you run | yes | `pg_dump` + filestore copy, or an Odoo backup zip |
| Bare-metal / package / source install | yes | `pg_dump` + filestore copy, or an Odoo backup zip |
| Odoo.sh | limited (no root, cannot stop prod) | backup zip from the Backups tab |
| Odoo Online (SaaS) | no | backup zip from the database manager |
| Managed hoster without root | no | whatever backup they hand out — insist on database **and** filestore |

## Ground rules

- **The user decides; you prepare.** Stop with `AskUserQuestion` at every gate
  below. Everything before the cutover must run without downtime for the old
  system. A preparation step that would interrupt it belongs in the cutover.
- **The old system stays intact until the user says it can go.** Stop it, never
  delete it. Copy or hardlink data instead of moving it.
- **Never print secrets** (API token, database passwords, `admin_passwd`,
  OAuth tokens) into commands you show or files you write. Mask them in the
  inventory.
- **Read a tool's schema before the first call.** Arguments a tool does not
  know may be dropped without an error, so a misspelt flag silently does the
  default (e.g. `private: true` instead of `is_private: true`).
- **Do not restore live data into a running calmo.cloud service before the
  cutover.** Odoo starts right after a restore, with scheduled actions,
  outgoing mail and incoming-mail fetching active: it would mail customers and
  pull mails out of shared mailboxes while the old system still runs. Rehearse
  the restore in a throwaway Postgres container instead (phase 3).
- **Use SSH multiplexing** from the first command; many hosts run fail2ban
  and ban bursts of new connections:
  `ssh -o ControlMaster=auto -o ControlPath=/tmp/ssh-%r@%h -o ControlPersist=30m root@<host>`.
- Pass SQL through a quoted heredoc or a file, not through `echo "$VAR"`
  (shells mangle backslashes), and parse JSON with `python3`.

## Phase 0 — access

1. **calmo.cloud MCP.** Call `get_team`. It names the team, its plan and what
   the plan allows (servers, services, API). If the tools are missing, the
   plugin has no token yet: the user sets it with `/plugin` → calmo → configure,
   using an API token from **Developer → API Tokens** in the panel. Suggest a
   token made for this migration, revoked afterwards.
2. **Old host.** Where the source has a shell, check SSH as root (or a sudo
   user) and note whose keys are in `authorized_keys`. For Odoo.sh, Odoo Online
   and managed hosters, find out who can download a backup with the filestore.
3. **GitHub.** calmo.cloud deploys custom addons from GitHub through its GitHub
   App. `list_github_installations` shows whether the App is installed on the
   account that holds the addon code.

## Phase 1 — inventory (read-only)

On a host with a shell, run [scripts/inventory.sh](scripts/inventory.sh) over
SSH: `ssh root@<host> 'bash -s' < "<skill dir>/scripts/inventory.sh"`
(`DB=<name>` before `bash` when the host has several databases). It detects
Docker and systemd installs and changes nothing on the host apart from
refreshing Git remote-tracking refs. Otherwise gather the facts from the
source's UI and a downloaded backup. What you need:

| Fact | Why it matters |
|------|----------------|
| Odoo version and edition | calmo.cloud runs **Enterprise 18.0, 19.0 and 20.0**. Community, older versions and Odoo Online's `saas~x.y` versions need an upgrade first (upgrade.odoo.com); restore needs the same major version |
| database name(s), DB size, filestore size, free disk on old and new host | decides the transfer method and the disk the new server needs (see "Disk") |
| every hostname that reaches this Odoo: reverse-proxy config (nginx `server_name`, Traefik labels and rules, Caddyfile, Apache vhosts), **plus every `website.domain`** | calmo.cloud routes explicit hostnames, not wildcards: `*.example.com` becomes one hostname per website |
| DNS of each hostname, who hosts each zone, current TTL | the switch is a DNS change unless the move is in place |
| custom addon code: where it lives, Git remote and branch, commits not pushed, local changes, untracked module folders | calmo.cloud deploys addons from GitHub only |
| installed modules missing from code and image | a restored database needs every installed module present |
| Python packages the addons import but do not declare in `external_dependencies` | the platform installs declared dependencies only |
| **absolute paths in addon code** (`grep -rnE '"/(data|opt|mnt|home|srv|var)/' --include=*.py`), `open(`/`os.path` uses, **and path-like values stored in the database** | paths of the old host do not exist in the platform container; imports that read them then fail silently |
| untracked folders next to the addons and extra folders in the data dir | usually import sources the code above reads (often many GB of images); never dismiss one without finding what reads it |
| `ir_config_parameter` values that name the old infrastructure (see query below), above all **`report.url`** | a `report.url` pointing at the old container or host makes wkhtmltopdf fail to load CSS, fonts and images; Odoo tolerates that, and every PDF goes out without the company layout until someone notices |
| `odoo.conf` options: workers, memory and time limits, `server_wide_modules`, `[queue_job] channels`, `proxy_mode`, `dbfilter` | become the service's `extra_config` (`"section.key"` for sections other than `[options]`) |
| outgoing and incoming mail servers (OAuth with Microsoft or Google?), `web.base.url`, `web.base.url.freeze`, `database.enterprise_code` | mail links and OAuth redirects follow the base URL; the subscription follows the database identity |
| integrations that may allow-list the old server's IP (supplier APIs, punchout, payment providers, EDI), and inbound callers (webhooks, external scripts using XML-RPC/JSON-RPC with the **database name**) | a new server changes the outgoing IP; the database on calmo.cloud is named after the service, so callers that send the old database name fail |
| IoT boxes, printers, VoIP | the IoT pairing is bound to the database identity |
| what else runs on the old host: crons, backups, other apps, VPN/Tailscale, ports 80/443 | decides whether an in-place move is possible and what the cutover must not break |

The query for infrastructure leftovers:

```sql
select key, value from ir_config_parameter
 where value ~* '//(localhost|127\.0\.0\.1|odoo|db|web|proxy|wkhtmltopdf)[:/]|:8069|/opt/|/srv/|/data/|/var/lib/odoo'
   and not (key = 'report.url' and value = 'http://localhost:8069');
```

Also measure while the old system runs: the time and size of a dump, and of a
restore into a throwaway container (phase 3). That turns the downtime estimate
into a number.

## Phase 2 — plan and decisions

Write the plan down for the user and ask (`AskUserQuestion`, recommendation first):

1. **Target server.** A **new server** is the default: it can be set up and
   rehearsed in parallel, and the old system stays untouched as the fallback.
   It needs a DNS change and, if partners allow-list IPs, their update.
   **In place** (calmo.cloud takes over the old machine) keeps the IP and DNS
   but means a hard cutover and only works on a host that runs nothing else
   important; read [references/in-place.md](references/in-place.md) first.
   A server can be added (`create_server` for a machine the user has) or
   ordered (`list_server_providers` → `list_server_provider_options` for
   location, type and image → `provision_server`; costs money, needs confirmation).
2. **Cutover time.** Default: prepare everything, then cut over on the user's go,
   outside business hours. Offer the measured downtime.
3. **SSH keys on the new server.** Every key on a calmo.cloud server grants
   root. Never attach all of the team's keys; show them and ask which.
4. **Transfer method** (see [references/transfer.md](references/transfer.md)):
   the standard Odoo backup zip with filestore (simple, fine up to roughly
   10 GB of filestore), or a database-only archive plus a direct filestore copy
   (large filestores, tight disk).
5. **Code.** Unpushed commits and untracked modules: push them, or leave a
   module out (only if it is not installed). Odoo.sh repositories name branches
   after environments; calmo.cloud expects a branch per version unless told
   otherwise.
6. **Subscription.** Leaving Odoo.sh or Odoo Online means asking Odoo or the
   partner to switch the Enterprise subscription to self-hosting.
7. **Test copy** now or after the move (a copy needs free disk of about twice
   the filestore on the server it lands on).

## Phase 3 — preparation (no downtime)

1. Push outstanding addon commits (`git fetch` first; a stale tracking ref
   often makes a checkout look ahead when it is not).
2. **Server.** `create_server` (its name becomes the platform domain slug) →
   `check_server_reachability` → `install_docker`, poll `get_server` until
   Docker is installed → `update_server` with `database_postgres: true`,
   `proxy_traefik: true` and `proxy_traefik_acme_mail`, `monitoring_telegraf: true`
   if wanted. Send `database_postgres_tuning` in a second call; it is refused
   until the server has a database. None of these can be switched off again.
   Poll `get_server` until `is_ready_for_odoo` is true (reachable, Docker,
   Postgres and Traefik running); `create_service` refuses a server before that.
   If a flag is on but its `*_running` field stays false for more than a few
   minutes, look on the server (`docker ps`) and contact calmo.cloud support
   rather than retrying.
3. **Backup destination.** `list_backup_destinations`. The import stores the
   archive at the service's **primary** destination and is refused without one.
4. **Repository.** `create_repository` with `is_private`, the
   `github_app_installation_uuid` and the `branch` to discover addons on (it is
   not stored on the repository). Poll `get_repository` until `addons_count`
   stops growing. Connect each extra
   addon repository (OCA, vendors, submodules) the same way.
5. **Service.** `create_service` with the version, type `live`, the
   `extra_config` from the inventory, the backup destination, and **no custom
   hostnames yet** (they would compete for certificates while DNS still points
   at the old host). Poll `get_service` until it runs, then `attach_repository`
   with the `branch` whenever it is not the version name (Odoo.sh `production`,
   a `main` branch): without it the service looks for a branch named `18.0` etc.
   Follow `list_service_operations` until every "Deploy addon" operation is done.
   `busy` can be false before those operations are queued; if none appear within
   about ten minutes, nothing was deployable or GitHub could not be read — check
   the repository's branch and the GitHub App's access.
   Many addons mean many parallel SSH connections to the server; if deploys fail
   with `kex_exchange_identification: Connection reset`, raise sshd's
   `MaxStartups` (e.g. `MaxStartups 100:30:200` in
   `/etc/ssh/sshd_config.d/99-migration.conf`, `systemctl reload ssh`) and remove
   it after the move. If the compose file of the service does not mount the
   addons yet, `redeploy_service`.
6. **Rehearse the restore** with a current backup, without touching the service:
   **[ssh]** on the new server load the dump into a throwaway container
   (`docker run -d --name restore-probe -e POSTGRES_PASSWORD=x pgvector/pgvector:pg18`,
   `psql -f dump.sql`, time it, then `docker rm -fv restore-probe`; without `-v`
   the anonymous volume keeps a full copy of the database). A restore over
   about 6 minutes risks the platform's SSH timeout: plan the direct load
   ([references/transfer.md](references/transfer.md)).
7. **Hostnames and DNS.** Prepare the list: routed names (main domain, one per
   website, other shop domains) and redirects (`www.` and old domains → main,
   permanent). On a new server, lower the TTL of the records to 300 s a day
   ahead. Leave out names whose DNS will not point at the new server: one
   failing name blocks the certificate of the whole service.
8. **Go/no-go list** for the user: what is ready, the expected downtime, who
   must do what at the switch (DNS, IP allow-lists, Odoo subscription), what
   users must do afterwards (e.g. re-add the account in the Odoo mobile app if
   it stored the old database name), and how to go back.

## Phase 4 — cutover

The order is fixed; the commands depend on the source (see its section in
[references/sources.md](references/sources.md)).

1. **Freeze the old system.** Stop Odoo (and its cron/worker processes) on a host
   you control, keeping the database server running for the dump. Where you
   cannot stop it (Odoo.sh, Odoo Online, managed hoster), the user tells their
   team to stop working and you note the time; anything entered after the final
   backup is lost. Make sure the old Odoo does not come back by itself
   (`restart: always` in compose, systemd `Restart=`, a Docker daemon restart).
2. **Record the identity** of each database before anything else:
   `database.uuid`, `database.secret`, `database.create_date`,
   `database.enterprise_code`, `web.base.url`, `web.base.url.freeze` (into a file,
   chmod 600). Without a shell, read them from the backup's `dump.sql`
   ([references/transfer.md](references/transfer.md)).
3. **Take the final data** and build the archive the chosen transfer method
   needs; put it on the new server under `/var/tmp` (not `/tmp`, which is a small
   tmpfs on some systems).
4. Wait until `get_service` is not `busy` (a restore is refused while another
   operation runs), then `import_backup` with `source_path`, `restore: true`,
   `skip_safety_backup: true` (the service is empty), and `confirm` with the
   service's name. Poll `get_backup` until `completed` or `failed` (read the error).
   For the direct load or a separate filestore copy, follow
   [references/transfer.md](references/transfer.md).
5. **Restore the identity and fix parameters.** The platform restores *as a
   copy*: Odoo gives the database a new `database.uuid`, `database.secret` and
   `create_date` (which unlinks the Enterprise subscription and an IoT box
   pairing) and calmo.cloud sets `web.base.url` to the platform hostname.
   **[ssh]** write the recorded values back
   (`docker exec -i postgres psql -U postgres -d <service_uuid>`;
   the database is named after the service uuid), set `web.base.url` to the
   customer domain, `report.url` to `http://localhost:8069`, fix every other
   parameter and stored path the inventory flagged, then `restart_service`.
6. **Data the code reads from disk** (inventory): copy it into the service's data
   volume on the server (`/data/aura/services/odoo/<service_uuid>/volumes/odoo/data/…`,
   which is `/home/odoo/data/…` in the container) and point the code or the stored
   path at it. Only `filestore/` inside that directory is part of calmo.cloud
   backups; tell the user about anything else.
7. **Hostnames.** `add_hostname` for every routed name, then the redirects
   (`redirect_to` the main hostname, `redirect_permanent: true`). Switch DNS
   now on a new server. Each name is routed as soon as its DNS points at the
   server, and the certificate follows within minutes. Adding many names starts
   one redeploy per name; wait until `get_service` is no longer busy, then check
   `is_running` and `restart_service` if it reports stopped while Odoo answers.
8. Downtime ends when the main domain answers with a valid certificate and the
   login works.

## Phase 5 — verification

- `curl -sI` every routed hostname (200/303, valid certificate) and every redirect
  (301 to the right target, path kept).
- Log in; **Settings → Apps**: modules installed, none waiting for an upgrade.
- `web.base.url` is the customer domain; `database.uuid` and the Enterprise code
  are the recorded ones; **Settings** shows no subscription warning.
- Outgoing mail sends; incoming mail servers connect and fetch (OAuth tokens still
  valid); scheduled actions run (`ir_cron.lastcall` moves); `queue_job` processes
  jobs; live chat and Discuss connect (`/websocket`).
- **Render real PDFs** (invoice, delivery slip) and compare with one made before
  the move: a plain default font instead of the company layout means the CSS did
  not load (`report.url`). Search the Odoo log for `wkhtmltopdf`.
- Integrations: one real call each, or ask the partner to test. IoT: one test
  print by the user.
- Odoo log: count `ERROR` lines by message and compare with the old system's log
  over a similar span. A burst of crawler traffic right after the switch causes
  `website_visitor` serialization errors that stop with the burst.
- Callers that still send the old database name show up as failed logins or
  `database ... does not exist` in the log; list them for the user.
- `create_uptime_monitor` for the main hostname (`hostname_uuid` from
  `list_hostnames`); set the backup schedule
  (`update_service`) once the disk allows it.
- Report the result, the actual downtime and what is left to do.

## Phase 6 — aftercare (each step only with the user's go)

- **Disk.** A calmo.cloud backup packs the whole filestore on the server first,
  so the server needs free space above filestore plus database. Until then the
  first scheduled backups fail; on an in-place move the old system's data is
  what is in the way.
- Remove the old system (after a final backup of it): containers, images,
  volumes, services, dumps. Keep the migration files until the user drops them.
- Remove temporary changes: the sshd `MaxStartups` drop-in, and on an in-place
  move the Docker compatibility drop-in (needs a Docker restart, which restarts
  every container — schedule it).
- Test copy: `copy_service` with `neutralize: true`; hostnames on the copy only
  once it runs.
- Revoke the API token if it was made for the migration.

## Rollback (until the old system is removed)

Stop the calmo.cloud service (`stop_service`, `confirm` with its name), switch DNS back (or, in place,
stop the platform's containers and start the old stack), and restart the old
Odoo. The old database and filestore are untouched. Anything entered on
calmo.cloud since the switch is lost unless it is exported first, so decide
early, and tell the user that at the go/no-go.

## Pitfalls seen in real moves

- `report.url` / `web.base.url` pointing at the old container: PDFs without layout.
- Addon code reading absolute paths of the old host: imports silently empty.
- A wildcard proxy rule hiding dozens of website domains.
- Odoo coming back on the old host after a Docker or host restart because of a
  restart policy, while users already work on the new one.
- Something else listening on 443 on the target (a VPN's HTTPS serve, another
  web server): Traefik cannot bind, and every hostname fails.
- External scripts and the Odoo mobile app still sending the old database name.
- A first scheduled backup failing for lack of disk.
