#ifndef ZDE_SHIM_H
#define ZDE_SHIM_H

#include <wayland-server-core.h>

struct wlr_output;  /* forward decl -- wystarczy dla wskaźnika w prototypie poniżej */
struct wlr_xdg_surface;
struct wlr_box;
struct wlr_backend;
struct wlr_seat;

void zde_wl_list_init(struct wl_list *list);
void zde_wl_list_remove(struct wl_list *elm);
void zde_signal_add(struct wl_signal *signal, struct wl_listener *listener,
                     wl_notify_func_t notify);
void zde_display_init_shm(struct wl_display *display);

/* Kompatybilność 0.17 <-> 0.18: `wlr_output_create_global()` w 0.18
 * zaczęła przyjmować `struct wl_display*` jako drugi argument (żeby nie
 * polegać na globalnym stanie); w 0.17 bierze tylko `output`. Ten shim
 * wybiera właściwy wariant w czasie kompilacji (patrz shim.c), więc kod
 * Nim może zawsze wołać dwuargumentową wersję, niezależnie od tego, którą
 * dokładnie wersję wlroots akurat linkujemy. */
void zde_output_create_global(struct wlr_output *output, struct wl_display *display);

/* Patrz komentarz w shim.c -- ujednolica geometrię xdg-surface między
 * wlroots 0.17 (funkcja) i 0.18 (pole struktury). */
void zde_xdg_surface_get_geometry(struct wlr_xdg_surface *surface, struct wlr_box *out_box);

/* Kompatybilność 0.17 <-> 0.18 dla `wlr_output_layout_create()` (zmiana
 * liczby argumentów) -- patrz shim.c. */
struct wl_display;
struct wlr_output_layout;
struct wlr_output_layout *zde_output_layout_create(struct wl_display *display);

/* Patrz komentarz w shim.c -- ujednolica `wlr_backend_autocreate()` między
 * 0.17 (bierze wl_display*) i 0.18+ (bierze wl_event_loop*). Znaleziony
 * przez realne uruchomienie zde-comp pod zagnieżdżonym backendem X11
 * (Xvfb), nie przez samą kompilację -- błędny typ wskaźnika przez granicę
 * importc nie jest wykrywalny statycznie. */
struct wlr_backend *zde_backend_autocreate(struct wl_display *display);

/* Patrz komentarz w shim.c -- ujednolica `wlr_seat_pointer_notify_axis()`
 * między wlroots <0.18 (6 argumentów) i >=0.18 (7 argumentów, dodatkowy
 * `relative_direction`). Typy enumów przyjmowane jako `int`, żeby nie
 * musieć w tym nagłówku włączać całego <wlr/types/wlr_seat.h> -- C
 * pozwala niejawnie konwertować `int` <-> `enum` na granicy wywołania. */
void zde_seat_pointer_notify_axis(struct wlr_seat *seat, uint32_t time_msec,
                                   int orientation, double value,
                                   int32_t value_discrete, int source);

#endif
