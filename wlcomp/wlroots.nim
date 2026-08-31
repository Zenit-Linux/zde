import std/[os, strutils]

proc detectPkgConfigName(candidates: openArray[string]): string =
  ## Różne dystrybucje nazywają plik .pc dla wlroots inaczej: Ubuntu (od
  ## 24.10) trzyma kilka wersji równolegle jako `wlroots-0.20.pc` itd.,
  ## a Debian (na niektórych wersjach) też potrafi używać wersjonowanej
  ## nazwy zamiast prostego `wlroots.pc`. Zamiast wymagać ręcznego
  ## `ln -s wlroots-0.20.pc wlroots.pc`, próbujemy po kolei znanych nazw
  ## i używamy pierwszej, którą faktycznie widzi `pkg-config --exists`.
  for c in candidates:
    let (_, code) = gorgeEx("pkg-config --exists " & c)
    if code == 0:
      return c
  return ""

const wlrootsCandidates = [
  "wlroots", "wlroots-0.20", "wlroots-0.19", "wlroots-0.18", "wlroots-0.17"
]
const wlrootsPkgName = detectPkgConfigName(wlrootsCandidates)

when wlrootsPkgName.len == 0:
  {.error: "pkg-config nie widzi żadnej z nazw: " & wlrootsCandidates.join(", ") &
           ". Zainstaluj pakiet -dev dla wlroots (>= 0.18) -- np. `sudo apt " &
           "install libwlroots-dev` albo, jeśli Twoja dystrybucja wersjonuje " &
           "równolegle, `libwlroots-0.20-dev`. Sprawdź ręcznie: " &
           "`pkg-config --list-all | grep -i wlroots`.".}

proc pkgConfigOrDie(pkgName, mode: string): string =
  ## Zwykłe `gorge()` po cichu zwraca połączone stdout+stderr bez sprawdzania
  ## kodu wyjścia -- jeśli `pkg-config` nie znajdzie paczki, jego komunikat
  ## błędu ("Package X was not found in the pkg-config search path...")
  ## trafiał wtedy DOSŁOWNIE jako flagi do gcc, co dawało lawinę bezsensownych
  ## błędów linkera zamiast jednego czytelnego komunikatu. `gorgeEx` daje kod
  ## wyjścia osobno -- sprawdzamy go i przerywamy kompilację jasnym błędem.
  let (output, code) = gorgeEx("pkg-config " & mode & " " & pkgName)
  if code != 0:
    raise newException(ValueError, "\n\n" &
      "==============================================================\n" &
      "BŁĄD: pkg-config nie znalazł paczki '" & pkgName & "' (" & mode & ").\n" &
      "Zainstaluj odpowiedni pakiet -dev, np. na Debian/Ubuntu:\n" &
      "  sudo apt install lib" & pkgName & "-dev\n" &
      "Sprawdź: `pkg-config --exists " & pkgName & " && echo OK`.\n" &
      "Jeśli paczka jest zainstalowana w niestandardowym miejscu, ustaw\n" &
      "PKG_CONFIG_PATH tak, żeby wskazywała katalog z " & pkgName & ".pc.\n" &
      "Surowe wyjście pkg-config:\n" & output & "\n" &
      "==============================================================\n")
  output

{.passC: "-DWLR_USE_UNSTABLE".}
{.passC: "-I" & currentSourcePath().parentDir() / "protocol".}
{.passC: pkgConfigOrDie(wlrootsPkgName, "--cflags").}
{.passL: pkgConfigOrDie(wlrootsPkgName, "--libs").}
{.passC: pkgConfigOrDie("wayland-server", "--cflags").}
{.passL: pkgConfigOrDie("wayland-server", "--libs").}
{.passC: pkgConfigOrDie("xkbcommon", "--cflags").}
{.passL: pkgConfigOrDie("xkbcommon", "--libs").}
{.passL: "-lm".}

{.compile: "shim.c".}

# ---------------------------------------------------------------------------
# wayland-server-core: wl_display, wl_list, wl_signal, wl_listener
# ---------------------------------------------------------------------------

