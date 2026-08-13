#!/usr/bin/env bash
set -euo pipefail

# ONLYOFFICE Community Storage Profiles — v0.3.1
# Provider dropdown + non-secret preset autofill. Requires v0.3.
# No credential reads, no updateStorage call, no migration.

COMM="${OCSP_COMMUNITY_CONTAINER:-onlyoffice-community-server}"
CP="${OCSP_CONTROL_PANEL_CONTAINER:-onlyoffice-control-panel}"
STATE_DIR="/var/lib/onlyoffice-community-storage-profiles"
BACKUP_ROOT="/var/backups/onlyoffice-community-storage-profiles"
V03_STATE="$STATE_DIR/storage-profiles-v0.3.state"
STATE_FILE="$STATE_DIR/storage-profiles-v0.3.1.state"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
LOCAL_CATALOGUE="$REPO_DIR/profiles/runtime-s3-catalogue.json"

CP_STORAGE_JS="/var/www/onlyoffice/controlpanel/www/public/javascripts/views/storage.js"
CP_PARTIAL="/var/www/onlyoffice/controlpanel/www/views/consumerSettingsPartial.pug"
CP_CATALOGUE="/var/www/onlyoffice/controlpanel/www/public/resources/ocsp-s3-providers.json"
AUTH_JS_REL="UserControls/Management/AuthorizationKeys/js/authorizationkeys.js"
ROOTS=(WebStudio WebStudio2 WebStudio3 WebStudio4)
V03_CP_MARKER='OCSP v0.3 S3Compatible Control Panel'
V031_CP_MARKER='OCSP v0.3.1 provider catalogue'
V03_AUTH_MARKER='OCSP v0.3 S3Compatible presentation'
V031_AUTH_MARKER='OCSP v0.3.1 delayed presentation'
TMP_DIR=""

say(){ printf '%s\n' "$*"; }
die(){ say "ERROR: $*" >&2; exit 1; }
cleanup(){ [ -n "${TMP_DIR:-}" ] && [ -d "$TMP_DIR" ] && rm -rf -- "$TMP_DIR" || true; }
trap cleanup EXIT

banner(){
  cat <<'EOF'
====================================================================
 ONLYOFFICE Community Storage Profiles — v0.3.1
 Provider profiles
====================================================================
EOF
}

need(){ command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }
meta_in(){ docker exec "$1" stat -c '%u:%g:%a' "$2"; }
restore_meta(){
  local c="$1" p="$2" m="$3" uid gid mode rest
  uid="${m%%:*}"; rest="${m#*:}"; gid="${rest%%:*}"; mode="${rest##*:}"
  docker exec "$c" chown "$uid:$gid" "$p"
  docker exec "$c" chmod "$mode" "$p"
}
wait_container(){
  local c="$1" i
  for i in $(seq 1 90); do
    if [ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null || true)" = true ] && docker exec "$c" true >/dev/null 2>&1; then return 0; fi
    sleep 2
  done
  die "$c did not return to running state"
}
auth_files(){
  local root p
  for root in "${ROOTS[@]}"; do
    p="/var/www/onlyoffice/$root/$AUTH_JS_REL"
    docker exec "$COMM" test -f "$p" >/dev/null 2>&1 && printf '%s\n' "$p"
  done
}
backup_file(){
  local c="$1" label="$2" path="$3" backup="$4" meta dst
  meta="$(meta_in "$c" "$path")"
  dst="$backup/$label$path"
  mkdir -p "$(dirname "$dst")"
  docker cp "$c:$path" "$dst" >/dev/null
  chmod 600 "$dst"
  printf 'RESTORE\t%s\t%s\t%s\n' "$label" "$path" "$meta" >>"$backup/manifest.tsv"
}

