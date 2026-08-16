# STOP Migration — ONLYOFFICE Workspace emergency recovery

Use this only when an ONLYOFFICE storage migration has failed or has deliberately been aborted and the tenant remains stuck in `Migrating` state.

## Known failure signature

The affected tenant appears in `onlyoffice.tenants_tenants` with:

- `status = 5` — Migrating
- normal active state is `status = 0`

This recovery was proven on the Grange Workspace installation on 16 August 2026 with:

- Community Server: `onlyoffice-community-server`
- MySQL: `onlyoffice-mysql-server`
- database: `onlyoffice`
- tenant: `1 / localhost`

## What the script does

`scripts/STOP-Migration.sh`:

1. Confirms Docker, Community Server and MySQL are present.
2. Verifies MySQL over TCP `127.0.0.1:3306`.
3. Refuses to continue unless exactly one tenant is `status=5`.
4. Stops Community Server before changing SQL, preventing the migration worker from continuing.
5. Backs up the affected `tenants_tenants` row to `/root`.
6. Re-checks that the tenant is still `status=5` after Community Server has stopped.
7. Updates only that tenant from `status=5` to `status=0` and refreshes `statuschanged` / `last_modified`.
8. Starts Community Server again.
9. Verifies the tenant remains Active and checks that no storage migration worker remains.

## What it deliberately does NOT do

It does not:

- change storage configuration;
- change S3 credentials or buckets;
- delete either source or destination files;
- restore MySQL;
- empty partial migration data;
- start a new migration;
- perform a portal restore.

## Run

```bash
chmod 700 scripts/STOP-Migration.sh
sudo scripts/STOP-Migration.sh
```

The script is intentionally fail-closed. If the observed system state does not match the known stuck-migration condition, it exits without applying the SQL change.

## Important

A partial migration destination may contain copied files. Treat it as disposable only after independently confirming that the old/source storage remains authoritative. This recovery script does not make that decision and does not remove any files.
