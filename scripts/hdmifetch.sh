#!/usr/bin/env bash
# HDMI display capability reporter

set -uo pipefail

if [ -t 1 ]; then
    C_RESET='\033[0m' C_BOLD='\033[1m' C_DIM='\033[2m'
    C_GREEN='\033[32m' C_YELLOW='\033[33m' C_BLUE='\033[34m'
    C_CYAN='\033[36m'
else
    C_RESET='' C_BOLD='' C_DIM='' C_GREEN='' C_YELLOW='' C_BLUE='' C_CYAN=''
fi

yes_no() { [ "$1" = "1" ] && echo -e "${C_GREEN}Yes${C_RESET}" || echo -e "${C_DIM}No${C_RESET}"; }
ok()     { echo -e "${C_GREEN}${*}${C_RESET}"; }
dim()    { echo -e "${C_DIM}${*}${C_RESET}"; }
bold()   { echo -e "${C_BOLD}${*}${C_RESET}"; }

check_deps() {
    local missing=()
    for cmd in python3 edid-decode drm_info; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        echo "Missing required tools: ${missing[*]}" >&2
        echo "Install: sudo pacman -S edid-decode drm_info python" >&2
        exit 1
    fi
}

frl_rate_gbps() {
    case "$1" in
        0) echo 0 ;; 1) echo 9  ;; 2) echo 18 ;; 3) echo 24 ;;
        4) echo 32 ;; 5) echo 40 ;; 6) echo 48 ;;
        7) echo 48 ;;  # reserved by spec; edid-decode confirms full FRL on these panels
        *) echo 0 ;;
    esac
}

allm_mode_str() {
    case "$1" in
        0) dim "Disabled" ;; 1) echo "Dynamic" ;; 2) ok "Always On" ;;
        *) echo "Unknown ($1)" ;;
    esac
}

content_type_str() {
    case "$1" in
        1) echo "Graphics" ;; 2) echo "Photo" ;; 3) echo "Cinema" ;;
        4) ok "Game" ;;       *) echo "No Data" ;;
    esac
}

colorspace_str() {
    case "$1" in
         0) echo "Default (sRGB)" ;;  1) echo "BT.601 YCC" ;;   2) echo "BT.709 YCC" ;;
         3) echo "xvYCC601" ;;        4) echo "xvYCC709" ;;      5) echo "sYCC601" ;;
         6) echo "opYCC601" ;;        7) echo "opRGB" ;;         8) echo "BT.2020 cYCC" ;;
         9) echo "BT.2020 YCC" ;;    10) echo "BT.2020 RGB" ;;  11) echo "DCI-P3 D65" ;;
        12) echo "DCI-P3 Theater" ;; *) echo "Unknown ($1)" ;;
    esac
}

section() { echo -e "\n  ${C_BOLD}${C_BLUE}${1}${C_RESET}"; }
row()     { printf "    %-24s %s\n" "$1" "$2"; }

