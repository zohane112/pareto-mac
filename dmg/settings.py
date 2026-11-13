# How the .dmg looks when it's opened, for dmgbuild. build.sh passes the paths with -D.
# The positions match the arrow and steps drawn in background.html.
import os.path

app = defines["app"]
guide = defines["guide"]

files = [app, guide]
symlinks = {"Applications": "/Applications"}
icon = defines["icon"]
background = defines["background"]  # background@2x.png next to it is used on Retina screens
format = "UDZO"

window_rect = ((200, 140), (640, 470))
default_view = "icon-view"
icon_size = 96
text_size = 13
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
hide_extensions = [os.path.basename(guide)]
icon_locations = {
    os.path.basename(app): (160, 205),
    "Applications": (480, 205),
    os.path.basename(guide): (320, 360),
}
