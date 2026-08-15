'use strict';

// OCSP v0.3.4 — transient S3-compatible connection/bucket validation helper.
// Credentials arrive in an authenticated Control Panel request, are used only
// for that request, and are never persisted or deliberately logged here.

const crypto = require('crypto');
const http = require('http');
const https = require('https');
const URLCtor = require('url').URL;

const TEST_BYTES = 100 * 1024;
const MAX_ERROR_BODY = 1024;

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
        throw new Error('Access key and secret key are required before checking S3-compatible storage.');
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

function sha256(value, encoding) {
    return crypto.createHash('sha256').update(value).digest(encoding || 'hex');
}

function hmac(key, value, encoding) {
    return crypto.createHmac('sha256', key).update(value).digest(encoding);
}

function awsEncode(value) {
    return encodeURIComponent(value).replace(/[!'()*]/g, function (ch) {
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

    if (key) {
        pathname += '/' + encodeKey(key);
    }

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

function signedRequest(cfg, method, bucket, key, body, headers) {
    body = body || Buffer.alloc(0);
    headers = Object.assign({}, headers || {});

    const target = requestTarget(cfg, bucket, key);
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
        '',
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

    headers.Host = target.host;
    headers['x-amz-date'] = amzDate;
    headers['x-amz-content-sha256'] = payloadHash;
    headers.Authorization =
        'AWS4-HMAC-SHA256 Credential=' + cfg.accessKey + '/' + scope +
        ', SignedHeaders=' + signedHeaders +
        ', Signature=' + signature;
    headers['Content-Length'] = body.length;

    const client = target.protocol === 'http:' ? http : https;

    return new Promise(function (resolve, reject) {
        const req = client.request({
            protocol: target.protocol,
            hostname: target.hostname,
            port: target.port,
            method: method,
            path: target.path,
            headers: headers,
            timeout: 20000
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
        if (body.length) req.write(body);
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

function parseBucketNames(xml) {
    const bucketsMatch = /<(?:\w+:)?Buckets\b[^>]*>([\s\S]*?)<\/(?:\w+:)?Buckets>/i.exec(xml);
    if (!bucketsMatch) return [];

    const names = [];
    const re = /<(?:\w+:)?Name\b[^>]*>([^<]+)<\/(?:\w+:)?Name>/gi;
    let match;
    while ((match = re.exec(bucketsMatch[1])) !== null) {
        names.push(decodeXml(match[1]).trim());
    }
    return names.filter(Boolean).sort();
}

async function listBuckets(config) {
    const cfg = cleanConfig(config);
    const response = await signedRequest(cfg, 'GET', null, null);

    if (response.status === 200) {
        return {
            reachable: true,
            listDenied: false,
            buckets: parseBucketNames(response.body.toString('utf8'))
        };
    }

    // Restricted IAM-style policies often allow a known bucket without
    // allowing the account-wide ListBuckets operation.  The UI can continue
    // with manual bucket entry, but validation is still mandatory.
    if (response.status === 401 || response.status === 403) {
        return {
            reachable: true,
            listDenied: true,
            buckets: [],
            message: 'Endpoint reached but bucket listing was denied. Enter a known bucket and validate it.'
        };
    }

    throw responseError('ListBuckets', response);
}

async function createBucket(config, bucket) {
    const cfg = cleanConfig(config);
    bucket = validateBucketName(bucket);

    let body = Buffer.alloc(0);
    let headers = {};

    // Native AWS needs a location constraint outside us-east-1. Most custom
    // endpoints accept an empty CreateBucket request and use the endpoint's
    // configured region, so only send the AWS location document when no custom
    // service URL was supplied by the caller.
    const callerHadServiceUrl = !!String((config || {}).serviceurl || '').trim();
    if (!callerHadServiceUrl && cfg.region !== 'us-east-1') {
        body = Buffer.from(
            '<CreateBucketConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">' +
            '<LocationConstraint>' + cfg.region + '</LocationConstraint>' +
            '</CreateBucketConfiguration>',
            'utf8');
        headers['Content-Type'] = 'application/xml';
    }

    const response = await signedRequest(cfg, 'PUT', bucket, null, body, headers);
    if (response.status !== 200 && response.status !== 201 && response.status !== 204) {
        throw responseError('CreateBucket', response);
    }

    return { bucket: bucket };
}

function sleep(ms) {
    return new Promise(function (resolve) { setTimeout(resolve, ms); });
}

async function validateBucket(config, bucket) {
    const cfg = cleanConfig(config);
    bucket = validateBucketName(bucket || cfg.bucket);

    const key = '.onlyoffice-storage-test/validation-' + crypto.randomBytes(16).toString('hex') + '.bin';
    const payload = crypto.randomBytes(TEST_BYTES);
    const expectedHash = sha256(payload);
    let objectCreated = false;
    let deleted = false;

    try {
        let response = await signedRequest(
            cfg,
            'PUT',
            bucket,
            key,
            payload,
            { 'Content-Type': 'application/octet-stream' });
        if (response.status !== 200 && response.status !== 201 && response.status !== 204) {
            throw responseError('100 KiB validation PUT', response);
        }
        objectCreated = true;

        response = await signedRequest(cfg, 'HEAD', bucket, key);
        if (response.status !== 200) {
            throw responseError('validation HEAD', response);
        }
        const contentLength = Number(response.headers['content-length']);
        if (contentLength !== TEST_BYTES) {
            throw new Error('Validation HEAD returned ' + contentLength + ' bytes; expected ' + TEST_BYTES + '.');
        }

        response = await signedRequest(cfg, 'GET', bucket, key);
        if (response.status !== 200) {
            throw responseError('validation GET', response);
        }
        const receivedHash = sha256(response.body);
        if (receivedHash !== expectedHash) {
            throw new Error('Validation GET SHA-256 mismatch.');
        }

        response = await signedRequest(cfg, 'DELETE', bucket, key);
        if (response.status !== 200 && response.status !== 202 && response.status !== 204) {
            throw responseError('validation DELETE', response);
        }
        deleted = true;

        // Confirm the disposable object is actually gone. Retry briefly for
        // S3-compatible implementations that expose delete state asynchronously.
        let gone = false;
        for (let attempt = 0; attempt < 4; attempt++) {
            response = await signedRequest(cfg, 'HEAD', bucket, key);
            if (response.status === 404) {
                gone = true;
                break;
            }
            if (response.status !== 200) {
                throw responseError('post-delete validation HEAD', response);
            }
            await sleep(500);
        }
        if (!gone) {
            throw new Error('Validation object still exists after DELETE.');
        }

        return {
            bucket: bucket,
            bytes: TEST_BYTES,
            sha256: expectedHash,
            deleted: true
        };
    } finally {
        if (objectCreated && !deleted) {
            try { await signedRequest(cfg, 'DELETE', bucket, key); } catch (e) { }
        }
    }
}

function sendSuccess(res, data) {
    res.send({ success: true, data: data });
    res.end();
}

function sendFailure(res, error) {
    res.status(502);
    res.send({
        success: false,
        message: error && error.message ? error.message : 'S3-compatible operation failed.'
    });
    res.end();
}

function listBucketsHandler(req, res) {
    listBuckets(req.body && req.body.config)
        .then(function (data) { sendSuccess(res, data); })
        .catch(function (error) { sendFailure(res, error); });
}

function createBucketHandler(req, res) {
    createBucket(req.body && req.body.config, req.body && req.body.bucket)
        .then(function (data) { sendSuccess(res, data); })
        .catch(function (error) { sendFailure(res, error); });
}

function validateBucketHandler(req, res) {
    validateBucket(req.body && req.body.config, req.body && req.body.bucket)
        .then(function (data) { sendSuccess(res, data); })
        .catch(function (error) { sendFailure(res, error); });
}

module.exports = {
    listBucketsHandler: listBucketsHandler,
    createBucketHandler: createBucketHandler,
    validateBucketHandler: validateBucketHandler,
    _test: {
        cleanConfig: cleanConfig,
        requestTarget: requestTarget,
        parseBucketNames: parseBucketNames,
        validateBucketName: validateBucketName
    }
};