type
  WlDisplay* {.importc: "struct wl_display", header: "<wayland-server-core.h>", incompleteStruct.} = object
  WlEventLoop* {.importc: "struct wl_event_loop", header: "<wayland-server-core.h>", incompleteStruct.} = object
  WlClient* {.importc: "struct wl_client", header: "<wayland-server-core.h>", incompleteStruct.} = object
  WlResource* {.importc: "struct wl_resource", header: "<wayland-server-core.h>", incompleteStruct.} = object
  WlGlobal* {.importc: "struct wl_global", header: "<wayland-server-core.h>", incompleteStruct.} = object

  WlList* {.importc: "struct wl_list", header: "<wayland-server-core.h>", incompleteStruct.} = object
    prev*, next*: pointer

  WlSignal* {.importc: "struct wl_signal", header: "<wayland-server-core.h>", incompleteStruct.} = object
    listenerList*: WlList

  WlNotifyFunc* = proc(listener: ptr WlListener, data: pointer) {.cdecl.}

  WlListener* {.importc: "struct wl_listener", header: "<wayland-server-core.h>", incompleteStruct.} = object
    link*: WlList
    notify*: WlNotifyFunc

proc wlDisplayCreate*(): ptr WlDisplay {.importc: "wl_display_create", header: "<wayland-server-core.h>".}
proc wlDisplayDestroy*(d: ptr WlDisplay) {.importc: "wl_display_destroy", header: "<wayland-server-core.h>".}
proc wlDisplayGetEventLoop*(d: ptr WlDisplay): ptr WlEventLoop {.importc: "wl_display_get_event_loop", header: "<wayland-server-core.h>".}
proc wlDisplayAddSocketAuto*(d: ptr WlDisplay): cstring {.importc: "wl_display_add_socket_auto", header: "<wayland-server-core.h>".}
proc wlDisplayRun*(d: ptr WlDisplay) {.importc: "wl_display_run", header: "<wayland-server-core.h>".}
proc wlDisplayDestroyClients*(d: ptr WlDisplay) {.importc: "wl_display_destroy_clients", header: "<wayland-server-core.h>".}
proc wlDisplayTerminate*(d: ptr WlDisplay) {.importc: "wl_display_terminate", header: "<wayland-server-core.h>".}

## Zamiast wl_signal_add/wl_list_init (static inline, brak symbolu do
## zlinkowania) -- wołamy nasze wrappery z shim.c.
proc zdeSignalAdd*(signal: ptr WlSignal, listener: ptr WlListener, notify: WlNotifyFunc) {.importc: "zde_signal_add", header: "shim.h".}
proc zdeListInit*(list: ptr WlList) {.importc: "zde_wl_list_init", header: "shim.h".}
proc zdeListRemove*(elm: ptr WlList) {.importc: "zde_wl_list_remove", header: "shim.h".}
proc zdeDisplayInitShm*(d: ptr WlDisplay) {.importc: "zde_display_init_shm", header: "shim.h".}

# ---------------------------------------------------------------------------
# Podstawowe typy geometrii
# ---------------------------------------------------------------------------

type
  WlrBox* {.importc: "struct wlr_box", header: "wlr/util/box.h", incompleteStruct.} = object
    x*, y*, width*, height*: cint

  Timespec* {.importc: "struct timespec", header: "<time.h>", incompleteStruct.} = object
    tvSec* {.importc: "tv_sec".}: clong
    tvNsec* {.importc: "tv_nsec".}: clong

# ---------------------------------------------------------------------------
# Backend / renderer / allocator
# ---------------------------------------------------------------------------

type
  WlrBackend* {.importc: "struct wlr_backend", header: "wlr/backend.h", incompleteStruct.} = object
    ## `events` to zagnieżdżony anonimowy struct w C -- odtwarzamy go jako
    ## osobny typ i importujemy z odpowiednim offsetem pola.
  WlrBackendEvents* {.importc: "struct wlr_backend", header: "wlr/backend.h", incompleteStruct.} = object
    destroy* {.importc: "events.destroy".}: WlSignal
    newInput* {.importc: "events.new_input".}: WlSignal
    newOutput* {.importc: "events.new_output".}: WlSignal

  WlrRenderer* {.importc: "struct wlr_renderer", header: "wlr/render/wlr_renderer.h", incompleteStruct.} = object
  WlrAllocator* {.importc: "struct wlr_allocator", header: "wlr/render/allocator.h", incompleteStruct.} = object

proc wlrBackendAutocreate*(loop: ptr WlEventLoop, sessionPtr: pointer = nil): ptr WlrBackend {.importc: "wlr_backend_autocreate", header: "wlr/backend.h".}
proc wlrBackendStart*(b: ptr WlrBackend): bool {.importc: "wlr_backend_start", header: "wlr/backend.h".}
proc wlrBackendDestroy*(b: ptr WlrBackend) {.importc: "wlr_backend_destroy", header: "wlr/backend.h".}
proc backendEvents*(b: ptr WlrBackend): ptr WlrBackendEvents {.inline.} = cast[ptr WlrBackendEvents](b)

