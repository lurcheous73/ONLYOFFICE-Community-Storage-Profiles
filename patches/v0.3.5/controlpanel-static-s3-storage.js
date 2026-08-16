/* OCSP v0.3.5 — S3-compatible static-storage bucket picker and safety gate. */
window.OCSPStaticS3Storage = (function ($, apiService) {
    'use strict';

    var connectionFingerprint = null;
    var validatedFingerprint = null;
    var initialised = false;
    var busy = false;

    function $view() { return $('.storageView'); }
    function $box() { return $view().find('#storageSettingsBox'); }
    function $s3() { return $box().find("div.storage[data-id='S3Compatible']"); }
    function $connect() { return $view().find('#storageButton'); }

    function active() {
        return $box().find('.thirdSelectStorage .radioBox.checked').attr('data-value') === 'S3Compatible';
    }

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

    function validationKey(cfg) {
        return connectionKey(cfg) + '\n' + cfg.bucket;
    }

    function connectionCurrent() {
        return connectionFingerprint !== null && connectionFingerprint === connectionKey(currentConfig());
    }

    function validationCurrent() {
        return validatedFingerprint !== null && validatedFingerprint === validationKey(currentConfig());
    }

    function setStatus(text, kind) {
        var $status = $s3().find('.ocsp-static-s3-status');
        $status.text(text || '');
        $status.css('font-weight', kind === 'ok' || kind === 'error' ? '600' : 'normal');
        if (kind === 'ok') $status.css('color', '#4a8f29');
        else if (kind === 'error') $status.css('color', '#c4473a');
        else $status.css('color', '');
    }

    function gateConnect() {
        var $btn = $connect();
        if (active() && !validationCurrent()) {
            if (!$btn.attr('data-ocsp-static-gated')) {
                $btn.attr('data-ocsp-static-gated', '1');
                $btn.attr('data-ocsp-static-pre-disabled', $btn.hasClass('disabled') ? '1' : '0');
            }
            $btn.addClass('disabled');
            return;
        }
        if ($btn.attr('data-ocsp-static-gated')) {
            if ($btn.attr('data-ocsp-static-pre-disabled') !== '1') $btn.removeClass('disabled');
            $btn.removeAttr('data-ocsp-static-gated data-ocsp-static-pre-disabled');
        }
    }

    function resetValidation(message) {
        validatedFingerprint = null;
        if (message && active()) setStatus(message, 'info');
        gateConnect();
    }

    function resetConnection(message) {
        connectionFingerprint = null;
        validatedFingerprint = null;
        $s3().find('.ocsp-static-s3-bucket-tools').hide();
        if (message && active()) setStatus(message, 'info');
        gateConnect();
    }

    function bucketInput() {
        return $s3().find(".flexContainer[data-id='bucket'] .textBox").first();
    }

    function applyBucket(bucket) {
        bucketInput().val(bucket || '');
        resetValidation(bucket ? 'Bucket selected — validate it before CONNECT.' : 'Select a bucket.');
    }

    function populateBuckets(buckets) {
        var $select = $s3().find('.ocsp-static-s3-bucket-select');
        var current = String(bucketInput().val() || '').trim();
        $select.empty();
        $('<option/>').attr('value', '').text('-- Select bucket --').appendTo($select);
        (buckets || []).forEach(function (bucket) {
            $('<option/>').attr('value', bucket).text(bucket).appendTo($select);
        });
        $select.val(current && (buckets || []).indexOf(current) >= 0 ? current : '');
    }

    function ensureTools() {
        var $storage = $s3();
        if (!$storage.length) return;

        $storage.find(".flexContainer[data-id='backupchunksize']").hide();
        $storage.find(".flexContainer[data-id='disabledefaultchecksumvalidation']").hide();

        if ($storage.find('.ocsp-static-s3-tools').length) return;
        var $bucketRow = $storage.find(".flexContainer[data-id='bucket']").first();
        if (!$bucketRow.length) return;

        var html = '' +
            '<div class="ocsp-static-s3-tools" style="margin:12px 0 16px 0;">' +
              '<div style="margin-bottom:8px;">' +
                '<button type="button" class="button blue ocsp-static-s3-check">Check connection & fetch buckets</button>' +
                '<span class="ocsp-static-s3-status" style="margin-left:10px;"></span>' +
              '</div>' +
              '<div class="ocsp-static-s3-bucket-tools" style="display:none;">' +
                '<div style="margin:8px 0;">' +
                  '<select class="ocsp-static-s3-bucket-select" style="min-width:340px;height:30px;"></select>' +
                  '<button type="button" class="button ocsp-static-s3-refresh" style="margin-left:6px;">Refresh buckets</button>' +
                '</div>' +
                '<div style="margin:8px 0;">' +
                  '<input type="text" class="ocsp-static-s3-new-bucket" placeholder="new-bucket-name" style="min-width:340px;height:26px;" />' +
                  '<button type="button" class="button ocsp-static-s3-create" style="margin-left:6px;">Create bucket</button>' +
                '</div>' +
                '<div style="margin:8px 0;">' +
                  '<button type="button" class="button blue ocsp-static-s3-validate">Validate bucket (100 KiB)</button>' +
                  '<span style="margin-left:10px;">PUT → HEAD → GET/SHA-256 → DELETE → confirm gone</span>' +
                '</div>' +
                '<div style="margin-top:8px;font-size:12px;">CONNECT can migrate portal static data. This helper only validates the destination bucket; it never starts migration itself.</div>' +
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

    function checkConnection() {
        if (busy || !active()) return;
        var cfg = currentConfig();
        busy = true;
        resetConnection();
        setStatus((cfg.acesskey && cfg.secretaccesskey) ? 'Checking endpoint and fetching buckets…' : 'Loading saved S3Compatible keys and fetching buckets…', 'info');
        resolveCredentials(cfg)
            .then(function (resolved) { return apiService.post('backup/ocspS3ListBuckets', { config: resolved }); })
            .done(function (response) {
                if (!response || !response.success) {
                    setStatus((response && response.message) || 'Connection check failed.', 'error');
                    return;
                }
                connectionFingerprint = connectionKey(currentConfig());
                validatedFingerprint = null;
                populateBuckets((response.data && response.data.buckets) || []);
                $s3().find('.ocsp-static-s3-bucket-tools').show();
                setStatus(response.data && response.data.listDenied ? (response.data.message || 'Bucket listing denied; enter a known bucket manually.') : 'Connection OK — choose or create a bucket.', response.data && response.data.listDenied ? 'info' : 'ok');
                gateConnect();
            })
            .fail(function (error) { setStatus(requestErrorMessage(error, 'Connection check failed.'), 'error'); })
            .always(function () { busy = false; });
    }

    function createBucket() {
        if (busy || !active()) return;
        if (!connectionCurrent()) { window.toastr.error('Check the connection before creating a bucket.'); return; }
        var bucket = String($s3().find('.ocsp-static-s3-new-bucket').val() || '').trim();
        if (!bucket) { window.toastr.error('Enter a new bucket name.'); return; }
        var cfg = currentConfig();
        busy = true;
        setStatus('Creating bucket ' + bucket + '…', 'info');
        resolveCredentials(cfg)
            .then(function (resolved) { return apiService.post('backup/ocspS3CreateBucket', { config: resolved, bucket: bucket }); })
            .done(function (response) {
                if (!response || !response.success) { setStatus((response && response.message) || 'Bucket creation failed.', 'error'); return; }
                var $select = $s3().find('.ocsp-static-s3-bucket-select');
                if (!$select.find('option').filter(function(){ return $(this).val() === bucket; }).length) $('<option/>').attr('value', bucket).text(bucket).appendTo($select);
                $select.val(bucket);
                $s3().find('.ocsp-static-s3-new-bucket').val('');
                applyBucket(bucket);
                setStatus('Bucket created and selected — validate it before CONNECT.', 'ok');
            })
            .fail(function (error) { setStatus(requestErrorMessage(error, 'Bucket creation failed.'), 'error'); })
            .always(function () { busy = false; });
    }

    function validateBucket() {
        if (busy || !active()) return;
        if (!connectionCurrent()) { window.toastr.error('Connection settings changed. Check the connection again first.'); resetConnection('Connection settings changed — check again.'); return; }
        var cfg = currentConfig();
        if (!cfg.bucket) { window.toastr.error('Select or enter a bucket first.'); return; }
        busy = true;
        validatedFingerprint = null;
        gateConnect();
        setStatus('Validating ' + cfg.bucket + ' with a disposable 100 KiB object…', 'info');
        resolveCredentials(cfg)
            .then(function (resolved) { return apiService.post('backup/ocspS3ValidateBucket', { config: resolved, bucket: cfg.bucket }); })
            .done(function (response) {
                if (!response || !response.success) { setStatus((response && response.message) || 'Bucket validation failed.', 'error'); return; }
                validatedFingerprint = validationKey(currentConfig());
                setStatus('Bucket validated. CONNECT is unlocked — pressing CONNECT will start ONLYOFFICE storage migration.', 'ok');
                gateConnect();
            })
            .fail(function (error) { setStatus(requestErrorMessage(error, 'Bucket validation failed.'), 'error'); gateConnect(); })
            .always(function () { busy = false; });
    }

    function bindEvents() {
        var $v = $view();
        $v.off('.ocspStaticS3');
        $v.on('click.ocspStaticS3', '.ocsp-static-s3-check', checkConnection);
        $v.on('click.ocspStaticS3', '.ocsp-static-s3-refresh', checkConnection);
        $v.on('click.ocspStaticS3', '.ocsp-static-s3-create', createBucket);
        $v.on('click.ocspStaticS3', '.ocsp-static-s3-validate', validateBucket);
        $v.on('change.ocspStaticS3', '.ocsp-static-s3-bucket-select', function () { applyBucket($(this).val() || ''); });
        $v.on('input.ocspStaticS3 change.ocspStaticS3', "#storageSettingsBox div.storage[data-id='S3Compatible'] .textBox", function () {
            var key = $(this).closest('.flexContainer').attr('data-id');
            if (key === 'backupchunksize' || key === 'disabledefaultchecksumvalidation') return;
            if (key === 'bucket') resetValidation('Bucket changed — validate it before CONNECT.');
            else resetConnection('Connection settings changed — check again.');
        });
        $v.on('change.ocspStaticS3', '#storageSettingsBox .ocsp-profile-select', function () {
            setTimeout(function () { resetConnection('Provider changed — check the connection.'); }, 0);
        });
    }

    function sync() {
        ensureTools();
        if (active()) $s3().find('.ocsp-static-s3-tools').show();
        gateConnect();
    }

    function init() {
        if (!initialised) { bindEvents(); initialised = true; }
        sync();
    }

    function canConnect() {
        if (!active()) return true;
        return validationCurrent();
    }

    function warn() {
        if (active() && !validationCurrent()) window.toastr.error('Fetch the S3-compatible buckets and validate the selected bucket before CONNECT.');
    }

    return { init: init, sync: sync, canConnect: canConnect, warn: warn };
})($, window.ApiService);
