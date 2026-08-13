#!/usr/bin/env bash
set -euo pipefail

# Non-migrating acceptance test for v0.3.2 S3Compatible handler.
# Uses the root-only disposable MEGA S4 test configuration by default.
# Does not call settings/storage, updateStorage, or any migration API.

C="${OCSP_COMMUNITY_CONTAINER:-onlyoffice-community-server}"
CREDS="${OCSP_S3_TEST_ENV:-/root/.mega-s4-test.env}"
WORK="/tmp/ocsp-v032-acceptance"
REFDIR="/var/www/onlyoffice/WebStudio/bin"
CUSTOM_DLL="$REFDIR/ASC.Data.Storage.S3Compatible.dll"

[ -r "$CREDS" ] || { echo "ERROR: test configuration not readable: $CREDS"; exit 1; }
# shellcheck disable=SC1090
source "$CREDS"

ENDPOINT="${ENDPOINT:-https://s3.g.megas4.com}"
REGION="${REGION:-g}"
BUCKET="${BUCKET:-}"

for v in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY ENDPOINT REGION BUCKET; do
  [ -n "${!v:-}" ] || { echo "ERROR: $v missing from $CREDS"; exit 1; }
done

CNAME="${CNAME:-${ENDPOINT%/}/${BUCKET}/}"
CNAMESSL="${CNAMESSL:-${ENDPOINT%/}/${BUCKET}/}"
if [[ "$CNAME" == https:* ]]; then CNAME="http:${CNAME#https:}"; fi
if [[ "$CNAMESSL" == http:* ]]; then CNAMESSL="https:${CNAMESSL#http:}"; fi

docker exec "$C" test -f "$CUSTOM_DLL" || {
  echo "ERROR: v0.3.2 custom handler not deployed: $CUSTOM_DLL"
  exit 1
}

cat >/tmp/ocsp-v032-acceptance.cs <<'CS'
using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;

using Amazon.S3;
using Amazon.S3.Model;
using ASC.Data.Storage.S3Compatible;

class Program
{
    static string Hash(byte[] data)
    {
        using (var sha = SHA256.Create())
        {
            byte[] h = sha.ComputeHash(data);
            var sb = new StringBuilder();
            foreach (byte b in h) sb.Append(b.ToString("x2"));
            return sb.ToString();
        }
    }

    static string Hash(Stream stream)
    {
        using (var sha = SHA256.Create())
        {
            byte[] h = sha.ComputeHash(stream);
            var sb = new StringBuilder();
            foreach (byte b in h) sb.Append(b.ToString("x2"));
            return sb.ToString();
        }
    }

    static byte[] Payload(int size, int seed)
    {
        var b = new byte[size];
        new Random(seed).NextBytes(b);
        return b;
    }

    static FieldInfo Field(Type t, string name)
    {
        var f = t.GetField(name, BindingFlags.Instance | BindingFlags.NonPublic);
        if (f == null) throw new MissingFieldException(t.FullName, name);
        return f;
    }

    static MethodInfo Method(Type t, string name)
    {
        var m = t.GetMethod(name, BindingFlags.Instance | BindingFlags.NonPublic);
        if (m == null) throw new MissingMethodException(t.FullName, name);
        return m;
    }

    static string MakePath(S3CompatibleStorage store, string domain, string path)
    {
        return Convert.ToString(Method(typeof(S3CompatibleStorage), "MakePath").Invoke(store, new object[] { domain, path }));
    }

    static void SetLayout(S3CompatibleStorage store, string tenant, string module)
    {
        var t = typeof(S3CompatibleStorage);
        Field(t, "_tenant").SetValue(store, tenant);
        Field(t, "_modulename").SetValue(store, module);
        Method(t, "SyncBaseState").Invoke(store, null);
    }

    static void ConfirmGone(IAmazonS3 client, string bucket, string key)
    {
        try
        {
            client.GetObjectMetadata(new GetObjectMetadataRequest { BucketName = bucket, Key = key });
            throw new Exception("object still exists after delete: " + key);
        }
        catch (AmazonS3Exception ex)
        {
            if ((int)ex.StatusCode != 404 && ex.ErrorCode != "NoSuchKey") throw;
        }
    }

