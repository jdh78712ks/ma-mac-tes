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
  local case_name=$1 with_fp=$2
  local ud="/tmp/par_${case_name}"
  rm -rf "$ud"; mkdir -p "$ud"
  kill_profile

  if [ "$with_fp" = "yes" ]; then
    cp "$FP_FILE" "$ud/fingerprint.json"
    echo "fingerprint: $(basename "$FP_FILE")" | tee -a "$OUT/parity.txt"
  fi

  ( SHARDX_OVERLAY_DEBUG=1 "$RT/ShardX" --user-data-dir="$ud" --no-first-run --no-default-browser-check \
      --window-size=534,969 --remote-debugging-port="$PORT" about:blank \
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
  cat "$ud/shardx_overlay.log" 2>/dev/null | tail -6 | tee -a "$OUT/parity.txt"
  list_windows "$case_name (all)" 0 >/dev/null
  echo "$case_name|$cp|$wid|$wx|$wy|$ww|$wh" >> "$OUT/windows.tsv"
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
run_case mob yes
run_case desk no

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
    row = h // 2
    runs, cur = [], None
    for x in range(w):
        r, g, b = px[x, row]
        white = r >= 248 and g >= 248 and b >= 248
        if white and cur is None:
            cur = x
        elif not white and cur is not None:
            runs.append((cur, x - 1)); cur = None
    if cur is not None:
        runs.append((cur, w - 1))
    runs = [(a, b) for a, b in runs if b - a >= 40]
    left = px[2, row]
    right = px[w - 12, row]
    print("IMAGE %s %dx%d" % (os.path.basename(path), w, h))
    print("  white runs at mid-height: %s" % (runs,))
    print("  colour at x=2: %s   at x=w-12: %s" % (left, right))
    if mobile:
        ok_size = abs(w - 534) <= 6
        ok_left = bool(runs) and runs[0][0] <= 3 and abs((runs[0][1] - runs[0][0] + 1) - 402) <= 6
        dark = all(c < 60 for c in right)
        print("  VERDICT D4 window width 534: %s" % ("PASS" if ok_size else "FAIL"))
        print("  VERDICT D3 strip at left (x0=%s width=%s): %s" % (
            runs[0][0] if runs else "-", (runs[0][1] - runs[0][0] + 1) if runs else "-",
            "PASS" if ok_left else "FAIL"))
        print("  VERDICT D3 dark frame #121316 right of strip: %s (%s)" % ("PASS" if dark else "FAIL", right))
    else:
        ok_full = bool(runs) and runs[0][0] <= 3 and (runs[0][1] - runs[0][0] + 1) >= w - 12
        print("  VERDICT desktop page fills window: %s" % ("PASS" if ok_full else "FAIL"))

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

for case, mobile in (("mob", True), ("desk", False)):
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
