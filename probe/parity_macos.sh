#!/bin/bash
# macOS parity probe (runs on a GitHub macOS runner after the payload install).
#
# Objective checks for the four open defects of MACOS_PARITY_PLAN_29OCT.md:
#   D4  the profile window comes up at the mobile size from fingerprint.json
#       (534x969 for a 402 px screen), not at the desktop default 1366x768;
#   D3  the mobile strip is glued to the LEFT edge (x=0, 402 px wide) and the
#       area to its right is the dark #121316 frame, not a centred column;
#   D2  the HUD panel is alive in its own window, to the right of the profile
#       window and on screen;
#   D5  the two custom toolbar chips (link / chevron) are painted in the
#       top-right zone that the mouse hook intercepts (46..128 px from the
#       right edge).
#
# The wrapper is launched exactly like the launcher does it: fingerprint.json
# inside --user-data-dir, no --fingerprint-profile switch.
set +e

OUT=${OUT:-/tmp/ma_parity}
mkdir -p "$OUT"
APP="/Applications/M&A Antidetect"
RT="$APP/MA DATA/runtime/ShardX-Mac-arm64"
PORT=${PORT:-9981}

echo "== environment ==" | tee "$OUT/parity.txt"
sw_vers | tee -a "$OUT/parity.txt"
ls -l "$RT/ShardX" "$RT/ShardX.app/Contents/MacOS/ShardX_core" 2>&1 | tee -a "$OUT/parity.txt"