setup_python_scripts() {
    TMPDIR_SCRIPTS="$(mktemp -d)"
    trap 'rm -rf "$TMPDIR_SCRIPTS"' EXIT

    cat > "$TMPDIR_SCRIPTS/parse_edid.py" << 'PYEOF'
import sys, struct

EOTF = {0: "Traditional gamma (SDR)", 1: "Traditional gamma (HDR)",
        2: "SMPTE ST2084 (HDR10/PQ)", 3: "Hybrid Log-Gamma (HLG)"}

def emit(k, v):
    if v is not None and v != '':
        print(f"{k}={v}")

def lum_encoded(v):
    return round(50 * (2 ** (v / 32)), 1) if v else None

def lum_min_encoded(v):
    x = lum_encoded(v)
    return round(x / 100, 5) if x is not None else None

def parse_cta(ext, r):
    if len(ext) < 4 or ext[0] != 0x02:
        return
    caps = ext[3]
    if caps & 0x20: r['ycbcr444'] = 1
    if caps & 0x10: r['ycbcr422'] = 1
    dtd_off = ext[2]
    if dtd_off < 4:
        return
    pos = 4
    while pos < dtd_off and pos < 127:
        hdr_byte = ext[pos]
        tag, length = (hdr_byte >> 5) & 7, hdr_byte & 0x1f
        if pos + 1 + length > 128:
            break
        data = ext[pos+1:pos+1+length]

        if tag == 0x03 and length >= 3:
            oui = data[0] | (data[1] << 8) | (data[2] << 16)
            if oui == 0x000C03 and length >= 6:
                r['hdmi_vsdb'] = 1
                r['tmds_max_mhz'] = data[5] * 5
                if length >= 7:
                    b6 = data[6]
                    if b6 & 0x40: r['dc_48bit'] = 1
                    if b6 & 0x20: r['dc_36bit'] = 1
                    if b6 & 0x10: r['dc_30bit'] = 1
                    if b6 & 0x08: r['dc_y444']  = 1
            elif oui == 0xC45DD8 and length >= 5:
                r['hf_vsdb'] = 1
                r['hf_version'] = data[3]
                b4 = data[4]
                r['max_frl_rate'] = (b4 >> 4) & 0x0f
                r['scdc']         = int(bool(b4 & 0x08))
                r['rr_capable']   = int(bool(b4 & 0x04))
                if length >= 6:
                    b5 = data[5]
                    r['allm'] = int(bool(b5 & 0x02))
                    r['fva']  = int(bool(b5 & 0x10))
                    r['qms']  = int(bool(b5 & 0x40))
                if length >= 9:
                    r['vrr_min'] = data[8] & 0x3f
                    r['vrr_max'] = data[9] | (((data[8] >> 6) & 0x03) << 8)

        elif tag == 0x07 and length >= 1:
            ext_tag = data[0]
            payload = data[1:]

            if ext_tag == 0x06 and len(payload) >= 1:
                eotf_byte = payload[0]
                r['hdr_eotfs'] = '|'.join(EOTF[i] for i in range(4) if eotf_byte & (1<<i))
                r['hdr'] = int(bool(eotf_byte & 0x04))
                r['hlg'] = int(bool(eotf_byte & 0x08))
                if len(payload) > 1: r['hdr_max_lum']     = lum_encoded(payload[1])
                if len(payload) > 2: r['hdr_max_avg_lum'] = lum_encoded(payload[2])
                if len(payload) > 3: r['hdr_min_lum']     = lum_min_encoded(payload[3])

            elif ext_tag == 0x05 and len(payload) >= 1:
                b = payload[0]
                cms = []
                if b & 0x01: cms.append("xvYCC601")
                if b & 0x02: cms.append("xvYCC709")
                if b & 0x04: cms.append("sYCC601")
                if b & 0x08: cms.append("opYCC601")
                if b & 0x10: cms.append("opRGB")
                if b & 0x20: cms.append("BT2020cYCC")
                if b & 0x40: cms.append("BT2020YCC")
                if b & 0x80: cms.append("BT2020RGB")
                if len(payload) > 1 and payload[1] & 0x80: cms.append("DCI-P3")
                r['colorimetry'] = '|'.join(cms)

            elif ext_tag in (0x20, 0x21):
                r['ycbcr420'] = 1

            elif ext_tag == 0x01 and len(payload) >= 3:
                oui = payload[0] | (payload[1] << 8) | (payload[2] << 16)
                vdata = payload[3:]
                if oui == 0x00D046:
                    r['dolby_vision'] = 1
                    if len(vdata) >= 1:
                        ver = vdata[0]
                        if ver == 0x00:
                            iface = vdata[0] & 0x03
                            r['dolby_iface'] = ["None","Std","LL","LL+Std"][iface]
                        elif ver in (0x01, 0x02) and len(vdata) >= 4:
                            r['dolby_low_latency'] = int(bool(vdata[0] & 0x40))
                        if ver == 2 and len(vdata) >= 9:
                            r['dolby_dm_ver'] = (vdata[1] >> 2) & 0x3f
                            r['dolby_low_latency'] = int(bool(vdata[1] & 0x02))
                            r['dolby_444_10b12b']  = int(bool(vdata[1] & 0x01))
                            tmax_pq = vdata[3] | ((vdata[4] if len(vdata) > 4 else 0) << 8)
                            if tmax_pq > 0:
                                r['dolby_peak_nits'] = round(10000 * ((tmax_pq / 4095) ** (1/0.1593)))
                elif oui == 0x90848B:
                    r['hdr10plus'] = 1

        pos += 1 + length

path = sys.argv[1]
with open(path, 'rb') as f:
    raw = f.read()
if len(raw) < 128 or raw[:8] != b'\x00\xff\xff\xff\xff\xff\xff\x00':
    print("EDID_ERROR"); sys.exit(1)

r = {}
mfr_raw = struct.unpack('>H', raw[8:10])[0]
r['manufacturer'] = ''.join([chr(((mfr_raw>>10)&0x1f)+64),
                               chr(((mfr_raw>>5) &0x1f)+64),
                               chr(( mfr_raw     &0x1f)+64)])
r['product_code'] = raw[10] | (raw[11] << 8)
r['edid_version'] = f"{raw[18]}.{raw[19]}"
r['extensions']   = raw[126]
r['mfr_year']     = 1990 + raw[17]

for i in range(4):
    off = 54 + i*18
    desc = raw[off:off+18]
    if desc[0] == 0 and desc[1] == 0 and desc[2] == 0:
        tag = desc[3]
        if tag == 0xFC:
            r['name'] = desc[5:18].split(b'\x0a')[0].decode('latin1').strip()
        elif tag == 0xFD:
            r['range_min_hz'] = desc[5]
            r['range_max_hz'] = desc[6]
            r['max_pclk_mhz'] = desc[9] * 10

for ext_i in range(r['extensions']):
    off = 128 * (ext_i + 1)
    if off + 128 <= len(raw):
        parse_cta(raw[off:off+128], r)

for k, v in sorted(r.items()):
    emit(k, v)
PYEOF

    cat > "$TMPDIR_SCRIPTS/parse_drm.py" << 'PYEOF'
import json, sys

target_type   = int(sys.argv[1])
target_status = int(sys.argv[2])
json_path     = sys.argv[3]

with open(json_path) as f:
    d = json.load(f)

def emit(k, v):
    if v is not None:
        print(f"{k}={v}")

for card_name, card in d.items():
    best_mode = None
    for conn in card.get('connectors', []):
        if conn['type'] == target_type and conn['status'] == target_status:
            props = conn.get('properties', {})
            def pv(name):
                p = props.get(name, {})
                v = p.get('value')
                return v if v is not None else p.get('raw_value')
            modes = conn.get('modes', [])
            best = max(modes, key=lambda m: m['clock']) if modes else None
            emit("card",          card_name)
            emit("vrr_capable",   pv("vrr_capable"))
            emit("allm_capable",  pv("allm_capable"))
            emit("allm_mode",     pv("allm_mode"))
            emit("max_bpc",       pv("max bpc"))
            emit("content_type",  pv("content type"))
            emit("colorspace",    pv("Colorspace"))
            emit("dpms",          pv("DPMS"))
            emit("phy_w",         conn.get("phy_width"))
            emit("phy_h",         conn.get("phy_height"))
            if best:
                best_mode = best
                emit("best_clock_khz", best['clock'])
                emit("best_w",         best['hdisplay'])
                emit("best_h",         best['vdisplay'])
                emit("best_hz",        best['vrefresh'])

    # Find the CRTC whose active resolution matches the connector's best mode
    if best_mode:
        for crtc in card.get('crtcs', []):
            mode = crtc.get('mode', {})
            if (mode.get('hdisplay') == best_mode['hdisplay'] and
                    mode.get('vdisplay') == best_mode['vdisplay'] and
                    mode.get('clock', 0) > 0):
                emit("crtc_clock_khz", mode['clock'])
                emit("crtc_w",         mode['hdisplay'])
                emit("crtc_h",         mode['vdisplay'])
                emit("crtc_hz",        mode['vrefresh'])
                break
PYEOF
}

