#include <dbus/dbus.h>
#include <string.h>
#include <stdlib.h>

#define ZDE_NOTIFY_RING_CAP 16
#define ZDE_NOTIFY_FIELD_MAX 512

typedef struct {
  char app[ZDE_NOTIFY_FIELD_MAX];
  char summary[ZDE_NOTIFY_FIELD_MAX];
  char body[ZDE_NOTIFY_FIELD_MAX];
} ZdeNotifyItem;

static DBusConnection *g_conn = NULL;
static dbus_uint32_t g_next_id = 1;

/* Pierścieniowy bufor oczekujących powiadomień -- przy przepełnieniu
   (nikt nie odpytał ZDE_NOTIFY_RING_CAP powiadomień z rzędu, skrajnie
   mało prawdopodobne przy odpytywaniu co klatkę) NAJSTARSZE jest po
   cichu nadpisywane -- ten sam kompromis co inne ograniczone bufory w
   tym projekcie (patrz np. `MaxHistory` w notifications.nim): utrata
   najstarszego to najwyżej niedogodność, nigdy błąd. */
static ZdeNotifyItem g_ring[ZDE_NOTIFY_RING_CAP];
static int g_ring_head = 0;  /* następny do odczytu */
static int g_ring_count = 0;

static void zde_ring_push(const char *app, const char *summary, const char *body) {
  int tail = (g_ring_head + g_ring_count) % ZDE_NOTIFY_RING_CAP;
  if (g_ring_count == ZDE_NOTIFY_RING_CAP) {
    /* pełny -- nadpisujemy najstarszy, przesuwamy głowę */
    g_ring_head = (g_ring_head + 1) % ZDE_NOTIFY_RING_CAP;
  } else {
    g_ring_count++;
  }
  strncpy(g_ring[tail].app, app ? app : "", ZDE_NOTIFY_FIELD_MAX - 1);
  g_ring[tail].app[ZDE_NOTIFY_FIELD_MAX - 1] = '\0';
  strncpy(g_ring[tail].summary, summary ? summary : "", ZDE_NOTIFY_FIELD_MAX - 1);
  g_ring[tail].summary[ZDE_NOTIFY_FIELD_MAX - 1] = '\0';
  strncpy(g_ring[tail].body, body ? body : "", ZDE_NOTIFY_FIELD_MAX - 1);
  g_ring[tail].body[ZDE_NOTIFY_FIELD_MAX - 1] = '\0';
}

static int zde_ring_pop(char *out_app, int out_app_len,
                         char *out_summary, int out_summary_len,
                         char *out_body, int out_body_len) {
  if (g_ring_count == 0) return 0;
  ZdeNotifyItem *it = &g_ring[g_ring_head];
  g_ring_head = (g_ring_head + 1) % ZDE_NOTIFY_RING_CAP;
  g_ring_count--;
  if (out_app && out_app_len > 0) {
    strncpy(out_app, it->app, out_app_len - 1);
    out_app[out_app_len - 1] = '\0';
  }
  if (out_summary && out_summary_len > 0) {
    strncpy(out_summary, it->summary, out_summary_len - 1);
    out_summary[out_summary_len - 1] = '\0';
  }
  if (out_body && out_body_len > 0) {
    strncpy(out_body, it->body, out_body_len - 1);
    out_body[out_body_len - 1] = '\0';
  }
  return 1;
}

static void zde_reply_strings(DBusMessage *msg, const char *const *strs, int n) {
  DBusMessage *reply = dbus_message_new_method_return(msg);
  if (!reply) return;
  DBusMessageIter iter;
  dbus_message_iter_init_append(reply, &iter);
  int i;
  for (i = 0; i < n; i++) {
    dbus_message_iter_append_basic(&iter, DBUS_TYPE_STRING, &strs[i]);
  }
  dbus_connection_send(g_conn, reply, NULL);
  dbus_message_unref(reply);
}

static void zde_handle_notify(DBusMessage *msg) {
  DBusMessageIter iter;
  char app[ZDE_NOTIFY_FIELD_MAX] = {0};
  char summary[ZDE_NOTIFY_FIELD_MAX] = {0};
  char body[ZDE_NOTIFY_FIELD_MAX] = {0};

  if (dbus_message_iter_init(msg, &iter)) {
    /* Sygnatura Notify: s u s s s as a{sv} i -- czytamy TYLKO pierwsze
       pięć argumentów o znanych, prostych typach (app_name, replaces_id,
       app_icon, summary, body); `actions`/`hints`/`expire_timeout`
       świadomie pomijamy, patrz duży komentarz na górze pliku. */
    /* app_name */
    if (dbus_message_iter_get_arg_type(&iter) == DBUS_TYPE_STRING) {
      const char *s; dbus_message_iter_get_basic(&iter, &s);
      strncpy(app, s, ZDE_NOTIFY_FIELD_MAX - 1);
    }
    if (!dbus_message_iter_next(&iter)) goto reply;
    /* replaces_id (UINT32) -- pomijamy wartość */
    if (!dbus_message_iter_next(&iter)) goto reply;
    /* app_icon -- pomijamy wartość */
    if (!dbus_message_iter_next(&iter)) goto reply;
    /* summary */
    if (dbus_message_iter_get_arg_type(&iter) == DBUS_TYPE_STRING) {
      const char *s; dbus_message_iter_get_basic(&iter, &s);
      strncpy(summary, s, ZDE_NOTIFY_FIELD_MAX - 1);
    }
    if (!dbus_message_iter_next(&iter)) goto reply;
    /* body */
    if (dbus_message_iter_get_arg_type(&iter) == DBUS_TYPE_STRING) {
      const char *s; dbus_message_iter_get_basic(&iter, &s);
      strncpy(body, s, ZDE_NOTIFY_FIELD_MAX - 1);
    }
  }

reply:
  zde_ring_push(app, summary, body);
  {
    DBusMessage *reply = dbus_message_new_method_return(msg);
    if (reply) {
      dbus_uint32_t id = g_next_id++;
      dbus_message_append_args(reply, DBUS_TYPE_UINT32, &id, DBUS_TYPE_INVALID);
      dbus_connection_send(g_conn, reply, NULL);
      dbus_message_unref(reply);
    }
  }
}