    public static int Main()
    {
        string endpoint = Console.ReadLine();
        string region   = Console.ReadLine();
        string bucket   = Console.ReadLine();
        string cname    = Console.ReadLine();
        string cnamessl = Console.ReadLine();
        string access   = Console.ReadLine();
        string secret   = Console.ReadLine();

        var cfg = new AmazonS3Config {
            ServiceURL = endpoint,
            ForcePathStyle = true,
            UseHttp = false,
            AuthenticationRegion = region,
            MaxErrorRetry = 1
        };

        string stamp = DateTime.UtcNow.ToString("yyyyMMddTHHmmssZ") + "-" + Guid.NewGuid().ToString("N").Substring(0, 10);
        string smallPath = "ocsp-v032/small-" + stamp + ".bin";
        string privatePath = "ocsp-v032/private-" + stamp + ".bin";
        string multiPath = "ocsp-v032/multipart-" + stamp + ".bin";
        string uploadId = null;
        string smallKey = null, privateKey = null, multiKey = null;

        try
        {
            Console.WriteLine("============================================================");
            Console.WriteLine(" S3Compatible v0.3.2 — NON-MIGRATING ACCEPTANCE TEST");
            Console.WriteLine("============================================================");
            Console.WriteLine("Endpoint : " + endpoint);
            Console.WriteLine("Region   : " + region);
            Console.WriteLine("Bucket   : " + bucket);
            Console.WriteLine("Handler  : " + typeof(S3CompatibleStorage).AssemblyQualifiedName);

            var store = new S3CompatibleStorage("");
            var props = new Dictionary<string,string> {
                {"acesskey", access},
                {"secretaccesskey", secret},
                {"bucket", bucket},
                {"region", region},
                {"serviceurl", endpoint},
                {"forcepathstyle", "true"},
                {"usehttp", "false"},
                {"cname", cname},
                {"cnamessl", cnamessl},
                {"sse", "none"},
                {"ssekey", ""},
                {"disabledefaultchecksumvalidation", "true"}
            };

            Console.WriteLine();
            Console.WriteLine("[1/8] Configure custom ONLYOFFICE handler...");
            store.Configure(props);
            Console.WriteLine("PASS");

            Console.WriteLine();
            Console.WriteLine("[2/8] Migration-shaped empty-domain key normalization...");
            SetLayout(store, "1", "files");
            string migrationKey = MakePath(store, "", "ocsp-v032/migration-shape.bin");
            Console.WriteLine("Key: " + migrationKey);
            if (migrationKey.Contains("//")) throw new Exception("consecutive slash survived MakePath");
            if (migrationKey != "1/files/ocsp-v032/migration-shape.bin")
                throw new Exception("unexpected normalized migration key: " + migrationKey);
            Console.WriteLine("PASS");

            // Empty tenant makes BaseStorage.GetUri use GetInternalUri in this standalone harness.
            SetLayout(store, "", "");
            smallKey = MakePath(store, "", smallPath);
            privateKey = MakePath(store, "", privatePath);
            multiKey = MakePath(store, "", multiPath);
            if (smallKey.Contains("//") || privateKey.Contains("//") || multiKey.Contains("//"))
                throw new Exception("standalone test key contains consecutive slash");

            Console.WriteLine();
            Console.WriteLine("[3/8] Small Save() via TransferUtility + checksum compatibility...");
            byte[] small = Payload(256 * 1024, 3201);
            using (var ms = new MemoryStream(small)) store.Save("", smallPath, ms);
            Console.WriteLine("PASS");

            Console.WriteLine();
            Console.WriteLine("[4/8] Small GET + SHA256 + DELETE...");
            using (var s = store.GetReadStream("", smallPath)) {
                string remote = Hash(s), local = Hash(small);
                if (remote != local) throw new Exception("small SHA256 mismatch");
                Console.WriteLine("SHA256: " + remote);
            }
            store.Delete("", smallPath);
            using (var client = new AmazonS3Client(access, secret, cfg)) ConfirmGone(client, bucket, smallKey);
            Console.WriteLine("PASS");

            Console.WriteLine();
            Console.WriteLine("[5/8] SavePrivate() TransferUtility path + GET + DELETE...");
            byte[] priv = Payload(128 * 1024, 3202);
            using (var ms = new MemoryStream(priv)) store.SavePrivate("", privatePath, ms, DateTime.UtcNow.AddMinutes(15));
            using (var s = store.GetReadStream("", privatePath)) {
                if (Hash(s) != Hash(priv)) throw new Exception("private SHA256 mismatch");
            }
            store.Delete("", privatePath);
            using (var client = new AmazonS3Client(access, secret, cfg)) ConfirmGone(client, bucket, privateKey);
            Console.WriteLine("PASS");

            Console.WriteLine();
            Console.WriteLine("[6/8] Multipart initiate + 5MiB/5MiB/1MiB UploadChunk...");
            byte[] p1 = Payload(5 * 1024 * 1024, 3211);
            byte[] p2 = Payload(5 * 1024 * 1024, 3212);
            byte[] p3 = Payload(1 * 1024 * 1024, 3213);
            byte[] all = new byte[p1.Length + p2.Length + p3.Length];
            Buffer.BlockCopy(p1, 0, all, 0, p1.Length);
            Buffer.BlockCopy(p2, 0, all, p1.Length, p2.Length);
            Buffer.BlockCopy(p3, 0, all, p1.Length + p2.Length, p3.Length);

            uploadId = store.InitiateChunkedUpload("", multiPath);
            var etags = new Dictionary<int,string>();
            using (var ms = new MemoryStream(p1)) etags[1] = store.UploadChunk("", multiPath, uploadId, ms, p1.Length, 1, p1.Length);
            using (var ms = new MemoryStream(p2)) etags[2] = store.UploadChunk("", multiPath, uploadId, ms, p2.Length, 2, p2.Length);
            using (var ms = new MemoryStream(p3)) etags[3] = store.UploadChunk("", multiPath, uploadId, ms, p3.Length, 3, p3.Length);
            Console.WriteLine("PASS");

            Console.WriteLine();
            Console.WriteLine("[7/8] Multipart complete + GET/SHA256...");
            store.FinalizeChunkedUpload("", multiPath, uploadId, etags);
            uploadId = null;
            using (var s = store.GetReadStream("", multiPath)) {
                string remote = Hash(s), local = Hash(all);
                if (remote != local) throw new Exception("multipart SHA256 mismatch");
                Console.WriteLine("SHA256: " + remote);
            }
            Console.WriteLine("PASS");

            Console.WriteLine();
            Console.WriteLine("[8/8] Multipart DELETE + gone check...");
            store.Delete("", multiPath);
            using (var client = new AmazonS3Client(access, secret, cfg)) ConfirmGone(client, bucket, multiKey);
            Console.WriteLine("PASS");

            Console.WriteLine();
            Console.WriteLine("============================================================");
            Console.WriteLine(" PASS — v0.3.2 S3Compatible ACCEPTANCE COMPLETE");
            Console.WriteLine("============================================================");
            Console.WriteLine("Key normalization       : PASS");
            Console.WriteLine("Small TransferUtility   : PASS");
            Console.WriteLine("Private TransferUtility : PASS");
            Console.WriteLine("Multipart UploadPart    : PASS");
            Console.WriteLine("Read/SHA256/Delete      : PASS");
            Console.WriteLine("Migration/API calls     : NONE");
            return 0;
        }
        catch (Exception ex)
        {
            if (ex is TargetInvocationException && ex.InnerException != null) ex = ex.InnerException;
            Console.WriteLine();
            Console.WriteLine("RESULT: FAIL");
            Console.WriteLine("Type    : " + ex.GetType().FullName);
            Console.WriteLine("Message : " + ex.Message);
            var s3 = ex as AmazonS3Exception;
            if (s3 != null) {
                Console.WriteLine("ErrorCode: " + s3.ErrorCode);
                Console.WriteLine("Status   : " + s3.StatusCode);
            }
            return 10;
        }
        finally
        {
            try {
                using (var cleanup = new AmazonS3Client(access, secret, cfg)) {
                    if (!String.IsNullOrEmpty(uploadId)) {
                        try { cleanup.AbortMultipartUpload(new AbortMultipartUploadRequest { BucketName=bucket, Key=multiKey, UploadId=uploadId }); } catch { }
                    }
                    foreach (string key in new [] { smallKey, privateKey, multiKey }) {
                        if (!String.IsNullOrEmpty(key)) {
                            try { cleanup.DeleteObject(new DeleteObjectRequest { BucketName=bucket, Key=key }); } catch { }
                        }
                    }
                }
            } catch { }
        }
    }
}
CS

