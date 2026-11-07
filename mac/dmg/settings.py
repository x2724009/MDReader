# dmgbuild settings for the MDReader disk image.
# Usage: dmgbuild -s mac/dmg/settings.py -D app=<MDReader.app> -D bg=<background.png> -D readme=<安装说明.txt> "MDReader x.y.z" out.dmg
app = defines["app"]                       # noqa: F821 (provided by dmgbuild)
readme = defines["readme"]                 # noqa: F821

format = "ULFO"
filesystem = "HFS+"
files = [app, readme]
symlinks = {"Applications": "/Applications"}

background = defines["bg"]                 # noqa: F821  (background@2x.png next to it is picked up for Retina)
window_rect = ((200, 120), (660, 480))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 96
text_size = 12
icon_locations = {
    "MDReader.app": (170, 150),
    "Applications": (490, 150),
    "安装说明.txt": (560, 360),
}
