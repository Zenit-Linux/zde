import std/os
import wlroots
import types
import output
import toplevel
import input

proc main() =
  let server = Server()
  server.display = wlDisplayCreate()
  # Od wlroots 0.18 wlr_backend_autocreate() bierze wl_event_loop, nie
  # wl_display bezpośrednio.
  let eventLoop = wlDisplayGetEventLoop(server.display)
  server.backend = wlrBackendAutocreate(eventLoop)
  if server.backend == nil:
    quit("zde-comp: wlr_backend_autocreate() nie powiodło się")

  server.renderer = wlrRendererAutocreate(server.backend)
  discard wlrRendererInitWlDisplay(server.renderer, server.display)
  server.allocator = wlrAllocatorAutocreate(server.backend, server.renderer)

  zdeDisplayInitShm(server.display)
  server.compositor = wlrCompositorCreate(server.display, 5, server.renderer)
  discard wlrSubcompositorCreate(server.display)
  discard wlrDataDeviceManagerCreate(server.display)

  server.outputLayout = wlrOutputLayoutCreate(server.display)
  server.scene = wlrSceneCreate()
  server.sceneLayout = wlrSceneAttachOutputLayout(server.scene, server.outputLayout)

  server.xdgShell = wlrXdgShellCreate(server.display, 3)
  zdeSignalAdd(addr xdgShellEvents(server.xdgShell).newSurface, addr server.newXdgSurfaceL, onNewXdgSurface)

  server.cursor = wlrCursorCreate()
  wlrCursorAttachOutputLayout(server.cursor, server.outputLayout)
  server.xcursorMgr = wlrXcursorManagerCreate(nil, CursorSizePx)
  discard wlrXcursorManagerLoad(server.xcursorMgr, 1.0)

  zdeSignalAdd(addr cursorEvents(server.cursor).motion, addr server.cursorMotionL, onCursorMotion)
  zdeSignalAdd(addr cursorEvents(server.cursor).motionAbsolute, addr server.cursorMotionAbsL, onCursorMotionAbsolute)
  zdeSignalAdd(addr cursorEvents(server.cursor).button, addr server.cursorButtonL, onCursorButton)
  zdeSignalAdd(addr cursorEvents(server.cursor).axis, addr server.cursorAxisL, onCursorAxis)
  zdeSignalAdd(addr cursorEvents(server.cursor).frame, addr server.cursorFrameL, onCursorFrame)

  server.seat = wlrSeatCreate(server.display, SeatName)

  zdeSignalAdd(addr backendEvents(server.backend).newOutput, addr server.newOutputL, onNewOutput)
  zdeSignalAdd(addr backendEvents(server.backend).newInput, addr server.newInputL, onNewInput)

  if not wlrBackendStart(server.backend):
    wlrBackendDestroy(server.backend)
    wlDisplayDestroy(server.display)
    quit("zde-comp: wlr_backend_start() nie powiodło się")

  let socket = wlDisplayAddSocketAuto(server.display)
  if socket == nil:
    wlrBackendDestroy(server.backend)
    quit("zde-comp: nie udało się utworzyć socketu Waylanda")
  putEnv("WAYLAND_DISPLAY", $socket)

  server.xwayland = wlrXwaylandCreate(server.display, server.compositor, false)
  if server.xwayland != nil:
    wlrXwaylandSetSeat(server.xwayland, server.seat)
    stderr.writeLine("zde-comp: XWayland gotowy na DISPLAY=" & "(patrz zmienna środowiskowa DISPLAY procesu Xwayland)")

  stderr.writeLine("zde-comp: uruchomiony na WAYLAND_DISPLAY=" & $socket)
  wlDisplayRun(server.display)

  wlDisplayDestroyClients(server.display)
  if server.xwayland != nil:
    wlrXwaylandDestroy(server.xwayland)
  wlDisplayDestroy(server.display)

when isMainModule:
  main()
