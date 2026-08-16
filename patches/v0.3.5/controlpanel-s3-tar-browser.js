/* OCSP v0.3.5.1 — Restore-page streaming TAR inspector / single-file recovery UI. */
window.OCSPS3TarBrowser = (function ($, apiService) {
    'use strict';

    var initialised = false;
    var scanId = null;
    var scanTimer = null;
    var extractId = null;
    var extractTimer = null;
    var selectedEntry = null;

    function $view() { return $('#restoreView'); }
    function $consumerBox() { return $view().find('#consumerStorageSettingsBox'); }
    function $s3() { return $consumerBox().find("div.storage[data-id='S3Compatible']"); }

    function readSetting(name) {
        var $row = $s3().find(".flexContainer[data-id='" + name + "'], .flexContainer[prop-id='" + name + "']").first();
        if (!$row.length) return '';
        var $item = $row.find('.textBox, .selectBox, .radioBox.checked, .checkBox').first();
        if (!$item.length) return '';
        if ($item.hasClass('textBox')) return $item.val() || '';
        if ($item.hasClass('selectBox')) return $item.attr('data-value') || '';
        if ($item.hasClass('radioBox')) return $item.attr('data-value') || '';
        if ($item.hasClass('checkBox')) return $item.hasClass('checked');
        return '';
    }

    function config() {
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

    function backupKey() {
        return String($s3().find(".flexContainer[data-id='filePath'] .textBox").first().val() || '').trim();
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
        return $.ajax({ url: '/Management.aspx?type=ThirdPartyAuthorization', method: 'GET', dataType: 'html', cache: false })
            .then(function (html) {
                var resolved = $.extend({}, cfg);
                if (!resolved.acesskey) resolved.acesskey = readSavedKeyFromManagement(html, 'acesskey');
                if (!resolved.secretaccesskey) resolved.secretaccesskey = readSavedKeyFromManagement(html, 'secretaccesskey');
                if (!resolved.acesskey || !resolved.secretaccesskey) throw new Error('Saved S3Compatible access/secret keys were not found in Third-Party Services.');
                return resolved;
            });
    }

    function requestErrorMessage(error, fallback) {
        if (error && error.responseJSON && error.responseJSON.message) return error.responseJSON.message;
        if (error && error.responseText) return error.responseText;
        if (error && error.message) return error.message;
        return fallback;
    }

    function formatBytes(value) {
        var n = Number(value || 0);
        if (!n) return '0 B';
        var units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
        var i = Math.min(units.length - 1, Math.floor(Math.log(n) / Math.log(1024)));
        return (n / Math.pow(1024, i)).toFixed(i >= 3 ? 2 : 1) + ' ' + units[i];
    }

    function setStatus(text, kind) {
        var $status = $s3().find('.ocsp-tar-status');
        $status.text(text || '');
        $status.css('font-weight', kind === 'error' || kind === 'ok' ? '600' : 'normal');
        if (kind === 'error') $status.css('color', '#c4473a');
        else if (kind === 'ok') $status.css('color', '#4a8f29');
        else $status.css('color', '');
    }

    function ensureTools() {
        var $storage = $s3();
        if (!$storage.length || $storage.find('.ocsp-tar-browser').length) return;
        var $restoreTools = $storage.find('.ocsp-s3-restore-tools').first();
        if (!$restoreTools.length) return;

        var html = '' +
          '<div class="ocsp-tar-browser" style="margin:16px 0;padding:12px;border-top:1px solid #ddd;">' +
            '<div style="font-weight:600;margin-bottom:6px;">Inspect backup archive / recover one file</div>' +
            '<div style="margin-bottom:8px;">Streams the selected .tar.gz directly from S3. The full archive is not saved locally. Because this is one gzip stream, a scan or recovery may need to read from the start of the backup.</div>' +
            '<button type="button" class="button blue ocsp-tar-scan">Inspect selected backup</button>' +
            '<span class="ocsp-tar-status" style="margin-left:10px;"></span>' +
            '<div class="ocsp-tar-progress" style="margin-top:8px;display:none;"></div>' +
            '<div class="ocsp-tar-results" style="margin-top:12px;display:none;">' +
              '<div style="margin-bottom:6px;">' +
                '<input type="text" class="ocsp-tar-query" placeholder="search path / filename" style="min-width:360px;height:26px;" />' +
                '<button type="button" class="button ocsp-tar-search" style="margin-left:6px;">Search scanned entries</button>' +
              '</div>' +
              '<select class="ocsp-tar-entry-select" size="12" style="width:100%;min-height:220px;"></select>' +
              '<div class="ocsp-tar-entry-details" style="margin:8px 0;"></div>' +
              '<button type="button" class="button blue ocsp-tar-recover disabled">Recover selected file</button>' +
              '<span class="ocsp-tar-recover-status" style="margin-left:10px;"></span>' +
            '</div>' +
          '</div>';
        $restoreTools.after(html);
    }

    function clearTimers() {
        if (scanTimer) { clearTimeout(scanTimer); scanTimer = null; }
        if (extractTimer) { clearTimeout(extractTimer); extractTimer = null; }
    }

    function reset() {
        clearTimers();
        scanId = null;
        extractId = null;
        selectedEntry = null;
        $s3().find('.ocsp-tar-progress').hide().text('');
        $s3().find('.ocsp-tar-results').hide();
        $s3().find('.ocsp-tar-entry-select').empty();
        $s3().find('.ocsp-tar-entry-details').text('');
        $s3().find('.ocsp-tar-recover').addClass('disabled');
        $s3().find('.ocsp-tar-recover-status').text('');
        setStatus('', 'info');
    }

    function populateEntries(entries) {
        var $select = $s3().find('.ocsp-tar-entry-select');
        $select.empty();
        (entries || []).forEach(function (entry) {
            if (!entry.regular) return;
            $('<option/>')
                .attr('value', entry.name)
                .attr('data-size', entry.size)
                .text(entry.name + ' — ' + formatBytes(entry.size))
                .appendTo($select);
        });
        $s3().find('.ocsp-tar-results').show();
    }

    function pollScan() {
        if (!scanId) return;
        apiService.get('backup/ocspS3TarScanStatus?id=' + encodeURIComponent(scanId))
            .done(function (response) {
                if (!response || !response.success) return;
                var data = response.data || {};
                $s3().find('.ocsp-tar-progress').show().text(
                    'Archive stream: ' + (data.progress || 0) + '% — ' + formatBytes(data.compressedRead) +
                    (data.compressedTotal ? ' / ' + formatBytes(data.compressedTotal) : '') +
                    ' — entries ' + (data.entries || 0) + ' — files ' + (data.files || 0) +
                    (data.lastEntry ? ' — last: ' + data.lastEntry : '')
                );
                if (data.preview && data.preview.length) populateEntries(data.preview);
                if (data.state === 'completed') {
                    setStatus('Archive scan complete. Search the manifest or select one of the recent files.', 'ok');
                    return;
                }
                if (data.state === 'error') {
                    setStatus(data.error || 'Archive scan failed.', 'error');
                    return;
                }
                scanTimer = setTimeout(pollScan, 2000);
            })
            .fail(function (error) { setStatus(requestErrorMessage(error, 'Archive scan status failed.'), 'error'); });
    }

    function startScan() {
        var cfg = config();
        var key = backupKey();
        if (!cfg.bucket || !key) { window.toastr.error('Select and verify an S3-compatible backup first.'); return; }
        reset();
        setStatus('HEAD-verifying selected backup before streaming its TAR index…', 'info');
        resolveCredentials(cfg)
            .then(function (resolved) {
                return apiService.post('backup/ocspS3HeadBackup', { config: resolved, bucket: cfg.bucket, key: key })
                    .then(function (headResponse) {
                        if (!headResponse || !headResponse.success) throw new Error((headResponse && headResponse.message) || 'Backup HEAD failed.');
                        setStatus('Starting streaming TAR inspection…', 'info');
                        return apiService.post('backup/ocspS3TarScanStart', { config: resolved, bucket: cfg.bucket, key: key });
                    });
            })
            .done(function (response) {
                if (!response || !response.success || !response.data || !response.data.id) { setStatus((response && response.message) || 'Could not start archive scan.', 'error'); return; }
                scanId = response.data.id;
                pollScan();
            })
            .fail(function (error) { setStatus(requestErrorMessage(error, 'Could not start archive scan.'), 'error'); });
    }

    function searchEntries() {
        if (!scanId) { window.toastr.error('Start archive inspection first.'); return; }
        var query = String($s3().find('.ocsp-tar-query').val() || '').trim();
        setStatus('Searching entries already scanned…', 'info');
        apiService.post('backup/ocspS3TarSearch', { id: scanId, query: query })
            .done(function (response) {
                if (!response || !response.success) { setStatus((response && response.message) || 'Archive search failed.', 'error'); return; }
                var results = (response.data && response.data.results) || [];
                populateEntries(results);
                setStatus('Found ' + results.length + ' matching file' + (results.length === 1 ? '' : 's') + ' in the scanned manifest.', results.length ? 'ok' : 'info');
            })
            .fail(function (error) { setStatus(requestErrorMessage(error, 'Archive search failed.'), 'error'); });
    }

    function selectEntry() {
        var $opt = $s3().find('.ocsp-tar-entry-select option:selected');
        if (!$opt.length) return;
        selectedEntry = { name: $opt.val(), size: Number($opt.attr('data-size') || 0) };
        $s3().find('.ocsp-tar-entry-details').text(selectedEntry.name + ' — ' + formatBytes(selectedEntry.size));
        $s3().find('.ocsp-tar-recover').removeClass('disabled');
        $s3().find('.ocsp-tar-recover-status').text('');
    }

    function pollExtract() {
        if (!extractId) return;
        apiService.get('backup/ocspS3TarExtractStatus?id=' + encodeURIComponent(extractId))
            .done(function (response) {
                if (!response || !response.success) return;
                var data = response.data || {};
                $s3().find('.ocsp-tar-recover-status').text(
                    'Scanning archive ' + (data.scanProgress || 0) + '% — recovered ' + formatBytes(data.written) +
                    (data.expectedSize ? ' / ' + formatBytes(data.expectedSize) : '')
                );
                if (data.state === 'ready') {
                    var $status = $s3().find('.ocsp-tar-recover-status');
                    $status.empty();
                    $('<a/>')
                        .attr('href', '/backup/ocspS3TarDownload?id=' + encodeURIComponent(extractId))
                        .text('Download recovered ' + (data.outputName || 'file'))
                        .appendTo($status);
                    return;
                }
                if (data.state === 'error') {
                    $s3().find('.ocsp-tar-recover-status').text(data.error || 'Single-file recovery failed.');
                    return;
                }
                extractTimer = setTimeout(pollExtract, 2000);
            })
            .fail(function (error) { $s3().find('.ocsp-tar-recover-status').text(requestErrorMessage(error, 'Recovery status failed.')); });
    }

    function recoverSelected() {
        if (!selectedEntry || $s3().find('.ocsp-tar-recover').hasClass('disabled')) return;
        var cfg = config();
        var key = backupKey();
        if (!cfg.bucket || !key) { window.toastr.error('Selected backup is no longer available in the form.'); return; }
        $s3().find('.ocsp-tar-recover').addClass('disabled');
        $s3().find('.ocsp-tar-recover-status').text('Starting single-file recovery. The gzip stream must be read from the beginning…');
        resolveCredentials(cfg)
            .then(function (resolved) {
                return apiService.post('backup/ocspS3TarExtractStart', {
                    config: resolved, bucket: cfg.bucket, key: key, entryName: selectedEntry.name, size: selectedEntry.size
                });
            })
            .done(function (response) {
                if (!response || !response.success || !response.data || !response.data.id) {
                    $s3().find('.ocsp-tar-recover-status').text((response && response.message) || 'Could not start recovery.');
                    $s3().find('.ocsp-tar-recover').removeClass('disabled');
                    return;
                }
                extractId = response.data.id;
                pollExtract();
            })
            .fail(function (error) {
                $s3().find('.ocsp-tar-recover-status').text(requestErrorMessage(error, 'Could not start recovery.'));
                $s3().find('.ocsp-tar-recover').removeClass('disabled');
            });
    }

    function bindEvents() {
        var $v = $view();
        $v.off('.ocspTarBrowser');
        $v.on('click.ocspTarBrowser', '.ocsp-tar-scan', startScan);
        $v.on('click.ocspTarBrowser', '.ocsp-tar-search', searchEntries);
        $v.on('change.ocspTarBrowser', '.ocsp-tar-entry-select', selectEntry);
        $v.on('click.ocspTarBrowser', '.ocsp-tar-recover', recoverSelected);
        $v.on('input.ocspTarBrowser change.ocspTarBrowser', "#consumerStorageSettingsBox div.storage[data-id='S3Compatible'] .textBox", function () {
            var key = $(this).closest('.flexContainer').attr('data-id');
            if (key === 'filePath' || key === 'bucket' || key === 'serviceurl' || key === 'region') reset();
        });
        $v.on('change.ocspTarBrowser', '#consumerStorageSettingsBox .ocsp-profile-select, .ocsp-s3-restore-backup-select, .ocsp-s3-restore-bucket-select', function () { reset(); });
    }

    function init() {
        ensureTools();
        if (!initialised) { bindEvents(); initialised = true; }
    }

    return { init: init, reset: reset };
})($, window.ApiService);
