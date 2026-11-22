from pathlib import Path

app = Path(defines["app"])
files = [str(app)]
symlinks = {"Applications": "/Applications"}
background = "builtin-arrow"
window_rect = ((180, 160), (640, 240))
icon_size = 104
text_size = 14
icon_locations = {app.name: (155, 120), "Applications": (485, 120)}
show_toolbar = False
show_status_bar = False
show_pathbar = False
show_sidebar = False