proc wlrRendererAutocreate*(b: ptr WlrBackend): ptr WlrRenderer {.importc: "wlr_renderer_autocreate", header: "wlr/render/wlr_renderer.h".}
proc wlrRendererInitWlDisplay*(r: ptr WlrRenderer, d: ptr WlDisplay): bool {.importc: "wlr_renderer_init_wl_display", header: "wlr/render/wlr_renderer.h".}
proc wlrAllocatorAutocreate*(b: ptr WlrBackend, r: ptr WlrRenderer): ptr WlrAllocator {.importc: "wlr_allocator_autocreate", header: "wlr/render/allocator.h".}

# ---------------------------------------------------------------------------
# Compositor / subcompositor / data device manager
# ---------------------------------------------------------------------------

type
  WlrCompositor* {.importc: "struct wlr_compositor", header: "wlr/types/wlr_compositor.h", incompleteStruct.} = object
  WlrSubcompositor* {.importc: "struct wlr_subcompositor", header: "wlr/types/wlr_subcompositor.h", incompleteStruct.} = object
  WlrDataDeviceManager* {.importc: "struct wlr_data_device_manager", header: "wlr/types/wlr_data_device.h", incompleteStruct.} = object
  WlrSurface* {.importc: "struct wlr_surface", header: "wlr/types/wlr_compositor.h", incompleteStruct.} = object

proc wlrCompositorCreate*(d: ptr WlDisplay, version: uint32, r: ptr WlrRenderer): ptr WlrCompositor {.importc: "wlr_compositor_create", header: "wlr/types/wlr_compositor.h".}
proc wlrSubcompositorCreate*(d: ptr WlDisplay): ptr WlrSubcompositor {.importc: "wlr_subcompositor_create", header: "wlr/types/wlr_subcompositor.h".}
proc wlrDataDeviceManagerCreate*(d: ptr WlDisplay): ptr WlrDataDeviceManager {.importc: "wlr_data_device_manager_create", header: "wlr/types/wlr_data_device.h".}

# ---------------------------------------------------------------------------
# Output + output layout + scene graph
# ---------------------------------------------------------------------------

type
  WlrOutput* {.importc: "struct wlr_output", header: "wlr/types/wlr_output.h", incompleteStruct.} = object
    name* {.importc: "name".}: array[24, char]

  WlrOutputEvents* {.importc: "struct wlr_output", header: "wlr/types/wlr_output.h", incompleteStruct.} = object
    frame* {.importc: "events.frame".}: WlSignal
    destroy* {.importc: "events.destroy".}: WlSignal

  WlrOutputMode* {.importc: "struct wlr_output_mode", header: "wlr/types/wlr_output.h", incompleteStruct.} = object

  WlrOutputLayout* {.importc: "struct wlr_output_layout", header: "wlr/types/wlr_output_layout.h", incompleteStruct.} = object

  WlrScene* {.importc: "struct wlr_scene", header: "wlr/types/wlr_scene.h", incompleteStruct.} = object
  WlrSceneNode* {.importc: "struct wlr_scene_node", header: "wlr/types/wlr_scene.h", incompleteStruct.} = object
    data* {.importc: "data".}: pointer
    parent* {.importc: "parent".}: ptr WlrSceneTree

  WlrSceneTree* {.importc: "struct wlr_scene_tree", header: "wlr/types/wlr_scene.h", incompleteStruct.} = object
    node* {.importc: "node".}: WlrSceneNode
  WlrSceneOutput* {.importc: "struct wlr_scene_output", header: "wlr/types/wlr_scene.h", incompleteStruct.} = object
  WlrSceneOutputLayout* {.importc: "struct wlr_scene_output_layout", header: "wlr/types/wlr_scene.h", incompleteStruct.} = object

proc outputEvents*(o: ptr WlrOutput): ptr WlrOutputEvents {.inline.} = cast[ptr WlrOutputEvents](o)

proc wlrOutputInitRender*(o: ptr WlrOutput, alloc: ptr WlrAllocator, r: ptr WlrRenderer): bool {.importc: "wlr_output_init_render", header: "wlr/types/wlr_output.h".}
proc wlrOutputPreferredMode*(o: ptr WlrOutput): ptr WlrOutputMode {.importc: "wlr_output_preferred_mode", header: "wlr/types/wlr_output.h".}
## Od wlroots 0.18 konfiguracja wyjścia (tryb/enable/commit) idzie przez
## `struct wlr_output_state`, nie przez proste `wlr_output_set_mode` /
## `wlr_output_enable` / `wlr_output_commit` (te trzy funkcje zniknęły z
## nagłówków -- stąd "implicit declaration" przy starszym kodzie pisanym
## pod wlroots 0.17). WlrOutputState NIE jest oznaczony `incompleteStruct`,
## bo alokujemy go na stosie (`var state: WlrOutputState`) -- C i tak użyje
## prawdziwego rozmiaru z nagłówka.
type
  WlrOutputState* {.importc: "struct wlr_output_state", header: "wlr/types/wlr_output.h".} = object

