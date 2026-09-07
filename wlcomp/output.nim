import std/[posix, sequtils]
import wlroots
import types
import ../zdeconfig

proc outputName(wlrOutput: ptr WlrOutput): string =
  ## `name` to `char[24]` w C -- ucinamy na pierwszym \0.
  for c in wlrOutput.name:
    if c == '\0': break
    result.add(c)

proc onOutputFrame*(listener: ptr WlListener, data: pointer) {.cdecl.} =
  let output = containerOf(listener, Output, OutputObj, frameL)
  var now: posix.Timespec
  discard clock_gettime(CLOCK_MONOTONIC, now)
  discard wlrSceneOutputCommit(output.sceneOutput)
  wlrSceneOutputSendFrameDone(output.sceneOutput, cast[ptr wlroots.Timespec](addr now))

proc onOutputDestroy*(listener: ptr WlListener, data: pointer) {.cdecl.} =
  let output = containerOf(listener, Output, OutputObj, destroyL)
  zdeListRemove(addr output.frameL.link)
  zdeListRemove(addr output.destroyL.link)
  output.server.outputs.keepItIf(it != output)

proc applyOutputPosition(server: Server, wlrOutput: ptr WlrOutput, cfg: ZdeConfig) =
  let name = outputName(wlrOutput)
  for m in cfg.monitors:
    if m.name == name and m.enabled:
      wlrOutputLayoutAdd(server.outputLayout, wlrOutput, cint(m.x), cint(m.y))
      return
  wlrOutputLayoutAddAuto(server.outputLayout, wlrOutput)

proc reloadOutputLayout*(server: Server) =
  ## Wołane z obsługi SIGHUP (main.nim) -- ponownie wczytuje układ
  ## monitorów z configu i przestawia WSZYSTKIE aktualnie podłączone
  ## wyjścia na nowe pozycje, bez restartu kompozytora. `wlr_output_layout`
  ## sam powiadamia scenę o zmianie (przez `sceneLayout`, spięte przy
  ## starcie w main.nim) -- okna/warstwy po prostu renderują się we
  ## właściwym miejscu od następnej klatki.
  let cfg = zdeconfig.loadConfig()
  for output in server.outputs:
    applyOutputPosition(server, output.wlrOutput, cfg)
  stderr.writeLine("zde-comp: przeładowano układ monitorów (" & $server.outputs.len & " wyjść)")

proc onNewOutput*(listener: ptr WlListener, data: pointer) {.cdecl.} =
  let server = containerOf(listener, Server, ServerObj, newOutputL)
  let wlrOutput = cast[ptr WlrOutput](data)

  discard wlrOutputInitRender(wlrOutput, server.allocator, server.renderer)

  # Od wlroots 0.18 tryb/enable/commit idą przez wlr_output_state, nie przez
  # osobne wlr_output_set_mode/wlr_output_enable/wlr_output_commit (te
  # zniknęły z nagłówków -- stąd "implicit declaration" na starszym kodzie).
  var state: WlrOutputState
  wlrOutputStateInit(addr state)
  wlrOutputStateSetEnabled(addr state, true)
  let mode = wlrOutputPreferredMode(wlrOutput)
  if mode != nil:
    wlrOutputStateSetMode(addr state, mode)
  let committed = wlrOutputCommitState(wlrOutput, addr state)
  wlrOutputStateFinish(addr state)
  if not committed:
    stderr.writeLine("zde-comp: nie udało się włączyć wyjścia")
    return

  let output = Output(server: server, wlrOutput: wlrOutput)
  zdeSignalAdd(addr outputEvents(wlrOutput).frame, addr output.frameL, onOutputFrame)
  zdeSignalAdd(addr outputEvents(wlrOutput).destroy, addr output.destroyL, onOutputDestroy)
  server.outputs.add(output)

  ## NAPRAWIONY BRAK: układ wielu monitorów był zawsze automatyczny
  ## (`wlr_output_layout_add_auto` -- wlroots samo dobiera "sensowne"
  ## położenie, zwykle rząd obok siebie). Aplikacja "Ustawienia"
  ## (apps/settings/settings.nim) pozwala teraz użytkownikowi ręcznie
  ## ułożyć monitory i zapisuje to do tego samego pliku konfiguracyjnego
  ## (zdeconfig.nim), kluczowanego nazwą wyjścia (np. "eDP-1", "HDMI-A-1").
  ## Jeśli w configu jest wpis dla TEGO wyjścia i jest `enabled`, używamy
  ## jawnej pozycji z configu -- inaczej wracamy do automatycznego układu
  ## (np. dla monitora podłączonego po raz pierwszy, jeszcze nieopisanego
  ## w Ustawieniach). To samo dzieje się później przy SIGHUP (patrz
  ## `reloadOutputLayout` wyżej), bez potrzeby restartu.
  applyOutputPosition(server, wlrOutput, zdeconfig.loadConfig())

  output.sceneOutput = wlrSceneOutputCreate(server.scene, wlrOutput)
  wlrOutputCreateGlobal(wlrOutput, server.display)  # kompatybilne 0.17/0.18 (patrz shim.c)
