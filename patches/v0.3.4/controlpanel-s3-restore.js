/* OCSP v0.3.4.3 — S3-compatible restore bucket / backup object picker. */
window.OCSPS3Restore = (function ($, apiService) {
    'use strict';

    var connectionFingerprint = null;
    var verifiedFingerprint = null;
    var initialised = false;
    var busy = false;

    function $view() { return $('#restoreView'); }
    function $consumerBox() { return $view().find('#consumerStorageSettingsBox'); }
    function $s3() { return $consumerBox().find("div.storage[data-id='S3Compatible']"); }
    function $startButton() { return $view().find('#startRestoreBtn'); }

    function active() {
        var source = $view().find('.selectButton[data-name=restoreSource].checked').attr('data-value');
        var consumer = $consumerBox().find('.thirdSelectStorageFlexbox .radioBox.checked').attr('data-value');
        return String(source) === '5' && consumer === 'S3Compatible';
    }

    function readSetting(name) {
        var $row = $s3().find(
            ".flexContainer[data-id='" + name + "'], .flexContainer[prop-id='" + name + "']"
        ).first();
        if (!$row.length) return '';

        var $item = $row.find('.textBox, .selectBox, .radioBox.checked, .checkBox').first();
        if (!$item.length) return '';
        if ($item.hasClass('textBox')) return $item.val() || '';
        if ($item.hasClass('selectBox')) return $item.attr('data-value') || '';
        if ($item.hasClass('radioBox')) return $item.attr('data-value') || '';
        if ($item.hasClass('checkBox')) return $item.hasClass('checked');
        return '';
    }

    function currentConfig() {
        return {
            acesskey: String(readSetting('acesskey') || '').trim(),
            secretaccesskey: String(readSetting('secretaccesskey') || '').trim(),
            region: String(readSetting('region') || 'us-east-1').trim(),
            serviceurl: String(readSetting('serviceurl') || '').trim(),
            forcepathstyle: !!readSetting('forcepathstyle'),
            usehttp: !!readSetting('usehttp'),
            bucket: String(readSetting('bucket') || '').trim()
        };
    }

    function filePathInput() {
        return $s3().find(".flexContainer[data-id='filePath'] .textBox").first();
    }

    function currentBackupKey() {
        return String(filePathInput().val() || '').trim();
    }

    function connectionKey(cfg) {
        return JSON.stringify({
            acesskey: cfg.acesskey ? 'explicit' : 'stored',
            secretaccesskey: cfg.secretaccesskey ? 'explicit' : 'stored',
            region: cfg.region,
            serviceurl: cfg.serviceurl,
            forcepathstyle: cfg.forcepathstyle,
            usehttp: cfg.usehttp
        });
    }

    function verifyKey(cfg, key) {
        return connectionKey(cfg) + '\n' + cfg.bucket + '\n' + key;
    }

    function connectionCurrent() {
        return connectionFingerprint !== null && connectionFingerprint === connectionKey(currentConfig());
    }

    function verificationCurrent() {
        var cfg = currentConfig();
        var key = currentBackupKey();
        return verifiedFingerprint !== null && verifiedFingerprint === verifyKey(cfg, key);
    }

    function setStatus(text, kind) {
        var $status = $s3().find('.ocsp-s3-restore-status');
        $status.text(text || '');
        $status.css('font-weight', kind === 'ok' || kind === 'error' ? '600' : 'normal');
        if (kind === 'ok') $status.css('color', '#4a8f29');
        else if (kind === 'error') $status.css('color', '#c4473a');
        else $status.css('color', '');
    }

    function gateStart() {
        var $btn = $startButton();
        if (active() && !verificationCurrent()) {
            if (!$btn.attr('data-ocsp-restore-gated')) {
                $btn.attr('data-ocsp-restore-gated', '1');
                $btn.attr('data-ocsp-restore-pre-disabled', $btn.hasClass('disabled') ? '1' : '0');
            }
            $btn.addClass('disabled');
            return;
        }

        if ($btn.attr('data-ocsp-restore-gated')) {
            if ($btn.attr('data-ocsp-restore-pre-disabled') !== '1') $btn.removeClass('disabled');
            $btn.removeAttr('data-ocsp-restore-gated data-ocsp-restore-pre-disabled');
        }
    }

    function resetVerification(message) {
        verifiedFingerprint = null;
        $s3().find('.ocsp-s3-restore-details').text('');
        if (message && active()) setStatus(message, 'info');
        gateStart();
    }

    function resetConnection(message) {
        connectionFingerprint = null;
        verifiedFingerprint = null;
        $s3().find('.ocsp-s3-restore-bucket-tools').hide();
        $s3().find('.ocsp-s3-restore-backup-tools').hide();
        $s3().find('.ocsp-s3-restore-details').text('');
        if (message && active()) setStatus(message, 'info');
        gateStart();
    }

    function originalBucketInput() {
        return $s3().find(".flexContainer[data-id='bucket'] .textBox").first();
    }

    function applyBucket(bucket) {
        originalBucketInput().val(bucket || '');
        filePathInput().val('');
        $s3().find('.ocsp-s3-restore-backup-select').empty();
        $s3().find('.ocsp-s3-restore-backup-tools').hide();
        resetVerification(bucket ? 'Bucket selected — fetch its backup list.' : 'Select a bucket.');
    }

    function applyBackup(key) {
        filePathInput().val(key || '');
        resetVerification(key ? 'Backup selected — verify it before restore.' : 'Select a backup object.');
    }

    function populateBuckets(buckets) {
        var $select = $s3().find('.ocsp-s3-restore-bucket-select');
        var current = String(originalBucketInput().val() || '').trim();
        $select.empty();
        $('<option/>').attr('value', '').text('-- Select bucket --').appendTo($select);
        (buckets || []).forEach(function (bucket) {
            $('<option/>').attr('value', bucket).text(bucket).appendTo($select);
        });
        $select.val(current && (buckets || []).indexOf(current) >= 0 ? current : '');
    }

    function formatBytes(value) {
        var n = Number(value || 0);
        if (!n) return '0 B';
        var units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
        var i = Math.min(units.length - 1, Math.floor(Math.log(n) / Math.log(1024)));
        return (n / Math.pow(1024, i)).toFixed(i >= 3 ? 2 : 1) + ' ' + units[i];
    }

    function backupLabel(item) {
        var key = item.key || '';
        var name = key.split('/').pop() || key;
        var date = item.lastModified ? new Date(item.lastModified) : null;
        var dateText = date && !isNaN(date.getTime()) ? date.toLocaleString() : '';
        return name + ' — ' + formatBytes(item.size) + (dateText ? ' — ' + dateText : '');
    }

    function populateBackups(backups) {
        var $select = $s3().find('.ocsp-s3-restore-backup-select');
        var current = currentBackupKey();
        $select.empty();
        $('<option/>').attr('value', '').text('-- Select backup object --').appendTo($select);
        (backups || []).forEach(function (item) {
            $('<option/>')
                .attr('value', item.key)
                .attr('title', item.key)
                .text(backupLabel(item))
                .appendTo($select);
        });
        $select.val(current && (backups || []).some(function (item) { return item.key === current; }) ? current : '');
    }

    function ensureTools() {
        var $storage = $s3();
        if (!$storage.length) return;

        $storage.find(".flexContainer[data-id='backupchunksize']").hide();
        $storage.find(".flexContainer[data-id='disabledefaultchecksumvalidation']").hide();

        if ($storage.find('.ocsp-s3-restore-tools').length) return;

        var $bucketRow = $storage.find(".flexContainer[data-id='bucket']").first();
        if (!$bucketRow.length) return;

        var html = '' +
            '<div class="ocsp-s3-restore-tools" style="margin:12px 0 16px 0;">' +
              '<div style="margin-bottom:8px;">' +
                '<button type="button" class="button blue ocsp-s3-restore-check">Check connection & fetch buckets</button>' +
                '<span class="ocsp-s3-restore-status" style="margin-left:10px;"></span>' +
              '</div>' +
              '<div class="ocsp-s3-restore-bucket-tools" style="display:none;">' +
                '<div style="margin:8px 0;">' +
                  '<select class="ocsp-s3-restore-bucket-select" style="min-width:420px;height:30px;"></select>' +
                  '<button type="button" class="button ocsp-s3-restore-refresh" style="margin-left:6px;">Refresh buckets</button>' +
                  '<button type="button" class="button blue ocsp-s3-restore-fetch" style="margin-left:6px;">Fetch backup list</button>' +
                '</div>' +
              '</div>' +
              '<div class="ocsp-s3-restore-backup-tools" style="display:none;">' +
                '<div style="margin:8px 0;">' +
                  '<select class="ocsp-s3-restore-backup-select" style="min-width:620px;max-width:100%;height:30px;"></select>' +
                '</div>' +
                '<div style="margin:8px 0;">' +
                  '<button type="button" class="button blue ocsp-s3-restore-verify">Verify selected backup</button>' +
                  '<span class="ocsp-s3-restore-details" style="margin-left:10px;"></span>' +
                '</div>' +
              '</div>' +
            '</div>';

        $bucketRow.after(html);
    }

    function decodeHtml(value) {
        var txt = document.createElement('textarea');
        txt.innerHTML = value || '';
        return txt.value;
    }

    function readSavedKeyFromManagement(html, id) {
        var start = html.indexOf('id="popupDialogS3Compatible"');
        if (start < 0) return '';
        var end = html.indexOf('id="saveBtnS3Compatible"', start);
        if (end < 0) end = Math.min(html.length, start + 20000);
        var block = html.substring(start, end);
        var escaped = id.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
        var re = new RegExp('<input[^>]*\\bid="' + escaped + '"[^>]*\\bvalue="([^"]*)"', 'i');
        var match = re.exec(block);
        return match ? decodeHtml(match[1]).trim() : '';
    }

    function resolveCredentials(cfg) {
        if (cfg.acesskey && cfg.secretaccesskey) return $.Deferred().resolve(cfg).promise();

        return $.ajax({
            url: '/Management.aspx?type=ThirdPartyAuthorization',
            method: 'GET',
            dataType: 'html',
            cache: false
        }).then(function (html) {
            var resolved = $.extend({}, cfg);
            if (!resolved.acesskey) resolved.acesskey = readSavedKeyFromManagement(html, 'acesskey');
            if (!resolved.secretaccesskey) resolved.secretaccesskey = readSavedKeyFromManagement(html, 'secretaccesskey');
            if (!resolved.acesskey || !resolved.secretaccesskey) {
                throw new Error('Saved S3Compatible access/secret keys were not found in Third-Party Services.');
            }
            return resolved;
        });
    }

    function requestErrorMessage(error, fallback) {
        if (error && error.responseJSON && error.responseJSON.message) return error.responseJSON.message;
        if (error && error.responseText) return error.responseText;
        if (error && error.message) return error.message;
        return fallback;
    }

    function checkConnection() {
        if (busy || !active()) return;
        var cfg = currentConfig();
        busy = true;
        resetConnection();
        setStatus((cfg.acesskey && cfg.secretaccesskey)
            ? 'Checking endpoint and fetching buckets…'
            : 'Loading saved S3Compatible keys and fetching buckets…', 'info');

        resolveCredentials(cfg)
            .then(function (resolved) {
                return apiService.post('backup/ocspS3ListBuckets', { config: resolved });
            })
            .done(function (response) {
                if (!response || !response.success) {
                    setStatus((response && response.message) || 'Connection check failed.', 'error');
                    return;
                }
                connectionFingerprint = connectionKey(currentConfig());
                populateBuckets((response.data && response.data.buckets) || []);
                $s3().find('.ocsp-s3-restore-bucket-tools').show();
                setStatus(response.data && response.data.listDenied
                    ? (response.data.message || 'Bucket listing denied; enter the known bucket path manually.')
                    : 'Connection OK — choose the bucket containing the backup.',
                    response.data && response.data.listDenied ? 'info' : 'ok');
                gateStart();
            })
            .fail(function (error) {
                setStatus(requestErrorMessage(error, 'Connection check failed.'), 'error');
            })
            .always(function () { busy = false; });
    }

    function refreshBuckets() {
        if (busy || !active()) return;
        checkConnection();
    }

    function fetchBackups() {
        if (busy || !active()) return;
        if (!connectionCurrent()) {
            window.toastr.error('Check the connection again before listing backups.');
            resetConnection('Connection settings changed — check again.');
            return;
        }

        var cfg = currentConfig();
        if (!cfg.bucket) {
            window.toastr.error('Select a bucket first.');
            return;
        }

        busy = true;
        resetVerification();
        setStatus('Listing .tar.gz backup objects in ' + cfg.bucket + '…', 'info');

        resolveCredentials(cfg)
            .then(function (resolved) {
                return apiService.post('backup/ocspS3ListBackups', { config: resolved, bucket: cfg.bucket });
            })
            .done(function (response) {
                if (!response || !response.success) {
                    setStatus((response && response.message) || 'Backup listing failed.', 'error');
                    return;
                }
                var backups = (response.data && response.data.backups) || [];
                populateBackups(backups);
                $s3().find('.ocsp-s3-restore-backup-tools').show();
                setStatus(backups.length
                    ? ('Found ' + backups.length + ' backup object' + (backups.length === 1 ? '' : 's') + '. Select one and verify it.')
                    : 'No .tar.gz backup objects were found in this bucket.',
                    backups.length ? 'ok' : 'info');
            })
            .fail(function (error) {
                setStatus(requestErrorMessage(error, 'Backup listing failed.'), 'error');
            })
            .always(function () { busy = false; });
    }

    function verifyBackup() {
        if (busy || !active()) return;
        if (!connectionCurrent()) {
            window.toastr.error('Connection settings changed. Check again first.');
            resetConnection('Connection settings changed — check again.');
            return;
        }

        var cfg = currentConfig();
        var key = currentBackupKey();
        if (!cfg.bucket || !key) {
            window.toastr.error('Select a bucket and backup object first.');
            return;
        }

        busy = true;
        resetVerification();
        setStatus('Verifying ' + key + '…', 'info');

        resolveCredentials(cfg)
            .then(function (resolved) {
                return apiService.post('backup/ocspS3HeadBackup', {
                    config: resolved,
                    bucket: cfg.bucket,
                    key: key
                });
            })
            .done(function (response) {
                if (!response || !response.success) {
                    setStatus((response && response.message) || 'Backup verification failed.', 'error');
                    return;
                }
                var data = response.data || {};
                verifiedFingerprint = verifyKey(currentConfig(), currentBackupKey());
                $s3().find('.ocsp-s3-restore-details').text(
                    formatBytes(data.size) +
                    (data.lastModified ? ' — ' + data.lastModified : '') +
                    (data.etag ? ' — ETag ' + data.etag : '')
                );
                setStatus('Backup verified by HEAD. Restore is unlocked.', 'ok');
                gateStart();
            })
            .fail(function (error) {
                setStatus(requestErrorMessage(error, 'Backup verification failed.'), 'error');
                gateStart();
            })
            .always(function () { busy = false; });
    }

    function bindEvents() {
        var $v = $view();
        $v.off('.ocspS3Restore');
        $v.on('click.ocspS3Restore', '.ocsp-s3-restore-check', checkConnection);
        $v.on('click.ocspS3Restore', '.ocsp-s3-restore-refresh', refreshBuckets);
        $v.on('click.ocspS3Restore', '.ocsp-s3-restore-fetch', fetchBackups);
        $v.on('click.ocspS3Restore', '.ocsp-s3-restore-verify', verifyBackup);

        $v.on('change.ocspS3Restore', '.ocsp-s3-restore-bucket-select', function () {
            applyBucket($(this).val() || '');
        });
        $v.on('change.ocspS3Restore', '.ocsp-s3-restore-backup-select', function () {
            applyBackup($(this).val() || '');
        });

        $v.on('input.ocspS3Restore change.ocspS3Restore',
            "#consumerStorageSettingsBox div.storage[data-id='S3Compatible'] .textBox",
            function () {
                var key = $(this).closest('.flexContainer').attr('data-id');
                if (key === 'backupchunksize' || key === 'disabledefaultchecksumvalidation') return;
                if (key === 'filePath') {
                    resetVerification('Backup path changed — verify it before restore.');
                    return;
                }
                if (key === 'bucket') {
                    $s3().find('.ocsp-s3-restore-backup-tools').hide();
                    resetVerification('Bucket changed — fetch its backup list.');
                    return;
                }
                resetConnection('Connection settings changed — check again.');
            });

        $v.on('click.ocspS3Restore',
            "#consumerStorageSettingsBox div.storage[data-id='S3Compatible'] .checkBox, " +
            "#consumerStorageSettingsBox div.storage[data-id='S3Compatible'] .radioBox",
            function () {
                var key = $(this).closest('.flexContainer').attr('data-id');
                if (key === 'forcepathstyle' || key === 'usehttp') {
                    setTimeout(function () { resetConnection('Connection settings changed — check again.'); }, 0);
                } else {
                    setTimeout(sync, 0);
                }
            });

        $v.on('click.ocspS3Restore', '.selectButton[data-name=restoreSource], .thirdSelectStorageFlexbox .radioBox', function () {
            setTimeout(sync, 0);
        });
    }

    function sync() {
        ensureTools();
        gateStart();
    }

    function init() {
        ensureTools();
        if (!initialised) {
            bindEvents();
            initialised = true;
        }
        sync();
    }

    function canStart() {
        return !active() || verificationCurrent();
    }

    function warn() {
        if (active() && !verificationCurrent()) {
            window.toastr.error('Select and verify the S3-compatible backup object before restoring.');
        }
    }

    return {
        init: init,
        sync: sync,
        canStart: canStart,
        warn: warn
    };
}($, window.ApiService));
