#include "shim.h"
#include <wlr/backend.h>
#include <wlr/render/wlr_renderer.h>
#include <wlr/render/allocator.h>
#include <wlr/types/wlr_compositor.h>
#include <wlr/types/wlr_subcompositor.h>
#include <wlr/types/wlr_data_device.h>
#include <wlr/types/wlr_output.h>
#include <wlr/types/wlr_output_layout.h>
#include <wlr/types/wlr_scene.h>
#include <wlr/types/wlr_xdg_shell.h>
#include <wlr/types/wlr_seat.h>
#include <wlr/types/wlr_cursor.h>
#include <wlr/types/wlr_xcursor_manager.h>
#include <wlr/types/wlr_keyboard.h>
#include <wlr/types/wlr_input_device.h>
#include <wlr/types/wlr_pointer.h>
#include <wlr/xwayland/xwayland.h>

/* --- wl_list / wl_signal ------------------------------------------------ */

void zde_wl_list_init(struct wl_list *list) {
  wl_list_init(list);
}

void zde_wl_list_remove(struct wl_list *elm) {
  wl_list_remove(elm);
}

/* Ustawia listener->notify na `notify` i podpina go pod dany sygnał.
 * To zastępuje ręczne przypisanie pola + wl_signal_add z C -- w Nim
 * wygodniej wywołać to jedną funkcją. */
void zde_signal_add(struct wl_signal *signal, struct wl_listener *listener,
                     wl_notify_func_t notify) {
  listener->notify = notify;
  wl_signal_add(signal, listener);
}

void zde_display_init_shm(struct wl_display *display) {
  wl_display_init_shm(display);
}

/* --- drobne helpery, których wygodniej użyć z C niż odtwarzać w Nim ---- */

int zde_wlr_output_state_is_empty_dummy(void) {
  /* placeholder utrzymujący plik niepusty gdyby powyższe funkcje kiedyś
     zostały wycięte przy refaktoryzacji -- celowo nieużywane. */
  return 0;
}
