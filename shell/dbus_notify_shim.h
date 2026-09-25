#ifndef ZDE_DBUS_NOTIFY_SHIM_H
#define ZDE_DBUS_NOTIFY_SHIM_H

/* Runda 34/35 -- minimalny serwer org.freedesktop.Notifications na
   session-bus DBus, żeby ZEWNĘTRZNE aplikacje (spoza ZDE) mogły
   wysyłać powiadomienia widoczne w natywnym systemie powiadomień ZDE
   (patrz duży komentarz w shell/dbus_notify_shim.c i shell/dbusnotify.nim
   po pełny opis zakresu i tego, czego świadomie NIE robi). */

/* Zwraca 1 przy powodzeniu (połączono z session bus i zarezerwowano
   nazwę org.freedesktop.Notifications), 0 przy błędzie (np. brak
   session bus w środowisku -- zdarza się w headless/testowych sesjach,
   NIE jest to błąd krytyczny dla reszty ZDE). Bezpieczne wywołać
   ponownie po błędzie (np. przy starcie, zanim dbus-daemon zdąży
   wystartować) -- idempotentne. */
int zde_notify_dbus_init(void);

/* Odpytuje bufor DBus NIEBLOKUJĄCO (timeout 0) i, jeśli w kolejce jest
   choć jedno oczekujące powiadomienie odebrane od ostatniego wywołania,
   wypełnia bufory i zwraca 1. Zwraca 0, gdy nic nowego nie ma (typowy
   przypadek -- wołane co klatkę/tick z Nim, jak reszta pollingu w tym
   projekcie, patrz np. `checkExternalChanges` w texteditor.nim).
   Bufory są bezpiecznie obcinane do podanego rozmiaru (zawsze
   zakończone bajtem zerowym), nigdy nie przepełniane. */
int zde_notify_dbus_poll(char *out_app, int out_app_len,
                          char *out_summary, int out_summary_len,
                          char *out_body, int out_body_len);

#endif
