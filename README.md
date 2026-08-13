# ONLYOFFICE Community Storage Profiles

Community-driven storage profiles, S3-compatible presets, cloud integrations and self-hosted backup bridges for **ONLYOFFICE Workspace Community Server**.

> **Project status: early development / experimental.**
> No production storage migration patch has been released yet. Initial development is based on ONLYOFFICE Workspace Community Server 12.8.0.1971 and the upstream CommunityServer v12.8 source.

## Core design decision

The stock user-facing **Amazon AWS S3** storage slot is repurposed as **S3-Compatible Object Storage**.

Internally, ONLYOFFICE keeps its existing `S3` consumer ID and `ASC.Data.Storage.S3.S3Storage` handler for backward compatibility. Amazon is no longer treated as the product or top-level storage type; it becomes one provider preset alongside MEGA S4, Wasabi, Backblaze B2 S3, Cloudflare R2, MinIO, Ceph RGW, OVHcloud and Custom.

In other words:

```text
ONLYOFFICE internal engine: S3   (unchanged)
User-facing storage type:   S3-Compatible Object Storage
Provider profile:           Amazon S3 | MEGA S4 | Wasabi | B2 | R2 | MinIO | Ceph | OVH | Custom
```

This preserves the existing ONLYOFFICE storage backend while removing the artificial assumption that the S3 protocol means Amazon.

## Why this project exists

ONLYOFFICE Workspace 12.8 already contains more storage capability than its stock UI exposes. The existing S3 handler supports a custom service URL, region, path-style addressing, HTTP/HTTPS behaviour and server-side encryption. Google Cloud Storage also has a native storage handler.

The project exposes those capabilities through provider-neutral profiles rather than adding a separate implementation for every S3-compatible vendor.

Primary storage and backup destinations remain separate concepts so inexpensive cloud drives, NAS targets and backup bridges are not misrepresented as safe live document storage.

## Design goals

- Keep the internal ONLYOFFICE `S3` engine and settings compatibility intact.
- Replace user-facing **Amazon AWS S3** with **S3-Compatible Object Storage**.
- Make Amazon S3 a preset inside the generic S3-compatible storage family.
- Provide maintained presets for common S3-compatible providers.
- Use native ONLYOFFICE storage handlers where they already exist.
- Keep credentials out of source code, profile files and logs.
- Support self-hosted and low-cost backup workflows.
- Allow provider additions primarily as data profiles rather than provider-specific JavaScript branches.
- Provide install, status, test and rollback tooling for supported ONLYOFFICE versions.
- Keep primary-storage and backup-only targets clearly distinguished.
- Keep the implementation suitable for an upstream ONLYOFFICE contribution.

## Storage families

### S3-Compatible Object Storage

This is the single user-facing S3 storage type. Initial provider presets include:

- Amazon S3
- MEGA S4
- Wasabi
- Backblaze B2 S3
- Cloudflare R2
- MinIO
- Ceph RGW
- OVHcloud Object Storage
- Custom S3-compatible endpoint

A provider preset supplies endpoint, region/signing and addressing defaults where appropriate. Credentials are never stored in the profile catalogue.

### Native object storage

- Google Cloud Storage using the existing `ASC.Data.Storage.GoogleCloud.GoogleCloudStorage` handler
- Other native ONLYOFFICE handlers where they are useful and safe

### Backup / bridge targets

These are intentionally separate from primary document storage:

- Local filesystem
- NAS / mounted filesystem
- WebDAV
- SFTP
- Google Drive
- OneDrive
- Dropbox
- Azure Blob Storage
- Duplicati-managed backup destinations
- rclone remotes
- Experimental local S3 gateway using `rclone serve s3`

## Current ONLYOFFICE baseline

Initial development target:

- ONLYOFFICE Workspace Community Server **12.8.0.1971**
- Upstream CommunityServer tag **v12.8**
- Existing storage API family: `settings/storage.json`
- Existing S3 region API: `settings/storage/s3/regions.json`
- Existing S3 engine: `ASC.Data.Storage.S3.S3Storage`
- Existing Google Cloud engine: `ASC.Data.Storage.GoogleCloud.GoogleCloudStorage`

The S3 consumer already contains these storage properties:

- `bucket`
- `region`
- `serviceurl`
- `forcepathstyle`
- `usehttp`
- `sse`
- `ssekey`

The project therefore focuses first on the Control Panel / Storage UI and provider-profile layer rather than replacing the proven S3 backend.

## Architecture

Profiles are metadata. Engines do the storage work.

```text
ONLYOFFICE Workspace
        |
        +-- S3-Compatible Object Storage   [internal engine id: S3]
        |      +-- Amazon S3 preset
        |      +-- MEGA S4 preset
        |      +-- Wasabi preset
        |      +-- B2 / R2 / MinIO / Ceph / OVH presets
        |      +-- Custom S3 profile
        |
        +-- Native Google Cloud engine
        |      +-- Google Cloud Storage
        |
        +-- Backup / bridge layer
               +-- Local / NAS
               +-- Duplicati
               +-- rclone
               +-- consumer cloud drives
```

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Safety model

Storage changes can cause data loss. This project therefore treats the following as mandatory:

1. Version preflight before modifying ONLYOFFICE files.
2. Backup of every modified source/configuration file.
3. Idempotent installation where practical.
4. Explicit `status`, `test` and `rollback` operations.
5. No credentials in repository files.
6. Test environment before production.
7. Selecting a different primary storage provider is treated as a migration operation, not a harmless settings save.
8. Primary-storage testing must cover write, read, overwrite, delete, restart persistence and integrity verification.
9. Experimental gateway targets must be labelled as such and must not silently become recommended production primary storage.

## Repository layout

```text
docs/        architecture, compatibility and testing notes
profiles/    provider-neutral schemas and provider presets
scripts/     discovery, installation, test and rollback tooling
```

## Roadmap

### Phase 1 — discovery and profile framework

- [x] Confirm ONLYOFFICE 12.8.0.1971 storage API and S3 consumer
- [x] Confirm hidden custom S3 endpoint/path-style configuration
- [x] Confirm native Google Cloud Storage handler
- [x] Confirm Control Panel has a dedicated S3 storage template
- [x] Decide to replace the user-facing Amazon slot with S3-Compatible Object Storage
- [ ] Build provider profile loader
- [ ] Add provider selector to the stock S3 storage form
- [ ] Preserve Amazon compatibility as a preset

### Phase 2 — development Workspace

- [ ] Test MEGA S4 against a non-production Workspace
- [ ] Small-object CRUD test
- [ ] Large-object test
- [ ] SHA-256 integrity verification
- [ ] Container/service restart persistence
- [ ] Log/credential leakage check
- [ ] Rollback verification

### Phase 3 — wider provider testing

- [ ] Amazon S3 compatibility regression test
- [ ] MinIO test
- [ ] Google Cloud native handler test
- [ ] At least one additional hosted S3-compatible provider
- [ ] Backup bridge proof of concept

### Phase 4 — upstream

- [ ] Publish tested patch/release
- [ ] Document changed upstream source files
- [ ] Prepare upstream proposal to generalise the stock Amazon-labelled S3 slot into **S3-Compatible Object Storage**
- [ ] Notify / submit to ONLYOFFICE upstream

## Contributing

Provider additions should prefer profile data over special-case implementation code.

## Licence

Apache License 2.0.

## Trademark / affiliation

This is an independent community project. It is not an official ONLYOFFICE product and is not endorsed by Ascensio System SIA unless and until an upstream contribution is accepted. ONLYOFFICE names and trademarks remain the property of their respective owners.
