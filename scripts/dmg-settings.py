# dmgbuild settings for the PortPilot installer window.
# Used by scripts/release.sh:  dmgbuild -s scripts/dmg-settings.py -D app=… -D background=… -D icon=… PortPilot out.dmg
import os.path

app = defines["app"]  # noqa: F821 (provided by dmgbuild)
app_name = os.path.basename(app)

format = "ULFO"          # lzfse-compressed, macOS 10.11+
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = defines.get("icon")  # noqa: F821  volume icon (.icns)
background = defines["background"]  # noqa: F821  HiDPI TIFF, 660 × 400 pt

window_rect = ((200, 120), (660, 400))
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
icon_locations = {
    app_name: (180, 205),
    "Applications": (480, 205),
}
