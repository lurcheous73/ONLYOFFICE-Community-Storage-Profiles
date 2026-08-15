/* OCSP v0.3.4.2 — manual S3-compatible backup connection/bucket gate. */
window.OCSPManualS3Backup = (function ($, apiService) {
    'use strict';

    var connectionFingerprint = null;
    var validatedFingerprint = null;
    var initialised = false;
    var busy = false;

    function $backupBox() { return $('#backupView #backupBox'); }
    function $consumerBox() { return $('#backupView #backupConsumerStorageSettingsBox'); }
    function $s3() { return $consumerBox().find("div.storage[data-id='S3Compatible']"); }
    function $startButton() { return $backupBox().find('#startBackupBtn'); }

    function active() {
        var storageType = $backupBox().find('#backupStorageBox .selectButton.checked').attr('data-value');
        var consumer = $consumerBox().find('.thirdSelectStorageFlexbox .radioBox.checked').attr('data-value');
        return String(storageType) === '5' && consumer === 'S3Compatible';
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
        var $status = $s3().find('.ocsp-s3-manual-status');
        $status.text(text || '');
        $status.css('font-weight', kind === 'ok' || kind === 'error' ? '600' : 'normal');
        if (kind === 'ok') $status.css('color', '#4a8f29');
        else if (kind === 'error') $status.css('color', '#c4473a');
        else $status.css('color', '');
    }

    function gateStart() {
        var $btn = $startButton();
        if (active() && !validationCurrent()) {
            if (!$btn.attr('data-ocsp-gated')) {
                $btn.attr('data-ocsp-gated', '1');
                $btn.attr('data-ocsp-pre-disabled', $btn.hasClass('disabled') ? '1' : '0');
            }
            $btn.addClass('disabled');
            return;
        }

        if ($btn.attr('data-ocsp-gated')) {
            if ($btn.attr('data-ocsp-pre-disabled') !== '1') {
                $btn.removeClass('disabled');
            }
            $btn.removeAttr('data-ocsp-gated data-ocsp-pre-disabled');
        }
    }

    function resetValidation(message) {
        validatedFingerprint = null;
        if (message && active()) setStatus(message, 'info');
        gateStart();
    }

    function resetConnection(message) {
        connectionFingerprint = null;
        validatedFingerprint = null;
        $s3().find('.ocsp-s3-bucket-tools').hide();
        if (message && active()) setStatus(message, 'info');
        gateStart();
    }

    function originalBucketInput() {
        return $s3().find(".flexContainer[data-id='bucket'] .textBox").first();
    }

    function applyBucket(bucket) {
        originalBucketInput().val(bucket || '');
        resetValidation(bucket ? 'Bucket selected — validate it before backup.' : 'Select a bucket.');
    }

    function populateBuckets(buckets) {
        var $select = $s3().find('.ocsp-s3-bucket-select');
        var current = String(originalBucketInput().val() || '').trim();
        $select.empty();
        $('<option/>').attr('value', '').text('-- Select bucket --').appendTo($select);

        (buckets || []).forEach(function (bucket) {
            $('<option/>').attr('value', bucket).text(bucket).appendTo($select);
        });

        if (current && (buckets || []).indexOf(current) >= 0) {
            $select.val(current);
        } else {
            $select.val('');
        }
    }

    function ensureTools() {
        var $storage = $s3();
        if (!$storage.length) return;

        // Internal backend compatibility values are not user-editable controls.
        $storage.find(".flexContainer[data-id='backupchunksize']").hide();
        $storage.find(".flexContainer[data-id='disabledefaultchecksumvalidation']").hide();

        if ($storage.find('.ocsp-s3-manual-tools').length) return;

        var $bucketRow = $storage.find(".flexContainer[data-id='bucket']").first();
        if (!$bucketRow.length) return;

        var html = '' +
            '<div class="ocsp-s3-manual-tools" style="margin:12px 0 16px 0;">' +
              '<div style="margin-bottom:8px;">' +
                '<button type="button" class="button blue ocsp-s3-check">Check connection & fetch buckets</button>' +
                '<span class="ocsp-s3-manual-status" style="margin-left:10px;"></span>' +
              '</div>' +
              '<div class="ocsp-s3-bucket-tools" style="display:none;">' +
                '<div style="margin:8px 0;">' +
                  '<select class="ocsp-s3-bucket-select" style="min-width:320px;height:30px;"></select>' +
                  '<button type="button" class="button ocsp-s3-refresh" style="margin-left:6px;">Refresh buckets</button>' +
                '</div>' +
                '<div style="margin:8px 0;">' +
                  '<input type="text" class="ocsp-s3-new-bucket" placeholder="new-bucket-name" style="min-width:320px;height:26px;" />' +
                  '<button type="button" class="button ocsp-s3-create" style="margin-left:6px;">Create bucket</button>' +
                '</div>' +
                '<div style="margin:8px 0;">' +
                  '<button type="button" class="button blue ocsp-s3-validate">Validate bucket (100 KiB)</button>' +
                  '<span style="margin-left:10px;">PUT → HEAD → GET/SHA-256 → DELETE → confirm gone</span>' +
                '</div>' +
              '</div>' +
            '</div>';

        $bucketRow.after(html);
    }

    function requireConfig(requireBucket) {
        var cfg = currentConfig();
        if (requireBucket && !cfg.bucket) {
            window.toastr.error('Select or enter a bucket first.');
            return null;
        }
        return cfg;
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
        if (cfg.acesskey && cfg.secretaccesskey) {
            return $.Deferred().resolve(cfg).promise();
        }

        return $.ajax({
            url: '/Management.aspx?type=ThirdPartyAuthorization',
            method: 'GET',
            dataType: 'html',
            cache: false
        }).then(function (html) {
            var resolved = $.extend({}, cfg);
            if (!resolved.acesskey) {
                resolved.acesskey = readSavedKeyFromManagement(html, 'acesskey');
            }
            if (!resolved.secretaccesskey) {
                resolved.secretaccesskey = readSavedKeyFromManagement(html, 'secretaccesskey');
            }

            if (!resolved.acesskey || !resolved.secretaccesskey) {
                throw new Error('Saved S3Compatible access/secret keys were not found in Third-Party Services.');
            }
            return resolved;
        });
    }

    function showBucketTools(data) {
        ensureTools();
        populateBuckets(data.buckets || []);
        $s3().find('.ocsp-s3-bucket-tools').show();
        if (data.listDenied) {
            setStatus(data.message || 'Bucket listing denied; enter a known bucket and validate it.', 'info');
        } else {
            setStatus('Connection OK — buckets fetched. Choose or create a bucket.', 'ok');
        }
    }

    function requestErrorMessage(error, fallback) {
        if (error && error.responseJSON && error.responseJSON.message) return error.responseJSON.message;
        if (error && error.responseText) return error.responseText;
        if (error && error.message) return error.message;
        return fallback;
    }

    function checkConnection() {
        if (busy || !active()) return;
        var cfg = requireConfig(false);
        if (!cfg) return;

        busy = true;
        resetConnection();
        setStatus((cfg.acesskey && cfg.secretaccesskey)
            ? 'Checking endpoint and credentials…'
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
                validatedFingerprint = null;
                showBucketTools(response.data || {});
                gateStart();
            })
            .fail(function (error) {
                setStatus(requestErrorMessage(error, 'Connection check failed.'), 'error');
            })
            .always(function () { busy = false; });
    }

    function refreshBuckets() {
        if (busy || !active()) return;
        if (!connectionCurrent()) {
            window.toastr.error('Connection settings changed. Check the connection again first.');
            resetConnection('Connection settings changed — check again.');
            return;
        }
        checkConnection();
    }

    function createBucket() {
        if (busy || !active()) return;
        if (!connectionCurrent()) {
            window.toastr.error('Check the connection before creating a bucket.');
            return;
        }

        var bucket = String($s3().find('.ocsp-s3-new-bucket').val() || '').trim();
        if (!bucket) {
            window.toastr.error('Enter a new bucket name.');
            return;
        }

        var cfg = requireConfig(false);
        if (!cfg) return;
        busy = true;
        setStatus('Creating bucket ' + bucket + '…', 'info');

        resolveCredentials(cfg)
            .then(function (resolved) {
                return apiService.post('backup/ocspS3CreateBucket', { config: resolved, bucket: bucket });
            })
            .done(function (response) {
                if (!response || !response.success) {
                    setStatus((response && response.message) || 'Bucket creation failed.', 'error');
                    return;
                }

                var $select = $s3().find('.ocsp-s3-bucket-select');
                if (!$select.find('option[value="' + bucket.replace(/"/g, '\\"') + '"]').length) {
                    $('<option/>').attr('value', bucket).text(bucket).appendTo($select);
                }
                $select.val(bucket);
                $s3().find('.ocsp-s3-new-bucket').val('');
                applyBucket(bucket);
                setStatus('Bucket created and selected — validate it before backup.', 'ok');
            })
            .fail(function (error) {
                setStatus(requestErrorMessage(error, 'Bucket creation failed.'), 'error');
            })
            .always(function () { busy = false; });
    }

    function validateBucket() {
        if (busy || !active()) return;
        if (!connectionCurrent()) {
            window.toastr.error('Connection settings changed. Check the connection again first.');
            resetConnection('Connection settings changed — check again.');
            return;
        }

        var cfg = requireConfig(true);
        if (!cfg) return;
        busy = true;
        validatedFingerprint = null;
        gateStart();
        setStatus('Validating ' + cfg.bucket + ' with a disposable 100 KiB object…', 'info');

        resolveCredentials(cfg)
            .then(function (resolved) {
                return apiService.post('backup/ocspS3ValidateBucket', { config: resolved, bucket: cfg.bucket });
            })
            .done(function (response) {
                if (!response || !response.success) {
                    setStatus((response && response.message) || 'Bucket validation failed.', 'error');
                    return;
                }

                validatedFingerprint = validationKey(currentConfig());
                setStatus('Bucket validated: write/read/SHA-256/delete all passed. Make Backup is unlocked.', 'ok');
                gateStart();
            })
            .fail(function (error) {
                setStatus(requestErrorMessage(error, 'Bucket validation failed.'), 'error');
                gateStart();
            })
            .always(function () { busy = false; });
    }

    function bindEvents() {
        var $view = $('#backupView');
        $view.off('.ocspManualS3');

        $view.on('click.ocspManualS3', '.ocsp-s3-check', checkConnection);
        $view.on('click.ocspManualS3', '.ocsp-s3-refresh', refreshBuckets);
        $view.on('click.ocspManualS3', '.ocsp-s3-create', createBucket);
        $view.on('click.ocspManualS3', '.ocsp-s3-validate', validateBucket);

        $view.on('change.ocspManualS3', '.ocsp-s3-bucket-select', function () {
            applyBucket($(this).val() || '');
        });

        $view.on('input.ocspManualS3 change.ocspManualS3',
            "#backupConsumerStorageSettingsBox div.storage[data-id='S3Compatible'] .textBox",
            function () {
                var key = $(this).closest('.flexContainer').attr('data-id');
                if (key === 'backupchunksize' || key === 'disabledefaultchecksumvalidation') return;
                if (key === 'bucket') resetValidation('Bucket changed — validate it before backup.');
                else resetConnection('Connection settings changed — check again.');
            });

        $view.on('valueChanged.ocspManualS3',
            "#backupConsumerStorageSettingsBox div.storage[data-id='S3Compatible'] .selectBox",
            function () { resetConnection('Connection settings changed — check again.'); });

        $view.on('click.ocspManualS3',
            "#backupConsumerStorageSettingsBox div.storage[data-id='S3Compatible'] .checkBox",
            function () {
                setTimeout(function () { resetConnection('Connection settings changed — check again.'); }, 0);
            });

        $view.on('change.ocspManualS3',
            '#backupConsumerStorageSettingsBox .ocsp-profile-select',
            function () {
                setTimeout(function () { resetConnection('Provider changed — check the connection.'); }, 0);
            });
    }

    function sync() {
        ensureTools();
        if (active()) {
            $s3().find('.ocsp-s3-manual-tools').show();
        }
        gateStart();
    }

    function init() {
        if (!initialised) {
            bindEvents();
            initialised = true;
        }
        sync();
    }

    function canStart() {
        if (!active()) return true;
        return validationCurrent();
    }

    function warn() {
        if (active() && !validationCurrent()) {
            window.toastr.error('Check the S3-compatible connection and validate the selected bucket before starting this backup.');
        }
    }

    return {
        init: init,
        sync: sync,
        canStart: canStart,
        warn: warn
    };
})($, window.ApiService);
