# dmgbuild settings for the Flockbook installer window.
# Used by scripts/package.sh: dmgbuild -s scripts/dmg/settings.py -D app=<Flockbook.app> -D icon=<.icns> Flockbook <out.dmg>
# Layout constants are shared with scripts/dmg/check.py (readback + preview).
import os.path

app = defines["app"]  # noqa: F821 (dmgbuild injects `defines`)
app_name = os.path.basename(app)

format = "UDZO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = defines.get("icon")  # noqa: F821  volume icon: .VolumeIcon.icns
if icon and not os.path.isfile(icon):
    icon = None
# Relative to the repo root (package.sh runs there). background@2x.png is combined into a HiDPI TIFF.
background = defines.get("background", "scripts/dmg/background.png")  # noqa: F821

window_rect = ((200, 120), (640, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
arrange_by = None
icon_size = 128
text_size = 13
label_pos = "bottom"
icon_locations = {app_name: (160, 180), "Applications": (480, 180)}
# No hide_extensions: SetFile -a E adds a FinderInfo xattr to the app, which breaks codesign --strict.
