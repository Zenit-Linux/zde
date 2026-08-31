import std/[posix, sequtils]
import wlroots
import types

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

  wlrOutputLayoutAddAuto(server.outputLayout, wlrOutput)
  output.sceneOutput = wlrSceneOutputCreate(server.scene, wlrOutput)
  wlrOutputCreateGlobal(wlrOutput, server.display)  # od 0.18 wymaga jawnego display
