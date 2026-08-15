using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Threading.Tasks;

using ASC.Common;
using ASC.Core.ChunkedUploader;
using ASC.Data.Storage.ZipOperators;

using ICSharpCode.SharpZipLib.GZip;
using ICSharpCode.SharpZipLib.Tar;

namespace ASC.Data.Storage.S3Compatible
{
    // OCSP v0.3.4: backup-only S3-compatible writer.
    //
    // The stock S3ZipWriteOperator uses CommonChunkedUploadSessionHolder's
    // files.uploader.chunk-size (20 MiB in the 12.8 TeamLabSvc config).  S3 has
    // a hard 10,000-part multipart limit, which caps a streamed backup at about
    // 195 GiB with 20 MiB parts.  This writer keeps the normal ONLYOFFICE
    // TAR/GZIP and multipart format but uses a dedicated backup part size.
    internal sealed class S3CompatibleZipWriteOperator : IDataWriteOperator
    {
        private const int MaxS3Parts = 10000;
        private const int CopyBufferSize = 1024 * 1024;
        private const long MinS3PartSize = 5L * 1024L * 1024L;
        private const long MaxS3PartSize = 5L * 1024L * 1024L * 1024L;

        private readonly TarOutputStream _tarOutputStream;
        private readonly GZipOutputStream _gZipOutputStream;
        private readonly CommonChunkedUploadSession _chunkedUploadSession;
        private readonly CommonChunkedUploadSessionHolder _sessionHolder;
        private readonly StreamingSha256 _sha;
        private readonly long _partSize;
        private readonly int _tasksLimit;
        private readonly List<Task> _tasks;
        private readonly List<Stream> _streams;

        private Stream _fileStream;
        private byte[] _hash;
        private int _partsQueued;
        private bool _aborted;
        private bool _disposed;

        public string Hash { get; private set; }
        public string StoragePath { get; private set; }
        public bool NeedUpload { get { return false; } }

        public S3CompatibleZipWriteOperator(
            CommonChunkedUploadSession chunkedUploadSession,
            CommonChunkedUploadSessionHolder sessionHolder,
            long partSize)
        {
            if (partSize < MinS3PartSize || partSize > MaxS3PartSize)
            {
                throw new ArgumentOutOfRangeException(
                    "partSize",
                    partSize,
                    "S3 multipart part size must be between 5 MiB and 5 GiB.");
            }

            _chunkedUploadSession = chunkedUploadSession;
            _sessionHolder = sessionHolder;
            _partSize = partSize;

            // Manual v0.3.4 does not add scheduling policy, but keep the upload
            // side bounded and polite: at most half the logical CPUs, hard cap 8.
            var halfCpu = Math.Max(1, Environment.ProcessorCount / 2);
            _tasksLimit = Math.Max(1, Math.Min(8, halfCpu));
            _tasks = new List<Task>(_tasksLimit);
            _streams = new List<Stream>(_tasksLimit);

            _fileStream = TempStream.Create();
            _gZipOutputStream = new GZipOutputStream(_fileStream)
            {
                IsStreamOwner = false
            };
            _tarOutputStream = new TarOutputStream(_gZipOutputStream, Encoding.UTF8);
            _sha = new StreamingSha256();
        }

        public void WriteEntry(string key, Stream stream)
        {
            if (_disposed)
            {
                throw new ObjectDisposedException(GetType().FullName);
            }

            try
            {
                EnsureOutputStream();

                using (var buffered = stream.GetBuffered())
                {
                    var entry = TarEntry.CreateTarEntry(key);
                    entry.Size = buffered.Length;
                    _tarOutputStream.PutNextEntry(entry);
                    buffered.Position = 0;
                    buffered.CopyTo(_tarOutputStream);
                    _tarOutputStream.Flush();
                    _tarOutputStream.CloseEntry();
                }

                if (_fileStream.Length >= _partSize)
                {
                    var completed = _fileStream;
                    _fileStream = null;
                    SplitAndQueue(completed, false);
                    EnsureOutputStream();
                }
            }
            catch
            {
                FailAndAbort();
                throw;
            }
        }

        private void EnsureOutputStream()
        {
            if (_fileStream != null)
            {
                return;
            }

            _fileStream = TempStream.Create();
            _gZipOutputStream.baseOutputStream_ = _fileStream;
        }

        private static void CopyExactly(Stream source, Stream destination, long count)
        {
            var buffer = new byte[CopyBufferSize];
            var remaining = count;

            while (remaining > 0)
            {
                var want = (int)Math.Min(buffer.Length, remaining);
                var read = source.Read(buffer, 0, want);
                if (read <= 0)
                {
                    throw new EndOfStreamException("Unexpected end of backup part stream.");
                }

                destination.Write(buffer, 0, read);
                remaining -= read;
            }

            destination.Flush();
        }

