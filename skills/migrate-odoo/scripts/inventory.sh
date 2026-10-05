#!/usr/bin/env bash
# Read-only inventory of a host that runs Odoo, for a move to calmo.cloud.
# Works for Docker / docker compose and for package, source and venv installs
# under systemd. It changes nothing and prints no passwords.
#
#   ssh root@<host> 'bash -s' < inventory.sh
#   ssh root@<host> 'DB=mydb bash -s' < inventory.sh
#
# Overrides when detection guesses wrong:
#   DB              database to inspect (default: db_name from odoo.conf, or the only one)
#   ODOO_CONTAINER  the Odoo container (Docker)
#   PG_CONTAINER    the Postgres container (Docker)
#   CONF            path of odoo.conf (non-Docker)
#   PSQL            full psql prefix, e.g. "sudo -u postgres psql"
set -u

# Everything runs inside main so that bash reads the whole script before it
# starts: with `bash -s` a command reading stdin would otherwise eat the rest.
main() {

section() { printf '\n===== %s =====\n' "$1"; }
have() { command -v "$1" >/dev/null 2>&1; }
secret_filter() { grep -v -i -E 'pass(wd|word)?|secret|token|api_?key|^\s*;|^\s*$'; }

section "host"
hostname; grep PRETTY_NAME /etc/os-release 2>/dev/null; nproc; free -h | sed -n 2p
df -h / /var /data /opt 2>/dev/null | awk 'NR==1 || !seen[$0]++'
echo "public ip: $(curl -s -4 --max-time 5 ifconfig.me)"
echo "listening: $(ss -ltnH 2>/dev/null | awk '{print $4}' | grep -E ':(80|443|5432|8069|8072)$' | sort -u | tr '\n' ' ')"
have docker && docker version --format 'docker {{.Server.Version}} (api {{.Server.APIVersion}})' 2>/dev/null

# ---------------------------------------------------------------- detection
MODE=process
if have docker && docker info >/dev/null 2>&1; then
    ODOO_CONTAINER="${ODOO_CONTAINER:-$(docker ps --format '{{.Names}}\t{{.Image}}\t{{.Command}}' \
        | awk -F'\t' 'tolower($2" "$3) ~ /odoo/ && tolower($2) !~ /postgres|pgvector|postgis/ {print $1; exit}')}"
    [ -n "$ODOO_CONTAINER" ] && MODE=docker
fi

if [ "$MODE" = docker ]; then
    CONF_TEXT="$(docker exec "$ODOO_CONTAINER" sh -c 'cat "${ODOO_RC:-/etc/odoo/odoo.conf}"' 2>/dev/null)"
    in_odoo() { docker exec "$ODOO_CONTAINER" sh -c "$1" 2>/dev/null; }
else
    if [ -z "${CONF:-}" ]; then
        CONF="$(ps -eo args | grep -E '[o]doo(-bin)?' | grep -oE '(-c|--config)[ =][^ ]+' | head -1 | sed -E 's/^(-c|--config)[ =]//')"
        for candidate in /etc/odoo/odoo.conf /etc/odoo.conf /etc/odoo-server.conf; do
            [ -z "$CONF" ] && [ -f "$candidate" ] && CONF="$candidate"
        done
    fi
    CONF_TEXT="$(cat "${CONF:-/dev/null}" 2>/dev/null)"
    in_odoo() { sh -c "$1" 2>/dev/null; }
fi

conf_get() {
    printf '%s\n' "$CONF_TEXT" | awk -v key="$1" '
        /^\s*\[/ { section = $0 }
        section ~ /options/ || section == "" {
            line = $0; sub(/^[ \t]+/, "", line)
            if (index(line, key) == 1) { rest = substr(line, length(key) + 1); sub(/^[ \t]*=[ \t]*/, "", rest)
                if (rest != line) { print rest; exit } }
        }'
}

DB_HOST="$(conf_get db_host)"; DB_USER="$(conf_get db_user)"; DB_PASSWORD="$(conf_get db_password)"
DB_PORT="$(conf_get db_port)"; DATA_DIR="$(conf_get data_dir)"; ADDONS_PATH="$(conf_get addons_path)"

if [ -z "${PSQL:-}" ]; then
    if [ "$MODE" = docker ]; then
        PG_CONTAINER="${PG_CONTAINER:-$(docker ps --format '{{.Names}}\t{{.Image}}' \
            | awk -F'\t' 'tolower($2) ~ /postgres|pgvector|postgis/ {print $1; exit}')}"
        if [ -n "$PG_CONTAINER" ]; then
            PG_USER="${DB_USER:-$(docker exec "$PG_CONTAINER" printenv POSTGRES_USER 2>/dev/null)}"
            PSQL="docker exec -i $PG_CONTAINER psql -U ${PG_USER:-postgres}"
        else
            PSQL="docker exec -i -e PGPASSWORD=$DB_PASSWORD $ODOO_CONTAINER psql -h ${DB_HOST:-db} -p ${DB_PORT:-5432} -U ${DB_USER:-odoo}"
        fi
    elif [ -z "$DB_HOST" ] || [ "$DB_HOST" = localhost ] || [ "$DB_HOST" = 127.0.0.1 ] || [ "$DB_HOST" = False ]; then
        PSQL="sudo -u postgres psql"
    else
        PSQL="env PGPASSWORD=$DB_PASSWORD psql -h $DB_HOST -p ${DB_PORT:-5432} -U ${DB_USER:-odoo}"
    fi
fi
psql_any() { $PSQL -d postgres -At -F ' | ' "$@" 2>/dev/null; }

DATABASES="$(psql_any -c "select datname from pg_database where not datistemplate and datname <> 'postgres' order by 1")"
if [ -z "${DB:-}" ]; then
    DB="$(conf_get db_name)"
    [ -z "$DB" ] || [ "$DB" = False ] && [ "$(printf '%s\n' "$DATABASES" | grep -c .)" = 1 ] && DB="$DATABASES"
fi
psql_db() { $PSQL -d "$DB" -At -F ' | ' "$@" 2>/dev/null; }

section "detected"
echo "mode: $MODE"
[ "$MODE" = docker ] && echo "odoo container: $ODOO_CONTAINER   postgres container: ${PG_CONTAINER:-none (external db_host ${DB_HOST:-?})}"
[ "$MODE" = process ] && { echo "config: ${CONF:-not found}"; ps -eo user,args | grep -E '[o]doo(-bin)?' | cut -c1-200; systemctl list-units --all --no-legend 2>/dev/null | grep -i odoo; }
echo "databases: $(printf '%s ' $DATABASES)"
echo "inspecting database: ${DB:-NONE - rerun with DB=<name>}"

if [ "$MODE" = docker ]; then
    section "containers"
    docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
    echo "--- restart policies"
    docker inspect $(docker ps -aq) --format '{{.Name}} {{.HostConfig.RestartPolicy.Name}}' 2>/dev/null
    echo "--- odoo mounts"
    docker inspect "$ODOO_CONTAINER" --format '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{"\n"}}{{end}}'
    echo "--- compose project: $(docker inspect "$ODOO_CONTAINER" --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}')"
fi

section "odoo.conf (secrets dropped)"
printf '%s\n' "$CONF_TEXT" | secret_filter

section "sizes"
[ -z "$DATA_DIR" ] && { [ "$MODE" = docker ] && DATA_DIR=/var/lib/odoo || DATA_DIR="$(getent passwd odoo | cut -d: -f6)/.local/share/Odoo"; }
echo "data_dir: $DATA_DIR"
in_odoo "du -sh '$DATA_DIR/filestore/$DB' '$DATA_DIR'/* 2>/dev/null"
psql_any -c "select datname, pg_size_pretty(pg_database_size(datname)) from pg_database where not datistemplate"

section "hostnames seen by proxies"
{
    if have docker && docker info >/dev/null 2>&1; then
        docker inspect $(docker ps -q) --format '{{json .Config.Labels}}' 2>/dev/null | grep -oE 'Host(Regexp|SNI)?\(`[^)]*\)'
    fi
    grep -rhoE 'Host(Regexp|SNI)?\(`[^)]*\)' /etc/traefik /opt /srv /data --include='*.yml' --include='*.yaml' --include='*.toml' \
        --exclude-dir=filestore --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=sessions 2>/dev/null
    grep -rhE '^\s*server_name\s' /etc/nginx 2>/dev/null
    grep -rhE '^\s*Server(Name|Alias)\s' /etc/apache2 /etc/httpd 2>/dev/null
    grep -hE '^[^ #\t].*\{\s*$' /etc/caddy/Caddyfile 2>/dev/null
} | sed 's/^[[:space:]]*//' | sort -u

section "addon code"
echo "addons_path: $ADDONS_PATH"
CANDIDATES=""
if [ "$MODE" = docker ]; then
    CANDIDATES="$(docker inspect "$ODOO_CONTAINER" --format '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}')"
else
    CANDIDATES="$(printf '%s' "$ADDONS_PATH" | tr ',' '\n' | sed 's/^ *//')"
fi
for dir in $CANDIDATES; do
    for repo in "$dir" "$dir"/*/ "$dir"/*/*/; do
        [ -d "$repo/.git" ] || continue
        ( cd "$repo" || exit
          git fetch -q 2>/dev/null
          echo "== $repo  $(git remote get-url origin 2>/dev/null)  branch=$(git branch --show-current)  head=$(git rev-parse --short HEAD)"
          echo "   ahead of upstream: $(git rev-list --count '@{u}..HEAD' 2>/dev/null || echo '?')"
          git status --porcelain | head -20 | sed 's/^/   /' )
    done
done
echo "--- absolute paths in addon code"
for dir in $CANDIDATES; do
    grep -rnE "[\"'](/(data|opt|mnt|home|srv|var|media))/" --include='*.py' "$dir" 2>/dev/null | grep -v -E '/(odoo|enterprise)/addons/' | head -40
done

section "database $DB"
psql_db <<'SQL'
select 'odoo version', latest_version from ir_module_module where name = 'base';
select 'enterprise', count(*) from ir_module_module where name = 'web_enterprise' and state = 'installed';
select 'modules installed', count(*) from ir_module_module where state = 'installed';
select 'param', key || ' = ' || value from ir_config_parameter
 where key in ('web.base.url', 'web.base.url.freeze', 'report.url', 'database.enterprise_code',
               'database.expiration_date', 'database.expiration_reason', 'database.uuid');
select 'infrastructure param', key || ' = ' || value from ir_config_parameter
 where value ~* '//(localhost|127\.0\.0\.1|odoo|db|web|proxy|wkhtmltopdf)[:/]|:8069|/opt/|/srv/|/data/|/var/lib/odoo'
   and not (key = 'report.url' and value = 'http://localhost:8069');
select 'website', id || ' | ' || name || ' | ' || coalesce(domain, '') from website order by id;
select 'mail server', name || ' (' || smtp_host || ')' from ir_mail_server where active;
select 'fetchmail', name || ' (' || server || ')' from fetchmail_server where active;
select 'crons active', count(*) from ir_cron where active;
select 'languages', string_agg(code, ',') from res_lang where active;
select 'iot boxes', count(*) from iot_box;
SQL

section "installed modules not found in any addons path"
if [ -n "${DB:-}" ]; then
    INSTALLED="$(psql_db -c "select name from ir_module_module where state = 'installed' order by 1")"
    AVAILABLE="$(in_odoo '
        for d in $(python3 -c "import odoo, os; print(os.path.dirname(odoo.__file__))" 2>/dev/null)/addons \
                 $(python3 -c "import odoo, os; print(os.path.dirname(os.path.dirname(odoo.__file__)))" 2>/dev/null)/addons \
                 '"$(printf '%s' "$ADDONS_PATH" | tr ',' ' ')"'; do
            [ -d "$d" ] && ls "$d"
        done')"
    if [ -n "$AVAILABLE" ]; then
        LC_ALL=C comm -23 <(printf '%s\n' "$INSTALLED" | LC_ALL=C sort -u) <(printf '%s\n' "$AVAILABLE" | LC_ALL=C sort -u) \
            | grep -vx studio_customization  # lives in the database only
    else
        echo "could not list addons paths; compare by hand"
    fi
fi

section "other things on this host"
crontab -l 2>/dev/null | grep -v '^#'; ls /etc/cron.d 2>/dev/null | tr '\n' ' '; echo
systemctl list-units --type=service --state=running --no-legend 2>/dev/null | awk '{print $1}' | grep -v -E '^(systemd|dbus|ssh|cron|rsyslog|getty|user@|polkit|networkd|resolved|udev|containerd|docker)' | head -30
have tailscale && tailscale serve status 2>/dev/null | head -5
}

main "$@" < /dev/null
