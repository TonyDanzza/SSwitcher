"""Finder layout, written without automating Finder or requesting UI access."""
from pathlib import Path

application = Path(defines["app"])
files = [str(application)]
symlinks = {"Applications": "/Applications"}
format = "UDZO"
filesystem = "HFS+"
icon = str(application / "Contents/Resources/AppIcon.icns")
background = defines["background"]
window_rect = ((180, 160), (640, 380))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
include_icon_view_settings = True
include_list_view_settings = False
arrange_by = None
grid_spacing = 80
scroll_position = (0, 0)
label_pos = "bottom"
text_size = 14
icon_size = 100
icon_locations = {application.name: (170, 190), "Applications": (470, 190)}