preflight(){
  need docker; need python3
  [ -f "$V03_STATE" ] || die "v0.3 state not found; install v0.3 first"
  [ ! -f "$STATE_FILE" ] || die "v0.3.1 already installed; use status or rollback"
  [ -f "$LOCAL_CATALOGUE" ] || die "runtime catalogue missing: $LOCAL_CATALOGUE"
  docker exec "$CP" grep -Fq "$V03_CP_MARKER" "$CP_STORAGE_JS" || die "expected v0.3 Control Panel base patch missing"
  docker exec "$CP" test -f "$CP_PARTIAL" || die "consumerSettingsPartial.pug missing"
  mapfile -t AUTH_FILES < <(auth_files)
  [ "${#AUTH_FILES[@]}" -gt 0 ] || die "AuthorizationKeys JS not found"
  local p
  for p in "${AUTH_FILES[@]}"; do docker exec "$COMM" grep -Fq "$V03_AUTH_MARKER" "$p" || die "v0.3 auth marker missing: $p"; done
  python3 - "$LOCAL_CATALOGUE" <<'PY'
import json,re,sys
d=json.load(open(sys.argv[1],encoding='utf-8'))
assert d.get('schemaVersion')==1
assert isinstance(d.get('revision'),int) and d['revision']>=1
ps=d.get('providers'); assert isinstance(ps,list) and ps
ids=set()
for p in ps:
    assert re.fullmatch(r'[a-z0-9][a-z0-9-]*',p['id']) and p['id'] not in ids
    ids.add(p['id']); assert p.get('name')
PY
}

patch_partial(){
  python3 - "$1" "$2" <<'PY'
import sys
from pathlib import Path
src,dst=map(Path,sys.argv[1:3])
with src.open('r',encoding='utf-8',newline='') as f: text=f.read()
old='{{if name == "region" && regions.length > 0}}'
new='{{if name == "region" && regions.length > 0 && id == "S3"}}'
if text.count(old)!=1: raise SystemExit(f'expected one region condition, got {text.count(old)}')
text=text.replace(old,new,1)
with dst.open('w',encoding='utf-8',newline='') as f: f.write(text)
PY
}

patch_auth_js(){
  python3 - "$1" "$2" <<'PY'
import sys
from pathlib import Path
src,dst=map(Path,sys.argv[1:3])
with src.open('r',encoding='utf-8',newline='') as f: text=f.read()
if 'OCSP v0.3.1 delayed presentation' in text: raise SystemExit('v0.3.1 auth marker already present')
needle='        ocspDecorateS3Compatible();'
if text.count(needle)!=1: raise SystemExit(f'expected one v0.3 decorator call, got {text.count(needle)}')
replacement='''        ocspDecorateS3Compatible();\n        // OCSP v0.3.1 delayed presentation\n        setTimeout(ocspDecorateS3Compatible, 0);\n        jq("#switcherBtnS3Compatible").off("click.ocspDecorate").on("click.ocspDecorate", function () {\n            ocspDecorateS3Compatible();\n            setTimeout(ocspDecorateS3Compatible, 0);\n        });'''
text=text.replace(needle,replacement,1)
with dst.open('w',encoding='utf-8',newline='') as f: f.write(text)
PY
}

