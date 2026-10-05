# Transfer: archive, filestore, direct load, identity

## Standard archive (default)

A standard Odoo backup zip — `dump.sql`, `filestore/`, `manifest.json` — on the
new server, then `import_backup` with `source_path`, `restore: true`. From
Odoo.sh, Odoo Online and the database manager it is what you download. On a host
you control, build it yourself after the freeze:

```bash
scp "<skill dir>/scripts/make-archive.py" root@<host>:/var/tmp/
ssh root@<host> python3 /var/tmp/make-archive.py --dump dump.sql \
    --filestore /path/to/filestore/<db> --version 18.0 --out /var/tmp/import_<db>.zip
```

The import copies the zip to the backup destination and restores it; the server
needs free disk of about twice the archive plus the extracted filestore.

## Database-only archive plus filestore copy (large filestores)

Zipping and unzipping a filestore of tens of GB costs an hour and the disk. Send
only the database through the import, and copy the filestore directly:

1. After the freeze, dump, and build a database-only archive (leave out
   `--filestore`). A plain dump compresses well: 4 GB of SQL zips to about
   600 MB in under a minute with compression level 1.
2. While the import runs, copy the filestore to the new server:
   `rsync -aH --info=progress2 <old filestore>/ root@<new>:/var/tmp/fs_<db>/`.
   Do a first `rsync` during preparation; after the freeze only the changes go
   over. On the same machine (in place), `cp -al` hardlinks instead of copying —
   seconds for 60 GB, as long as both paths are on one filesystem (`df`).
3. After the restore, **[ssh]** swap it in:
   ```bash
   FS=/data/aura/services/odoo/$SVC/volumes/odoo/data/filestore
   mv $FS/$SVC $FS/$SVC.empty && mv /var/tmp/fs_<db> $FS/$SVC
   ```
   (`$SVC` is the service uuid; the filestore folder is named after the
   database, which is the service uuid.) Between restore and swap Odoo may have
   written a few files, typically regenerated asset bundles: copy them over from
   `.empty`, or delete the `ir_attachment` rows created since the restore whose
   file is missing (asset bundles regenerate). Then `restart_service`.

## Direct load (very large databases)

The platform restore runs over SSH with a timeout of about 10 minutes. If the
rehearsal restore takes more than about 6, load the dump directly:

1. `stop_service` (`confirm` with the service's name).
2. **[ssh]** in the `postgres` container:
   `DROP DATABASE "$SVC"; CREATE DATABASE "$SVC" OWNER "$SVC" TEMPLATE template0;`
   then create the extensions the dump uses as the `postgres` user
   (`grep -E '^CREATE EXTENSION' dump.sql`).
3. `docker exec -i postgres psql -U "$SVC" -d "$SVC" -v ON_ERROR_STOP=1 < dump.sql`.
4. Copy the filestore as above, `start_service`.

This keeps the database identity, so the identity step below is not needed; still
fix `web.base.url`, `report.url` and the flagged parameters.

## Restoring the identity

The import restores *as a copy*: new `database.uuid`, `database.secret` and
`database.create_date`, which unlinks the Enterprise subscription and IoT
pairings, and `web.base.url` set to the platform hostname. Record the old values
before (phase 4, step 2):

```sql
select key, value from ir_config_parameter where key in (
  'database.uuid', 'database.secret', 'database.create_date',
  'database.enterprise_code', 'web.base.url', 'web.base.url.freeze', 'report.url');
```

Without a shell on the old host, read them from the backup:

```bash
unzip -p backup.zip dump.sql | awk '/^COPY public.ir_config_parameter /{on=1; next} on && /^\\\.$/{exit} on' \
  | grep -E $'\t(database\\.(uuid|secret|create_date|enterprise_code)|web\\.base\\.url(\\.freeze)?|report\\.url)\t'
```

Write them back after the restore (values in a file, never on the command line
you show the user), then `restart_service`:

```sql
update ir_config_parameter set value = :'v' where key = 'database.uuid';
-- … the same for database.secret, database.create_date
update ir_config_parameter set value = 'https://erp.example.com' where key = 'web.base.url';
update ir_config_parameter set value = 'http://localhost:8069' where key = 'report.url';
```

Only one database may carry an identity at a time: once the new one has it, the
old system must not run again except as a rollback.