int zde_notify_dbus_init(void) {
  if (g_conn != NULL) return 1;  /* już zainicjalizowane -- idempotentne */
  DBusError err;
  dbus_error_init(&err);
  g_conn = dbus_bus_get(DBUS_BUS_SESSION, &err);
  if (dbus_error_is_set(&err)) {
    dbus_error_free(&err);
  }
  if (!g_conn) return 0;
  dbus_connection_set_exit_on_disconnect(g_conn, FALSE);

  dbus_error_init(&err);
  int ret = dbus_bus_request_name(g_conn, "org.freedesktop.Notifications",
                                   DBUS_NAME_FLAG_DO_NOT_QUEUE, &err);
  if (dbus_error_is_set(&err)) {
    dbus_error_free(&err);
  }
  if (ret != DBUS_REQUEST_NAME_REPLY_PRIMARY_OWNER &&
      ret != DBUS_REQUEST_NAME_REPLY_ALREADY_OWNER) {
    /* Ktoś inny (typowo demon powiadomień GNOME/KDE/dunst) już ma tę
       nazwę i nie prosiliśmy o REPLACE_EXISTING (świadomie -- odbieranie
       roli serwera powiadomień istniejącej, aktywnej sesji byłoby
       zaskakujące i potencjalnie zrywające inne aplikacje w trakcie
       wysyłania). Cichy, udokumentowany brak integracji w TEJ sesji --
       patrz duży komentarz na górze pliku. */
    g_conn = NULL;
    return 0;
  }
  return 1;
}

int zde_notify_dbus_poll(char *out_app, int out_app_len,
                          char *out_summary, int out_summary_len,
                          char *out_body, int out_body_len) {
  if (!g_conn) return 0;

  dbus_connection_read_write(g_conn, 0);
  DBusMessage *msg;
  while ((msg = dbus_connection_pop_message(g_conn)) != NULL) {
    if (dbus_message_is_method_call(msg, "org.freedesktop.Notifications", "Notify")) {
      zde_handle_notify(msg);
    } else if (dbus_message_is_method_call(msg, "org.freedesktop.Notifications", "GetCapabilities")) {
      const char *caps[] = {"body"};
      DBusMessage *reply = dbus_message_new_method_return(msg);
      if (reply) {
        DBusMessageIter iter, arr;
        dbus_message_iter_init_append(reply, &iter);
        dbus_message_iter_open_container(&iter, DBUS_TYPE_ARRAY, "s", &arr);
        dbus_message_iter_append_basic(&arr, DBUS_TYPE_STRING, &caps[0]);
        dbus_message_iter_close_container(&iter, &arr);
        dbus_connection_send(g_conn, reply, NULL);
        dbus_message_unref(reply);
      }
    } else if (dbus_message_is_method_call(msg, "org.freedesktop.Notifications", "GetServerInformation")) {
      const char *info[4] = {"ZDE", "Zenit Linux", "0.2.0", "1.2"};
      zde_reply_strings(msg, info, 4);
    } else if (dbus_message_is_method_call(msg, "org.freedesktop.Notifications", "CloseNotification")) {
      DBusMessage *reply = dbus_message_new_method_return(msg);
      if (reply) {
        dbus_connection_send(g_conn, reply, NULL);
        dbus_message_unref(reply);
      }
    } else if (dbus_message_is_method_call(msg, "org.freedesktop.DBus.Introspectable", "Introspect")) {
      const char *xml =
        "<node><interface name=\"org.freedesktop.Notifications\">"
        "<method name=\"Notify\"/><method name=\"GetCapabilities\"/>"
        "<method name=\"GetServerInformation\"/><method name=\"CloseNotification\"/>"
        "</interface></node>";
      zde_reply_strings(msg, &xml, 1);
    } else if (dbus_message_get_type(msg) == DBUS_MESSAGE_TYPE_METHOD_CALL) {
      /* Nieznana metoda -- odpowiadamy błędem, żeby nadawca (czekający
         na odpowiedź synchronicznie) nie zawisł w nieskończoność. */
      DBusMessage *errReply = dbus_message_new_error(msg, DBUS_ERROR_UNKNOWN_METHOD,
                                                       "ZDE notification service: method not implemented");
      if (errReply) {
        dbus_connection_send(g_conn, errReply, NULL);
        dbus_message_unref(errReply);
      }
    }
    dbus_message_unref(msg);
  }

  return zde_ring_pop(out_app, out_app_len, out_summary, out_summary_len,
                       out_body, out_body_len);
}
