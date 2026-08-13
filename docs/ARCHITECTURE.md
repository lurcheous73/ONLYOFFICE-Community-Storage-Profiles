# Architecture

## User-facing model

The stock **Amazon AWS S3** entry is replaced in the UI by:

**S3-Compatible Object Storage**

The underlying ONLYOFFICE storage engine remains unchanged:

- Consumer ID: `S3`
- Handler: `ASC.Data.Storage.S3.S3Storage`

Amazon S3 becomes one selectable provider preset inside the generic S3-compatible storage family.

```text
S3-Compatible Object Storage
  Provider
    Amazon S3
    MEGA S4
    Wasabi
    Backblaze B2 S3
    Cloudflare R2
    MinIO
    Ceph RGW
    OVHcloud Object Storage
    Custom
```

This is a deliberate compatibility boundary: **rename and generalise the UI, do not rename the internal ONLYOFFICE S3 consumer.**

## Why the internal `S3` ID stays

ONLYOFFICE 12.8 already uses the S3 consumer ID in storage configuration, persisted settings and API responses. Renaming that internal ID would create unnecessary migration and compatibility risk.

The project therefore treats `S3` as an engine identifier, not a vendor identifier.

## Two upstream UI surfaces

ONLYOFFICE Workspace 12.8 exposes storage through two related projects/surfaces:

1. **CommunityServer** contains the storage engine, consumer definitions, Settings API and portal-side storage templates.
2. **ControlPanel** contains the administrator Storage screen shown by the Workspace Control Panel.

The ControlPanel Storage page fetches all storage consumers through its backend API, injects the local-storage option, renders each provider as a radio/storage form, and uses a dedicated S3 template for region, path-style, HTTP and encryption controls.

That means the project should modify the **ControlPanel Storage presentation/profile layer** for the primary administrator experience while preserving CommunityServer's `S3` engine and storage API contract.

## Profile model

Profiles are metadata layered on top of an engine.

```text
profile                engine
---------------------  -------------------
Amazon S3              native-s3
MEGA S4                native-s3
Wasabi                 native-s3
Backblaze B2 S3        native-s3
Cloudflare R2          native-s3
MinIO                  native-s3
Ceph RGW               native-s3
OVHcloud               native-s3
Custom S3              native-s3
Google Cloud Storage   native-google-cloud
```

A profile may supply non-secret defaults such as:

- endpoint / service URL
- region or signing-region hint
- path-style addressing
- HTTP/HTTPS behaviour
- visibility of provider-relevant fields

Profiles never contain access keys, secret keys, service-account JSON or other credentials.

## Primary storage vs backup

Primary storage is migration-sensitive. Selecting a different active storage module in ONLYOFFICE invokes its storage migration path, so the project must never treat a provider change as a harmless preference save.

Backup bridges remain separate:

```text
ONLYOFFICE backup -> local staging -> Duplicati / rclone -> remote destination
```

This allows Google Drive, OneDrive, Dropbox, WebDAV, SFTP, Azure Blob and other targets to be useful without presenting them as equivalent to a native live object store.

## v0.1 finding

The v0.1 developer-preview experiment removed `hidden="true"` from selected S3 consumer properties. This proved that the properties were real and configurable, but also proved that the consumer loader then categorised them as normal managed credentials, causing them to appear in **Third-Party Services** rather than only in the Storage form.

That experiment is therefore considered a discovery proof, not the final architecture.

The correct implementation keeps storage-only S3 properties in the storage configuration path and adds the provider-profile UI in the Storage presentation layer.

## v0.2 target

The next implementation target is:

```text
Storage
  Local storage
  S3-Compatible Object Storage
  Google Cloud Storage
  Rackspace Cloud Storage
  Selectel Cloud Storage
```

When **S3-Compatible Object Storage** is selected:

```text
Provider:      [MEGA S4 ▼]
Endpoint:      [...]
Region:        [...]
Bucket:        [...]
Access key:    [...]
Secret key:    [••••••]
Path style:    [ ]
Use HTTP:      [ ]
Encryption:    [...]
```

The provider selector changes defaults/field visibility only. The actual storage module sent back to ONLYOFFICE remains `S3`.

## Safety requirements

- Never auto-select a new primary storage provider during installation.
- Never auto-submit the Storage form.
- Never include credentials in profile JSON, logs or Git commits.
- Backup every modified installed file and preserve owner/group/mode.
- Fail closed on unrecognised ONLYOFFICE / ControlPanel versions or file hashes.
- Provide `status`, `test`, `rollback` and upgrade-detection commands.
- Test migration and restore behaviour before production use.
