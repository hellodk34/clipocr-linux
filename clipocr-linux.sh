#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# wxocr.sh — OCR images from system clipboard via WeChat OCR API
#
# Usage:
#     1. Copy an image to clipboard (screenshot / browser "copy image")
#     2. Run:   wxocr.sh
#     3. Recognised text pops up in a dialog + auto-copied back to clipboard
#
# Supported environments:
#     Wayland   wl-paste (wl-clipboard)
#     X11       xclip
#     Dialogs   zenity > kdialog > yad > terminal fallback
#     Notify    notify-send > kdialog --passivepopup > terminal fallback
#
# Configuration (environment variables):
#     WXOCR_API_URL       OCR endpoint
#                           default: http://example.com:5000/ocr
#     WXOCR_DIALOG_WIDTH  dialog width  (default 700)
#     WXOCR_DIALOG_HEIGHT dialog height (default 500)
# ============================================================================

API_URL="${WXOCR_API_URL:-http://example.com:5000/ocr}"
DLG_W="${WXOCR_DIALOG_WIDTH:-700}"
DLG_H="${WXOCR_DIALOG_HEIGHT:-500}"

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
_notify() {
    local t="$1" m="$2"
    if command -v notify-send &>/dev/null; then
        notify-send "$t" "$m"
    elif command -v kdialog &>/dev/null; then
        kdialog --title "$t" --passivepopup "$m" 5 2>/dev/null
    else
        echo "[$t] $m" >&2
    fi
}

_show_text() {
    local title="$1" text="$2"
    if command -v zenity &>/dev/null; then
        echo "$text" | zenity --text-info --title="$title" \
            --width="$DLG_W" --height="$DLG_H" --ok-label="知道了" --cancel-label="关闭" 2>/dev/null
    elif command -v kdialog &>/dev/null; then
        local tmpf; tmpf=$(mktemp)
        echo "$text" > "$tmpf"
        kdialog --textbox "$tmpf" --title "$title" \
            --geometry "${DLG_W}x${DLG_H}" 2>/dev/null || true
        rm -f "$tmpf"
    elif command -v yad &>/dev/null; then
        echo "$text" | yad --text-info --title="$title" \
            --width="$DLG_W" --height="$DLG_H" 2>/dev/null
    else
        echo "=== $title ==="
        echo "$text"
        _notify "wxocr" "缺少对话框工具 (zenity/kdialog/yad)，结果已输出到终端"
    fi
}

_clip_copy() {
    if command -v wl-copy &>/dev/null; then
        wl-copy
    elif command -v xclip &>/dev/null; then
        xclip -selection clipboard
    elif command -v xsel &>/dev/null; then
        xsel --clipboard --input
    else
        cat >/dev/null
    fi
}

# ---------------------------------------------------------------------------
# detect clipboard tool
# ---------------------------------------------------------------------------
CLIP_TOOL=""
for c in wl-paste xclip; do
    if command -v "$c" &>/dev/null; then
        CLIP_TOOL="$c"
        break
    fi
done

if [ -z "$CLIP_TOOL" ]; then
    _notify "wxocr 警告⚠️" \
        "缺少剪贴板工具，请安装 wl-clipboard (wayland) 或 xclip (x11)"
    exit 1
fi

if ! command -v python3 &>/dev/null; then
    _notify "wxocr 错误⚠️" "未找到 python3，请先安装 python3"
    exit 1
fi

# ---------------------------------------------------------------------------
# clipboard read functions
# ---------------------------------------------------------------------------
_list_types() {
    case "$CLIP_TOOL" in
        wl-paste) wl-paste --list-types 2>/dev/null || true ;;
        xclip)    xclip -selection clipboard -t TARGETS -o 2>/dev/null || true ;;
    esac
}

_read_image() {
    case "$CLIP_TOOL" in
        wl-paste) wl-paste --type "$1" 2>/dev/null ;;
        xclip)    xclip -selection clipboard -t "$1" -o 2>/dev/null ;;
    esac
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
ctypes=$(_list_types)
if [ -z "$ctypes" ] || ! echo "$ctypes" | grep -q '^image/'; then
    _notify "wxocr 警告⚠️" "系统剪贴板内容不是图片，无法进行 ocr"
    exit 1
fi

img_type=$(echo "$ctypes" | grep '^image/' | head -1)

# --- poke OCR API via Python; text printed to stdout ---
ocr_text=$(_read_image "$img_type" 2>/dev/null | python3 -c "
import sys, base64, json, urllib.request, urllib.error, subprocess, os

API_URL  = os.environ.get('WXOCR_API_URL', 'http://host.940304.xyz:15001/ocr')

# ---- helper: push desktop notification (best-effort) ----
def notify(title, msg):
    for args in (
        ['notify-send', title, msg],
        ['kdialog', '--title', title, '--passivepopup', msg, '5'],
    ):
        try:
            subprocess.run(args, timeout=3)
            return
        except Exception:
            continue
    print(f'[{title}] {msg}', file=sys.stderr)

# ---- 1. read raw image from stdin ----
raw = sys.stdin.buffer.read()
if not raw:
    notify('wxocr 错误⚠️', '无法从剪贴板读取图片数据')
    sys.exit(1)

# ---- 2. convert to PNG if Pillow present (server works best with PNG) ----
try:
    from PIL import Image
    import io
    im = Image.open(io.BytesIO(raw))
    if im.mode in ('RGBA', 'LA', 'P'):
        im = im.convert('RGB')
    buf = io.BytesIO()
    im.save(buf, format='PNG')
    raw = buf.getvalue()
except ImportError:
    pass

# ---- 3. base64 → POST /ocr ----
b64 = base64.b64encode(raw).decode('utf-8')
req = urllib.request.Request(
    API_URL,
    data=json.dumps({'image': b64}).encode('utf-8'),
    headers={'Content-Type': 'application/json'},
)

try:
    with urllib.request.urlopen(req, timeout=30) as resp:
        data = json.loads(resp.read().decode('utf-8'))
except urllib.error.HTTPError as e:
    notify('wxocr 错误⚠️', 'HTTP ' + str(e.code))
    sys.exit(1)
except urllib.error.URLError as e:
    notify('wxocr 错误⚠️', '连接失败: ' + str(e.reason))
    sys.exit(1)
except Exception as e:
    notify('wxocr 错误⚠️', '请求异常: ' + str(e)[:200])
    sys.exit(1)

if 'error' in data:
    notify('wxocr 错误⚠️', '服务端: ' + str(data['error'])[:200])
    sys.exit(1)

# ---- 4. unwrap response {'result': {'ocr_response': [{'text':...}]}} ----
inner = data.get('result')
if not isinstance(inner, dict):
    inner = data

ocr = inner.get('ocr_response', [])
if not ocr and inner.get('errcode', 0) != 0:
    notify('wxocr 警告⚠️', '识别失败 errcode=' + str(inner.get('errcode')))
    sys.exit(0)

if not ocr:
    sys.exit(0)         # bash will show 'no text' notification

lines = []
for it in ocr:
    t = it.get('text', '')
    if t and t.strip():
        lines.append(t.strip())

out = '\n'.join(lines)
if out:
    print(out, end='')
")

# ---------------------------------------------------------------------------
# display & clipboard
# ---------------------------------------------------------------------------
if [ $? -eq 0 ]; then
    if [ -n "$ocr_text" ]; then
        _show_text "wxocr 识别结果" "$ocr_text"
        echo "$ocr_text" | _clip_copy
    else
        _notify "wxocr 警告⚠️" "未识别到任何文字"
    fi
fi
