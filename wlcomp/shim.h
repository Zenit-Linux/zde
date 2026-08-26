#ifndef ZDE_SHIM_H
#define ZDE_SHIM_H

#include <wayland-server-core.h>

void zde_wl_list_init(struct wl_list *list);
void zde_wl_list_remove(struct wl_list *elm);
void zde_signal_add(struct wl_signal *signal, struct wl_listener *listener,
                     wl_notify_func_t notify);
void zde_display_init_shm(struct wl_display *display);

#endif
