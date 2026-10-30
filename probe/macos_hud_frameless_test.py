#!/usr/bin/env python3
"""macOS: the HUD must be a frameless panel, not a titled window.

Defect being pinned (owner report, 30.10.2026): on macOS the HUD rail came up as
a separate window with a title bar and the close/minimise/zoom buttons, while the
Windows build has a chrome-less strip. Tk 9 ignores `overrideredirect(True)` and
`::tk::unsupported::MacWindowStyle ... plain none` for some windows, so the chrome
is removed in AppKit itself (`mac_compat.strip_window_chrome()`).

Contract checked here, on the shipped runtime file, natively on macOS:

  1. a default Tk window really starts WITH the chrome (resizable/closable bits),
     otherwise the check would be vacuous;
  2. after `strip_window_chrome()` no window carries Closable/Miniaturizable/
     Resizable, all three standard buttons report `isHidden == YES`, the title is
     hidden, the title bar is transparent, the window has no shadow and is not
     draggable; the Titled bit stays (borderless NSWindows lose `canBecomeKeyWindow`,
     and the HUD has a search field);
  3. a second call is idempotent (nothing left to strip);
  4. the same file imported WITHOUT `libmac_win_helper.dylib` still strips the
     chrome, i.e. the fix does not need the prebuilt dylib rebuilt.

Usage:
    python3 macos_hud_frameless_test.py [/path/to/MA DATA/runtime]
Exit 0 = PASS. Any failed check exits 1 with a FAIL line and the reason.
"""
import importlib.util
import os
import shutil
import sys
import tempfile

RESIZE_BITS = (1 << 1) | (1 << 2) | (1 << 3)  # Closable, Miniaturizable, Resizable
FULLSIZE_CONTENT = 1 << 15


def fail(msg):
    print("RESULT: FAIL - " + msg)
    sys.exit(1)


def load_mac_compat(runtime_dir, module_name="runtime_mac_compat"):
    path = os.path.join(runtime_dir, "mac_compat.py")
    if not os.path.exists(path):
        fail("mac_compat.py not found in %s" % runtime_dir)
    spec = importlib.util.spec_from_file_location(module_name, path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = mod
    spec.loader.exec_module(mod)
    return mod


def window_state(mac_compat):
    """[{mask, hidden, title_vis, transparent, movable, has_shadow}] per NSWindow."""
    fns = mac_compat._objc_funcs()
    if not fns:
        fail("libobjc unavailable: %s" % (mac_compat._OBJC_LOAD_ERROR or "unknown"))
    sel = fns["sel"]
    cls = fns["getClass"](b"NSApplication")
    app = fns["id_id"](cls, sel(b"sharedApplication"))
    wins = fns["id_id"](app, sel(b"windows"))
    count = int(fns["ul_id"](wins, sel(b"count")))
    out = []
    for i in range(count):
        win = fns["id_id_ul"](wins, sel(b"objectAtIndex:"), i)
        if not win:
            continue
        hidden = []
        for b in (0, 1, 2):
            btn = fns["id_id_ul"](win, sel(b"standardWindowButton:"), b)
            hidden.append(None if not btn else int(fns["bool_id"](btn, sel(b"isHidden"))))
        out.append({
            "mask": int(fns["ul_id"](win, sel(b"styleMask"))),
            "hidden": hidden,
            "title_vis": int(fns["long_id"](win, sel(b"titleVisibility"))),
            "transparent": int(fns["bool_id"](win, sel(b"titlebarAppearsTransparent"))),
            "movable": int(fns["bool_id"](win, sel(b"isMovable"))),
            "shadow": int(fns["bool_id"](win, sel(b"hasShadow"))),
        })
    return out


def main():
    if sys.platform != "darwin":
        fail("this check is macOS-only")
    runtime = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("MA_HUD_RUNTIME", "")
    if not runtime or not os.path.isdir(runtime):
        fail("pass the runtime directory (MA DATA/runtime) as the first argument")

    sys.path.insert(0, runtime)
    mac_compat = load_mac_compat(runtime)

    import tkinter as tk

    root = tk.Tk()
    root.title("frameless probe")
    root.geometry("240x140+90+90")
    root.update_idletasks()
    root.update()

    before = window_state(mac_compat)
    resizable_before = [w for w in before if w["mask"] & RESIZE_BITS]
    print("before: %d window(s), %d with resize chrome, masks=%s"
          % (len(before), len(resizable_before),
             ",".join("0x%x" % w["mask"] for w in before)))
    if not before:
        fail("NSApplication reported no windows at all")
    if not resizable_before:
        fail("the Tk probe window started without any window chrome - check would be vacuous")

    info = mac_compat.strip_window_chrome(bg="#0d0d13")
    if not info or not info.get("ok"):
        fail("strip_window_chrome() failed: %s" % (info or {}).get("error"))
    print("strip: ok windows=%s stripped=%s" % (info.get("windows"), info.get("stripped")))
    if not info.get("stripped"):
        fail("strip_window_chrome() reported nothing to strip although chrome existed")

    after = window_state(mac_compat)
    if not any(w["mask"] & (1 << 0) for w in after):
        # Titled is kept on purpose: borderless NSWindows lose canBecomeKeyWindow
        # and the HUD search field must keep taking input.
        fail("Titled bit was dropped from every window: %s"
             % ",".join("0x%x" % w["mask"] for w in after))
    if not any(w["mask"] & FULLSIZE_CONTENT for w in after):
        fail("no window got FullSizeContentView - the rail would show a title-bar band")
    for w in after:
        if w["mask"] & RESIZE_BITS:
            fail("resize chrome bits survived: 0x%x" % w["mask"])
        if (w["mask"] & (1 << 0)) and not (w["mask"] & FULLSIZE_CONTENT):
            fail("titled window left without FullSizeContentView: 0x%x" % w["mask"])
        if w["title_vis"] != 1:
            fail("titleVisibility is not NSWindowTitleHidden: %s" % w["title_vis"])
        if not w["transparent"]:
            fail("titlebarAppearsTransparent is not YES")
        if w["movable"]:
            fail("HUD window is still draggable")
        if w["shadow"]:
            fail("HUD window still casts a window shadow")
        for flag in w["hidden"]:
            if flag == 0:
                fail("a standard window button is still visible: %s" % (after,))
    print("after: %s" % ",".join("0x%x" % w["mask"] for w in after))

    again = mac_compat.strip_window_chrome()
    if not again or not again.get("ok"):
        fail("second strip_window_chrome() failed")
    if again.get("stripped"):
        fail("strip_window_chrome() is not idempotent (stripped=%s on an already clean set)"
             % again.get("stripped"))
    print("idempotent: PASS")

    root.destroy()

    # (4) The fix must not depend on the prebuilt helper dylib: run the exact
    # shipped mac_compat.py from a directory that has no libmac_win_helper.dylib.
    tmp = tempfile.mkdtemp(prefix="ma_nodl_")
    try:
        shutil.copyfile(os.path.join(runtime, "mac_compat.py"),
                        os.path.join(tmp, "mac_compat.py"))
        bare = load_mac_compat(tmp, "runtime_mac_compat_nodl")
        if bare.MAC_HELPER_AVAILABLE:
            fail("test harness error: the bare copy still found a helper dylib")
        info2 = bare.strip_window_chrome()
        if not info2 or not info2.get("ok"):
            fail("strip_window_chrome() needs the helper dylib: %s" % (info2 or {}).get("error"))
        print("no-dylib path: PASS (%d window(s) examined)" % info2.get("windows", 0))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    print("RESULT: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