proc wlrOutputStateInit*(state: ptr WlrOutputState) {.importc: "wlr_output_state_init", header: "wlr/types/wlr_output.h".}
proc wlrOutputStateFinish*(state: ptr WlrOutputState) {.importc: "wlr_output_state_finish", header: "wlr/types/wlr_output.h".}
proc wlrOutputStateSetEnabled*(state: ptr WlrOutputState, enabled: bool) {.importc: "wlr_output_state_set_enabled", header: "wlr/types/wlr_output.h".}
proc wlrOutputStateSetMode*(state: ptr WlrOutputState, mode: ptr WlrOutputMode) {.importc: "wlr_output_state_set_mode", header: "wlr/types/wlr_output.h".}
proc wlrOutputCommitState*(o: ptr WlrOutput, state: ptr WlrOutputState): bool {.importc: "wlr_output_commit_state", header: "wlr/types/wlr_output.h".}
## `wlr_output_create_global` od 0.18 wymaga jawnie podanego `wl_display`
## (wcześniej brał go z kontekstu outputu automatycznie).
proc wlrOutputCreateGlobal*(o: ptr WlrOutput, display: ptr WlDisplay) {.importc: "wlr_output_create_global", header: "wlr/types/wlr_output.h".}

proc wlrOutputLayoutCreate*(display: ptr WlDisplay): ptr WlrOutputLayout {.importc: "wlr_output_layout_create", header: "wlr/types/wlr_output_layout.h".}
proc wlrOutputLayoutAddAuto*(layout: ptr WlrOutputLayout, o: ptr WlrOutput) {.importc: "wlr_output_layout_add_auto", header: "wlr/types/wlr_output_layout.h".}

proc wlrSceneCreate*(): ptr WlrScene {.importc: "wlr_scene_create", header: "wlr/types/wlr_scene.h".}
proc wlrSceneAttachOutputLayout*(scene: ptr WlrScene, layout: ptr WlrOutputLayout): ptr WlrSceneOutputLayout {.importc: "wlr_scene_attach_output_layout", header: "wlr/types/wlr_scene.h".}
proc wlrSceneOutputCreate*(scene: ptr WlrScene, o: ptr WlrOutput): ptr WlrSceneOutput {.importc: "wlr_scene_output_create", header: "wlr/types/wlr_scene.h".}
proc wlrSceneOutputCommit*(so: ptr WlrSceneOutput, options: pointer = nil): bool {.importc: "wlr_scene_output_commit", header: "wlr/types/wlr_scene.h".}
proc wlrSceneOutputSendFrameDone*(so: ptr WlrSceneOutput, now: ptr Timespec) {.importc: "wlr_scene_output_send_frame_done", header: "wlr/types/wlr_scene.h".}
proc wlrSceneNodeSetPosition*(n: ptr WlrSceneNode, x, y: cint) {.importc: "wlr_scene_node_set_position", header: "wlr/types/wlr_scene.h".}
proc wlrSceneNodeRaiseToTop*(n: ptr WlrSceneNode) {.importc: "wlr_scene_node_raise_to_top", header: "wlr/types/wlr_scene.h".}
proc wlrSceneNodeDestroy*(n: ptr WlrSceneNode) {.importc: "wlr_scene_node_destroy", header: "wlr/types/wlr_scene.h".}
proc wlrSceneNodeAt*(n: ptr WlrSceneNode, lx, ly: cdouble, sx, sy: ptr cdouble): ptr WlrSceneNode {.importc: "wlr_scene_node_at", header: "wlr/types/wlr_scene.h".}
proc wlrSceneXdgSurfaceCreate*(parent: ptr WlrSceneTree, xdgSurface: pointer): ptr WlrSceneTree {.importc: "wlr_scene_xdg_surface_create", header: "wlr/types/wlr_scene.h".}
proc wlrSceneTreeFromNode*(n: ptr WlrSceneNode): ptr WlrSceneTree {.importc: "wlr_scene_tree_from_node", header: "wlr/types/wlr_scene.h".}

