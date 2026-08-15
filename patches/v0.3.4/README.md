# v0.3.4 patch sources

These sources implement the **manual-backup-first** v0.3.4 work. The branch was initially named for the later nightly goal, but no scheduler/cron/nightly policy is implemented here. Manual acceptance comes first.

- `S3CompatibleZipWriteOperator.cs` — 192 MiB backup-only multipart writer with bounded async uploads, 10,000-part guard and abort-on-failure.
- `build-s3compatible.py` — reproducible transformer from exact ONLYOFFICE 12.8 `S3Storage.cs` plus consumer-config update.
- `controlpanel-s3-probe.js` — authenticated transient S3 SigV4 connection/list/create/100 KiB validation helper.
- `controlpanel-manual-s3-backup.js` — manual Backup-page bucket workflow and Make Backup gate.
