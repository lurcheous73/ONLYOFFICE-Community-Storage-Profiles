# ONLYOFFICE Community Storage Profiles

Community-driven storage profiles, S3-compatible presets, cloud integrations and self-hosted backup bridges for **ONLYOFFICE Workspace Community Server**.

> **Project status: early development / experimental.**
> No production storage migration patch has been released yet. The current work is based on a live-code audit of ONLYOFFICE Workspace Community Server 12.8.0.1971 and will be tested on a non-production Workspace before any production recommendation.

## Why this project exists

ONLYOFFICE Workspace already contains more storage capability than the stock administration UI exposes. In the 12.8.0.1971 build examined for this project, the existing S3 consumer already has configuration properties for a custom service URL, region, path-style addressing, HTTP/HTTPS behaviour and server-side encryption. Google Cloud Storage also has a native storage handler.

The aim of this project is to expose those capabilities through a provider-neutral profile system instead of treating object storage as "Amazon only".

The project also separates **primary storage** from **backup destinations** so that inexpensive or free services can be useful without pretending that every sync target is suitable as a live production document store.

## Design goals

- Preserve existing Amazon S3 behaviour and backward compatibility.
- Add generic **S3-Compatible Object Storage** configuration.
- Provide maintained presets for common S3-compatible providers.
- Use native ONLYOFFICE storage handlers where they already exist.
- Keep credentials out of source code, profile files and logs.
- Support self-hosted and low-cost backup workflows.
- Allow additional providers to be added primarily as data profiles rather than provider-specific JavaScript branches.
- Provide install, status, test and rollback tooling for supported ONLYOFFICE versions.
- Keep primary-storage and backup-only targets clearly distinguished.
- Make upstream contribution to ONLYOFFICE practical.

## Planned storage families

### Native / object storage

- Amazon S3
- Generic S3-compatible storage
- Google Cloud Storage (native ONLYOFFICE handler)
- Existing native ONLYOFFICE storage consumers where safe and useful

### S3-compatible presets

Initial catalogue targets include:

- MEGA S4
- Wasabi
- Backblaze B2 S3
- Cloudflare R2
- MinIO
- Ceph RGW
- OVHcloud Object Storage
- Custom S3-compatible endpoint

A preset fills sensible endpoint/region/addressing defaults. It does **not** require a separate storage engine.

### Backup / bridge targets

These are intentionally treated separately from primary document storage:

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
- Existing storage API family: `settings/storage.json`
- Existing S3 region API: `settings/storage/s3/regions.json`
- Existing S3 engine: `ASC.Data.Storage.S3.S3Storage`
- Existing Google Cloud engine: `ASC.Data.Storage.GoogleCloud.GoogleCloudStorage`

The discovered S3 consumer configuration includes hidden properties for:

- `bucket`
- `region`
- `serviceurl`
- `forcepathstyle`
- `usehttp`
- `sse`
- `ssekey`

That means the first implementation should focus on exposing and safely profiling existing capabilities before considering changes to the storage DLL itself.

## Architecture

Profiles are metadata. Engines do the storage work.

```text
ONLYOFFICE Workspace
        |
        +-- Native S3 engine
        |      +-- AWS preset
        |      +-- MEGA S4 preset
        |      +-- Wasabi preset
        |      +-- B2 / R2 / MinIO / Ceph / OVH presets
        |      +-- Custom S3 profile
        |
        +-- Native Google Cloud engine
        |      +-- Google Cloud Storage profile
        |
        +-- Backup / bridge layer
               +-- Local / NAS
               +-- Duplicati
               +-- rclone
               +-- consumer cloud drives
```

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the design in more detail.

## Safety model

Storage changes can cause data loss. This project therefore treats the following as mandatory:

1. Version preflight before modifying ONLYOFFICE files.
2. Backup of every modified source/configuration file.
3. Idempotent installation where practical.
4. Explicit `status`, `test` and `rollback` operations.
5. No credentials in repository files.
6. Test environment before production.
7. Primary-storage migration tests must cover write, read, overwrite, delete, restart persistence and integrity verification.
8. Experimental gateway targets must be labelled as such and must not silently become recommended production primary storage.

## Repository layout

```text
docs/        architecture, compatibility and testing notes
profiles/    provider-neutral schemas and provider presets
scripts/     installation/test/rollback tooling (development)
```

## Roadmap

### Phase 1 — discovery and profile framework

- [x] Confirm ONLYOFFICE 12.8.0.1971 storage API and S3 consumer
- [x] Confirm hidden custom S3 endpoint/path-style configuration
- [x] Confirm native Google Cloud Storage handler
- [ ] Build provider profile loader
- [ ] Expose generic S3-compatible fields in storage UI
- [ ] Preserve stock AWS region behaviour

### Phase 2 — development Workspace

- [ ] Test MEGA S4 against a non-production Workspace
- [ ] Small-object CRUD test
- [ ] Large-object test
- [ ] SHA-256 integrity verification
- [ ] Container/service restart persistence
- [ ] Log/credential leakage check
- [ ] Rollback verification

### Phase 3 — wider provider testing

- [ ] AWS compatibility regression test
- [ ] MinIO test
- [ ] Google Cloud native handler test
- [ ] At least one additional hosted S3-compatible provider
- [ ] Backup bridge proof of concept

### Phase 4 — upstream

- [ ] Publish tested patch/release
- [ ] Document changed upstream source files
- [ ] Prepare minimal upstream proposal to generalise "Amazon S3" into "S3-Compatible Object Storage"
- [ ] Notify / submit to ONLYOFFICE upstream

## Contributing

Provider additions should prefer profile data over special-case implementation code. See [`CONTRIBUTING.md`](CONTRIBUTING.md).

## Licence

Apache License 2.0. See [`LICENSE`](LICENSE).

## Trademark / affiliation

This is an independent community project. It is not an official ONLYOFFICE product and is not endorsed by Ascensio System SIA unless and until an upstream contribution is accepted. ONLYOFFICE names and trademarks remain the property of their respective owners.