## `wlr_scene.tree` i `wlr_scene_tree.node` są zawsze pierwszym polem swojego
## struct-a (patrz nagłówek) -- więc rzutowanie wskaźnika na offset 0 daje
## bezpośrednio węzeł-korzeń całej sceny, bez potrzeby osobnej funkcji C.
proc sceneRootNode*(s: ptr WlrScene): ptr WlrSceneNode {.inline.} = cast[ptr WlrSceneNode](s)
proc treeNode*(t: ptr WlrSceneTree): ptr WlrSceneNode {.inline.} = cast[ptr WlrSceneNode](t)

# ---------------------------------------------------------------------------
# xdg-shell
# ---------------------------------------------------------------------------

type
  WlrXdgShell* {.importc: "struct wlr_xdg_shell", header: "wlr/types/wlr_xdg_shell.h", incompleteStruct.} = object
  WlrXdgShellEvents* {.importc: "struct wlr_xdg_shell", header: "wlr/types/wlr_xdg_shell.h", incompleteStruct.} = object
    newSurface* {.importc: "events.new_surface".}: WlSignal

  WlrXdgSurfaceRole* {.importc: "enum wlr_xdg_surface_role", header: "wlr/types/wlr_xdg_shell.h".} = cint

  WlrXdgSurface* {.importc: "struct wlr_xdg_surface", header: "wlr/types/wlr_xdg_shell.h", incompleteStruct.} = object
    surface* {.importc: "surface".}: ptr WlrSurface
    role* {.importc: "role".}: WlrXdgSurfaceRole
    toplevel* {.importc: "toplevel".}: ptr WlrXdgToplevel
    ## Od wlroots 0.18 to publiczne pole (dawniej trzeba było wołać
    ## `wlr_xdg_surface_get_geometry()`, którego już nie ma w nagłówkach).
    geometry* {.importc: "geometry".}: WlrBox

  WlrXdgSurfaceEvents* {.importc: "struct wlr_xdg_surface", header: "wlr/types/wlr_xdg_shell.h", incompleteStruct.} = object
    destroy* {.importc: "events.destroy".}: WlSignal

  WlrXdgToplevel* {.importc: "struct wlr_xdg_toplevel", header: "wlr/types/wlr_xdg_shell.h", incompleteStruct.} = object
    base* {.importc: "base".}: ptr WlrXdgSurface
    title* {.importc: "title".}: cstring
    appId* {.importc: "app_id".}: cstring

  WlrXdgToplevelEvents* {.importc: "struct wlr_xdg_toplevel", header: "wlr/types/wlr_xdg_shell.h", incompleteStruct.} = object
    requestMove* {.importc: "events.request_move".}: WlSignal
    requestResize* {.importc: "events.request_resize".}: WlSignal
    requestMaximize* {.importc: "events.request_maximize".}: WlSignal

const
  WlrXdgSurfaceRoleNone*: WlrXdgSurfaceRole = 0
  WlrXdgSurfaceRoleToplevel*: WlrXdgSurfaceRole = 1
  WlrXdgSurfaceRolePopup*: WlrXdgSurfaceRole = 2

proc wlrXdgShellCreate*(d: ptr WlDisplay, version: uint32): ptr WlrXdgShell {.importc: "wlr_xdg_shell_create", header: "wlr/types/wlr_xdg_shell.h".}
proc xdgShellEvents*(s: ptr WlrXdgShell): ptr WlrXdgShellEvents {.inline.} = cast[ptr WlrXdgShellEvents](s)
proc xdgSurfaceEvents*(s: ptr WlrXdgSurface): ptr WlrXdgSurfaceEvents {.inline.} = cast[ptr WlrXdgSurfaceEvents](s)
proc xdgToplevelEvents*(t: ptr WlrXdgToplevel): ptr WlrXdgToplevelEvents {.inline.} = cast[ptr WlrXdgToplevelEvents](t)

## `wlr_xdg_surface_get_geometry()` zniknęło z nagłówków w wlroots 0.18+ --
## `geometry` jest teraz zwykłym publicznym polem WlrXdgSurface (patrz wyżej).
proc wlrXdgToplevelSetActivated*(t: ptr WlrXdgToplevel, activated: bool): uint32 {.importc: "wlr_xdg_toplevel_set_activated", header: "wlr/types/wlr_xdg_shell.h".}
proc wlrXdgToplevelSetSize*(t: ptr WlrXdgToplevel, w, h: cint): uint32 {.importc: "wlr_xdg_toplevel_set_size", header: "wlr/types/wlr_xdg_shell.h".}
proc wlrXdgSurfaceSurfaceAt*(s: ptr WlrXdgSurface, sx, sy: cdouble, subX, subY: ptr cdouble): ptr WlrSurface {.importc: "wlr_xdg_surface_surface_at", header: "wlr/types/wlr_xdg_shell.h".}

