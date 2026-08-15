#!/usr/bin/env python3
"""Build helpers for OCSP v0.3.4 manual backup hardening.

This deliberately starts from the exact upstream ONLYOFFICE 12.8 S3Storage.cs
source, reproduces the v0.3.2 S3Compatible isolation/compatibility changes, and
adds only the v0.3.4 backup writer selection and dedicated backup part size.
"""

from pathlib import Path
import re
import sys

CUSTOM_HANDLER = "ASC.Data.Storage.S3Compatible.S3CompatibleStorage, ASC.Data.Storage.S3Compatible"
COMPAT_PROP = "disabledefaultchecksumvalidation"
BACKUP_CHUNK_PROP = "backupchunksize"
DEFAULT_BACKUP_CHUNK = "201326592"  # 192 MiB


def patch_storage(src_path: Path, dst_path: Path) -> None:
    text = src_path.read_text(encoding="utf-8")

    checks = {
        "namespace ASC.Data.Storage.S3": 1,
        "public class S3Storage : BaseStorage": 1,
        "public S3Storage(": 2,
        'result = result.Replace("//", "/").TrimStart(\'/\').TrimEnd(\'/\');': 1,
        "var request = new TransferUtilityUploadRequest": 2,
        "uploader.Upload(request);": 2,
        "var request = new UploadPartRequest": 2,
        "s3.UploadPart(request);": 1,
        "s3.UploadPartAsync(request)": 1,
        "return new S3ZipWriteOperator(chunkedUploadSession, sessionHolder);": 1,
    }
    for needle, want in checks.items():
        got = text.count(needle)
        if got != want:
            raise SystemExit(f"baseline mismatch for {needle!r}: expected {want}, got {got}")

    text = text.replace("using System.Linq;\n", "using System.Linq;\nusing System.Reflection;\n", 1)
    text = text.replace(
        "using ASC.Data.Storage.Configuration;\n",
        "using ASC.Data.Storage.Configuration;\nusing ASC.Data.Storage.S3;\n",
        1,
    )
    text = text.replace("namespace ASC.Data.Storage.S3\n", "namespace ASC.Data.Storage.S3Compatible\n", 1)
    text = text.replace("public class S3Storage : BaseStorage", "public class S3CompatibleStorage : BaseStorage", 1)
    text = text.replace("public S3Storage(", "public S3CompatibleStorage(", 2)

    class_anchor = "    public class S3CompatibleStorage : BaseStorage\n    {\n"
    if class_anchor not in text:
        raise SystemExit("custom class anchor missing")

    shadow = r'''    public class S3CompatibleStorage : BaseStorage
    {
        // OCSP v0.3.2+: BaseStorage state is internal in the stock assembly.
        // Keep a local mirror and sync the stock base fields after Configure().
        private string _tenant;
        private string _modulename;
        private bool _cache;
        private bool _attachment;
        private DataList _dataList;
        private Dictionary<string, TimeSpan> _domainsExpires = new Dictionary<string, TimeSpan>();
        private Dictionary<string, IDataStoreValidator> _domainsValidators = new Dictionary<string, IDataStoreValidator>();
        private bool _disableDefaultChecksumValidation;

        // OCSP v0.3.4: backup-only multipart size. The ordinary Workspace file
        // upload chunk setting is intentionally not changed.
        private long _backupChunkSize = 201326592L;

'''
    text = text.replace(class_anchor, shadow, 1)

    ctor_anchor = "        public S3CompatibleStorage(string tenant)\n"
    if ctor_anchor not in text:
        raise SystemExit("constructor anchor missing")

    helpers = r'''        private void SetBaseField(string name, object value)
        {
            var field = typeof(BaseStorage).GetField(name, BindingFlags.Instance | BindingFlags.NonPublic);
            if (field == null)
            {
                throw new MissingFieldException(typeof(BaseStorage).FullName, name);
            }
            field.SetValue(this, value);
        }

        private void SyncBaseState()
        {
            SetBaseField("_tenant", _tenant);
            SetBaseField("_modulename", _modulename);
            SetBaseField("_cache", _cache);
            SetBaseField("_attachment", _attachment);
            SetBaseField("_dataList", _dataList);
            SetBaseField("_domainsExpires", _domainsExpires);
            SetBaseField("_domainsValidators", _domainsValidators);
        }

        private string QuotaData(string domain)
        {
            return _dataList == null ? string.Empty : _dataList.GetData(domain);
        }

        private void QuotaUsedAdd(string domain, long size, bool quotaCheckFileSize = true)
        {
            QuotaUsedAdd(domain, size, Guid.Empty, quotaCheckFileSize);
        }

        private void QuotaUsedAdd(string domain, long size, Guid ownerId, bool quotaCheckFileSize = true)
        {
            if (QuotaController != null)
            {
                QuotaController.QuotaUsedAdd(_modulename, domain, QuotaData(domain), size, ownerId, quotaCheckFileSize);
            }
        }

        private void QuotaUsedDelete(string domain, long size)
        {
            QuotaUsedDelete(domain, size, Guid.Empty);
        }

        private void QuotaUsedDelete(string domain, long size, Guid ownerId)
        {
            if (QuotaController != null)
            {
                QuotaController.QuotaUsedDelete(_modulename, domain, QuotaData(domain), size, ownerId);
            }
        }

'''
    text = text.replace(ctor_anchor, helpers + ctor_anchor, 1)

    configure_anchor = '''            if (props.ContainsKey("subdir"))
            {
                _subDir = props["subdir"];
            }

            return this;
'''
    if text.count(configure_anchor) != 1:
        raise SystemExit("Configure tail anchor mismatch")

    configure_new = '''            if (props.ContainsKey("subdir"))
            {
                _subDir = props["subdir"];
            }

            if (props.ContainsKey("disabledefaultchecksumvalidation"))
            {
                bool.TryParse(props["disabledefaultchecksumvalidation"], out _disableDefaultChecksumValidation);
            }

            if (props.ContainsKey("backupchunksize") && !string.IsNullOrEmpty(props["backupchunksize"]))
            {
                long configuredBackupChunkSize;
                if (!long.TryParse(props["backupchunksize"], out configuredBackupChunkSize)
                    || configuredBackupChunkSize < 5L * 1024L * 1024L
                    || configuredBackupChunkSize > 5L * 1024L * 1024L * 1024L)
                {
                    throw new ConfigurationErrorsException("backupchunksize must be between 5 MiB and 5 GiB");
                }
                _backupChunkSize = configuredBackupChunkSize;
            }

            SyncBaseState();
            return this;
'''
    text = text.replace(configure_anchor, configure_new, 1)

    old_path = 'result = result.Replace("//", "/").TrimStart(\'/\').TrimEnd(\'/\');'
    new_path = '''while (result.Contains("//"))
            {
                result = result.Replace("//", "/");
            }
            result = result.TrimStart('/').TrimEnd('/');'''
    text = text.replace(old_path, new_path, 1)

    text = text.replace(
        "                uploader.Upload(request);",
        "                request.DisableDefaultChecksumValidation = _disableDefaultChecksumValidation;\n                uploader.Upload(request);",
        2,
    )
    text = text.replace(
        "                    var response = s3.UploadPart(request);",
        "                    request.DisableDefaultChecksumValidation = _disableDefaultChecksumValidation;\n                    var response = s3.UploadPart(request);",
        1,
    )
    text = text.replace(
        "                    var response = await s3.UploadPartAsync(request);",
        "                    request.DisableDefaultChecksumValidation = _disableDefaultChecksumValidation;\n                    var response = await s3.UploadPartAsync(request);",
        1,
    )

    text = text.replace(
        "return new S3ZipWriteOperator(chunkedUploadSession, sessionHolder);",
        "return new S3CompatibleZipWriteOperator(chunkedUploadSession, sessionHolder, _backupChunkSize);",
        1,
    )

    for forbidden in (
        "namespace ASC.Data.Storage.S3\n",
        "public class S3Storage : BaseStorage",
        "public S3Storage(",
    ):
        if forbidden in text:
            raise SystemExit("rename incomplete: " + forbidden)

    required = {
        "DisableDefaultChecksumValidation = _disableDefaultChecksumValidation;": 4,
        'while (result.Contains("//"))': 1,
        "new S3CompatibleZipWriteOperator(chunkedUploadSession, sessionHolder, _backupChunkSize)": 1,
        "private long _backupChunkSize = 201326592L;": 1,
    }
    for needle, want in required.items():
        got = text.count(needle)
        if got != want:
            raise SystemExit(f"post-patch mismatch for {needle!r}: expected {want}, got {got}")

    dst_path.write_text(text, encoding="utf-8")


