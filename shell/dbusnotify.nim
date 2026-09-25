{.passc: gorge("pkg-config --cflags dbus-1").}
{.passl: gorge("pkg-config --libs dbus-1").}
{.compile: "dbus_notify_shim.c".}

proc zdeNotifyDbusInitC(): cint {.importc: "zde_notify_dbus_init", header: "dbus_notify_shim.h".}
proc zdeNotifyDbusPollC(outApp: cstring, outAppLen: cint,
                         outSummary: cstring, outSummaryLen: cint,
                         outBody: cstring, outBodyLen: cint): cint
  {.importc: "zde_notify_dbus_poll", header: "dbus_notify_shim.h".}

const BufCap = 512

var
  dbusNotifyInitTried = false
  dbusNotifyReady = false

proc ensureDbusNotifyInit() =
  ## Ponawia próbę połączenia, dopóki się nie powiedzie -- `dbus-daemon`
  ## mógł jeszcze nie wystartować w chwili startu `zde-shell` (kolejność
  ## uruchamiania usług sesji przy logowaniu nie jest gwarantowana), więc
  ## JEDNORAZOWA nieudana próba na starcie nie powinna trwale wyłączać tej
  ## integracji na cały czas życia sesji. Sama funkcja C
  ## (`zde_notify_dbus_init`) jest idempotentna, więc powtarzanie
  ## wywołania jest tanie i bezpieczne.
  if not dbusNotifyReady:
    dbusNotifyReady = zdeNotifyDbusInitC() != 0

proc pollDbusNotification*(): tuple[got: bool, app, summary, body: string] =
  ## Odpytuje serwer DBus NIEBLOKUJĄCO. Wołane raz na sekundę z
  ## `tickMain` w `shell.nim` (patrz `tickDbusNotifications` w
  ## `notifications.nim`) -- ta sama kadencja co reszta pollingu w tym
  ## module (schowek, zmiany plików itd.).
  ensureDbusNotifyInit()
  if not dbusNotifyReady:
    return (false, "", "", "")
  var appBuf = newString(BufCap)
  var summaryBuf = newString(BufCap)
  var bodyBuf = newString(BufCap)
  let got = zdeNotifyDbusPollC(cstring(appBuf), BufCap.cint,
                                cstring(summaryBuf), BufCap.cint,
                                cstring(bodyBuf), BufCap.cint)
  if got == 0:
    return (false, "", "", "")
  ## `$cstring(...)` zatrzymuje się na pierwszym bajcie zerowym -- bufor
  ## Nim-owy jest dłuższy niż faktyczna treść, ale to bezpiecznie obcina
  ## do prawdziwej długości C-stringa wypełnionego przez `zde_ring_pop`.
  (true, $cstring(appBuf), $cstring(summaryBuf), $cstring(bodyBuf))
