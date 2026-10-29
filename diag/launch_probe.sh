#!/bin/bash
# M&A macOS launch probe.
# Separates three hypotheses for "profile does not open":
#   A. the browser process starts but never creates a window
#   B. the AppKit hook prevents/breaks the window
#   C. the wrapper/gate kills a healthy browser
# Prints every measurement to stdout (GitHub Actions job log).

set +e
R="/Applications/M&A Antidetect/MA DATA"
RT="$R/runtime/ShardX-Mac-arm64"
WRAP="$RT/ShardX"
CORE="$RT/ShardX.app/Contents/MacOS/ShardX_core"
P=90fee765-8550-44f0-8fb6-820bac044c6c
SRC="$R/profiles/$P.json"

echo "########## ENV ##########"
sw_vers
uname -m
echo "user=$(whoami) console_user=$(stat -f%Su /dev/console)"
echo "launcher running: $(pgrep -fc shardx-launcher-core)"
echo "hook in framework:"
FW="$RT/ShardX.app/Contents/Frameworks/ShardX Framework.framework/Versions/A/ShardX Framework"
[ -f "$FW" ] && otool -L "$FW" 2>/dev/null | grep -i "shardx_hook" || echo "  (framework not found at $FW)"
echo "hook dylib:"; ls -la "$RT/ShardX.app/Contents/MacOS/libshardx_hook.dylib" 2>&1
echo "baseline windows:"; /tmp/winlist

probe() {  # probe <pid> <label>
  local pid="$1" label="$2"
  echo "--- windows after 6s ($label), browser pid=$pid"
  sleep 6
  /tmp/winlist | grep -iE "window|shardx" | head -25
  echo "--- procs:"; pgrep -fl "ShardX" | head -8
}

echo
echo "########## CASE A: wrapper, window gate disabled, hook as shipped ##########"
UA="/tmp/udd_a"; rm -rf "$UA"; mkdir -p "$UA"; cp -f "$SRC" "$UA/fingerprint.json"
SHARDX_NO_WINDOW_CHECK=1 "$WRAP" --user-data-dir="$UA" --window-size=534,969 \
  --no-first-run --no-default-browser-check about:blank > /tmp/wrap_a.log 2>&1 &
WA=$!
sleep 8
echo "wrapper alive: $(kill -0 $WA 2>/dev/null && echo yes || echo no); marker=$(cat "$UA/window_ready" 2>/dev/null)"
probe "$WA" "A"
echo "--- wrap_a.log"; cat /tmp/wrap_a.log
echo "--- browser_stderr (tail)"; tail -25 "$UA/browser_stderr.log" 2>/dev/null
kill $WA 2>/dev/null; pkill -f "udd_a" 2>/dev/null; sleep 2
pkill -f ShardX_core 2>/dev/null; sleep 1

echo
echo "########## CASE B: bare ShardX_core (hook still loads via framework) ##########"
UB="/tmp/udd_b"; rm -rf "$UB"; mkdir -p "$UB"; cp -f "$SRC" "$UB/fingerprint.json"
"$CORE" --user-data-dir="$UB" --window-size=534,969 --no-first-run --no-default-browser-check about:blank \
  > /tmp/core_b.log 2>&1 &
CB=$!
probe "$CB" "B"
echo "--- core_b.log"; tail -30 /tmp/core_b.log
kill $CB 2>/dev/null; pkill -f "udd_b" 2>/dev/null; sleep 2

echo
echo "########## CASE C: bare ShardX_core with SHARDX_NO_HOOK=1 ##########"
UC="/tmp/udd_c"; rm -rf "$UC"; mkdir -p "$UC"; cp -f "$SRC" "$UC/fingerprint.json"
SHARDX_NO_HOOK=1 "$CORE" --user-data-dir="$UC" --window-size=534,969 --no-first-run \
  --no-default-browser-check about:blank > /tmp/core_c.log 2>&1 &
CC=$!
probe "$CC" "C"
echo "--- core_c.log"; tail -30 /tmp/core_c.log
kill $CC 2>/dev/null; pkill -f "udd_c" 2>/dev/null; sleep 2

echo
echo "########## CASE D: wrapper with gate + marker (the shipped path) ##########"
UD="/tmp/udd_d"; rm -rf "$UD"; mkdir -p "$UD"; cp -f "$SRC" "$UD/fingerprint.json"
SHARDX_WINDOW_READY_FILE="$UD/window_ready" "$WRAP" --user-data-dir="$UD" --window-size=534,969 \
  --no-first-run --no-default-browser-check about:blank > /tmp/wrap_d.log 2>&1 &
WD=$!
for i in $(seq 1 14); do
  sleep 2
  echo "t=$((i*2))s marker=$(cat "$UD/window_ready" 2>/dev/null) wrapper=$(kill -0 $WD 2>/dev/null && echo alive || echo dead) cores=$(pgrep -fc ShardX_core)"
  kill -0 $WD 2>/dev/null || break
done
echo "--- launch_error.txt"; cat "$UD/launch_error.txt" 2>/dev/null
echo "--- wrap_d.log"; cat /tmp/wrap_d.log
echo "--- proxy_bridge.log (tail 30)"; tail -30 "$RT/proxy_bridge.log" 2>/dev/null
kill $WD 2>/dev/null; pkill -f ShardX_core 2>/dev/null

echo
echo "########## DONE ##########"