patch_storage_js(){
  python3 - "$1" "$2" <<'PY'
import re,sys
from pathlib import Path
src,dst=map(Path,sys.argv[1:3])
text=src.read_text(encoding='utf-8')
if 'OCSP v0.3.1 provider catalogue' in text: raise SystemExit('v0.3.1 marker already present')
pat=re.compile(r'    // BEGIN OCSP v0\.3 S3Compatible Control Panel\n.*?    // END OCSP v0\.3 S3Compatible Control Panel\n',re.S)
m=pat.search(text)
if not m: raise SystemExit('v0.3 helper block not found')
helper=r'''    // BEGIN OCSP v0.3 S3Compatible Control Panel
    // BEGIN OCSP v0.3.1 provider catalogue
    var ocspCatalogue = {
        schemaVersion: 1,
        revision: 0,
        catalogueVersion: "embedded-fallback",
        updated: "",
        providers: [
            { id: "mega-s4", name: "MEGA S4", defaults: { region: "g", serviceurl: "https://s3.g.megas4.com", forcepathstyle: true, usehttp: false }, objectBase: { http: "http://s3.g.megas4.com/{bucket}/", https: "https://s3.g.megas4.com/{bucket}/" } },
            { id: "wasabi", name: "Wasabi", defaults: { forcepathstyle: true, usehttp: false } },
            { id: "backblaze-b2-s3", name: "Backblaze B2 S3", defaults: { forcepathstyle: true, usehttp: false } },
            { id: "cloudflare-r2", name: "Cloudflare R2", defaults: { region: "auto", forcepathstyle: true, usehttp: false } },
            { id: "ovhcloud-object-storage", name: "OVHcloud Object Storage", defaults: { forcepathstyle: true, usehttp: false } },
            { id: "minio", name: "MinIO", defaults: { forcepathstyle: true, usehttp: false } },
            { id: "ceph-rgw", name: "Ceph RGW", defaults: { forcepathstyle: true, usehttp: false } },
            { id: "amazon-s3", name: "Amazon S3", defaults: { forcepathstyle: false, usehttp: false } },
            { id: "custom-s3", name: "Custom S3-Compatible Endpoint", defaults: {} }
        ]
    };

    function ocspDecorateStorages(storages) {
        if (!Array.isArray(storages)) return storages;
        return storages.filter(function (item) {
            if (!item) return false;
            if (item.id === "S3Compatible") item.title = "S3-Compatible Object Storage";
            if (item.id === "S3") {
                if (!item.current && !item.isSet) return false;
                item.title = "Legacy Amazon S3";
            }
            return true;
        });
    }
    function ocspFindProvider(id) {
        return (ocspCatalogue.providers || []).find(function (p) { return p.id === id; });
    }
    function ocspTemplate(value, vars) {
        if (!value) return value || "";
        return value.replace(/\{([a-zA-Z0-9_]+)\}/g, function (_, key) { return vars[key] || ""; });
    }
    function ocspText($s3, key) {
        return $s3.find("[data-id='" + key + "'] .textBox").first();
    }
    function ocspSetText($s3, key, value) {
        var $input = ocspText($s3, key);
        if ($input.length) $input.val(value == null ? "" : value).trigger("input");
    }
    function ocspSetBool($s3, key, value) {
        var $box = $s3.find("[data-id='" + key + "'] .checkBox").first();
        if ($box.length) $box.toggleClass("checked", !!value);
    }
    function ocspRecalculate($s3, provider) {
        if (!provider || provider.id === "custom-s3") return;
        var region = ocspText($s3, "region").val() || "";
        var bucket = ocspText($s3, "bucket").val() || "";
        var service = ocspText($s3, "serviceurl").val() || "";
        var vars = { region: region, bucket: bucket };
        if (Object.prototype.hasOwnProperty.call(provider, "endpointTemplate")) {
            service = ocspTemplate(provider.endpointTemplate, vars);
            ocspSetText($s3, "serviceurl", service);
        }
        if (provider.objectBase && bucket) {
            ocspSetText($s3, "cname", ocspTemplate(provider.objectBase.http, vars));
            ocspSetText($s3, "cnamessl", ocspTemplate(provider.objectBase.https, vars));
        } else if (service && bucket) {
            var clean = service.replace(/\/$/, "");
            ocspSetText($s3, "cnamessl", clean.replace(/^http:/, "https:") + "/" + bucket + "/");
            ocspSetText($s3, "cname", clean.replace(/^https:/, "http:") + "/" + bucket + "/");
        } else {
            ocspSetText($s3, "cname", "");
            ocspSetText($s3, "cnamessl", "");
        }
    }
    function ocspApplyProfile($s3, provider) {
        if (!provider) return;
        var defaults = provider.defaults || {};
        if (provider.id !== "custom-s3") {
            ["region", "serviceurl"].forEach(function (key) {
                if (Object.prototype.hasOwnProperty.call(defaults, key)) ocspSetText($s3, key, defaults[key]);
            });
            ["forcepathstyle", "usehttp"].forEach(function (key) {
                if (Object.prototype.hasOwnProperty.call(defaults, key)) ocspSetBool($s3, key, defaults[key]);
            });
        }
        var $region = ocspText($s3, "region");
        var $service = ocspText($s3, "serviceurl");
        $region.removeAttr("list placeholder");
        $service.removeAttr("placeholder");
        $s3.find("#ocsp-region-list").remove();
        if (provider.regionPlaceholder) $region.attr("placeholder", provider.regionPlaceholder);
        if (provider.serviceurlPlaceholder) $service.attr("placeholder", provider.serviceurlPlaceholder);
        if (provider.regions && provider.regions.length) {
            var list = '<datalist id="ocsp-region-list">' + provider.regions.map(function (r) {
                return '<option value="' + r.id + '">' + r.name + '</option>';
            }).join("") + '</datalist>';
            $s3.append(list);
            $region.attr("list", "ocsp-region-list");
        }
        $s3.data("ocspProvider", provider.id);
        var meta = provider.note || "";
        if (ocspCatalogue.catalogueVersion) meta += (meta ? " " : "") + "Catalogue " + ocspCatalogue.catalogueVersion + (ocspCatalogue.updated ? " (" + ocspCatalogue.updated + ")" : "") + ".";
        $s3.find(".ocsp-profile-note span").text(meta);
        ocspRecalculate($s3, provider);
    }
    function ocspBuildOptions() {
        return '<option value="">— Choose provider —</option>' + (ocspCatalogue.providers || []).map(function (p) {
            return '<option value="' + p.id + '">' + p.name + '</option>';
        }).join("");
    }
    function ocspRefreshSelectors() {
        $view.find(".ocsp-profile-select").each(function () {
            var $select = $(this), old = $select.val();
            $select.html(ocspBuildOptions());
            if (old && ocspFindProvider(old)) $select.val(old);
        });
    }
    function ocspLoadCatalogue() {
        $.getJSON("/resources/ocsp-s3-providers.json")
            .done(function (data) {
                if (data && data.schemaVersion === 1 && Array.isArray(data.providers) && data.providers.length) {
                    ocspCatalogue = data;
                    ocspRefreshSelectors();
                }
            })
            .fail(function () {
                if (window.console) console.warn("OCSP: using embedded provider catalogue fallback");
            });
    }
    function ocspInjectProfileSelector($box) {
        var $s3 = $box.find(".storage[data-id='S3Compatible']");
        if (!$s3.length || $s3.find(".ocsp-profile-selector").length) return;
        $s3.prepend(
            '<div class="flexContainer ocsp-profile-selector"><span>Provider profile</span>' +
              '<select class="textBox ocsp-profile-select">' + ocspBuildOptions() + '</select></div>' +
            '<div class="flexContainer fullWidth emptyMargin ocsp-profile-note"><span>Selecting a profile only fills this form. It does not connect or migrate storage.</span></div>'
        );
        var labels = {
            serviceurl: "Endpoint / service URL", region: "Region / signing region", bucket: "Bucket",
            cname: "Object base URL (HTTP)", cnamessl: "Object base URL (HTTPS)",
            forcepathstyle: "Force path-style addressing", usehttp: "Use HTTP",
            sse: "Encryption", ssekey: "Encryption key"
        };
        Object.keys(labels).forEach(function (key) {
            var $row = $s3.find("[data-id='" + key + "']");
            var $label = $row.children("span").first();
            if (!$label.length) $label = $row.find(".checkBox span").first();
            if ($label.length) $label.text(labels[key]);
        });
        $s3.find(".ocsp-profile-select").on("change.ocsp", function () {
            ocspApplyProfile($s3, ocspFindProvider($(this).val()));
        });
        $s3.on("input.ocsp change.ocsp", "[data-id='region'] .textBox, [data-id='bucket'] .textBox, [data-id='serviceurl'] .textBox", function () {
            ocspRecalculate($s3, ocspFindProvider($s3.data("ocspProvider")));
        });
    }
    // END OCSP v0.3.1 provider catalogue
    // END OCSP v0.3 S3Compatible Control Panel
'''
text=text[:m.start()]+helper+text[m.end():]
anchor='    function init(portal) {\n'
if text.count(anchor)!=1: raise SystemExit('init(portal) anchor missing')
text=text.replace(anchor,anchor+'        ocspLoadCatalogue();\n',1)
if 'class="textBox ocsp-profile-select"' not in text: raise SystemExit('profile selector missing')
if 'data-id="ocsp-profile' in text: raise SystemExit('unsafe profile selector data-id found')
for required in ("request = 'storage/updateStorage';", 'module: storage.id,', 'props: storage.params'):
    if required not in text: raise SystemExit('stock storage API contract missing: '+required)
dst.write_text(text,encoding='utf-8')
PY
}

