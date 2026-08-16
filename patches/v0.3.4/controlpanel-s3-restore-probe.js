'use strict';

// OCSP v0.3.4.3 — read-only S3-compatible restore discovery helper.
// Credentials are supplied by the authenticated Control Panel request and are
// used only for ListObjectsV2 / HEAD requests. They are never persisted here.

const crypto = require('crypto');
const http = require('http');
const https = require('https');
const URLCtor = require('url').URL;

const MAX_ERROR_BODY = 2048;
const MAX_LIST_PAGES = 50;

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

    if (!cfg.accessKey || !cfg.secretKey) {
        throw new Error('Access key and secret key are required before browsing S3-compatible backups.');
    }

    if (!cfg.serviceUrl) {
        const scheme = cfg.useHttp ? 'http' : 'https';
        cfg.serviceUrl = cfg.region === 'us-east-1'
            ? scheme + '://s3.amazonaws.com'
            : scheme + '://s3.' + cfg.region + '.amazonaws.com';
    } else if (!/^https?:\/\//i.test(cfg.serviceUrl)) {
        cfg.serviceUrl = (cfg.useHttp ? 'http://' : 'https://') + cfg.serviceUrl;
    }

    const parsed = new URLCtor(cfg.serviceUrl);
    if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') {
        throw new Error('S3-compatible endpoint must use HTTP or HTTPS.');
    }
    if (parsed.username || parsed.password || parsed.search || parsed.hash) {
        throw new Error('S3-compatible endpoint must not contain credentials, query parameters or a fragment.');
    }

    cfg.endpoint = parsed;
    return cfg;
}

function validateBucketName(bucket) {
    bucket = String(bucket || '').trim();
    if (!/^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$/.test(bucket) || bucket.indexOf('..') !== -1) {
        throw new Error('Bucket name must be 3-63 characters using lowercase letters, digits, dots or hyphens.');
    }
    return bucket;
}

function validateBackupKey(key) {
    key = String(key || '').trim();
    if (!key || key.length > 4096 || /[\x00-\x1f\x7f]/.test(key)) {
        throw new Error('Select a valid backup object.');
    }
    if (!/\.tar\.gz$/i.test(key)) {
        throw new Error('Restore object must end in .tar.gz.');
    }
    return key;
}

function sha256(value, encoding) {
    return crypto.createHash('sha256').update(value).digest(encoding || 'hex');
}

function hmac(key, value, encoding) {
    return crypto.createHmac('sha256', key).update(value).digest(encoding);
}

function awsEncode(value) {
    return encodeURIComponent(String(value)).replace(/[!'()*]/g, function (ch) {
        return '%' + ch.charCodeAt(0).toString(16).toUpperCase();
    });
}

function encodeKey(key) {
    return String(key || '').split('/').map(awsEncode).join('/');
}

function requestTarget(cfg, bucket, key) {
    const endpoint = cfg.endpoint;
    const pathStyle = !!cfg.forcePathStyle;
    let hostname = endpoint.hostname;
    let host = hostname + (endpoint.port ? ':' + endpoint.port : '');
    let pathname = endpoint.pathname || '/';

    pathname = pathname.replace(/\/+$/, '');
    if (!pathname) pathname = '';

    if (bucket) {
        if (pathStyle) {
            pathname += '/' + awsEncode(bucket);
        } else {
            hostname = bucket + '.' + hostname;
            host = hostname + (endpoint.port ? ':' + endpoint.port : '');
        }
    }

    if (key) pathname += '/' + encodeKey(key);
    if (!pathname) pathname = '/';
    if (pathname.charAt(0) !== '/') pathname = '/' + pathname;

    return {
        protocol: endpoint.protocol,
        hostname: hostname,
        port: endpoint.port || undefined,
        host: host,
        path: pathname
    };
}

