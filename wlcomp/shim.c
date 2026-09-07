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

/* --- kompatybilność 0.17 <-> 0.18: patrz komentarz w shim.h -------------- */

#include <wlr/version.h>

void zde_output_create_global(struct wlr_output *output, struct wl_display *display) {
#if WLR_VERSION_MINOR >= 18
  wlr_output_create_global(output, display);
#else
  (void)display;
  wlr_output_create_global(output);
#endif
}

/* Kompatybilność 0.17 <-> 0.18: w 0.18 `geometry` jest zwykłym polem
 * `struct wlr_xdg_surface`; w 0.17 trzeba je wyliczyć wywołaniem
 * `wlr_xdg_surface_get_geometry()`. Ujednolicamy do "zawsze wypełnij mi
 * `struct wlr_box` przez wskaźnik wyjściowy", żeby kod Nim nie musiał
 * znać różnicy. */
void zde_xdg_surface_get_geometry(struct wlr_xdg_surface *surface, struct wlr_box *out_box) {
#if WLR_VERSION_MINOR >= 18
  *out_box = surface->geometry;
#else
  wlr_xdg_surface_get_geometry(surface, out_box);
#endif
}

/* `wlr_output_layout_create()`: bez argumentów w 0.17, z `struct
 * wl_display*` w wersjach, które go przyjmują -- ujednolicone tak samo
 * jak powyższe. */
struct wlr_output_layout *zde_output_layout_create(struct wl_display *display) {
#if WLR_VERSION_MINOR >= 18
  return wlr_output_layout_create(display);
#else
  (void)display;
  return wlr_output_layout_create();
#endif
}

/* `wlr_backend_autocreate()`: w 0.17 bierze `struct wl_display*`
 * bezpośrednio; w wersjach, które przeszły na `struct wl_event_loop*`,
 * trzeba je wyłuskać przez `wl_display_get_event_loop()`. Bez tego shimu
 * kod wołający tę funkcję z niewłaściwym typem wskaźnika kompiluje się
 * bez ostrzeżenia (Nim nie sprawdza typów przez granicę importc/C), ale
 * WYWALA SIĘ DOPIERO W RUNTIME -- wlroots dereferencjuje pierwsze pole
 * spod złego wskaźnika i segfaultuje. Właśnie to zostało złapane przy
 * pierwszym realnym uruchomieniu zde-comp (wlroots X11 backend zagnieżdżony
 * pod Xvfb) -- weryfikacja samą kompilacją tego nie wykrywa.  */
struct wlr_backend *zde_backend_autocreate(struct wl_display *display) {
#if WLR_VERSION_MINOR >= 18
  struct wl_event_loop *loop = wl_display_get_event_loop(display);
  return wlr_backend_autocreate(loop, NULL);
#else
  return wlr_backend_autocreate(display, NULL);
#endif
}

/* `wlr_seat_pointer_notify_axis()`: od wlroots 0.18.0 przyjmuje dodatkowy
 * siódmy argument, `enum wlr_axis_relative_direction relative_direction`
 * (obsługa wl_pointer.axis_relative_direction -- kierunek fizycznego
 * ruchu względem osi, potrzebny np. do "naturalnego" kierunku scrolla).
 * Bez tego shimu kod wołający starą, sześcioargumentową sygnaturę kompiluje
 * się i linkuje przeciw wlroots 0.17, ale wysypuje się błędem kompilacji
 * ("too few arguments") na 0.18+ -- dokładnie ten sam wzorzec
 * niezgodności co reszta funkcji w tym pliku. Domyślnie przekazujemy
 * WLR_AXIS_RELATIVE_DIRECTION_IDENTICAL (0) -- zwykły, nieodwrócony
 * kierunek scrolla; ZDE nie implementuje dziś ustawienia "naturalnego"
 * scrolla, więc nie ma z czego innego tego wypełnić. */
void zde_seat_pointer_notify_axis(struct wlr_seat *seat, uint32_t time_msec,
                                   int orientation, double value,
                                   int32_t value_discrete, int source) {
#if WLR_VERSION_MINOR >= 18
  wlr_seat_pointer_notify_axis(seat, time_msec,
                                (enum wl_pointer_axis)orientation, value,
                                value_discrete, (enum wl_pointer_axis_source)source,
                                WL_POINTER_AXIS_RELATIVE_DIRECTION_IDENTICAL);
#else
  wlr_seat_pointer_notify_axis(seat, time_msec,
                                (enum wl_pointer_axis)orientation, value,
                                value_discrete, (enum wl_pointer_axis_source)source);
#endif
}

/* --- drobne helpery, których wygodniej użyć z C niż odtwarzać w Nim ---- */

int zde_wlr_output_state_is_empty_dummy(void) {
  /* placeholder utrzymujący plik niepusty gdyby powyższe funkcje kiedyś
     zostały wycięte przy refaktoryzacji -- celowo nieużywane. */
  return 0;
}