status(){
  banner
  [ -f "$V03_STATE" ] && say "v0.3 base: PRESENT" || say "v0.3 base: absent"
  [ -f "$STATE_FILE" ] && { say "v0.3.1 state: PRESENT"; sed 's/^/  /' "$STATE_FILE"; } || say "v0.3.1 state: absent"
  if docker exec "$CP" grep -Fq "$V031_CP_MARKER" "$CP_STORAGE_JS" 2>/dev/null; then say "Control Panel provider UI: PRESENT"; else say "Control Panel provider UI: absent"; fi
  if docker exec "$CP" test -f "$CP_CATALOGUE" 2>/dev/null; then
    say "Runtime catalogue: PRESENT"
    docker exec "$CP" python3 -c 'import json; d=json.load(open("/var/www/onlyoffice/controlpanel/www/public/resources/ocsp-s3-providers.json")); print("  version=%s revision=%s updated=%s providers=%s"%(d.get("catalogueVersion"),d.get("revision"),d.get("updated"),len(d.get("providers",[]))))' 2>/dev/null || true
  else say "Runtime catalogue: absent"; fi
  say "No credentials are read and no storage API is called by status."
}

install_patch(){
  banner; preflight
  TMP_DIR="$(mktemp -d /tmp/ocsp-v031.XXXXXX)"
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  backup="$BACKUP_ROOT/v0.3.1-$stamp"
  mkdir -p "$backup" "$STATE_DIR"; chmod 700 "$backup" "$STATE_DIR"
  : >"$backup/manifest.tsv"; chmod 600 "$backup/manifest.tsv"
  say "Backing up v0.3 presentation files to: $backup"

  backup_file "$CP" CP "$CP_STORAGE_JS" "$backup"
  backup_file "$CP" CP "$CP_PARTIAL" "$backup"
  for p in "${AUTH_FILES[@]}"; do backup_file "$COMM" COMM "$p" "$backup"; done

  docker cp "$CP:$CP_STORAGE_JS" "$TMP_DIR/storage.orig.js" >/dev/null
  patch_storage_js "$TMP_DIR/storage.orig.js" "$TMP_DIR/storage.new.js"
  m="$(meta_in "$CP" "$CP_STORAGE_JS")"; docker cp "$TMP_DIR/storage.new.js" "$CP:$CP_STORAGE_JS" >/dev/null; restore_meta "$CP" "$CP_STORAGE_JS" "$m"

  docker cp "$CP:$CP_PARTIAL" "$TMP_DIR/partial.orig.pug" >/dev/null
  patch_partial "$TMP_DIR/partial.orig.pug" "$TMP_DIR/partial.new.pug"
  m="$(meta_in "$CP" "$CP_PARTIAL")"; docker cp "$TMP_DIR/partial.new.pug" "$CP:$CP_PARTIAL" >/dev/null; restore_meta "$CP" "$CP_PARTIAL" "$m"

  i=0
  for p in "${AUTH_FILES[@]}"; do
    i=$((i+1)); docker cp "$COMM:$p" "$TMP_DIR/auth-$i.orig.js" >/dev/null
    patch_auth_js "$TMP_DIR/auth-$i.orig.js" "$TMP_DIR/auth-$i.new.js"
    m="$(meta_in "$COMM" "$p")"; docker cp "$TMP_DIR/auth-$i.new.js" "$COMM:$p" >/dev/null; restore_meta "$COMM" "$p" "$m"
  done

  if docker exec "$CP" test -f "$CP_CATALOGUE"; then backup_file "$CP" CP "$CP_CATALOGUE" "$backup"; else printf 'DELETE\tCP\t%s\t-\n' "$CP_CATALOGUE" >>"$backup/manifest.tsv"; fi
  docker cp "$LOCAL_CATALOGUE" "$CP:$CP_CATALOGUE" >/dev/null
  docker exec "$CP" chown 0:0 "$CP_CATALOGUE"; docker exec "$CP" chmod 644 "$CP_CATALOGUE"

  docker exec "$CP" grep -Fq "$V031_CP_MARKER" "$CP_STORAGE_JS" || die "provider UI marker missing"
  docker exec "$CP" grep -Fq 'regions.length > 0 && id == "S3"' "$CP_PARTIAL" || die "non-AWS region textbox patch missing"
  for p in "${AUTH_FILES[@]}"; do docker exec "$COMM" grep -Fq "$V031_AUTH_MARKER" "$p" || die "delayed auth marker missing: $p"; done

  cat >"$STATE_FILE" <<EOF
PATCH_VERSION=v0.3.1
BACKUP_DIR=$backup
INSTALLED_UTC=$stamp
EOF
  chmod 600 "$STATE_FILE"

  say "Restarting CommunityServer and Control Panel..."
  docker restart "$COMM" >/dev/null; wait_container "$COMM"
  docker restart "$CP" >/dev/null; wait_container "$CP"
  say
  say "PASS: v0.3.1 provider profiles installed."
  say "Selecting a provider only fills non-secret form values; Connect is never pressed automatically."
  say "No credentials were read and no migration was started."
}