# --- wlr_surface: map / unmap / destroy / commit sygnały -------------------

type
  WlrSurfaceEvents* {.importc: "struct wlr_surface", header: "wlr/types/wlr_compositor.h", incompleteStruct.} = object
    map* {.importc: "events.map".}: WlSignal
    unmap* {.importc: "events.unmap".}: WlSignal
    destroy* {.importc: "events.destroy".}: WlSignal
    commit* {.importc: "events.commit".}: WlSignal

proc surfaceEvents*(s: ptr WlrSurface): ptr WlrSurfaceEvents {.inline.} = cast[ptr WlrSurfaceEvents](s)

# ---------------------------------------------------------------------------
# Wejście: input_device, keyboard, pointer
# ---------------------------------------------------------------------------

type
  WlrInputDeviceType* {.importc: "enum wlr_input_device_type", header: "wlr/types/wlr_input_device.h".} = cint

  WlrInputDevice* {.importc: "struct wlr_input_device", header: "wlr/types/wlr_input_device.h", incompleteStruct.} = object
    `type`* {.importc: "type".}: WlrInputDeviceType

  WlrInputDeviceEvents* {.importc: "struct wlr_input_device", header: "wlr/types/wlr_input_device.h", incompleteStruct.} = object
    destroy* {.importc: "events.destroy".}: WlSignal

  WlrKeyboard* {.importc: "struct wlr_keyboard", header: "wlr/types/wlr_keyboard.h", incompleteStruct.} = object
  WlrKeyboardEvents* {.importc: "struct wlr_keyboard", header: "wlr/types/wlr_keyboard.h", incompleteStruct.} = object
    key* {.importc: "events.key".}: WlSignal
    modifiers* {.importc: "events.modifiers".}: WlSignal

  WlrKeyboardKeyEvent* {.importc: "struct wlr_keyboard_key_event", header: "wlr/types/wlr_keyboard.h", incompleteStruct.} = object
    timeMsec* {.importc: "time_msec".}: uint32
    keycode* {.importc: "keycode".}: uint32
    state* {.importc: "state".}: cint  # enum wl_keyboard_key_state

  WlrPointer* {.importc: "struct wlr_pointer", header: "wlr/types/wlr_pointer.h", incompleteStruct.} = object
  WlrPointerEvents* {.importc: "struct wlr_pointer", header: "wlr/types/wlr_pointer.h", incompleteStruct.} = object
    motion* {.importc: "events.motion".}: WlSignal
    motionAbsolute* {.importc: "events.motion_absolute".}: WlSignal
    button* {.importc: "events.button".}: WlSignal
    axis* {.importc: "events.axis".}: WlSignal
    frame* {.importc: "events.frame".}: WlSignal

  WlrPointerMotionEvent* {.importc: "struct wlr_pointer_motion_event", header: "wlr/types/wlr_pointer.h", incompleteStruct.} = object
    timeMsec* {.importc: "time_msec".}: uint32
    deltaX* {.importc: "delta_x".}: cdouble
    deltaY* {.importc: "delta_y".}: cdouble

  WlrPointerButtonEvent* {.importc: "struct wlr_pointer_button_event", header: "wlr/types/wlr_pointer.h", incompleteStruct.} = object
    timeMsec* {.importc: "time_msec".}: uint32
    button* {.importc: "button".}: uint32
    state* {.importc: "state".}: cint

  WlrPointerAxisEvent* {.importc: "struct wlr_pointer_axis_event", header: "wlr/types/wlr_pointer.h", incompleteStruct.} = object
    timeMsec* {.importc: "time_msec".}: uint32
    orientation* {.importc: "orientation".}: cint
    delta* {.importc: "delta".}: cdouble

const
  WlrInputDeviceKeyboard*: WlrInputDeviceType = 0
  WlrInputDevicePointer*: WlrInputDeviceType = 1

