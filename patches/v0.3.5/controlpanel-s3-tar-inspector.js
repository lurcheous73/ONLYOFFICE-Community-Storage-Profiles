'use strict';

// OCSP v0.3.5.1 — streaming S3 tar.gz inspector / single-file recovery.
// The archive is streamed from S3 through gunzip and a small TAR parser. The
// whole backup is never written locally. A selected recovered file is written
// to /tmp only after an explicit recovery request, then offered as a one-time
// authenticated Control Panel download.

const crypto = require('crypto');
const fs = require('fs');
const http = require('http');
const https = require('https');
const path = require('path');
const readline = require('readline');
const zlib = require('zlib');
const URLCtor = require('url').URL;

const jobs = Object.create(null);
const extracts = Object.create(null);
const JOB_TTL_MS = 2 * 60 * 60 * 1000;
const PREVIEW_LIMIT = 60;
const SEARCH_LIMIT = 200;
const MAX_SPECIAL_BYTES = 1024 * 1024;
const MAX_RECOVERY_BYTES = Number(process.env.OCSP_TAR_SINGLE_FILE_MAX_BYTES || 64 * 1024 * 1024 * 1024);

function boolValue(value, fallback) {
    if (value === undefined || value === null || value === '') return fallback;
    if (typeof value === 'boolean') return value;
    return String(value).toLowerCase() === 'true';
}

function cleanConfig(input) {
    input = input || {};
    const cfg = {
        accessKey: String(input.acesskey || input.accesskey || '').trim(),
        secretKey: String(input.secretaccesskey || '').trim(),
        region: String(input.region || 'us-east-1').trim() || 'us-east-1',
        serviceUrl: String(input.serviceurl || '').trim(),
        forcePathStyle: boolValue(input.forcepathstyle, false),
        useHttp: boolValue(input.usehttp, false),
        bucket: String(input.bucket || '').trim()
    };
    if (!cfg.accessKey || !cfg.secretKey) throw new Error('Access key and secret key are required.');
    if (!cfg.serviceUrl) {
        const scheme = cfg.useHttp ? 'http' : 'https';
        cfg.serviceUrl = cfg.region === 'us-east-1' ? scheme + '://s3.amazonaws.com' : scheme + '://s3.' + cfg.region + '.amazonaws.com';
    } else if (!/^https?:\/\//i.test(cfg.serviceUrl)) {
        cfg.serviceUrl = (cfg.useHttp ? 'http://' : 'https://') + cfg.serviceUrl;
    }
    const parsed = new URLCtor(cfg.serviceUrl);
    if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') throw new Error('S3-compatible endpoint must use HTTP or HTTPS.');
    if (parsed.username || parsed.password || parsed.search || parsed.hash) throw new Error('S3-compatible endpoint must not contain credentials, query parameters or a fragment.');
    cfg.endpoint = parsed;
    return cfg;
}

function validateBucketName(bucket) {
    bucket = String(bucket || '').trim();
    if (!/^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$/.test(bucket) || bucket.indexOf('..') !== -1) throw new Error('Invalid S3 bucket name.');
    return bucket;
}

function validateBackupKey(key) {
    key = String(key || '').trim();
    if (!key || key.length > 4096 || /[\x00-\x1f\x7f]/.test(key) || !/\.tar\.gz$/i.test(key)) throw new Error('Select a valid .tar.gz backup object.');
    return key;
}