rollback_patch(){
  banner
  [ -f "$STATE_FILE" ] || die "v0.3.1 state absent"
  # shellcheck disable=SC1090
  source "$STATE_FILE"
  [ "${PATCH_VERSION:-}" = v0.3.1 ] || die "unexpected state version"
  [ -f "$BACKUP_DIR/manifest.tsv" ] || die "backup manifest missing"
  while IFS=$'\t' read -r action label path meta; do
    case "$label" in COMM) c="$COMM";; CP) c="$CP";; *) die "unknown backup label $label";; esac
    case "$action" in
      RESTORE) src="$BACKUP_DIR/$label$path"; [ -f "$src" ] || die "missing backup $src"; docker cp "$src" "$c:$path" >/dev/null; restore_meta "$c" "$path" "$meta";;
      DELETE) docker exec "$c" rm -f "$path";;
      *) die "unknown manifest action $action";;
    esac
  done <"$BACKUP_DIR/manifest.tsv"
  rm -f "$STATE_FILE"
  docker restart "$COMM" >/dev/null; wait_container "$COMM"
  docker restart "$CP" >/dev/null; wait_container "$CP"
  say "PASS: v0.3.1 rolled back to v0.3 presentation."
}

case "${1:-}" in
  install) install_patch;;
  status) status;;
  rollback) rollback_patch;;
  *) echo "Usage: $0 {install|status|rollback}" >&2; exit 2;;
esac