def patch_consumer(src_path: Path, dst_path: Path, part_size: str) -> None:
    text = src_path.read_text(encoding="utf-8")
    pat = re.compile(r'<component\b(?=[^>]*\bname="S3Compatible")[^>]*>.*?</component>', re.S)
    match = pat.search(text)
    if not match:
        raise SystemExit("S3Compatible component not found")

    block = match.group(0)
    if CUSTOM_HANDLER not in block:
        raise SystemExit("S3Compatible is not using the v0.3.2 custom handler")
    if f'key="{COMPAT_PROP}"' not in block:
        raise SystemExit("v0.3.2 checksum compatibility property missing")

    nl = "\r\n" if "\r\n" in block else "\n"
    existing = re.search(rf'^[ \t]*<item\s+key="{BACKUP_CHUNK_PROP}"[^>]*/>', block, re.M)
    if existing:
        replacement = re.sub(r'value="[^"]*"', f'value="{part_size}"', existing.group(0), count=1)
        block = block[: existing.start()] + replacement + block[existing.end() :]
    else:
        anchor = re.search(rf'(?P<indent>^[ \t]*)<item\s+key="{COMPAT_PROP}"[^>]*/>', block, re.M)
        if not anchor:
            raise SystemExit("checksum compatibility property anchor missing")
        indent = anchor.group("indent")
        item = (
            indent
            + f'<item key="{BACKUP_CHUNK_PROP}" value="{part_size}" hidden="true" optional="true" />'
        )
        block = block[: anchor.end()] + nl + item + block[anchor.end() :]

    new_text = text[: match.start()] + block + text[match.end() :]
    if new_text.count(f'key="{BACKUP_CHUNK_PROP}"') != 1:
        raise SystemExit("backup chunk property post-patch validation failed")
    dst_path.write_text(new_text, encoding="utf-8")


def main() -> None:
    if len(sys.argv) < 4:
        raise SystemExit(
            "usage: build-s3compatible.py storage IN OUT | "
            "consumer IN OUT [PART_SIZE_BYTES]"
        )

    mode = sys.argv[1]
    src = Path(sys.argv[2])
    dst = Path(sys.argv[3])

    if mode == "storage":
        patch_storage(src, dst)
    elif mode == "consumer":
        part_size = sys.argv[4] if len(sys.argv) > 4 else DEFAULT_BACKUP_CHUNK
        if not part_size.isdigit():
            raise SystemExit("part size must be integer bytes")
        patch_consumer(src, dst, part_size)
    else:
        raise SystemExit("unknown mode: " + mode)


if __name__ == "__main__":
    main()