function sha256(value, encoding) { return crypto.createHash('sha256').update(value).digest(encoding || 'hex'); }
function hmac(key, value, encoding) { return crypto.createHmac('sha256', key).update(value).digest(encoding); }
function awsEncode(value) { return encodeURIComponent(String(value)).replace(/[!'()*]/g, function (ch) { return '%' + ch.charCodeAt(0).toString(16).toUpperCase(); }); }
function encodeKey(key) { return String(key || '').split('/').map(awsEncode).join('/'); }

function requestTarget(cfg, bucket, key) {
    const endpoint = cfg.endpoint;
    let hostname = endpoint.hostname;
    let host = hostname + (endpoint.port ? ':' + endpoint.port : '');
    let pathname = (endpoint.pathname || '/').replace(/\/+$/, '');
    if (!pathname) pathname = '';
    if (bucket) {
        if (cfg.forcePathStyle) pathname += '/' + awsEncode(bucket);
        else {
            hostname = bucket + '.' + hostname;
            host = hostname + (endpoint.port ? ':' + endpoint.port : '');
        }
    }
    if (key) pathname += '/' + encodeKey(key);
    if (!pathname) pathname = '/';
    if (pathname.charAt(0) !== '/') pathname = '/' + pathname;
    return { protocol: endpoint.protocol, hostname: hostname, port: endpoint.port || undefined, host: host, path: pathname };
}

function signedGetStream(config, bucket, key) {
    const cfg = cleanConfig(config);
    bucket = validateBucketName(bucket || cfg.bucket);
    key = validateBackupKey(key);
    const target = requestTarget(cfg, bucket, key);
    const now = new Date();
    const amzDate = now.toISOString().replace(/[:-]|\.\d{3}/g, '');
    const dateStamp = amzDate.substring(0, 8);
    const payloadHash = sha256(Buffer.alloc(0));
    const canonicalHeaders = 'host:' + target.host + '\n' + 'x-amz-content-sha256:' + payloadHash + '\n' + 'x-amz-date:' + amzDate + '\n';
    const signedHeaders = 'host;x-amz-content-sha256;x-amz-date';
    const canonicalRequest = ['GET', target.path, '', canonicalHeaders, signedHeaders, payloadHash].join('\n');
    const scope = dateStamp + '/' + cfg.region + '/s3/aws4_request';
    const stringToSign = ['AWS4-HMAC-SHA256', amzDate, scope, sha256(Buffer.from(canonicalRequest, 'utf8'))].join('\n');
    const kDate = hmac(Buffer.from('AWS4' + cfg.secretKey, 'utf8'), dateStamp);
    const kRegion = hmac(kDate, cfg.region);
    const kService = hmac(kRegion, 's3');
    const kSigning = hmac(kService, 'aws4_request');
    const signature = hmac(kSigning, stringToSign, 'hex');
    const headers = {
        Host: target.host,
        'x-amz-date': amzDate,
        'x-amz-content-sha256': payloadHash,
        Authorization: 'AWS4-HMAC-SHA256 Credential=' + cfg.accessKey + '/' + scope + ', SignedHeaders=' + signedHeaders + ', Signature=' + signature
    };
    const client = target.protocol === 'http:' ? http : https;

    return new Promise(function (resolve, reject) {
        const req = client.request({ protocol: target.protocol, hostname: target.hostname, port: target.port, method: 'GET', path: target.path, headers: headers, timeout: 30000 }, function (res) {
            if (res.statusCode !== 200) {
                const chunks = [];
                let bytes = 0;
                res.on('data', function (chunk) { if (bytes < 4096) { chunks.push(chunk); bytes += chunk.length; } });
                res.on('end', function () { reject(new Error('S3 GET failed with HTTP ' + res.statusCode + ': ' + Buffer.concat(chunks).toString('utf8', 0, 4096).replace(/\s+/g, ' ').trim())); });
                return;
            }
            resolve({ request: req, response: res, contentLength: Number(res.headers['content-length'] || 0) });
        });
        req.on('timeout', function () { req.destroy(new Error('S3-compatible archive request timed out.')); });
        req.on('error', reject);
        req.end();
    });
}

function textField(buf, start, length) {
    const end = start + length;
    let zero = buf.indexOf(0, start);
    if (zero < 0 || zero > end) zero = end;
    return buf.toString('utf8', start, zero).trim();
}

function octalField(buf, start, length) {
    const raw = textField(buf, start, length).replace(/^\s+|\s+$/g, '').replace(/\0/g, '');
    if (!raw) return 0;
    const value = parseInt(raw, 8);
    return isFinite(value) ? value : 0;
}

function allZero(buf) {
    for (let i = 0; i < buf.length; i++) if (buf[i] !== 0) return false;
    return true;
}

function parseHeader(header) {
    const name = textField(header, 0, 100);
    const prefix = textField(header, 345, 155);
    return {
        name: prefix ? prefix + '/' + name : name,
        size: octalField(header, 124, 12),
        mtime: octalField(header, 136, 12),
        type: String.fromCharCode(header[156] || 48),
        linkName: textField(header, 157, 100)
    };
}

function parsePax(buf) {
    const result = {};
    const text = buf.toString('utf8');
    let pos = 0;
    while (pos < text.length) {
        const space = text.indexOf(' ', pos);
        if (space < 0) break;
        const len = parseInt(text.substring(pos, space), 10);
        if (!len || pos + len > text.length) break;
        const record = text.substring(space + 1, pos + len - 1);
        const eq = record.indexOf('=');
        if (eq > 0) result[record.substring(0, eq)] = record.substring(eq + 1);
        pos += len;
    }
    return result;
}

function isRegular(type) { return type === '0' || type === '\0' || type === '7'; }

function makeManifestEntry(header, pendingLongName, pendingPax) {
    const pax = pendingPax || {};
    const name = pax.path || pendingLongName || header.name;
    let size = header.size;
    if (pax.size && /^\d+$/.test(pax.size)) size = Number(pax.size);
    return {
        name: name,
        size: size,
        type: header.type,
        regular: isRegular(header.type),
        mtime: pax.mtime ? Number(pax.mtime) : header.mtime
    };
}

function startArchiveScan(config, bucket, key) {
    const id = crypto.randomBytes(12).toString('hex');
    const manifestPath = '/tmp/ocsp-tar-manifest-' + id + '.jsonl';
    const job = jobs[id] = {
        id: id,
        state: 'starting',
        bucket: String(bucket || ''),
        key: String(key || ''),
        started: Date.now(),
        updated: Date.now(),
        compressedRead: 0,
        compressedTotal: 0,
        entries: 0,
        files: 0,
        dirs: 0,
        lastEntry: '',
        preview: [],
        manifestPath: manifestPath,
        error: ''
    };

    (async function () {
        let manifest;
        try {
            const remote = await signedGetStream(config, bucket, key);
            job.state = 'running';
            job.compressedTotal = remote.contentLength;
            manifest = fs.createWriteStream(manifestPath, { flags: 'wx', mode: 0o600 });
            remote.response.on('data', function (chunk) {
                job.compressedRead += chunk.length;
                job.updated = Date.now();
            });

            const gunzip = zlib.createGunzip();
            let buffer = Buffer.alloc(0);
            let state = 'header';
            let remaining = 0;
            let padding = 0;
            let specialType = '';
            let specialChunks = [];
            let specialBytes = 0;
            let pendingLongName = '';
            let pendingPax = {};
            let ended = false;

            function finishSpecial() {
                const data = Buffer.concat(specialChunks, specialBytes);
                if (specialType === 'L') pendingLongName = data.toString('utf8').replace(/\0.*$/, '').replace(/\n$/, '');
                else if (specialType === 'x') pendingPax = parsePax(data);
                specialType = '';
                specialChunks = [];
                specialBytes = 0;
            }

            function record(entry) {
                if (!entry.name) return;
                job.entries++;
                if (entry.regular) job.files++;
                if (entry.type === '5') job.dirs++;
                job.lastEntry = entry.name;
                job.updated = Date.now();
                job.preview.push(entry);
                if (job.preview.length > PREVIEW_LIMIT) job.preview.shift();
                manifest.write(JSON.stringify(entry) + '\n');
            }

            function processBuffer() {
                while (!ended) {
                    if (state === 'header') {
                        if (buffer.length < 512) return;
                        const headerBuf = buffer.subarray(0, 512);
                        buffer = buffer.subarray(512);
                        if (allZero(headerBuf)) { ended = true; return; }
                        const header = parseHeader(headerBuf);
                        remaining = header.size;
                        padding = (512 - (header.size % 512)) % 512;
                        if (header.type === 'L' || header.type === 'x') {
                            specialType = header.type;
                            specialChunks = [];
                            specialBytes = 0;
                            state = remaining ? 'special' : (padding ? 'padding-special' : 'header');
                            if (!remaining && !padding) finishSpecial();
                        } else {
                            const entry = makeManifestEntry(header, pendingLongName, pendingPax);
                            pendingLongName = '';
                            pendingPax = {};
                            record(entry);
                            state = remaining ? 'skip' : (padding ? 'padding' : 'header');
                        }
                    } else if (state === 'skip') {
                        if (!buffer.length) return;
                        const take = Math.min(remaining, buffer.length);
                        buffer = buffer.subarray(take);
                        remaining -= take;
                        if (!remaining) state = padding ? 'padding' : 'header';
                    } else if (state === 'special') {
                        if (!buffer.length) return;
                        const take = Math.min(remaining, buffer.length);
                        if (specialBytes + take <= MAX_SPECIAL_BYTES) {
                            specialChunks.push(Buffer.from(buffer.subarray(0, take)));
                            specialBytes += take;
                        } else throw new Error('TAR long-name/PAX record exceeds safety limit.');
                        buffer = buffer.subarray(take);
                        remaining -= take;
                        if (!remaining) {
                            finishSpecial();
                            state = padding ? 'padding-special' : 'header';
                        }
                    } else if (state === 'padding' || state === 'padding-special') {
                        if (buffer.length < padding) return;
                        buffer = buffer.subarray(padding);
                        padding = 0;
                        state = 'header';
                    }
                }
            }

            gunzip.on('data', function (chunk) {
                buffer = buffer.length ? Buffer.concat([buffer, chunk]) : chunk;
                processBuffer();
            });
            await new Promise(function (resolve, reject) {
                gunzip.on('end', resolve);
                gunzip.on('error', reject);
                remote.response.on('error', reject);
                remote.response.pipe(gunzip);
            });
            processBuffer();
            await new Promise(function (resolve) { manifest.end(resolve); });
            manifest = null;
            job.state = 'completed';
            job.updated = Date.now();
        } catch (e) {
            job.state = 'error';
            job.error = e && e.message ? e.message : String(e);
            job.updated = Date.now();
            if (manifest) try { manifest.end(); } catch (_) { }
        }
    })();

    return { id: id };
}

function publicScan(job) {
    return {
        id: job.id,
        state: job.state,
        bucket: job.bucket,
        key: job.key,
        compressedRead: job.compressedRead,
        compressedTotal: job.compressedTotal,
        progress: job.compressedTotal ? Math.min(100, Math.floor(job.compressedRead * 10000 / job.compressedTotal) / 100) : 0,
        entries: job.entries,
        files: job.files,
        dirs: job.dirs,
        lastEntry: job.lastEntry,
        preview: job.preview,
        error: job.error
    };
}

async function searchManifest(job, query) {
    query = String(query || '').toLowerCase();
    const results = [];
    if (!fs.existsSync(job.manifestPath)) return results;
    const input = fs.createReadStream(job.manifestPath, { encoding: 'utf8' });
    const rl = readline.createInterface({ input: input, crlfDelay: Infinity });
    for await (const line of rl) {
        if (!line) continue;
        let entry;
        try { entry = JSON.parse(line); } catch (_) { continue; }
        if (!entry.regular) continue;
        if (query && String(entry.name || '').toLowerCase().indexOf(query) < 0) continue;
        results.push(entry);
        if (results.length >= SEARCH_LIMIT) { rl.close(); input.destroy(); break; }
    }
    return results;
}

function safeRecoveredName(entryName) {
    let name = path.basename(String(entryName || '')).replace(/[^A-Za-z0-9._ -]/g, '_');
    if (!name || name === '.' || name === '..') name = 'recovered-file.bin';
    return name.substring(0, 180);
}

function startExtraction(config, bucket, key, entryName, expectedSize) {
    entryName = String(entryName || '');
    if (!entryName || /[\x00-\x1f\x7f]/.test(entryName)) throw new Error('Select a valid archive file entry.');
    expectedSize = Number(expectedSize || 0);
    if (expectedSize > MAX_RECOVERY_BYTES) throw new Error('Selected file exceeds the single-file recovery safety limit of ' + MAX_RECOVERY_BYTES + ' bytes.');

    const id = crypto.randomBytes(12).toString('hex');
    const outputName = safeRecoveredName(entryName);
    const outputPath = '/tmp/ocsp-recovered-' + id + '-' + outputName;
    const job = extracts[id] = {
        id: id, state: 'starting', started: Date.now(), updated: Date.now(), bucket: String(bucket || ''), key: String(key || ''), entryName: entryName,
        expectedSize: expectedSize, written: 0, compressedRead: 0, compressedTotal: 0, outputPath: outputPath, outputName: outputName, error: ''
    };

    (async function () {
        let out = null;
        let remote = null;
        try {
            remote = await signedGetStream(config, bucket, key);
            job.state = 'running';
            job.compressedTotal = remote.contentLength;
            remote.response.on('data', function (chunk) { job.compressedRead += chunk.length; job.updated = Date.now(); });
            const gunzip = zlib.createGunzip();
            let buffer = Buffer.alloc(0);
            let state = 'header';
            let remaining = 0;
            let padding = 0;
            let specialType = '';
            let specialChunks = [];
            let specialBytes = 0;
            let pendingLongName = '';
            let pendingPax = {};
            let currentEntry = null;
            let capture = false;
            let found = false;
            let done = false;

            function finishSpecial() {
                const data = Buffer.concat(specialChunks, specialBytes);
                if (specialType === 'L') pendingLongName = data.toString('utf8').replace(/\0.*$/, '').replace(/\n$/, '');
                else if (specialType === 'x') pendingPax = parsePax(data);
                specialType = '';
                specialChunks = [];
                specialBytes = 0;
            }

            function finishCapture() {
                if (!capture || !out || done) return;
                done = true;
                out.end(function () {
                    out = null;
                    job.state = 'ready';
                    job.updated = Date.now();
                    try { remote.response.destroy(); } catch (_) { }
                    try { gunzip.destroy(); } catch (_) { }
                });
            }

            function processBuffer() {
                while (!done) {
                    if (state === 'header') {
                        if (buffer.length < 512) return;
                        const headerBuf = buffer.subarray(0, 512);
                        buffer = buffer.subarray(512);
                        if (allZero(headerBuf)) return;
                        const header = parseHeader(headerBuf);
                        remaining = header.size;
                        padding = (512 - (header.size % 512)) % 512;
                        if (header.type === 'L' || header.type === 'x') {
                            specialType = header.type; specialChunks = []; specialBytes = 0;
                            state = remaining ? 'special' : (padding ? 'padding-special' : 'header');
                            if (!remaining && !padding) finishSpecial();
                        } else {
                            currentEntry = makeManifestEntry(header, pendingLongName, pendingPax);
                            pendingLongName = ''; pendingPax = {};
                            capture = currentEntry.regular && currentEntry.name === entryName;
                            if (capture) {
                                found = true;
                                if (currentEntry.size > MAX_RECOVERY_BYTES) throw new Error('Selected file exceeds single-file recovery safety limit.');
                                out = fs.createWriteStream(outputPath, { flags: 'wx', mode: 0o600 });
                                job.expectedSize = currentEntry.size;
                            }
                            state = remaining ? 'body' : (padding ? 'padding' : 'header');
                            if (capture && !remaining) finishCapture();
                        }
                    } else if (state === 'body') {
                        if (!buffer.length) return;
                        const take = Math.min(remaining, buffer.length);
                        const piece = buffer.subarray(0, take);
                        buffer = buffer.subarray(take);
                        remaining -= take;
                        if (capture) {
                            job.written += take;
                            job.updated = Date.now();
                            const ok = out.write(piece);
                            if (!ok) {
                                gunzip.pause();
                                out.once('drain', function () { processBuffer(); gunzip.resume(); });
                                return;
                            }
                        }
                        if (!remaining) {
                            if (capture) { finishCapture(); return; }
                            state = padding ? 'padding' : 'header';
                        }
                    } else if (state === 'special') {
                        if (!buffer.length) return;
                        const take = Math.min(remaining, buffer.length);
                        if (specialBytes + take <= MAX_SPECIAL_BYTES) { specialChunks.push(Buffer.from(buffer.subarray(0, take))); specialBytes += take; }
                        else throw new Error('TAR long-name/PAX record exceeds safety limit.');
                        buffer = buffer.subarray(take); remaining -= take;
                        if (!remaining) { finishSpecial(); state = padding ? 'padding-special' : 'header'; }
                    } else if (state === 'padding' || state === 'padding-special') {
                        if (buffer.length < padding) return;
                        buffer = buffer.subarray(padding); padding = 0; state = 'header';
                    }
                }
            }

            gunzip.on('data', function (chunk) { buffer = buffer.length ? Buffer.concat([buffer, chunk]) : chunk; processBuffer(); });
            await new Promise(function (resolve, reject) {
                gunzip.on('end', resolve);
                gunzip.on('close', resolve);
                gunzip.on('error', function (e) { if (done) resolve(); else reject(e); });
                remote.response.on('error', function (e) { if (done) resolve(); else reject(e); });
                remote.response.pipe(gunzip);
            });
            if (!done) {
                if (!found) throw new Error('Selected archive entry was not found before end of TAR stream.');
                if (capture) finishCapture();
            }
        } catch (e) {
            job.state = 'error';
            job.error = e && e.message ? e.message : String(e);
            job.updated = Date.now();
            if (out) try { out.destroy(); } catch (_) { }
            try { fs.unlinkSync(outputPath); } catch (_) { }
        }
    })();

    return { id: id };
}

function publicExtract(job) {
    return {
        id: job.id, state: job.state, entryName: job.entryName, expectedSize: job.expectedSize, written: job.written,
        compressedRead: job.compressedRead, compressedTotal: job.compressedTotal,
        scanProgress: job.compressedTotal ? Math.min(100, Math.floor(job.compressedRead * 10000 / job.compressedTotal) / 100) : 0,
        fileProgress: job.expectedSize ? Math.min(100, Math.floor(job.written * 10000 / job.expectedSize) / 100) : 0,
        outputName: job.outputName, error: job.error
    };
}

function sendSuccess(res, data) { res.send({ success: true, data: data }); res.end(); }
function sendFailure(res, error) { res.status(502); res.send({ success: false, message: error && error.message ? error.message : String(error) }); res.end(); }

function scanStartHandler(req, res) {
    try { sendSuccess(res, startArchiveScan(req.body && req.body.config, req.body && req.body.bucket, req.body && req.body.key)); }
    catch (e) { sendFailure(res, e); }
}
function scanStatusHandler(req, res) {
    const job = jobs[String(req.query.id || '')];
    if (!job) { res.status(404).send({ success: false, message: 'Archive scan not found.' }); return; }
    sendSuccess(res, publicScan(job));
}
function searchHandler(req, res) {
    const job = jobs[String(req.body && req.body.id || '')];
    if (!job) { res.status(404).send({ success: false, message: 'Archive scan not found.' }); return; }
    searchManifest(job, req.body && req.body.query).then(function (results) { sendSuccess(res, { results: results, state: job.state, entries: job.entries }); }).catch(function (e) { sendFailure(res, e); });
}
function extractStartHandler(req, res) {
    try { sendSuccess(res, startExtraction(req.body && req.body.config, req.body && req.body.bucket, req.body && req.body.key, req.body && req.body.entryName, req.body && req.body.size)); }
    catch (e) { sendFailure(res, e); }
}
function extractStatusHandler(req, res) {
    const job = extracts[String(req.query.id || '')];
    if (!job) { res.status(404).send({ success: false, message: 'Recovery job not found.' }); return; }
    sendSuccess(res, publicExtract(job));
}
function downloadHandler(req, res) {
    const id = String(req.query.id || '');
    const job = extracts[id];
    if (!job || job.state !== 'ready' || !fs.existsSync(job.outputPath)) { res.status(404).end('Recovered file is not ready.'); return; }
    res.download(job.outputPath, job.outputName, function (err) {
        if (!err) {
            try { fs.unlinkSync(job.outputPath); } catch (_) { }
            delete extracts[id];
        }
    });
}

function cleanupOld() {
    const cutoff = Date.now() - JOB_TTL_MS;
    Object.keys(jobs).forEach(function (id) {
        const job = jobs[id];
        if (job.updated < cutoff && job.state !== 'running' && job.state !== 'starting') {
            try { fs.unlinkSync(job.manifestPath); } catch (_) { }
            delete jobs[id];
        }
    });
    Object.keys(extracts).forEach(function (id) {
        const job = extracts[id];
        if (job.updated < cutoff && job.state !== 'running' && job.state !== 'starting') {
            try { fs.unlinkSync(job.outputPath); } catch (_) { }
            delete extracts[id];
        }
    });
}
const cleanupTimer = setInterval(cleanupOld, 10 * 60 * 1000);
if (cleanupTimer.unref) cleanupTimer.unref();

module.exports = {
    scanStartHandler: scanStartHandler,
    scanStatusHandler: scanStatusHandler,
    searchHandler: searchHandler,
    extractStartHandler: extractStartHandler,
    extractStatusHandler: extractStatusHandler,
    downloadHandler: downloadHandler,
    _test: { parseHeader: parseHeader, parsePax: parsePax, validateBucketName: validateBucketName, validateBackupKey: validateBackupKey }
};