proc wlrKeyboardFromInputDevice*(dev: ptr WlrInputDevice): ptr WlrKeyboard {.importc: "wlr_keyboard_from_input_device", header: "wlr/types/wlr_keyboard.h".}
proc wlrPointerFromInputDevice*(dev: ptr WlrInputDevice): ptr WlrPointer {.importc: "wlr_pointer_from_input_device", header: "wlr/types/wlr_pointer.h".}
proc keyboardEvents*(k: ptr WlrKeyboard): ptr WlrKeyboardEvents {.inline.} = cast[ptr WlrKeyboardEvents](k)
proc pointerEvents*(p: ptr WlrPointer): ptr WlrPointerEvents {.inline.} = cast[ptr WlrPointerEvents](p)
## `wlr_keyboard.base`/`wlr_pointer.base` (typu `wlr_input_device`) jest
## zawsze PIERWSZYM polem swojego structa, więc żeby dostać się do wspólnego
## sygnału `destroy` (który siedzi na wlr_input_device, nie na wlr_keyboard
## ani wlr_pointer -- patrz komentarz w main.nim), wystarczy rzutowanie na
## offset 0, dokładnie jak przy scenie.
proc inputDeviceEvents*(dev: ptr WlrInputDevice): ptr WlrInputDeviceEvents {.inline.} = cast[ptr WlrInputDeviceEvents](dev)
proc asInputDevice*(k: ptr WlrKeyboard): ptr WlrInputDevice {.inline.} = cast[ptr WlrInputDevice](k)

proc wlrKeyboardSetRepeatInfo*(k: ptr WlrKeyboard, rate, delay: int32) {.importc: "wlr_keyboard_set_repeat_info", header: "wlr/types/wlr_keyboard.h".}
proc wlrKeyboardGetModifiers*(k: ptr WlrKeyboard): uint32 {.importc: "wlr_keyboard_get_modifiers", header: "wlr/types/wlr_keyboard.h".}

# ---------------------------------------------------------------------------
# xkbcommon (mapa klawiszy)
# ---------------------------------------------------------------------------

type
  XkbContext* {.importc: "struct xkb_context", header: "<xkbcommon/xkbcommon.h>", incompleteStruct.} = object
  XkbKeymap* {.importc: "struct xkb_keymap", header: "<xkbcommon/xkbcommon.h>", incompleteStruct.} = object
  XkbRuleNames* {.importc: "struct xkb_rule_names", header: "<xkbcommon/xkbcommon.h>", incompleteStruct.} = object
    rules* {.importc: "rules".}: cstring
    model* {.importc: "model".}: cstring
    layout* {.importc: "layout".}: cstring
    variant* {.importc: "variant".}: cstring
    options* {.importc: "options".}: cstring

proc xkbContextNew*(flags: cint): ptr XkbContext {.importc: "xkb_context_new", header: "<xkbcommon/xkbcommon.h>".}
proc xkbKeymapNewFromNames*(ctx: ptr XkbContext, names: ptr XkbRuleNames, flags: cint): ptr XkbKeymap {.importc: "xkb_keymap_new_from_names", header: "<xkbcommon/xkbcommon.h>".}
proc wlrKeyboardSetKeymap*(kb: ptr WlrKeyboard, keymap: ptr XkbKeymap): bool {.importc: "wlr_keyboard_set_keymap", header: "wlr/types/wlr_keyboard.h".}

# ---------------------------------------------------------------------------
# Seat, kursor, xcursor manager
# ---------------------------------------------------------------------------

type
  WlrSeat* {.importc: "struct wlr_seat", header: "wlr/types/wlr_seat.h", incompleteStruct.} = object
  WlrCursor* {.importc: "struct wlr_cursor", header: "wlr/types/wlr_cursor.h", incompleteStruct.} = object
    x* {.importc: "x".}: cdouble
    y* {.importc: "y".}: cdouble

  WlrCursorEvents* {.importc: "struct wlr_cursor", header: "wlr/types/wlr_cursor.h", incompleteStruct.} = object
    motion* {.importc: "events.motion".}: WlSignal
    motionAbsolute* {.importc: "events.motion_absolute".}: WlSignal
    button* {.importc: "events.button".}: WlSignal
    axis* {.importc: "events.axis".}: WlSignal
    frame* {.importc: "events.frame".}: WlSignal
  WlrXcursorManager* {.importc: "struct wlr_xcursor_manager", header: "wlr/types/wlr_xcursor_manager.h", incompleteStruct.} = object