function canonicalQuery(params) {
    params = params || {};
    const pairs = [];
    Object.keys(params).forEach(function (key) {
        if (params[key] === undefined || params[key] === null) return;
        pairs.push([awsEncode(key), awsEncode(params[key])]);
    });
    pairs.sort(function (a, b) {
        if (a[0] === b[0]) return a[1] < b[1] ? -1 : (a[1] > b[1] ? 1 : 0);
        return a[0] < b[0] ? -1 : 1;
    });
    return pairs.map(function (pair) { return pair[0] + '=' + pair[1]; }).join('&');
}

function signedRequest(cfg, method, bucket, key, queryParams) {
    const body = Buffer.alloc(0);
    const target = requestTarget(cfg, bucket, key);
    const query = canonicalQuery(queryParams);
    const now = new Date();
    const amzDate = now.toISOString().replace(/[:-]|\.\d{3}/g, '');
    const dateStamp = amzDate.substring(0, 8);
    const payloadHash = sha256(body);
    const canonicalHeaders =
        'host:' + target.host + '\n' +
        'x-amz-content-sha256:' + payloadHash + '\n' +
        'x-amz-date:' + amzDate + '\n';
    const signedHeaders = 'host;x-amz-content-sha256;x-amz-date';
    const canonicalRequest = [
        method,
        target.path,
        query,
        canonicalHeaders,
        signedHeaders,
        payloadHash
    ].join('\n');

    const scope = dateStamp + '/' + cfg.region + '/s3/aws4_request';
    const stringToSign = [
        'AWS4-HMAC-SHA256',
        amzDate,
        scope,
        sha256(Buffer.from(canonicalRequest, 'utf8'))
    ].join('\n');

    const kDate = hmac(Buffer.from('AWS4' + cfg.secretKey, 'utf8'), dateStamp);
    const kRegion = hmac(kDate, cfg.region);
    const kService = hmac(kRegion, 's3');
    const kSigning = hmac(kService, 'aws4_request');
    const signature = hmac(kSigning, stringToSign, 'hex');

    const headers = {
        Host: target.host,
        'x-amz-date': amzDate,
        'x-amz-content-sha256': payloadHash,
        Authorization:
            'AWS4-HMAC-SHA256 Credential=' + cfg.accessKey + '/' + scope +
            ', SignedHeaders=' + signedHeaders +
            ', Signature=' + signature
    };

    const client = target.protocol === 'http:' ? http : https;
    const requestPath = target.path + (query ? '?' + query : '');

    return new Promise(function (resolve, reject) {
        const req = client.request({
            protocol: target.protocol,
            hostname: target.hostname,
            port: target.port,
            method: method,
            path: requestPath,
            headers: headers,
            timeout: 30000
        }, function (res) {
            const chunks = [];
            res.on('data', function (chunk) { chunks.push(chunk); });
            res.on('end', function () {
                resolve({
                    status: res.statusCode,
                    headers: res.headers || {},
                    body: Buffer.concat(chunks)
                });
            });
        });

        req.on('timeout', function () {
            req.destroy(new Error('S3-compatible request timed out.'));
        });
        req.on('error', reject);
        req.end();
    });
}

function bodyText(response) {
    if (!response || !response.body) return '';
    return response.body.toString('utf8', 0, Math.min(response.body.length, MAX_ERROR_BODY));
}

function responseError(action, response) {
    const suffix = bodyText(response).replace(/\s+/g, ' ').trim();
    return new Error(action + ' failed with HTTP ' + response.status + (suffix ? ': ' + suffix : ''));
}

function decodeXml(value) {
    return String(value || '')
        .replace(/&lt;/g, '<')
        .replace(/&gt;/g, '>')
        .replace(/&quot;/g, '"')
        .replace(/&apos;/g, "'")
        .replace(/&amp;/g, '&');
}

function xmlValue(block, name) {
    const re = new RegExp('<(?:\\w+:)?' + name + '\\b[^>]*>([\\s\\S]*?)<\\/(?:\\w+:)?' + name + '>', 'i');
    const match = re.exec(block || '');
    return match ? decodeXml(match[1]).trim() : '';
}

