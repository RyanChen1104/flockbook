# Offscreen check of a Flockbook dmg: attach -nobrowse -readonly, read back the window layout
# from .DS_Store, and optionally render a preview PNG (background + icons + labels) with ImageMagick.
# usage: build/dmg-venv/bin/python -I scripts/dmg/check.py <dmg> [<preview-dir>]
import json, os, plistlib, shutil, subprocess, sys, tempfile
from ds_store import DSStore

dmg = sys.argv[1]
preview = sys.argv[2] if len(sys.argv) > 2 else None
mnt = tempfile.mkdtemp(prefix="fbdmg-")
subprocess.run(["hdiutil", "attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mnt, dmg],
               check=True, stdout=subprocess.DEVNULL)
try:
    with DSStore.open(os.path.join(mnt, ".DS_Store"), "r") as d:
        bwsp = d["."]["bwsp"]
        icvp = d["."]["icvp"]
        pos = {n: d[n]["Iloc"] for n in ("Flockbook.app", "Applications")}
    alias_bytes = icvp.get("backgroundImageAlias", b"")
    bg = sorted(f for f in os.listdir(mnt) if f.startswith(".background"))
    bg_info = subprocess.run(["tiffutil", "-info", os.path.join(mnt, bg[0])], capture_output=True, text=True).stdout if bg else ""
    out = {
        "WindowBounds": bwsp["WindowBounds"],
        "ShowToolbar": bwsp.get("ShowToolbar"), "ShowSidebar": bwsp.get("ShowSidebar"),
        "ShowStatusBar": bwsp.get("ShowStatusBar"), "ShowPathbar": bwsp.get("ShowPathbar"), "ShowTabView": bwsp.get("ShowTabView"),
        "iconSize": icvp["iconSize"], "textSize": icvp["textSize"], "arrangeBy": icvp["arrangeBy"],
        "backgroundType": icvp["backgroundType"], "backgroundAlias": b".background" in alias_bytes,
        "backgroundFile": bg, "backgroundImages": [l.strip() for l in bg_info.splitlines() if "Image Width" in l or "Resolution" in l],
        "iconPositions": pos,
        "volumeIcon": os.path.isfile(os.path.join(mnt, ".VolumeIcon.icns")),
        "customIconAttr": "C" in subprocess.run(["GetFileInfo", "-a", mnt], capture_output=True, text=True).stdout,  # uppercase = set
        "applicationsLink": os.readlink(os.path.join(mnt, "Applications")),
    }
    app = os.path.join(mnt, "Flockbook.app")
    out["appSignature"] = subprocess.run(["codesign", "--verify", "--deep", "--strict", app], capture_output=True, text=True).returncode == 0
    print(json.dumps(out, indent=1))
    ok = (out["WindowBounds"].endswith("{640, 400}}") and out["iconSize"] == 128 and out["backgroundType"] == 2
          and out["backgroundAlias"] and pos["Flockbook.app"] == (160, 180) and pos["Applications"] == (480, 180)
          and out["volumeIcon"] and out["customIconAttr"] and out["appSignature"] and out["applicationsLink"] == "/Applications" and not out["ShowToolbar"] and not out["ShowSidebar"])
    if preview and shutil.which("magick"):
        os.makedirs(preview, exist_ok=True)
        tmp = tempfile.mkdtemp()
        subprocess.run(["sips", "-s", "format", "png", os.path.join(mnt, ".VolumeIcon.icns"), "--out", f"{tmp}/app.png"], check=True, stdout=subprocess.DEVNULL)
        apps = "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/ApplicationsFolderIcon.icns"
        subprocess.run(["sips", "-s", "format", "png", apps, "--out", f"{tmp}/apps.png"], check=True, stdout=subprocess.DEVNULL)
        bgpng = f"{tmp}/bg.png"
        subprocess.run(["magick", os.path.join(mnt, bg[0]) + "[1]", bgpng], check=True)  # page 1 = @2x
        for mode, color in (("light", "black"), ("dark", "white")):  # Finder label color per appearance
            cmd = ["magick", bgpng, "-resize", "1280x800!"]
            for name, png, label in (("Flockbook.app", "app.png", "Flockbook"), ("Applications", "apps.png", "Applications")):
                x, y = pos[name]
                cmd += ["(", f"{tmp}/{png}", "-resize", "256x256", ")", "-geometry", f"+{2*x-128}+{2*y-128}", "-composite",
                        "-font", "/System/Library/Fonts/SFNS.ttf", "-pointsize", "26", "-fill", color, "-gravity", "North",
                        "-annotate", f"{2*x-640:+d}+{2*y+136}", label, "-gravity", "NorthWest"]
            out_png = os.path.join(preview, f"dmg-preview-{mode}.png")
            subprocess.run(cmd + [out_png], check=True)
            print("preview:", out_png)
    print("OK" if ok else "FAIL")
    sys.exit(0 if ok else 1)
finally:
    subprocess.run(["hdiutil", "detach", "-quiet", mnt], check=False)
    os.rmdir(mnt)