proc wlrSeatCreate*(d: ptr WlDisplay, name: cstring): ptr WlrSeat {.importc: "wlr_seat_create", header: "wlr/types/wlr_seat.h".}
proc wlrSeatSetCapabilities*(seat: ptr WlrSeat, caps: uint32) {.importc: "wlr_seat_set_capabilities", header: "wlr/types/wlr_seat.h".}
proc wlrSeatSetKeyboard*(seat: ptr WlrSeat, kb: ptr WlrKeyboard) {.importc: "wlr_seat_set_keyboard", header: "wlr/types/wlr_seat.h".}
proc wlrSeatKeyboardNotifyEnter*(seat: ptr WlrSeat, surface: ptr WlrSurface, keycodes: ptr uint32, numKeycodes: csize_t, modifiers: pointer) {.importc: "wlr_seat_keyboard_notify_enter", header: "wlr/types/wlr_seat.h".}
proc wlrSeatKeyboardNotifyKey*(seat: ptr WlrSeat, timeMsec, keycode, state: uint32) {.importc: "wlr_seat_keyboard_notify_key", header: "wlr/types/wlr_seat.h".}
proc wlrSeatKeyboardNotifyModifiers*(seat: ptr WlrSeat, modifiers: pointer) {.importc: "wlr_seat_keyboard_notify_modifiers", header: "wlr/types/wlr_seat.h".}
proc wlrSeatPointerNotifyEnter*(seat: ptr WlrSeat, surface: ptr WlrSurface, sx, sy: cdouble) {.importc: "wlr_seat_pointer_notify_enter", header: "wlr/types/wlr_seat.h".}
proc wlrSeatPointerNotifyMotion*(seat: ptr WlrSeat, timeMsec: uint32, sx, sy: cdouble) {.importc: "wlr_seat_pointer_notify_motion", header: "wlr/types/wlr_seat.h".}
proc wlrSeatPointerNotifyButton*(seat: ptr WlrSeat, timeMsec, button, state: uint32): uint32 {.importc: "wlr_seat_pointer_notify_button", header: "wlr/types/wlr_seat.h".}
proc wlrSeatPointerNotifyFrame*(seat: ptr WlrSeat) {.importc: "wlr_seat_pointer_notify_frame", header: "wlr/types/wlr_seat.h".}
proc wlrSeatPointerNotifyClearFocus*(seat: ptr WlrSeat) {.importc: "wlr_seat_pointer_notify_clear_focus", header: "wlr/types/wlr_seat.h".}

proc wlrCursorCreate*(): ptr WlrCursor {.importc: "wlr_cursor_create", header: "wlr/types/wlr_cursor.h".}
proc wlrCursorAttachOutputLayout*(cur: ptr WlrCursor, layout: ptr WlrOutputLayout) {.importc: "wlr_cursor_attach_output_layout", header: "wlr/types/wlr_cursor.h".}
proc wlrCursorAttachInputDevice*(cur: ptr WlrCursor, dev: ptr WlrInputDevice) {.importc: "wlr_cursor_attach_input_device", header: "wlr/types/wlr_cursor.h".}
proc wlrCursorMove*(cur: ptr WlrCursor, dev: ptr WlrInputDevice, dx, dy: cdouble) {.importc: "wlr_cursor_move", header: "wlr/types/wlr_cursor.h".}
proc wlrCursorWarpAbsolute*(cur: ptr WlrCursor, dev: ptr WlrInputDevice, x, y: cdouble) {.importc: "wlr_cursor_warp_absolute", header: "wlr/types/wlr_cursor.h".}
proc cursorEvents*(c: ptr WlrCursor): ptr WlrCursorEvents {.inline.} = cast[ptr WlrCursorEvents](c)

proc wlrXcursorManagerCreate*(name: cstring, size: uint32): ptr WlrXcursorManager {.importc: "wlr_xcursor_manager_create", header: "wlr/types/wlr_xcursor_manager.h".}
proc wlrXcursorManagerLoad*(mgr: ptr WlrXcursorManager, scale: cfloat): bool {.importc: "wlr_xcursor_manager_load", header: "wlr/types/wlr_xcursor_manager.h".}
proc wlrCursorSetXcursor*(cur: ptr WlrCursor, mgr: ptr WlrXcursorManager, name: cstring) {.importc: "wlr_cursor_set_xcursor", header: "wlr/types/wlr_cursor.h".}

# ---------------------------------------------------------------------------
# XWayland
# ---------------------------------------------------------------------------

type
  WlrXwayland* {.importc: "struct wlr_xwayland", header: "wlr/xwayland/xwayland.h", incompleteStruct.} = object

proc wlrXwaylandCreate*(d: ptr WlDisplay, compositor: ptr WlrCompositor, lazy: bool): ptr WlrXwayland {.importc: "wlr_xwayland_create", header: "wlr/xwayland/xwayland.h".}
proc wlrXwaylandSetSeat*(xw: ptr WlrXwayland, seat: ptr WlrSeat) {.importc: "wlr_xwayland_set_seat", header: "wlr/xwayland/xwayland.h".}
proc wlrXwaylandDestroy*(xw: ptr WlrXwayland) {.importc: "wlr_xwayland_destroy", header: "wlr/xwayland/xwayland.h".}