docker exec "$C" rm -rf "$WORK"
docker exec "$C" mkdir -p "$WORK"
docker cp /tmp/ocsp-v032-acceptance.cs "$C:$WORK/test.cs" >/dev/null
rm -f /tmp/ocsp-v032-acceptance.cs

echo "=== COMPILE ACCEPTANCE HARNESS ==="
docker exec "$C" bash -lc "
set -e
cd '$WORK'
mcs -out:test.exe \\
  -lib:'$REFDIR' \\
  -r:ASC.Data.Storage.S3Compatible.dll \\
  -r:ASC.Data.Storage.dll \\
  -r:ASC.Common.dll \\
  -r:ASC.Core.Common.dll \\
  -r:AWSSDK.Core.dll \\
  -r:AWSSDK.S3.dll \\
  -r:System.Core.dll \\
  test.cs
"
echo "PASS: compiled"

echo
echo "=== RUN ACCEPTANCE HARNESS ==="
set +e
printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
  "$ENDPOINT" "$REGION" "$BUCKET" "$CNAME" "$CNAMESSL" \
  "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY" |
docker exec -i "$C" bash -lc "
cd '$WORK'
MONO_PATH='$REFDIR' mono test.exe
"
RC=$?
set -e

docker exec "$C" rm -rf "$WORK" || true
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
exit "$RC"