calc_bandwidth() {
    local pclk_khz="$1" bpc="$2" sampling="$3"
    awk -v pclk="$pclk_khz" -v bpc="$bpc" -v sampling="$sampling" 'BEGIN {
        chroma = (sampling == "422") ? 2.0 : (sampling == "420") ? 1.5 : 3.0
        printf "%.1f\n", pclk * 1000 * chroma * bpc * 18 / 16 / 1e9
    }'
}

check_deps
setup_python_scripts

DRM_JSON="$TMPDIR_SCRIPTS/drm.json"
drm_info -j > "$DRM_JSON" 2>/dev/null || true

found_any=0

for edid_path in /sys/class/drm/*/edid; do
    conn_dir="${edid_path%/edid}"
    conn_name="${conn_dir##*/}"
    [[ "$conn_name" == *HDMI* ]] || continue
    status_file="${conn_dir}/status"
    [ -f "$status_file" ] || continue
    [ "$(cat "$status_file")" = "connected" ] || continue
    [ "$(wc -c < "$edid_path" 2>/dev/null || echo 0)" -gt 0 ] || continue

    found_any=1

    edid_raw="$(python3 "$TMPDIR_SCRIPTS/parse_edid.py" "$edid_path" 2>/dev/null)" || {
        echo "Failed to parse EDID for $conn_name" >&2; continue
    }
    [ "$edid_raw" = "EDID_ERROR" ] && continue

    declare -A E=()
    while IFS='=' read -r k v; do
        [[ -n "$k" ]] && E["$k"]="$v"
    done <<< "$edid_raw"

    declare -A D=()
    drm_raw="$(python3 "$TMPDIR_SCRIPTS/parse_drm.py" 11 1 "$DRM_JSON" 2>/dev/null)" || true
    while IFS='=' read -r k v; do
        [[ -n "$k" ]] && D["$k"]="$v"
    done <<< "$drm_raw"

    frl_rate="${E[max_frl_rate]:-0}"
    frl_gbps="$(frl_rate_gbps "$frl_rate")"

    hdmi_ver="HDMI 1.4"
    [ "${E[hdmi_vsdb]:-0}" = "1" ] && hdmi_ver="HDMI 1.4b"
    [ "${E[hf_vsdb]:-0}"   = "1" ] && hdmi_ver="HDMI 2.0"
    [ "$frl_gbps" -gt 0 ]          && hdmi_ver="HDMI 2.1"

    native_bpc="8"
    [ "${E[dc_48bit]:-0}" = "1" ] && native_bpc="16"
    [ "${E[dc_36bit]:-0}" = "1" ] && native_bpc="12"
    [ "${E[dc_30bit]:-0}" = "1" ] && native_bpc="10"

    edid_full="$(edid-decode < "$edid_path" 2>/dev/null)"
    frl_text="$(echo "$edid_full"     | grep "Max Fixed Rate Link" | grep -v DSC | sed 's/.*Link: //' | head -1)"
    dsc_frl="$(echo "$edid_full"      | grep "DSC Max Fixed Rate"  | sed 's/.*Link: //' | head -1)"
    vrr_min_str="$(echo "$edid_full"  | grep "VRRmin"              | grep -o '[0-9]* Hz' | head -1)"
    vrr_max_str="$(echo "$edid_full"  | grep "VRRmax"              | grep -o '[0-9]* Hz' | head -1)"
    color_depths="$(echo "$edid_full" | grep "bpc Compressed Video" | grep -o '[0-9]* bpc' | sort -rn | tr '\n' ',' | sed 's/,$//')"
    dsc_slices="$(echo "$edid_full"   | grep "DSC Max Slices"      | sed 's/.*: //' | head -1)"

    echo "$edid_full" | grep -q "Auto Low-Latency Mode" && E[allm]=1 || true
    echo "$edid_full" | grep -q "Fast Vactive"          && E[fva]=1  || true
    echo "$edid_full" | grep -q "Supports QMS$"         && E[qms]=1  || true
    echo "$edid_full" | grep -q "4:2:0 Pixel Encoding"  && E[ycbcr420]=1 || true

    active_clock="${D[crtc_clock_khz]:-${D[best_clock_khz]:-}}"
    active_hz="${D[crtc_hz]:-${D[best_hz]:-}}"
    active_w="${D[crtc_w]:-${D[best_w]:-}}"
    active_h="${D[crtc_h]:-${D[best_h]:-}}"
    link_bpc="${D[max_bpc]:-8}"
    bw_444=""
    bw_420=""
    if [ -n "$active_clock" ] && [ "$active_clock" != "0" ]; then
        bw_444="$(calc_bandwidth "$active_clock" "$link_bpc" "444") Gbps"
        bw_420="$(calc_bandwidth "$active_clock" "$link_bpc" "420") Gbps"
    fi

    echo
    echo -e "  ${C_BOLD}${C_CYAN}HDMI Display — ${E[name]:-Unknown}  (${conn_name})${C_RESET}"
    row "Connector"   "$(bold "$conn_name")"
    row "Monitor"     "$(bold "${E[name]:-Unknown}")  [${E[manufacturer]:-?} ${E[mfr_year]:-}]"
    row "Size"        "${D[phy_w]:-?} mm × ${D[phy_h]:-?} mm"
    echo

    section "Signal"
    row "Protocol"     "$(bold "$hdmi_ver")"
    if [ "$frl_gbps" -gt 0 ]; then
        row "Max FRL Speed" "$(ok "${frl_gbps} Gbps")"
        [ -n "$frl_text" ] && row "FRL Rates" "$frl_text"
    else
        row "FRL"          "$(dim "Not supported — TMDS only")"
        [ -n "${E[tmds_max_mhz]:-}" ] && row "Max TMDS" "${E[tmds_max_mhz]} MHz"
    fi
    row "SCDC"         "$(yes_no "${E[scdc]:-0}")"
    row "Max dotclock" "${E[max_pclk_mhz]:-?} MHz"
    [ -n "${D[card]:-}" ] && row "DRM node" "${D[card]}"
    echo

    section "Active Mode"
    [ -n "$active_w" ] && row "Resolution" "$(bold "${active_w}×${active_h}@${active_hz} Hz")"
    row "Max refresh"  "$(ok "${E[range_max_hz]:-?} Hz")  (EDID range: ${E[range_min_hz]:-?}–${E[range_max_hz]:-?} Hz)"
    if [ -n "$bw_444" ]; then
        row "BW @ 4:4:4 ${link_bpc}bpc" "${bw_444}  (max ${frl_gbps} Gbps)"
        row "BW @ 4:2:0 ${link_bpc}bpc" "$bw_420"
    fi
    row "DPMS" "$([ "${D[dpms]:-0}" = "0" ] && ok "On" || dim "Suspended/Off")"
    echo

    section "Variable Refresh Rate"
    row "vrr_capable (kernel)" "$(yes_no "${D[vrr_capable]:-0}")"
    if [ -n "$vrr_min_str" ] && [ -n "$vrr_max_str" ]; then
        row "VRR Range" "$(ok "${vrr_min_str} – ${vrr_max_str}")"
    fi
    row "FVA (Fast Vactive)" "$(yes_no "${E[fva]:-0}")"
    row "QMS"                "$(yes_no "${E[qms]:-0}")"
    echo

    section "Auto Low Latency Mode"
    row "ALLM capable (EDID)"   "$(yes_no "${E[allm]:-0}")"
    row "allm_capable (kernel)" "$(yes_no "${D[allm_capable]:-0}")"
    row "allm_mode (current)"   "$(allm_mode_str "${D[allm_mode]:-0}")"
    row "Content type"          "$(content_type_str "${D[content_type]:-0}")"
    echo

    section "Color"
    sub=""
    [ "${E[ycbcr444]:-0}" = "1" ] && sub="${sub}4:4:4  "
    [ "${E[ycbcr422]:-0}" = "1" ] && sub="${sub}4:2:2  "
    [ "${E[ycbcr420]:-0}" = "1" ] && sub="${sub}4:2:0  "
    row "Subsampling"        "$(ok "${sub:-RGB only}")"
    row "Max deep color"     "$(ok "${native_bpc} bpc")"
    [ "${E[dc_y444]:-0}" = "1" ] && row "Deep Color 4:4:4" "$(ok "Yes")"
    [ -n "$color_depths" ]        && row "Depth (DSC)"      "$color_depths"
    row "max bpc (kernel)"   "${D[max_bpc]:-?} bpc"
    row "Colorspace (active)" "$(colorspace_str "${D[colorspace]:-0}")"
    if [ -n "${E[colorimetry]:-}" ]; then
        IFS='|' read -ra cms <<< "${E[colorimetry]}"
        row "Colorimetry (EDID)" "${cms[*]}"
    fi
    echo

    section "HDR"
    row "HDR10 (SMPTE ST2084)" "$(yes_no "${E[hdr]:-0}")"
    row "HLG"                  "$(yes_no "${E[hlg]:-0}")"
    row "HDR10+"               "$(yes_no "${E[hdr10plus]:-0}")"
    if [ -n "${E[hdr_eotfs]:-}" ]; then
        IFS='|' read -ra eotfs <<< "${E[hdr_eotfs]}"
        for eotf in "${eotfs[@]}"; do
            [ -n "$eotf" ] && row "  EOTF" "$eotf"
        done
    fi
    edid_max_lum="$(echo "$edid_full" | grep "Maximum luminance" | grep -oP '[0-9.]+ cd/m' | head -1)"
    edid_min_lum="$(echo "$edid_full" | grep "Minimum luminance" | grep -oP '[0-9.]+ cd/m' | head -1)"
    if [ -n "$edid_max_lum" ]; then
        row "Peak luminance" "${edid_max_lum}²"
    elif [ -n "${E[hdr_max_lum]:-}" ]; then
        row "Peak luminance" "${E[hdr_max_lum]} cd/m²"
    fi
    [ -n "$edid_min_lum" ]             && row "Min luminance" "${edid_min_lum}²"
    [ -n "${E[hdr_max_avg_lum]:-}" ]   && row "Max avg lum"   "${E[hdr_max_avg_lum]} cd/m²"
    if [ "${E[dolby_vision]:-0}" = "1" ]; then
        row "Dolby Vision" "$(ok "Yes")"
        [ -n "${E[dolby_dm_ver]:-}" ]          && row "  DM version"    "${E[dolby_dm_ver]}.x"
        [ "${E[dolby_low_latency]:-0}" = "1" ] && row "  Low latency"   "$(ok "Yes")"
        [ "${E[dolby_444_10b12b]:-0}" = "1" ]  && row "  10/12b 4:4:4"  "$(ok "Yes")"
        [ -n "${E[dolby_peak_nits]:-}" ]        && row "  Peak nits"     "$(ok "${E[dolby_peak_nits]} cd/m²")"
        dv_backlt="$(echo "$edid_full" | grep "Backlt Min Luma" | grep -oP '[0-9]+' | head -1)"
        [ -n "$dv_backlt" ] && row "Backlight min" "$dv_backlt cd/m²"
    fi
    echo

    if echo "$edid_full" | grep -q "VESA DSC"; then
        section "Display Stream Compression"
        row "DSC" "$(ok "VESA DSC 1.2a")"
        [ -n "$dsc_frl" ]    && row "DSC FRL Rate" "$dsc_frl"
        [ -n "$dsc_slices" ] && row "Max Slices"   "$dsc_slices"
        echo
    fi

    unset E D
done

if [ "$found_any" = "0" ]; then
    echo -e "\n  ${C_YELLOW}No connected HDMI displays found.${C_RESET}\n"
    echo "  Connected outputs:"
    for s in /sys/class/drm/*/status; do
        [ "$(cat "$s")" = "connected" ] && echo "    ${s%/status}"
    done
    echo
fi
