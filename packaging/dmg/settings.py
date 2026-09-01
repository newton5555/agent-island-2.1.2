# dmgbuild settings — the styled installer window (dark backdrop, wordmark,
# app on the left, Applications on the right). Invoked from release.sh:
#   dmgbuild -s packaging/dmg/settings.py \
#            -D app=dist/AgentIsland.app \
#            -D background=dist/dmg-background.tiff \
#            -D icon=Assets/AgentIsland.icns \
#            "Agent Island <version>" dist/AgentIsland-<version>.dmg
#
# dmgbuild writes the .DS_Store directly (no Finder scripting), so this runs
# headless on CI. Background art lives in packaging/dmg/background*.png and
# regenerates via packaging/dmg/gen-assets.swift.
import os.path

app = defines.get("app", "dist/AgentIsland.app")  # noqa: F821
appname = os.path.basename(app)

format = "UDZO"
files = [app]
symlinks = {"Applications": "/Applications"}

icon = defines.get("icon")  # noqa: F821 — volume icon shown in the title bar
background = defines.get("background")  # noqa: F821

window_rect = ((200, 140), (660, 420))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False

icon_size = 128
text_size = 13
icon_locations = {
    appname: (165, 210),
    "Applications": (500, 210),
}