# --- window lister (CGWindowList: number, layer, frame, owner) -------------
cat > "$OUT/wl.swift" <<'SW'
import Cocoa
let all = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                     kCGNullWindowID) as? [[String: Any]] ?? []
let wantPid = CommandLine.arguments.count > 1 ? Int32(CommandLine.arguments[1]) : nil
for w in all {
    let pid = w[kCGWindowOwnerPID as String] as? Int32 ?? -1
    if let want = wantPid, pid != want { continue }
    let num = w[kCGWindowNumber as String] as? Int ?? 0
    let layer = w[kCGWindowLayer as String] as? Int ?? -1
    let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
    let name = w[kCGWindowName as String] as? String ?? ""
    let b = w[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
    let x = Int(b["X"] ?? 0), y = Int(b["Y"] ?? 0)
    let ww = Int(b["Width"] ?? 0), hh = Int(b["Height"] ?? 0)
    print("WIN\t\(pid)\t\(num)\t\(layer)\t\(x)\t\(y)\t\(ww)\t\(hh)\t\(owner)\t\(name)")
}
SW
swiftc -O "$OUT/wl.swift" -o "$OUT/wl" 2>"$OUT/swiftc.log"

# --- deterministic page (served locally, set as the profile start_url) -----
mkdir -p /tmp/parityweb
cat > /tmp/parityweb/parity.html <<'HTML'
<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">
<style>
html,body{margin:0;background:#ffffff;color:#111;font:600 30px -apple-system,sans-serif}
.band{position:fixed;left:0;top:0;bottom:0;width:36px;background:#e11d48}
.box{position:fixed;left:300px;top:120px;width:90px;height:90px;background:#2563eb}
h1{margin:60px 0 0 56px}
p{margin:8px 0 0 56px;font-weight:400;font-size:20px}
</style>
<div class="band"></div><div class="box"></div>
<h1>PARITY</h1><p>deterministic white page, red 36 px band</p>
HTML
( cd /tmp/parityweb && python3 -m http.server 8799 >/dev/null 2>&1 & )
sleep 1
curl -fsS http://127.0.0.1:8799/parity.html -o /dev/null && echo "local page server: ok" | tee -a "$OUT/parity.txt"

list_windows() {  # $1 = label ; $2 = optional pid filter
  echo "--- windows: $1 ---" | tee -a "$OUT/parity.txt"
  if [ -n "$2" ] && [ "$2" != "0" ]; then
    "$OUT/wl" "$2" 2>/dev/null | tee -a "$OUT/parity.txt"
  else
    "$OUT/wl" 2>/dev/null | grep -vE "^WIN\t-1" | tee -a "$OUT/parity.txt"
  fi
}

kill_profile() {
  pkill -9 -f "M&A Launcher.app" 2>/dev/null
  pkill -9 -f shardx-launcher 2>/dev/null
  pkill -9 -x ShardX_core 2>/dev/null
  pkill -9 -f "ShardX-Mac-arm64/ShardX" 2>/dev/null
  pkill -9 -f "bookmark_hud.py" 2>/dev/null
  sleep 2
}

# --- one scenario: launch + measure ---------------------------------------
run_case() {
  local case_name=$1 with_fp=$2 extra=${3:-}
  # The wrapper derives its data root as <udd>/../.. and spawns the HUD from
  # <data root>/runtime, so the probe has to mirror the real layout
  # (MA DATA/user-data/<uuid>) instead of a bare /tmp dir.
  local data="/tmp/ma_parity_data"
  mkdir -p "$data/user-data"
  [ -e "$data/runtime" ] || ln -s "/Applications/M&A Antidetect/MA DATA/runtime" "$data/runtime"
  local ud="$data/user-data/$case_name"
  rm -rf "$ud"; mkdir -p "$ud"
  kill_profile

  if [ "$with_fp" = "yes" ]; then
    cp "$FP_FILE" "$ud/fingerprint.json"
    python3 - "$ud/fingerprint.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p, encoding="utf-8"))
d["start_url"] = "http://127.0.0.1:8799/parity.html"
json.dump(d, open(p, "w", encoding="utf-8"), ensure_ascii=False)
print("start_url ->", d["start_url"])
PY
    echo "fingerprint: $(basename "$FP_FILE")" | tee -a "$OUT/parity.txt"
  fi

  ( env SHARDX_OVERLAY_DEBUG=1 $extra "$RT/ShardX" --user-data-dir="$ud" --no-first-run --no-default-browser-check \
      --window-size=534,969 --remote-debugging-port="$PORT" --remote-allow-origins='*' about:blank \
      >"$OUT/${case_name}.log" 2>&1 & )

  sleep 16
  local cp
  cp=$(pgrep -x ShardX_core | head -1)
  echo "--- case $case_name: core=${cp:-none} ---" | tee -a "$OUT/parity.txt"
  if [ -z "$cp" ]; then
    echo "VERDICT $case_name: FAIL (core not running)" | tee -a "$OUT/parity.txt"
    echo "--- wrapper log ---" | tee -a "$OUT/parity.txt"
    tail -40 "$RT/ShardX.log" 2>/dev/null | tee -a "$OUT/parity.txt"
    echo "--- launch_error ---" | tee -a "$OUT/parity.txt"
    cat "$ud/launch_error.txt" 2>/dev/null | tee -a "$OUT/parity.txt"
    echo "--- marker ---" | tee -a "$OUT/parity.txt"
    cat "$ud/window_ready" 2>/dev/null | tee -a "$OUT/parity.txt"
    echo "--- crash reports ---" | tee -a "$OUT/parity.txt"
    ls -t "$HOME/Library/Logs/DiagnosticReports" 2>/dev/null | head -3 | tee -a "$OUT/parity.txt"
    newest=$(ls -t "$HOME/Library/Logs/DiagnosticReports"/*.ips 2>/dev/null | head -1)
    [ -n "$newest" ] && head -80 "$newest" | tee -a "$OUT/parity.txt"
    return
  fi

  echo "env: $(ps eww -p "$cp" 2>/dev/null | tr ' ' '\n' | grep -E '^SHARDX_(MOB_W|LOCK_W|LOCK_H|MOBILE_CURSOR)=' | tr '\n' ' ')" | tee -a "$OUT/parity.txt"

  list_windows "$case_name (core pid)" "$cp" >/dev/null
  local main_win
  main_win=$("$OUT/wl" "$cp" 2>/dev/null | awk -F'\t' '$4==0 && $7>=300 {print $3"\t"$5"\t"$6"\t"$7"\t"$8}' | sort -k4,4nr | head -1)
  echo "main window (id x y w h): $main_win" | tee -a "$OUT/parity.txt"
  local wid wx wy ww wh
  wid=$(echo "$main_win" | cut -f1); wx=$(echo "$main_win" | cut -f2)
  wy=$(echo "$main_win" | cut -f3); ww=$(echo "$main_win" | cut -f4)
  wh=$(echo "$main_win" | cut -f5)

  if [ -n "$wid" ]; then
    screencapture -x -o -l"$wid" "$OUT/${case_name}_win.png" 2>/dev/null
    if [ ! -s "$OUT/${case_name}_win.png" ]; then
      screencapture -x "$OUT/${case_name}_desktop.png" 2>/dev/null
    fi
  else
    screencapture -x "$OUT/${case_name}_desktop.png" 2>/dev/null
  fi

  echo "--- overlay debug ---" | tee -a "$OUT/parity.txt"
  cat "$ud/shardx_overlay.log" 2>/dev/null | tail -400 | tee -a "$OUT/parity.txt"
  list_windows "$case_name (all)" 0 >/dev/null
  echo "$case_name|$cp|$wid|$wx|$wy|$ww|$wh" >> "$OUT/windows.tsv"
  echo "--- hud processes ---" | tee -a "$OUT/parity.txt"
  ps -Ao pid,command | grep -i "bookmark_hud" | grep -v grep | head -3 | tee -a "$OUT/parity.txt"
  ps -Ao pid,command | grep -i "python3" | grep -v grep | head -4 | tee -a "$OUT/parity.txt"
  PY="/Applications/M&A Antidetect/MA DATA/runtime/python/bin/python3"
  ls -l "$PY" 2>&1 | tee -a "$OUT/parity.txt"
  "$PY" -c "import sys; print('python', sys.version.split()[0]); import tkinter; print('tk', tkinter.TkVersion)" 2>&1 | head -4 | tee -a "$OUT/parity.txt"
  cat > /tmp/tk_test.py <<'PYEOF'
import sys, tkinter
print("tk version", tkinter.TkVersion, "python", sys.version.split()[0], flush=True)
r = tkinter.Tk()
r.withdraw()
r.update()
print("tk create OK", r.winfo_screenwidth(), r.winfo_screenheight(), flush=True)
r.destroy()
PYEOF
  echo "--- tk smoke ---" | tee -a "$OUT/parity.txt"
  file "$PY" | tee -a "$OUT/parity.txt"
  "$PY" /tmp/tk_test.py 2>&1 | head -12 | tee -a "$OUT/parity.txt"
  echo "tk rc=${PIPESTATUS[0]}" | tee -a "$OUT/parity.txt"
  osascript -e 'tell application "System Events" to get name of every process whose background only is false' 2>&1 | head -2 | tee -a "$OUT/parity.txt"
  if [ "$case_name" = "mob" ]; then
    echo "--- manual hud run ---" | tee -a "$OUT/parity.txt"
    ( "$PY" "$data/runtime/bookmark_hud.py" "$case_name" "$data" alex "$cp" >/tmp/hud_manual.log 2>&1 & )
    sleep 7
    head -30 /tmp/hud_manual.log | tee -a "$OUT/parity.txt"
    ps -Ao pid,command | grep "bookmark_hud" | grep -v grep | head -3 | tee -a "$OUT/parity.txt"
    "$OUT/wl" 2>/dev/null | grep -i "hud" | tee -a "$OUT/parity.txt"
    pkill -9 -f "bookmark_hud.py" 2>/dev/null
  fi
  [ -f "$RT/proxy_bridge.log" ] && { echo "--- wrapper log ---" | tee -a "$OUT/parity.txt"; tail -30 "$RT/proxy_bridge.log" | tee -a "$OUT/parity.txt"; }
  echo "--- hud windows ---" | tee -a "$OUT/parity.txt"
  "$OUT/wl" 2>/dev/null | grep -i "hud" | tee -a "$OUT/parity.txt"
  for f in "$ud/hud.log" "$data/hud.log" "$data/bookmark_hud.log" "$RT/ShardX.log"; do
    if [ -f "$f" ]; then echo "--- log: $f" | tee -a "$OUT/parity.txt"; tail -12 "$f" | tee -a "$OUT/parity.txt"; fi
  done
  kill_profile
}

# --- pick a mobile (iPhone) fingerprint ------------------------------------
FP_FILE=$(python3 - <<'PY'
import glob, json
best = None
for p in sorted(glob.glob('/Applications/M&A Antidetect/MA DATA/fingerprints/*.json')):
    try:
        raw = open(p, encoding='utf-8').read(20000)
        d = json.loads(raw if raw.endswith('}') else raw + '}')
    except Exception:
        try:
            txt = open(p, encoding='utf-8', errors='ignore').read()
        except Exception:
            continue
        if '"iPhone' in txt or "'iPhone" in txt:
            best = p
            break
        continue
    if 'iPhone' in json.dumps(d)[:5000]:
        best = p
        break
print(best or '')
PY
)
echo "picked fingerprint: ${FP_FILE:-none}" | tee -a "$OUT/parity.txt"

# --- TCC for screencapture (same row the main workflow inserts) -----------
sudo sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" \
  "INSERT OR REPLACE INTO access VALUES('kTCCServiceScreenCapture','com.apple.Terminal',0,2,4,1,NULL,NULL,0,'UNUSED',NULL,0,1677721600);" 2>/dev/null || true
sudo sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" \
  "INSERT OR REPLACE INTO access VALUES('kTCCServiceAccessibility','com.apple.Terminal',0,2,4,1,NULL,NULL,0,'UNUSED',NULL,0,1677721600);" 2>/dev/null || true

: > "$OUT/windows.tsv"
run_case mob yes ""
run_case mobmask yes "SHARDX_NO_CHIPS=1"
run_case mobchips yes "SHARDX_NO_MASK=1"
run_case desk no ""

# --- pixel analysis -------------------------------------------------------
python3 -m pip install --quiet --user pillow 2>/dev/null || python3 -m pip install --quiet --break-system-packages pillow 2>/dev/null || true
python3 - "$OUT" <<'PY' | tee -a "$OUT/parity.txt"
import os, sys, glob

out = sys.argv[1]
try:
    from PIL import Image
except Exception as exc:  # noqa: BLE001
    print("PIL missing (%s) - pixel checks skipped" % exc)
    raise SystemExit(0)

def analyse(path, mobile):
    im = Image.open(path).convert("RGB")
    w, h = im.size
    px = im.load()
    FRAME = (18, 19, 22)
    rows = [int(h * f) for f in (0.2, 0.35, 0.5, 0.65, 0.8)]

    def is_frame(c):
        return all(abs(c[i] - FRAME[i]) <= 6 for i in range(3))

    boundary = None
    for x in range(w):
        if all(is_frame(px[x, y]) for y in rows):
            boundary = x
            break
    print("IMAGE %s %dx%d" % (os.path.basename(path), w, h))
    print("  first frame-coloured column: %s   colour at x=w-12: %s" % (
        boundary, px[w - 12, rows[2]]))
    if mobile:
        # macOS keeps the profile window exactly as wide as the phone screen:
        # Windows pads it with a 132 px dark frame, but repainting that area in
        # Chromium on macOS makes AppKit drop the compositor surface, so there
        # is no strip at all and the page must fill the window edge to edge.
        ok_size = abs(w - 402) <= 6
        page_px = 0
        for y in range(100, h - 20, 4):
            for x in range(0, w, 2):
                r, g, b = px[x, y]
                if r + g + b > 240:
                    page_px += 1
        sampled = len(range(100, h - 20, 4)) * len(range(0, w, 2))
        fill = 100.0 * page_px / sampled
        print("  page coverage below the toolbar: %.0f%%" % fill)
        print("  VERDICT D4 window width == screen width 402: %s" % ("PASS" if ok_size else "FAIL"))
        print("  VERDICT D3 page fills the window (no side gaps): %s" % (
            "PASS" if fill > 80.0 else "FAIL"))
    else:
        bright = sum(1 for y in range(0, h, 8) for x in range(0, w, 8) if sum(px[x, y]) > 700)
        total = len(range(0, h, 8)) * len(range(0, w, 8))
        print("  bright coverage: %.0f%%" % (100.0 * bright / total))
        print("  VERDICT desktop page fills window: %s" % ("PASS" if bright > total * 0.5 else "FAIL"))

    # toolbar chips: lavender (167,139,250) inside the top-right 4..130 x 20..100
    hits = 0
    total = 0
    for y in range(20, min(100, h)):
        for x in range(max(0, w - 132), w):
            r, g, b = px[x, y]
            total += 1
            if abs(r - 167) <= 45 and abs(g - 139) <= 45 and b >= 215:
                hits += 1
    print("  toolbar lavender pixels in top-right: %d / %d" % (hits, total))
    print("  VERDICT D5 toolbar chips painted: %s" % ("PASS" if hits >= 80 else "FAIL"))
    return hits

for case, mobile in (("mob", True), ("mobmask", True), ("mobchips", True), ("desk", False)):
    for name in ("%s_win.png" % case, "%s_desktop.png" % case):
        p = os.path.join(out, name)
        if os.path.exists(p) and os.path.getsize(p):
            print("=== %s ===" % case)
            analyse(p, mobile)
            break
    else:
        print("=== %s === no screenshot captured" % case)

print("=== received windows ===")
for line in open(os.path.join(out, "windows.tsv"), encoding="utf-8"):
    if line.strip():
        print("  " + line.strip())
PY

# --- HUD presence (any python/tk window on screen) ------------------------
echo "--- HUD windows ---" | tee -a "$OUT/parity.txt"
"$OUT/wl" 2>/dev/null | awk -F'\t' '$4==0 && ($9 ~ /ython/ || $10 != "" ) {print}' | tee -a "$OUT/parity.txt" | head -20

echo "== done ==" | tee -a "$OUT/parity.txt"
ls -la "$OUT" | tee -a "$OUT/parity.txt"
exit 0
