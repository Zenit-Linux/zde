import std/times
import wlroots
import types

## Rozbudowa v0.1 ("Aurora"/DRM). Dwie ODDZIELNE rzeczy tu się dzieją --
## celowo nie mylić:
##
## 1. `wlr_idle_notifier_v1` (funkcje wlroots, patrz `wlroots.nim`) to
##    tylko PROTOKÓŁ (`ext-idle-notify-v1`) -- kompozytor informuje przez
##    niego KLIENTÓW Wayland o aktywności, a to sami KLIENCI proszą
##    "obudź mnie po X ms bezczynności" i sami decydują, co z tym zrobić
##    (np. zablokować ekran). Samo wystawienie tego protokołu NIE usypia
##    niczego -- to gotowość dla przyszłego klienta (np. demona blokady),
##    nie działająca funkcja sama w sobie: dziś żaden komponent ZDE nie
##    jest jeszcze takim klientem (`zde-shell` nie ma bindingów
##    protokołów KLIENCKICH do tego -- patrz ograniczenia w README).
##
## 2. DPMS (`checkIdle`/`blankOutputs`/`wakeOutputs` niżej) to WŁASNA,
##    wewnętrzna logika `zde-comp` -- działa NIEZALEŻNIE od tego, czy
##    jakikolwiek klient słucha protokołu z punktu 1. Po `DpmsTimeoutSec`
##    sekund bez ruchu myszy/klawiatury kompozytor SAM wygasza wszystkie
##    wyjścia (`wlr_output_state` z `enabled: false`, ten sam mechanizm
##    co włączanie wyjścia w `onNewOutput`, `wlcomp/output.nim`), a przy
##    pierwszym ruchu/klawiszu włącza je z powrotem. To jest realna,
##    działająca funkcja bez udziału żadnego klienta.

const
  DpmsTimeoutSec = 300.0     ## 5 minut -- typowa domyślna wartość DPMS w DE
  ## Co ile sprawdzamy, czy minął czas -- NIE musi (i nie powinien) być
  ## równy `DpmsTimeoutSec`: krótszy okres sprawdzania tylko zwiększa
  ## precyzję wygaszenia (błąd co najwyżej o `TimerTickMs`), nie zużywa
  ## realnie zasobów (to i tak tylko odczyt jednego floata co kilka sekund).
  TimerTickMs = 5000'i32

proc setOutputEnabled(o: ptr WlrOutput, enabled: bool) =
  ## Ten sam mechanizm co włączanie wyjścia w `onNewOutput`
  ## (`wlcomp/output.nim`) -- `wlr_output_state`, nie przestarzałe
  ## `wlr_output_enable`. Celowo NIE dotykamy trybu (`wlrOutputStateSetMode`)
  ## przy wygaszaniu/budzeniu -- tryb się nie zmienia, zmienia się tylko
  ## `enabled`.
  var state: WlrOutputState
  wlrOutputStateInit(addr state)
  wlrOutputStateSetEnabled(addr state, enabled)
  discard wlrOutputCommitState(o, addr state)
  wlrOutputStateFinish(addr state)

proc blankOutputs(server: Server) =
  if server.outputsBlanked: return
  stderr.writeLine("zde-comp: DPMS -- brak aktywności od " & $int(DpmsTimeoutSec) & "s, wygaszam wyjścia")
  for output in server.outputs:
    setOutputEnabled(output.wlrOutput, false)
  server.outputsBlanked = true

proc wakeOutputs(server: Server) =
  if not server.outputsBlanked: return
  stderr.writeLine("zde-comp: DPMS -- wybudzam wyjścia")
  for output in server.outputs:
    setOutputEnabled(output.wlrOutput, true)
    ## Wyjście było wyłączone, więc jego pętla `onOutputFrame` stała w
    ## miejscu z tego samego powodu co po powrocie z VT (patrz duży
    ## komentarz przy `wlrOutputScheduleFrame` w `wlroots.nim`) -- trzeba
    ## jawnie poprosić o nową klatkę, inaczej ekran zostaje czarny mimo
    ## że wyjście jest już `enabled`.
    wlrOutputScheduleFrame(output.wlrOutput)
  server.outputsBlanked = false

proc notifyActivity*(server: Server) =
  ## Wołane z `wlcomp/input.nim` przy KAŻDYM zdarzeniu klawiatury/kursora
  ## (ruch, przycisk, klawisz, scroll -- patrz wywołania w `input.nim`).
  server.lastInputActivity = epochTime()
  if server.idleNotifier != nil:
    wlrIdleNotifierV1NotifyActivity(server.idleNotifier, server.seat)
  if server.outputsBlanked:
    wakeOutputs(server)

proc onDpmsTimer(data: pointer): cint {.cdecl.} =
  ## `data` to surowy wskaźnik na `Server` (rzutowany w `hookIdle` niżej).
  ## Bezpieczne tak długo, jak `Server` żyje przez cały czas działania
  ## `zde-comp` (jeden globalny, długożyjący obiekt w `main.nim` -- patrz
  ## `gServer` -- Nim/ARC nie przenosi obiektów w pamięci, więc surowy
  ## wskaźnik przechowywany po stronie C pozostaje ważny).
  let server = cast[Server](data)
  if not server.outputsBlanked and epochTime() - server.lastInputActivity >= DpmsTimeoutSec:
    blankOutputs(server)
  ## `wl_event_source_timer_update` uzbraja timer TYLKO NA JEDNO kolejne
  ## wywołanie (patrz komentarz w `wlroots.nim`) -- musimy się sami
  ## przezbroić co klatkę timera, żeby dalej tykał cyklicznie.
  discard wlEventSourceTimerUpdate(server.dpmsTimerSource, TimerTickMs)
  0

proc hookIdle*(server: Server) =
  server.lastInputActivity = epochTime()
  server.idleNotifier = wlrIdleNotifierV1Create(server.display)
  let eventLoop = wlDisplayGetEventLoop(server.display)
  server.dpmsTimerSource = wlEventLoopAddTimer(eventLoop, onDpmsTimer, cast[pointer](server))
  discard wlEventSourceTimerUpdate(server.dpmsTimerSource, TimerTickMs)