function parseListObjects(xml) {
    const objects = [];
    const re = /<(?:\w+:)?Contents\b[^>]*>([\s\S]*?)<\/(?:\w+:)?Contents>/gi;
    let match;
    while ((match = re.exec(xml)) !== null) {
        const block = match[1];
        const key = xmlValue(block, 'Key');
        if (!key) continue;
        objects.push({
            key: key,
            lastModified: xmlValue(block, 'LastModified'),
            etag: xmlValue(block, 'ETag').replace(/^"|"$/g, ''),
            size: Number(xmlValue(block, 'Size') || 0)
        });
    }

    return {
        objects: objects,
        truncated: /^true$/i.test(xmlValue(xml, 'IsTruncated')),
        nextToken: xmlValue(xml, 'NextContinuationToken')
    };
}

async function listBackupObjects(config, bucket) {
    const cfg = cleanConfig(config);
    bucket = validateBucketName(bucket || cfg.bucket);
    const backups = [];
    let token = '';
    let scanned = 0;

    for (let page = 0; page < MAX_LIST_PAGES; page++) {
        const query = { 'list-type': '2', 'max-keys': '1000' };
        if (token) query['continuation-token'] = token;

        const response = await signedRequest(cfg, 'GET', bucket, null, query);
        if (response.status !== 200) throw responseError('ListObjectsV2', response);

        const parsed = parseListObjects(response.body.toString('utf8'));
        scanned += parsed.objects.length;
        parsed.objects.forEach(function (item) {
            if (/\.tar\.gz$/i.test(item.key)) backups.push(item);
        });

        if (!parsed.truncated) {
            backups.sort(function (a, b) {
                const da = Date.parse(a.lastModified) || 0;
                const db = Date.parse(b.lastModified) || 0;
                return db - da;
            });
            return { bucket: bucket, backups: backups, scanned: scanned, truncated: false };
        }

        if (!parsed.nextToken) throw new Error('ListObjectsV2 was truncated without a continuation token.');
        token = parsed.nextToken;
    }

    throw new Error('Backup listing exceeded ' + (MAX_LIST_PAGES * 1000) + ' objects; narrow the bucket before restoring.');
}

async function headBackupObject(config, bucket, key) {
    const cfg = cleanConfig(config);
    bucket = validateBucketName(bucket || cfg.bucket);
    key = validateBackupKey(key);

    const response = await signedRequest(cfg, 'HEAD', bucket, key);
    if (response.status !== 200) throw responseError('Backup HEAD', response);

    return {
        bucket: bucket,
        key: key,
        size: Number(response.headers['content-length'] || 0),
        etag: String(response.headers.etag || '').replace(/^"|"$/g, ''),
        lastModified: String(response.headers['last-modified'] || ''),
        contentType: String(response.headers['content-type'] || '')
    };
}

function sendSuccess(res, data) {
    res.send({ success: true, data: data });
    res.end();
}

function sendFailure(res, error) {
    res.status(502);
    res.send({
        success: false,
        message: error && error.message ? error.message : 'S3-compatible restore discovery failed.'
    });
    res.end();
}

function listBackupsHandler(req, res) {
    listBackupObjects(req.body && req.body.config, req.body && req.body.bucket)
        .then(function (data) { sendSuccess(res, data); })
        .catch(function (error) { sendFailure(res, error); });
}

function headBackupHandler(req, res) {
    headBackupObject(req.body && req.body.config, req.body && req.body.bucket, req.body && req.body.key)
        .then(function (data) { sendSuccess(res, data); })
        .catch(function (error) { sendFailure(res, error); });
}

module.exports = {
    listBackupsHandler: listBackupsHandler,
    headBackupHandler: headBackupHandler,
    _test: {
        cleanConfig: cleanConfig,
        canonicalQuery: canonicalQuery,
        requestTarget: requestTarget,
        parseListObjects: parseListObjects,
        validateBucketName: validateBucketName,
        validateBackupKey: validateBackupKey
    }
};
