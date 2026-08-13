# ONLYOFFICE Community Storage Profiles

Community-driven S3-compatible storage profiles and backup integrations for **ONLYOFFICE Workspace Community Server**.

> **Project status: early development / experimental.**
> The current development baseline is ONLYOFFICE Workspace Community Server 12.8.0.1971 with Control Panel 3.5.5.549. Do not use this project as a production storage migration tool until the migration and restore test matrix is complete.

## Current architecture — v0.3

The project adds a **new first-class ONLYOFFICE data-store consumer**:

```text
Internal consumer: S3Compatible
Display name:      S3-Compatible Object Storage
Storage handler:   ASC.Data.Storage.S3.S3Storage
```

The stock ONLYOFFICE consumer named `S3` is **not renamed or overwritten**. It remains available for backward compatibility with existing Amazon S3 installations.

For a new installation, `S3Compatible` is the project-owned storage family and Amazon is simply one provider profile inside it:

```text
S3-Compatible Object Storage
  ├─ Amazon S3
  ├─ MEGA S4
  ├─ Wasabi
  ├─ Backblaze B2 S3
  ├─ Cloudflare R2
  ├─ MinIO
  ├─ Ceph RGW
  ├─ OVHcloud Object Storage
  └─ Custom S3-Compatible Endpoint
```

This gives Community Storage Profiles its own consumer identity and credential namespace while reusing ONLYOFFICE's existing, tested S3 storage implementation.

## Why a separate consumer?

ONLYOFFICE loads data-store consumers from configuration and resolves them by name. The selected consumer supplies a `handlerType`, which is instantiated as the actual storage engine.

That means `S3Compatible` can point at the existing:

```text
ASC.Data.Storage.S3.S3Storage, ASC.Data.Storage
```

without forking or replacing `ASC.Data.Storage.dll`.

A separate consumer also means credentials are stored under the `S3Compatible` consumer namespace rather than colliding with the stock `S3` consumer.

## Existing S3-compatible capabilities in ONLYOFFICE 12.8

The native S3 handler already understands:

- `acesskey` — spelling retained exactly as ONLYOFFICE ships it
- `secretaccesskey`
- `bucket`
- `region`
- `serviceurl`
- `forcepathstyle`
- `usehttp`
- `sse`
- `ssekey`
- `cname`
- `cnamessl`

`serviceurl` and `forcepathstyle` are used by the AWS SDK client for custom S3-compatible endpoints.

The `cname` / `cnamessl` properties matter because ONLYOFFICE 12.8 otherwise constructs object URLs using Amazon-style `s3.<region>.amazonaws.com` roots even when a custom `serviceurl` is configured. Community Storage Profiles therefore includes optional object-base-URL fields in the generic consumer.

## v0.3 developer preview

`scripts/storage-profiles-v0.3.sh` currently:

- adds the `S3Compatible` consumer to the active CommunityServer / TeamLabSvc consumer configurations;
- uses the existing `ASC.Data.Storage.S3.S3Storage` handler;
- gives the new service its own neutral icon and Third-Party Services presentation;
- teaches Control Panel Storage, Backup and Restore to render `S3Compatible` with the existing S3 settings template;
- adds the provider-profile selector to the primary Storage form;
- hides the unused legacy `S3` option from the primary Storage list while preserving configured legacy Amazon S3 installations;
- creates exact backups and a rollback manifest;
- does **not** call the storage update API;
- does **not** select a provider;
- does **not** read or write credentials;
- does **not** start document migration.

The provider selector is intentionally non-activating at this stage. Provider-specific defaults will only be added after endpoint/signing/addressing behaviour has been verified against the ONLYOFFICE 12.8 AWS SDK.

## Cleaning up old development experiments

The v0.1 / v0.2 / v0.2.1 installers have been removed from the current branch because they explored the wrong presentation architecture.

If a development system previously installed one of those experiments, run:

```bash
bash scripts/cleanup-pre-v0.3.sh cleanup
```

before installing v0.3.

The experiments remain in Git history for transparency, but they are not part of the supported current tree.

## Storage families