        private void SplitAndQueue(Stream source, bool last)
        {
            if (source == null)
            {
                return;
            }

            try
            {
                source.Position = 0;

                while (source.Position < source.Length)
                {
                    var remaining = source.Length - source.Position;
                    var take = Math.Min(_partSize, remaining);

                    // A short tail is retained while the gzip stream is still
                    // open.  Only the final part may be shorter than 5 MiB.
                    if (!last && take < _partSize)
                    {
                        EnsureOutputStream();
                        CopyExactly(source, _fileStream, take);
                        break;
                    }

                    var part = TempStream.Create();
                    try
                    {
                        CopyExactly(source, part, take);
                        part.Position = 0;

                        var isFinalPart = last && source.Position == source.Length;
                        ComputeHash(part, isFinalPart);
                        part.Position = 0;
                        QueueUpload(part);
                        part = null; // ownership moved to _streams
                    }
                    finally
                    {
                        if (part != null)
                        {
                            part.Dispose();
                        }
                    }
                }
            }
            finally
            {
                source.Dispose();
            }
        }

        private void ComputeHash(Stream stream, bool isFinal)
        {
            stream.Position = 0;
            _hash = _sha.ComputeStreamingHash(stream, isFinal);
        }

        private void QueueUpload(Stream stream)
        {
            if (_partsQueued >= MaxS3Parts)
            {
                throw new InvalidOperationException(
                    "S3-compatible backup exceeded the 10,000 multipart-part limit. " +
                    "Increase the dedicated backup part size before retrying.");
            }

            ReapCompleted(true);

            _partsQueued++;
            _streams.Add(stream);
            _tasks.Add(_sessionHolder.UploadChunkAsync(
                _chunkedUploadSession,
                stream,
                stream.Length));
        }

        private void ReapCompleted(bool waitForSlot)
        {
            if (waitForSlot && _tasks.Count >= _tasksLimit)
            {
                Task.WaitAny(_tasks.ToArray());
            }

            for (var i = _tasks.Count - 1; i >= 0; i--)
            {
                if (!_tasks[i].IsCompleted)
                {
                    continue;
                }

                // Observe failures immediately rather than continuing to queue
                // many parts after a provider/network error.
                _tasks[i].Wait();
                _streams[i].Dispose();
                _tasks.RemoveAt(i);
                _streams.RemoveAt(i);
            }
        }

        private void WaitForUploads()
        {
            if (_tasks.Count == 0)
            {
                return;
            }

            Task.WaitAll(_tasks.ToArray());

            for (var i = 0; i < _streams.Count; i++)
            {
                _streams[i].Dispose();
            }
            _streams.Clear();
            _tasks.Clear();
        }

        private void DrainUploadsNoThrow()
        {
            try
            {
                if (_tasks.Count > 0)
                {
                    Task.WaitAll(_tasks.ToArray());
                }
            }
            catch
            {
                // The original backup failure is more useful than secondary
                // task errors while we are already unwinding.
            }

            for (var i = 0; i < _streams.Count; i++)
            {
                try { _streams[i].Dispose(); } catch { }
            }
            _streams.Clear();
            _tasks.Clear();
        }

        private void AbortNoThrow()
        {
            if (_aborted)
            {
                return;
            }

            _aborted = true;
            try
            {
                _sessionHolder.Abort(_chunkedUploadSession);
            }
            catch
            {
                // Preserve the primary backup error. The provider-side abort
                // failure will still be visible in its own service diagnostics.
            }
        }

        private void FailAndAbort()
        {
            DrainUploadsNoThrow();
            AbortNoThrow();
        }

        public void Dispose()
        {
            if (_disposed)
            {
                return;
            }
            _disposed = true;

            try
            {
                _tarOutputStream.Close();
                _tarOutputStream.Dispose();

                if (_fileStream != null)
                {
                    var tail = _fileStream;
                    _fileStream = null;
                    SplitAndQueue(tail, true);
                }

                WaitForUploads();
                StoragePath = _sessionHolder.Finalize(_chunkedUploadSession);

                if (_hash == null)
                {
                    throw new InvalidOperationException("Backup hash was not finalised.");
                }

                Hash = BitConverter.ToString(_hash).Replace("-", string.Empty);
            }
            catch
            {
                FailAndAbort();
                throw;
            }
            finally
            {
                if (_fileStream != null)
                {
                    try { _fileStream.Dispose(); } catch { }
                    _fileStream = null;
                }

                DrainUploadsNoThrow();
                _sha.Dispose();
            }
        }

        private sealed class StreamingSha256 : SHA256Managed
        {
            public byte[] ComputeStreamingHash(Stream inputStream, bool isFinal)
            {
                var buffer = new byte[4096];
                int read;
                do
                {
                    read = inputStream.Read(buffer, 0, buffer.Length);
                    if (read > 0)
                    {
                        HashCore(buffer, 0, read);
                    }
                }
                while (read > 0);

                if (!isFinal)
                {
                    return null;
                }

                HashValue = HashFinal();
                var result = (byte[])HashValue.Clone();
                Initialize();
                return result;
            }
        }
    }
}
