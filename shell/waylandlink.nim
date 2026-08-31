import std/os

when defined(wayland):
  {.passC: "-I" & currentSourcePath().parentDir() / "wlprotocol".}
  {.compile: "wlprotocol/wayland-xdg-shell-client-protocol.c".}
  {.compile: "wlprotocol/wayland-xdg-decoration-client-protocol.c".}
  {.compile: "wlprotocol/wayland-viewporter-client-protocol.c".}
  {.compile: "wlprotocol/wayland-relative-pointer-unstable-v1-client-protocol.c".}
  {.compile: "wlprotocol/wayland-pointer-constraints-unstable-v1-client-protocol.c".}
  {.compile: "wlprotocol/wayland-idle-inhibit-unstable-v1-client-protocol.c".}
  {.passL: "-lwayland-client -lwayland-cursor -lwayland-egl".}