### S3-Compatible Object Storage

Provider profiles are metadata layered over the `S3Compatible` consumer. Profiles never contain credentials.

Initial targets:

- Amazon S3
- MEGA S4
- Wasabi
- Backblaze B2 S3
- Cloudflare R2
- MinIO
- Ceph RGW
- OVHcloud Object Storage
- Custom S3-compatible endpoint

### Native object storage

ONLYOFFICE 12.8 also contains a native Google Cloud Storage consumer using:

```text
ASC.Data.Storage.GoogleCloud.GoogleCloudStorage
```

That remains a separate native engine rather than being forced through the S3-compatible layer.

### Backup / bridge targets

Primary document storage and backup destinations are deliberately separate concepts. Planned backup/bridge targets include:

- local filesystem / mounted NAS
- WebDAV
- SFTP
- Google Drive
- OneDrive
- Dropbox
- Azure Blob Storage
- Duplicati
- rclone
- experimental `rclone serve s3` gateway

A cloud-drive or gateway target will not be represented as safe production primary storage merely because it can be made to look like S3.

## Safety model

Storage changes can cause data loss. Current project rules:

1. Version/image preflight before modifying installed files.
2. Backup every modified file and preserve owner/group/mode.
3. Explicit `status` and `rollback` operations.
4. No credentials in Git, profile JSON, logs or command examples.
5. Installation must not auto-select `S3Compatible`.
6. Installation must not call the storage migration API.
7. Switching primary storage is treated as a migration event, not a harmless settings save.
8. Provider testing must cover write, read, overwrite, delete, large objects, restart persistence and SHA-256 integrity.
9. Restore testing is mandatory before a provider can be called production-ready.
10. Existing configured stock `S3` installations must not be stranded by the project UI.

## Current baseline

- ONLYOFFICE Workspace Community Server: **12.8.0.1971**
- Upstream CommunityServer source: **v12.8**
- ONLYOFFICE Control Panel image: **3.5.5.549**
- Upstream ControlPanel source: **v3.5.5**

## Repository layout

```text
docs/        architecture and design notes
profiles/    provider-neutral profile schema and catalogue
scripts/     bootstrap, discovery, cleanup, install/status/rollback tooling
```

## Roadmap

### v0.3 — first-class generic consumer

- [x] Confirm configurable consumer registration
- [x] Confirm arbitrary DataStoreConsumer names are supported
- [x] Confirm storage API enumerates DataStoreConsumers
- [x] Confirm StorageSettings resolves the selected consumer by name and handler type
- [x] Add `S3Compatible` consumer installer
- [x] Reuse stock `S3Storage` handler
- [x] Add Control Panel S3-template recognition
- [ ] Verify the new service appears correctly on the development Workspace
- [ ] Verify credentials save to the new consumer namespace
- [ ] Verify no legacy `S3` credential collision

### Provider profiles

- [ ] MEGA S4 endpoint/signing/addressing verification
- [ ] Amazon S3 compatibility regression test
- [ ] MinIO controlled compatibility test
- [ ] Wasabi test
- [ ] Backblaze B2 S3 test
- [ ] Cloudflare R2 test
- [ ] Ceph RGW test
- [ ] OVHcloud test

### Migration acceptance

- [ ] small-object CRUD
- [ ] large-object / multipart upload
- [ ] SHA-256 integrity verification
- [ ] restart persistence
- [ ] migration from local storage
- [ ] rollback / migration recovery
- [ ] backup creation
- [ ] restore from backup
- [ ] credential/log leakage review

### Upstream

- [ ] convert the tested runtime patch into clean source diffs
- [ ] document exact CommunityServer and ControlPanel changes
- [ ] prepare upstream proposal for a generic S3-compatible consumer/profile layer

## Licence and affiliation

Project code is intended for Apache-2.0-compatible contribution alongside the upstream ONLYOFFICE CommunityServer / ControlPanel codebases.

This is an independent community project. It is not an official ONLYOFFICE product and is not endorsed by Ascensio System SIA unless an upstream contribution is accepted. ONLYOFFICE names and trademarks remain the property of their respective owners.
