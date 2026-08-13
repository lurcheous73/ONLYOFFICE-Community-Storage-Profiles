# Architecture

## v0.3 design boundary

ONLYOFFICE Community Storage Profiles no longer repurposes or renames the stock `S3` consumer.

The project adds a separate consumer:

```text
Name:        S3Compatible
Type:        ASC.Core.Common.Configuration.DataStoreConsumer
HandlerType: ASC.Data.Storage.S3.S3Storage, ASC.Data.Storage
```

The stock consumer remains:

```text
Name:        S3
HandlerType: ASC.Data.Storage.S3.S3Storage, ASC.Data.Storage
Role:        legacy / backward-compatible Amazon S3 configuration
```

This means both consumers reuse the same storage engine but have different configuration identities and credential namespaces.

## Why this works without a storage DLL fork

CommunityServer's consumer loader builds registrations from the `consumers` configuration section. A component name is not restricted to a built-in list.

`ConsumerFactory.GetAll<DataStoreConsumer>()` supplies the available data-store consumers to the storage API. When a storage module is active, `StorageSettings` resolves that module name back through `ConsumerFactory.GetByName<DataStoreConsumer>()`, clones the selected consumer, and instantiates its `HandlerType`.

Therefore a new `S3Compatible` consumer can safely reuse the existing `S3Storage` handler.

## Credential isolation

`DataStoreConsumer` prefixes managed setting keys with the consumer name.

Conceptually:

```text
stock S3 access key:        AuthKey_S3acesskey
new generic access key:     AuthKey_S3Compatibleacesskey
```

The exact ONLYOFFICE property spelling `acesskey` is retained for compatibility with the existing handler.

This is important: the generic service can be configured and tested without overwriting an existing stock Amazon S3 credential set.

## New consumer properties

The v0.3 consumer uses:

```text
acesskey
secretaccesskey
handlerType
bucket
region
serviceurl
forcepathstyle
usehttp
cname
cnamessl
sse
ssekey
```

`acesskey` and `secretaccesskey` are managed credential properties and are configured through Third-Party Services.

The remaining properties are storage properties and are configured through Storage / Backup / Restore.

## Why `cname` and `cnamessl` are included

ONLYOFFICE 12.8's S3 handler correctly passes a custom `serviceurl` to `AmazonS3Config.ServiceURL` and applies `ForcePathStyle`.

However, the handler's object URI roots are constructed separately. Without `cname` / `cnamessl`, it falls back to Amazon-shaped roots:

```text
http://s3.<region>.amazonaws.com/<bucket>/
https://s3.<region>.amazonaws.com/<bucket>/
```

That can be wrong for a non-Amazon S3-compatible provider even when API operations successfully use a custom endpoint.

The generic consumer therefore exposes optional object-base-URL values so provider profiles can supply correct URI roots without modifying `ASC.Data.Storage.dll`.

## Runtime surfaces

### CommunityServer

The v0.3 installer registers `S3Compatible` in each active WebStudio consumer configuration and in TeamLabSvc's consumer configuration.

WebStudio is required for:

- Third-Party Services
- Settings API storage enumeration
- portal-side storage resolution

TeamLabSvc is required because storage migration, backup and related background services load the same consumer model from their own `web.consumers.config`.

The installer also adds a dedicated `s3compatible.svg` and a small presentation-only AuthorizationKeys JS decoration. It does not replace the stock `s3.svg`.

If the stock `S3` credential service is unused, the v0.3 presentation hides that legacy tile. If it is configured, it remains visible so an existing installation cannot be stranded.

### Control Panel

Control Panel v3.5.5 has a dedicated S3 settings template. Stock templates select it only when:

```text
id == "S3"
```

v0.3 extends that condition to:

```text
id == "S3" || id == "S3Compatible"
```

for:

- Storage
- Backup
- Restore

This reuses the existing controls for region, path-style addressing, HTTP selection and encryption.

The primary Storage page also receives the Community Storage Profiles provider selector. The selector has no `data-id`, so it is not serialized as an ONLYOFFICE storage property.

## Provider model

Profiles are non-secret metadata layered over `S3Compatible`.

```text
S3Compatible
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

A profile may eventually supply verified defaults for:

- `serviceurl`
- `region`
- `forcepathstyle`
- `usehttp`
- `cname`
- `cnamessl`
- provider-relevant encryption visibility

Profiles never contain credentials.

Provider defaults are not considered safe merely because a vendor claims S3 compatibility. Each profile must be tested against the AWS SDK version shipped in the supported ONLYOFFICE build.

## Primary storage vs backup

Primary storage changes are migration-sensitive. ONLYOFFICE's storage update path starts the storage migration service when the selected module changes.

Therefore installation of Community Storage Profiles must never:

- select `S3Compatible` automatically;
- submit the Storage form;
- call the storage update API;
- start migration as part of installation.

Backup integrations are a separate layer. Planned non-primary targets include local staging, NAS, Duplicati, rclone, Google Drive, OneDrive, WebDAV, SFTP and Azure Blob.

## Legacy `S3` policy

The stock `S3` consumer is retained in configuration.

UI policy:

```text
stock S3 unused        -> may be hidden from normal selection
stock S3 configured    -> keep visible as Legacy Amazon S3
S3Compatible           -> preferred generic service
```

This preserves compatibility without making Amazon the top-level concept for new Community Storage Profiles deployments.

## Rollback model

v0.3 backs up every file it modifies and records a manifest containing:

- target container;
- target path;
- original ownership/group/mode;
- whether rollback restores the original or removes a newly created file.

The new `s3compatible.svg` is removed on rollback; modified configuration, JS and Pug files are restored byte-for-byte from the backup directory.

## Acceptance requirements

Before a provider can be marked production-ready:

1. credentials save under the `S3Compatible` namespace;
2. storage form values round-trip correctly;
3. small object write/read/delete succeeds;
4. SHA-256 integrity matches after read-back;
5. overwrite succeeds;
6. multipart / large-object handling succeeds;
7. generated object URLs use the intended provider, not Amazon fallback roots;
8. container restart retains access;
9. local-to-object migration succeeds on test data;
10. backup and restore succeed;
11. rollback/recovery is tested;
12. secrets do not appear in logs, Git or status output.
