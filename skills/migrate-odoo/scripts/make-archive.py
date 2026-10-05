#!/usr/bin/env python3
"""Build an Odoo backup archive that calmo.cloud's import_backup accepts.

    make-archive.py --dump dump.sql --version 18.0 --out /var/tmp/import_live.zip
    make-archive.py --dump dump.sql --filestore /var/lib/odoo/filestore/live \
        --version 18.0 --out /var/tmp/import_live.zip

The archive holds dump.sql (a plain-format pg_dump, best taken with --no-owner),
manifest.json and filestore/. Without --filestore the filestore folder is
empty: use that for the database-only transfer, where the filestore is copied
to the server separately.

Uses compression level 1: a SQL dump still shrinks to a fraction, and the
archive is built in about the time it takes to read the files.
"""
import argparse
import json
import os
import sys
import zipfile


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dump", required=True, help="plain-format pg_dump file")
    parser.add_argument("--version", required=True, help="Odoo major version, e.g. 18.0")
    parser.add_argument("--out", required=True, help="archive to write, e.g. /var/tmp/import_live.zip")
    parser.add_argument("--filestore", help="the database's filestore directory (omit for a database-only archive)")
    parser.add_argument("--db-name", default="db", help="database name recorded in manifest.json")
    args = parser.parse_args()

    if not os.path.isfile(args.dump):
        sys.exit(f"dump not found: {args.dump}")
    if args.filestore and not os.path.isdir(args.filestore):
        sys.exit(f"filestore not found: {args.filestore}")

    major = args.version.split(".")[0]
    manifest = {
        "odoo_dump": "1",
        "db_name": args.db_name,
        "version": args.version,
        "version_info": [int(major), 0, 0, "final", 0, ""],
        "major_version": args.version,
        "pg_version": "",
        "modules": {},
    }

    files = 0
    with zipfile.ZipFile(args.out, "w", zipfile.ZIP_DEFLATED, compresslevel=1) as archive:
        archive.writestr("manifest.json", json.dumps(manifest, indent=4))
        archive.write(args.dump, "dump.sql")
        archive.writestr("filestore/", "")
        if args.filestore:
            for root, _, names in os.walk(args.filestore):
                for name in names:
                    path = os.path.join(root, name)
                    archive.write(path, os.path.join("filestore", os.path.relpath(path, args.filestore)))
                    files += 1

    size = os.path.getsize(args.out) / 1024 ** 2
    print(f"{args.out}: {size:.0f} MB, {files} filestore files")


if __name__ == "__main__":
    main()
