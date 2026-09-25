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
type
  WlEventSource* {.importc: "struct wl_event_source", header: "<wayland-server-core.h>", incompleteStruct.} = object
## NAPRAWIONY BRAK: konfiguracja (monitory, układ klawiatury) była czytana
## wyłącznie raz przy starcie -- zmiana w Ustawieniach wymagała ręcznego
## restartu zde-comp. `SIGHUP` to standardowa uniksowa konwencja "przeładuj
## konfigurację" (nginx, sshd itd.) -- `wl_event_loop_add_signal` integruje
## obsługę sygnału POSIX czysto z pętlą zdarzeń Wayland (bez ryzyk
## klasycznego handlera sygnału: brak async-signal-safe ograniczeń, bo
## faktyczne wywołanie callbacku i tak dzieje się w głównej pętli, nie w
## przerwaniu).
proc wlEventLoopAddSignal*(loop: ptr WlEventLoop, signalNumber: cint,
                            fn: proc(signalNumber: cint, data: pointer): cint {.cdecl.},
                            data: pointer): ptr WlEventSource {.importc: "wl_event_loop_add_signal", header: "<wayland-server-core.h>".}
## Rozbudowa v0.1 ("Aurora"/DPMS) -- patrz `wlcomp/idle.nim`. Ten sam
## mechanizm co `wlEventLoopAddSignal` wyżej (funkcja zwrotna wołana z
## głównej pętli zdarzeń), tylko po upływie czasu zamiast sygnału POSIX --
## `wl_event_source_timer_update` UZBRAJA/PRZEuzbraja timer na kolejne
## `msDelay` milisekund (jednorazowo -- callback musi sam się przezbroić
## na następne wywołanie, jeśli ma tykać cyklicznie, patrz `checkIdle` w
## `wlcomp/idle.nim`).
proc wlEventLoopAddTimer*(loop: ptr WlEventLoop,
                           fn: proc(data: pointer): cint {.cdecl.},
                           data: pointer): ptr WlEventSource {.importc: "wl_event_loop_add_timer", header: "<wayland-server-core.h>".}
proc wlEventSourceTimerUpdate*(source: ptr WlEventSource, msDelay: cint): cint {.importc: "wl_event_source_timer_update", header: "<wayland-server-core.h>".}
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

  ## Rozbudowa v0.1 ("Aurora"/DRM) -- zadeklarowane już tutaj (nie w sekcji
  ## "Sesja / przełączanie VT" niżej), bo `wlrBackendAutocreate` poniżej
  ## potrzebuje tego typu w swojej sygnaturze (Nim wymaga zadeklarowania
  ## typu przed użyciem, nawet jako `ptr ptr`). Osobny typ
  ## `WlrSessionEvents` (dalej w pliku) importuje TEN SAM C-struct pod
  ## innym nimowym typem, tylko po to, żeby dostać się do jego
  ## zagnieżdżonych `events.*` -- dokładnie ten sam trik co
  ## `WlrXdgSurface`/`WlrXdgSurfaceEvents` wyżej w tym pliku.
  WlrSession* {.importc: "struct wlr_session", header: "wlr/backend/session.h", incompleteStruct.} = object
    active* {.importc: "active".}: bool

proc wlrBackendAutocreate*(display: ptr WlDisplay, sessionOut: ptr ptr WlrSession): ptr WlrBackend {.importc: "zde_backend_autocreate", header: "shim.h".}
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
## Rozbudowa v0.1 ("Aurora"/DRM): patrz `wlcomp/session.nim` --
## `wlr_output_schedule_frame` "budzi" wyjście, żeby wysłało kolejne
## `frame` (i tym samym żeby kompozytor znów zaczął renderować) po
## odzyskaniu aktywnej sesji (VT). Bez tego wywołania pętla renderowania
## danego wyjścia zostaje trwale zatrzymana po powrocie z innego VT --
## `onOutputFrame` samo nie planuje swojej następnej klatki inaczej niż
## przez odpowiedź na poprzednią (a ta odpowiedź nigdy nie przyszła,
## skoro DRM nie mogło zrobić page-flipu, gdy VT było nieaktywne).
proc wlrOutputScheduleFrame*(o: ptr WlrOutput) {.importc: "wlr_output_schedule_frame", header: "wlr/types/wlr_output.h".}
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
proc wlrOutputCreateGlobal*(o: ptr WlrOutput, display: ptr WlDisplay) {.importc: "zde_output_create_global", header: "shim.h".}

proc wlrOutputLayoutCreate*(display: ptr WlDisplay): ptr WlrOutputLayout {.importc: "zde_output_layout_create", header: "shim.h".}
proc wlrOutputLayoutAddAuto*(layout: ptr WlrOutputLayout, o: ptr WlrOutput) {.importc: "wlr_output_layout_add_auto", header: "wlr/types/wlr_output_layout.h".}
## Rozbudowa v0.1 ("Aurora"): granice całego układu monitorów (wszystkie
## wyjścia razem) w jednym `WlrBox` -- używane do klamrowania geometrii,
## o jaką proszą okna X11 (`wlcomp/xwayland.nim`, `onXwaylandRequestConfigure`),
## żeby nie dało się np. otworzyć okna dialogowego całkowicie poza
## widocznym ekranem. Zweryfikowane wobec prawdziwego nagłówka (patrz
## `wlr/types/wlr_output_layout.h`).
proc wlrOutputLayoutGetBox*(layout: ptr WlrOutputLayout, reference: ptr WlrOutput, destBox: ptr WlrBox) {.importc: "wlr_output_layout_get_box", header: "wlr/types/wlr_output_layout.h".}
proc wlrOutputLayoutAdd*(layout: ptr WlrOutputLayout, o: ptr WlrOutput, lx, ly: cint) {.importc: "wlr_output_layout_add", header: "wlr/types/wlr_output_layout.h".}

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
proc wlrSceneTreeCreate*(parent: ptr WlrSceneTree): ptr WlrSceneTree {.importc: "wlr_scene_tree_create", header: "wlr/types/wlr_scene.h".}
proc wlrSceneNodeSetEnabled*(n: ptr WlrSceneNode, enabled: bool) {.importc: "wlr_scene_node_set_enabled", header: "wlr/types/wlr_scene.h".}

## `wlr_scene.tree` i `wlr_scene_tree.node` są zawsze pierwszym polem swojego
## struct-a (patrz nagłówek) -- więc rzutowanie wskaźnika na offset 0 daje
## bezpośrednio węzeł-korzeń całej sceny, bez potrzeby osobnej funkcji C.
proc sceneRootNode*(s: ptr WlrScene): ptr WlrSceneNode {.inline.} = cast[ptr WlrSceneNode](s)
proc treeNode*(t: ptr WlrSceneTree): ptr WlrSceneNode {.inline.} = cast[ptr WlrSceneNode](t)

## Rozbudowa v0.1 ("Aurora"): prostokąt jednolitego koloru w scenie --
## używany do podświetlenia "następnego" okna przy karuzeli Alt+Tab
## (patrz `cycleAltTab`/`altTabHighlight` w `wlcomp/toplevel.nim`). Tak
## jak `WlrSceneTree` powyżej, `wlr_scene_node` jest pierwszym polem
## `struct wlr_scene_rect`, więc rzutowanie na offset 0 daje węzeł.
type
  WlrSceneRect* {.importc: "struct wlr_scene_rect", header: "wlr/types/wlr_scene.h", incompleteStruct.} = object

proc wlrSceneRectCreate*(parent: ptr WlrSceneTree, width, height: cint, color: ptr cfloat): ptr WlrSceneRect {.importc: "wlr_scene_rect_create", header: "wlr/types/wlr_scene.h".}
proc wlrSceneRectSetSize*(rect: ptr WlrSceneRect, width, height: cint) {.importc: "wlr_scene_rect_set_size", header: "wlr/types/wlr_scene.h".}
proc rectNode*(r: ptr WlrSceneRect): ptr WlrSceneNode {.inline.} = cast[ptr WlrSceneNode](r)

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

## Geometria xdg-surface: pole `.geometry` w 0.18 kontra funkcja
## `wlr_xdg_surface_get_geometry()` w 0.17 -- ujednolicone przez shim,
## patrz komentarz w shim.c i shim.h.
proc zdeXdgSurfaceGetGeometry(s: ptr WlrXdgSurface, o: ptr WlrBox) {.importc: "zde_xdg_surface_get_geometry", header: "shim.h".}
proc geometry*(s: ptr WlrXdgSurface): WlrBox {.inline.} =
  zdeXdgSurfaceGetGeometry(s, addr result)

proc wlrXdgToplevelSetActivated*(t: ptr WlrXdgToplevel, activated: bool): uint32 {.importc: "wlr_xdg_toplevel_set_activated", header: "wlr/types/wlr_xdg_shell.h".}
proc wlrXdgToplevelSetSize*(t: ptr WlrXdgToplevel, w, h: cint): uint32 {.importc: "wlr_xdg_toplevel_set_size", header: "wlr/types/wlr_xdg_shell.h".}
proc wlrXdgSurfaceSurfaceAt*(s: ptr WlrXdgSurface, sx, sy: cdouble, subX, subY: ptr cdouble): ptr WlrSurface {.importc: "wlr_xdg_surface_surface_at", header: "wlr/types/wlr_xdg_shell.h".}

# ---------------------------------------------------------------------------
# xdg-popup (menu kontekstowe, podpowiedzi itd.)
# ---------------------------------------------------------------------------
## NAPRAWIONY BRAK: `onNewXdgSurface` (toplevel.nim) wcześniej ignorowało
## wszystko poza `WlrXdgSurfaceRoleToplevel` -- więc popupy (typowo: menu
## kontekstowe klienta, podpowiedzi, autouzupełnianie) w ogóle się nie
## wyświetlały. `wlr_xdg_popup` niesie referencję do surface'u-rodzica i
## pozycjonera (ustawionego przez klienta przez `xdg_positioner` --
## wyliczanie samej pozycji z reguł pozycjonera robi za nas
## `wlr_xdg_surface_schedule_configure`/wlroots wewnętrznie, nie musimy
## odtwarzać tej logiki ręcznie).
type
  WlrXdgPopup* {.importc: "struct wlr_xdg_popup", header: "wlr/types/wlr_xdg_shell.h", incompleteStruct.} = object
    base* {.importc: "base".}: ptr WlrXdgSurface
    parent* {.importc: "parent".}: ptr WlrSurface

  WlrXdgSurfacePopupField* {.importc: "struct wlr_xdg_surface", header: "wlr/types/wlr_xdg_shell.h", incompleteStruct.} = object
    popup* {.importc: "popup".}: ptr WlrXdgPopup

  WlrXdgSurfaceNewPopupEvents* {.importc: "struct wlr_xdg_surface", header: "wlr/types/wlr_xdg_shell.h", incompleteStruct.} = object
    newPopup* {.importc: "events.new_popup".}: WlSignal

proc xdgSurfacePopup*(s: ptr WlrXdgSurface): ptr WlrXdgPopup {.inline.} =
  cast[ptr WlrXdgSurfacePopupField](s).popup
proc xdgSurfaceNewPopupEvents*(s: ptr WlrXdgSurface): ptr WlrXdgSurfaceNewPopupEvents {.inline.} =
  cast[ptr WlrXdgSurfaceNewPopupEvents](s)
proc wlrXdgSurfaceTryFromWlrSurface*(s: ptr WlrSurface): ptr WlrXdgSurface {.importc: "wlr_xdg_surface_try_from_wlr_surface", header: "wlr/types/wlr_xdg_shell.h".}

# ---------------------------------------------------------------------------
# wlr-layer-shell-v1 (panele/paski dokowane do krawędzi ekranu -- launcher,
# statusbar, powiadomienia, itp.)
# ---------------------------------------------------------------------------
## NAPRAWIONY BRAK: kompozytor w ogóle nie tworzył globalnego obiektu
## `zwlr_layer_shell_v1` -- klienci mówiący tym protokołem (np. `waybar`,
## `wofi`, `mako`, albo w przyszłości zde-shell po stronie klienckiej, patrz
## uwaga w apps/settings dot. tego ograniczenia) nie mieli jak się nawet
## podłączyć. Protokół wymaga wygenerowanego nagłówka
## `wlr-layer-shell-unstable-v1-protocol.h` (patrz wlcomp/protocol-src/ i
## `build.janet`) -- Ubuntu go nie pakietuje, więc jest zrekonstruowany z
## oficjalnej specyfikacji wlr-protocols w tym repo.
type
  WlrLayerShellV1* {.importc: "struct wlr_layer_shell_v1", header: "wlr/types/wlr_layer_shell_v1.h", incompleteStruct.} = object
  WlrLayerShellV1Events* {.importc: "struct wlr_layer_shell_v1", header: "wlr/types/wlr_layer_shell_v1.h", incompleteStruct.} = object
    newSurface* {.importc: "events.new_surface".}: WlSignal

  WlrLayerSurfaceV1State* {.importc: "struct wlr_layer_surface_v1_state", header: "wlr/types/wlr_layer_shell_v1.h".} = object
    committed*: uint32
    anchor*: uint32
    exclusiveZone* {.importc: "exclusive_zone".}: int32
    marginTop* {.importc: "margin.top".}: int32
    marginRight* {.importc: "margin.right".}: int32
    marginBottom* {.importc: "margin.bottom".}: int32
    marginLeft* {.importc: "margin.left".}: int32
    keyboardInteractive* {.importc: "keyboard_interactive".}: cint
    desiredWidth* {.importc: "desired_width".}: uint32
    desiredHeight* {.importc: "desired_height".}: uint32
    layer*: cint
    configureSerial* {.importc: "configure_serial".}: uint32
    actualWidth* {.importc: "actual_width".}: uint32
    actualHeight* {.importc: "actual_height".}: uint32

  WlrLayerSurfaceV1* {.importc: "struct wlr_layer_surface_v1", header: "wlr/types/wlr_layer_shell_v1.h", incompleteStruct.} = object
    surface* {.importc: "surface".}: ptr WlrSurface
    output* {.importc: "output".}: ptr WlrOutput
    namespace0* {.importc: "namespace".}: cstring
    current*: WlrLayerSurfaceV1State
    pending*: WlrLayerSurfaceV1State

  WlrLayerSurfaceV1Events* {.importc: "struct wlr_layer_surface_v1", header: "wlr/types/wlr_layer_shell_v1.h", incompleteStruct.} = object
    destroy* {.importc: "events.destroy".}: WlSignal
    newPopup* {.importc: "events.new_popup".}: WlSignal

  WlrSceneLayerSurfaceV1* {.importc: "struct wlr_scene_layer_surface_v1", header: "wlr/types/wlr_scene.h", incompleteStruct.} = object
    tree* {.importc: "tree".}: ptr WlrSceneTree
    layerSurface* {.importc: "layer_surface".}: ptr WlrLayerSurfaceV1

const
  ZWLR_LAYER_SHELL_V1_LAYER_BACKGROUND*: cint = 0
  ZWLR_LAYER_SHELL_V1_LAYER_BOTTOM*: cint = 1
  ZWLR_LAYER_SHELL_V1_LAYER_TOP*: cint = 2
  ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY*: cint = 3

  ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP*: uint32 = 1
  ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM*: uint32 = 2
  ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT*: uint32 = 4
  ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT*: uint32 = 8

proc wlrLayerShellV1Create*(display: ptr WlDisplay, version: uint32): ptr WlrLayerShellV1 {.importc: "wlr_layer_shell_v1_create", header: "wlr/types/wlr_layer_shell_v1.h".}
proc layerShellEvents*(s: ptr WlrLayerShellV1): ptr WlrLayerShellV1Events {.inline.} = cast[ptr WlrLayerShellV1Events](s)
proc layerSurfaceEvents*(s: ptr WlrLayerSurfaceV1): ptr WlrLayerSurfaceV1Events {.inline.} = cast[ptr WlrLayerSurfaceV1Events](s)
proc wlrLayerSurfaceV1Configure*(s: ptr WlrLayerSurfaceV1, width, height: uint32): uint32 {.importc: "wlr_layer_surface_v1_configure", header: "wlr/types/wlr_layer_shell_v1.h".}
proc wlrLayerSurfaceV1Destroy*(s: ptr WlrLayerSurfaceV1) {.importc: "wlr_layer_surface_v1_destroy", header: "wlr/types/wlr_layer_shell_v1.h".}
proc wlrOutputEffectiveResolution*(o: ptr WlrOutput, width, height: ptr cint) {.importc: "wlr_output_effective_resolution", header: "wlr/types/wlr_output.h".}
proc wlrLayerSurfaceV1TryFromWlrSurface*(s: ptr WlrSurface): ptr WlrLayerSurfaceV1 {.importc: "wlr_layer_surface_v1_try_from_wlr_surface", header: "wlr/types/wlr_layer_shell_v1.h".}
proc wlrSceneLayerSurfaceV1Create*(parent: ptr WlrSceneTree, layerSurface: ptr WlrLayerSurfaceV1): ptr WlrSceneLayerSurfaceV1 {.importc: "wlr_scene_layer_surface_v1_create", header: "wlr/types/wlr_scene.h".}
proc wlrSceneLayerSurfaceV1Configure*(sceneLayerSurface: ptr WlrSceneLayerSurfaceV1, fullArea, usableArea: ptr WlrBox) {.importc: "wlr_scene_layer_surface_v1_configure", header: "wlr/types/wlr_scene.h".}

proc layerNamespace*(s: ptr WlrLayerSurfaceV1): string =
  if s.namespace0 == nil: "" else: $s.namespace0

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

  WlrPointerAxisEvent* {.importc: "struct wlr_pointer_axis_event", header: "wlr/types/wlr_pointer.h".} = object
    pointer*: pointer
    timeMsec* {.importc: "time_msec".}: uint32
    source* {.importc: "source".}: cint          ## enum wlr_axis_source
    orientation* {.importc: "orientation".}: cint ## enum wlr_axis_orientation
    delta*: cdouble
    deltaDiscrete* {.importc: "delta_discrete".}: int32

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
    ## Rozbudowa v0.1 ("Aurora"/gesty) -- patrz `wlcomp/gestures.nim`.
    ## `wlr_cursor` agreguje te same sygnały co touchpad/libinput
    ## bezpośrednio (nagłówek mówi wprost: "Re-broadcasting these signals
    ## ... is your responsibility" -- czyli te zdarzenia i tak trzeba
    ## samemu przekazać dalej klientom przez `wlr_pointer_gestures_v1`,
    ## jeśli mają być widoczne dla aplikacji -- patrz `hookGestures`).
    swipeBegin* {.importc: "events.swipe_begin".}: WlSignal
    swipeUpdate* {.importc: "events.swipe_update".}: WlSignal
    swipeEnd* {.importc: "events.swipe_end".}: WlSignal
    ## Runda 34 -- pinch i hold, ten sam re-broadcast obowiązek co swipe
    ## (patrz komentarz nad `swipeBegin` wyżej) -- `wlr_cursor` agreguje
    ## je identycznie.
    pinchBegin* {.importc: "events.pinch_begin".}: WlSignal
    pinchUpdate* {.importc: "events.pinch_update".}: WlSignal
    pinchEnd* {.importc: "events.pinch_end".}: WlSignal
    holdBegin* {.importc: "events.hold_begin".}: WlSignal
    holdEnd* {.importc: "events.hold_end".}: WlSignal
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
proc wlrSeatPointerNotifyAxis*(seat: ptr WlrSeat, timeMsec: uint32, orientation: cint, value: cdouble, valueDiscrete: int32, source: cint) {.importc: "zde_seat_pointer_notify_axis", header: "shim.h".}
proc wlrSeatPointerNotifyFrame*(seat: ptr WlrSeat) {.importc: "wlr_seat_pointer_notify_frame", header: "wlr/types/wlr_seat.h".}
proc wlrSeatPointerNotifyClearFocus*(seat: ptr WlrSeat) {.importc: "wlr_seat_pointer_notify_clear_focus", header: "wlr/types/wlr_seat.h".}

# ---------------------------------------------------------------------------
# Schowek (selection/data-device) i drag & drop
# ---------------------------------------------------------------------------
## NAPRAWIONY BRAK: `wlr_data_device_manager_create()` był wołany (main.nim)
## -- to samo w sobie wystawia klientom protokół `wl_data_device_manager` --
## ale kompozytor nigdy nie SŁUCHAŁ zgłoszeń od seata
## (`request_set_selection`/`request_start_drag`), więc: kopiowanie/wklejanie
## między aplikacjami (schowek) i przeciąganie-i-upuszczanie w ogóle nie
## działały, mimo że sam protokół był technicznie dostępny.
type
  WlrDataSource* {.importc: "struct wlr_data_source", header: "wlr/types/wlr_data_device.h", incompleteStruct.} = object

  WlrSeatRequestSetSelectionEvent* {.importc: "struct wlr_seat_request_set_selection_event", header: "wlr/types/wlr_seat.h", incompleteStruct.} = object
    source* {.importc: "source".}: ptr WlrDataSource
    serial*: uint32

  WlrDrag* {.importc: "struct wlr_drag", header: "wlr/types/wlr_data_device.h", incompleteStruct.} = object
    icon* {.importc: "icon".}: ptr WlrDragIcon

  WlrDragIcon* {.importc: "struct wlr_drag_icon", header: "wlr/types/wlr_data_device.h", incompleteStruct.} = object
    surface* {.importc: "surface".}: ptr WlrSurface

  WlrSeatRequestStartDragEvent* {.importc: "struct wlr_seat_request_start_drag_event", header: "wlr/types/wlr_seat.h", incompleteStruct.} = object
    drag* {.importc: "drag".}: ptr WlrDrag
    origin* {.importc: "origin".}: ptr WlrSurface
    serial*: uint32

  WlrDragEvents* {.importc: "struct wlr_drag", header: "wlr/types/wlr_data_device.h", incompleteStruct.} = object
    destroy* {.importc: "events.destroy".}: WlSignal

  WlrSeatEvents* {.importc: "struct wlr_seat", header: "wlr/types/wlr_seat.h", incompleteStruct.} = object
    requestSetSelection* {.importc: "events.request_set_selection".}: WlSignal
    requestStartDrag* {.importc: "events.request_start_drag".}: WlSignal
    startDrag* {.importc: "events.start_drag".}: WlSignal
    ## Rozbudowa v0.2 ("primary selection" -- schowek PIERWOTNY, środkowy
    ## klik w stylu X11): dokładnie ten sam kształt sygnału co
    ## `requestSetSelection` wyżej (patrz `WlrSeatRequestSetPrimarySelectionEvent`
    ## niżej -- `wlr_seat_request_set_primary_selection_event` w
    ## nagłówku ma DOKŁADNIE te same dwa pola co `wlr_seat_request_set_selection_event`,
    ## tylko inny typ `source`), więc obsługa w `wlcomp/seatext.nim` to
    ## kopia `onRequestSetSelection` ze zmienionym typem, nie nowy wzorzec.
    requestSetPrimarySelection* {.importc: "events.request_set_primary_selection".}: WlSignal

  ## "Primary selection" (schowek pierwotny, środkowy klik) był dotąd
  ## CAŁKOWICIE nieobsłużony -- `zde-comp` w ogóle nie tworzył
  ## `wlr_primary_selection_v1_device_manager`, więc protokół
  ## `zwp_primary_selection_v1` nigdy nie trafiał do rejestru Waylanda --
  ## klienty (np. terminale, GTK) poprawnie wykrywały jego brak i po
  ## prostu nie oferowały schowka pierwotnego, ale to był realny, jawnie
  ## wypisany w README brak funkcji, nie subtelny bug. Patrz
  ## `wlcomp/seatext.nim` (`onRequestSetPrimarySelection`) i `main.nim`
  ## (`wlrPrimarySelectionV1DeviceManagerCreate`) po resztę.
  WlrPrimarySelectionSource* {.importc: "struct wlr_primary_selection_source", header: "wlr/types/wlr_primary_selection.h", incompleteStruct.} = object

  WlrSeatRequestSetPrimarySelectionEvent* {.importc: "struct wlr_seat_request_set_primary_selection_event", header: "wlr/types/wlr_primary_selection.h", incompleteStruct.} = object
    source* {.importc: "source".}: ptr WlrPrimarySelectionSource
    serial*: uint32

  WlrPrimarySelectionV1DeviceManager* {.importc: "struct wlr_primary_selection_v1_device_manager", header: "wlr/types/wlr_primary_selection_v1.h", incompleteStruct.} = object

proc wlrPrimarySelectionV1DeviceManagerCreate*(d: ptr WlDisplay): ptr WlrPrimarySelectionV1DeviceManager {.importc: "wlr_primary_selection_v1_device_manager_create", header: "wlr/types/wlr_primary_selection_v1.h".}
proc wlrSeatSetPrimarySelection*(seat: ptr WlrSeat, source: ptr WlrPrimarySelectionSource, serial: uint32) {.importc: "wlr_seat_set_primary_selection", header: "wlr/types/wlr_primary_selection.h".}

proc seatEvents*(s: ptr WlrSeat): ptr WlrSeatEvents {.inline.} = cast[ptr WlrSeatEvents](s)
proc wlrSeatSetSelection*(seat: ptr WlrSeat, source: ptr WlrDataSource, serial: uint32) {.importc: "wlr_seat_set_selection", header: "wlr/types/wlr_seat.h".}
proc wlrSeatStartPointerDrag*(seat: ptr WlrSeat, drag: ptr WlrDrag, serial: uint32) {.importc: "wlr_seat_start_pointer_drag", header: "wlr/types/wlr_seat.h".}
proc wlrSceneDragIconCreate*(parent: ptr WlrSceneTree, dragIcon: ptr WlrDragIcon): ptr WlrSceneTree {.importc: "wlr_scene_drag_icon_create", header: "wlr/types/wlr_scene.h".}
proc dragEvents*(d: ptr WlrDrag): ptr WlrDragEvents {.inline.} = cast[ptr WlrDragEvents](d)

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
## Rozbudowa v0.1 ("Aurora"): do tej pory `zde-comp` uruchamiał proces
## Xwayland (`wlrXwaylandCreate` poniżej, wołane w `main.nim`), ale NIGDY
## nie nasłuchiwał na `events.new_surface` -- czyli żadne okno aplikacji
## X11 (np. stare GTK2, Java Swing, gry przez Wine/Proton) nigdy nie
## dostawało węzła w scenie ani nie trafiało na listę `toplevels`. Proces
## Xwayland się uruchamiał, ale efektywnie nic nie robił. `wlcomp/xwayland.nim`
## domyka tę lukę, podpinając powierzchnie X11 pod ten sam `Toplevel`, który
## do tej pory obsługiwał tylko xdg-shell (patrz rozszerzone pola w
## `types.nim` i uogólnione `surfaceOf`/`geometryOf` w `toplevel.nim`).
##
## ZWERYFIKOWANE KOMPILACJĄ (aktualizacja): w kolejnej sesji rozbudowy
## udało się zainstalować `nim` + `libwlroots-dev` (0.17.1, Ubuntu 24.04)
## w piaskownicy i realnie skompilować oraz uruchomić `zde-comp` z tym
## kodem -- w tym postawić zagnieżdżony kompozytor pod Xvfb, uruchomić
## pod nim prawdziwe okno X11 (`xclock` przez ten właśnie plik) i
## zobaczyć w logu poprawną sekwencję `new_surface` -> `associate` ze
## odczytanym tytułem okna. Każde pole/sygnał w tej sekcji, odtworzone
## wcześniej "z pamięci", okazało się zgodne co do nazwy z prawdziwym
## `wlr/xwayland/xwayland.h`. Jedyna poprawka, jakiej to wymagało: brakujący
## `import std/sequtils` w `wlcomp/xwayland.nim` (Nim, nie C/wlroots).
## Nie przetestowano jeszcze wobec wlroots 0.18/0.20 (tylko 0.17.1) ani
## pełnego renderowania okna (headless Xvfb w piaskownicy nie ma
## sprzętowego GL -- `associate` i `map` powinny nadal działać identycznie,
## ale bez GPU nie dało się potwierdzić samego rysowania klatek).

type
  WlrXwayland* {.importc: "struct wlr_xwayland", header: "wlr/xwayland/xwayland.h", incompleteStruct.} = object
    ## Realny numer wyświetlacza X (np. ":2"), pod którym nasłuchuje ten
    ## proces Xwayland -- zweryfikowane wobec prawdziwego nagłówka
    ## (patrz duży komentarz "ZWERYFIKOWANE KOMPILACJĄ" niżej). Klienci X11
    ## (i sam kompozytor przy logowaniu) potrzebują tego, żeby wiedzieć,
    ## pod jakim `DISPLAY` się łączyć.
    displayName* {.importc: "display_name".}: cstring

  WlrXwaylandEvents* {.importc: "struct wlr_xwayland", header: "wlr/xwayland/xwayland.h", incompleteStruct.} = object
    ready* {.importc: "events.ready".}: WlSignal
    newSurface* {.importc: "events.new_surface".}: WlSignal

  ## `wlr_xwayland_surface` -- odpowiednik `wlr_xdg_surface`, ale dla okna
  ## X11. `surface` jest `nil`, dopóki nie odpali się `associate` (X11 samo
  ## "kojarzy" swoje okno z powierzchnią Wayland dopiero po chwili, nie od
  ## razu przy `new_surface`) -- stąd osobne zdarzenia `associate`/
  ## `dissociate` obok zwykłego `map`/`unmap` na samej `surface` (patrz
  ## `xwayland.nim`, `onXwaylandAssociate`).
  WlrXwaylandSurface* {.importc: "struct wlr_xwayland_surface", header: "wlr/xwayland/xwayland.h", incompleteStruct.} = object
    surface* {.importc: "surface".}: ptr WlrSurface
    x* {.importc: "x".}: int16
    y* {.importc: "y".}: int16
    width* {.importc: "width".}: uint16
    height* {.importc: "height".}: uint16
    overrideRedirect* {.importc: "override_redirect".}: bool
    title* {.importc: "title".}: cstring
    class* {.importc: "class".}: cstring

  WlrXwaylandSurfaceEvents* {.importc: "struct wlr_xwayland_surface", header: "wlr/xwayland/xwayland.h", incompleteStruct.} = object
    destroy* {.importc: "events.destroy".}: WlSignal
    requestConfigure* {.importc: "events.request_configure".}: WlSignal
    requestMove* {.importc: "events.request_move".}: WlSignal
    requestResize* {.importc: "events.request_resize".}: WlSignal
    requestActivate* {.importc: "events.request_activate".}: WlSignal
    requestMaximize* {.importc: "events.request_maximize".}: WlSignal
    requestFullscreen* {.importc: "events.request_fullscreen".}: WlSignal
    requestMinimize* {.importc: "events.request_minimize".}: WlSignal
    associate* {.importc: "events.associate".}: WlSignal
    dissociate* {.importc: "events.dissociate".}: WlSignal
    setTitle* {.importc: "events.set_title".}: WlSignal
    setClass* {.importc: "events.set_class".}: WlSignal

  ## Dane niesione przez `request_configure` -- klient X11 prosi o
  ## konkretną pozycję/rozmiar (np. okno dialogowe wyśrodkowujące się
  ## względem rodzica). Honorujemy to wprost (patrz `xwayland.nim`) --
  ## podobnie jak większość minimalnych kompozytorów wlroots (tinywl).
  WlrXwaylandConfigureEvent* {.importc: "struct wlr_xwayland_surface_configure_event", header: "wlr/xwayland/xwayland.h", incompleteStruct.} = object
    x* {.importc: "x".}: int16
    y* {.importc: "y".}: int16
    width* {.importc: "width".}: uint16
    height* {.importc: "height".}: uint16

proc xwaylandEvents*(xw: ptr WlrXwayland): ptr WlrXwaylandEvents {.inline.} = cast[ptr WlrXwaylandEvents](xw)
proc xwaylandSurfaceEvents*(s: ptr WlrXwaylandSurface): ptr WlrXwaylandSurfaceEvents {.inline.} = cast[ptr WlrXwaylandSurfaceEvents](s)

proc wlrXwaylandCreate*(d: ptr WlDisplay, compositor: ptr WlrCompositor, lazy: bool): ptr WlrXwayland {.importc: "wlr_xwayland_create", header: "wlr/xwayland/xwayland.h".}
proc wlrXwaylandSetSeat*(xw: ptr WlrXwayland, seat: ptr WlrSeat) {.importc: "wlr_xwayland_set_seat", header: "wlr/xwayland/xwayland.h".}
proc wlrXwaylandDestroy*(xw: ptr WlrXwayland) {.importc: "wlr_xwayland_destroy", header: "wlr/xwayland/xwayland.h".}
proc wlrXwaylandSurfaceActivate*(s: ptr WlrXwaylandSurface, activated: bool) {.importc: "wlr_xwayland_surface_activate", header: "wlr/xwayland/xwayland.h".}
proc wlrXwaylandSurfaceConfigure*(s: ptr WlrXwaylandSurface, x, y: int16, width, height: uint16) {.importc: "wlr_xwayland_surface_configure", header: "wlr/xwayland/xwayland.h".}
proc wlrXwaylandSurfaceClose*(s: ptr WlrXwaylandSurface) {.importc: "wlr_xwayland_surface_close", header: "wlr/xwayland/xwayland.h".}
## Generyczne dołączenie DOWOLNEJ `wlr_surface` (razem z jej ewentualnymi
## subsurface'ami) pod drzewo sceny -- to samo, czego używają tinywl/sway
## dla okien XWayland (xdg-shell ma swój dedykowany
## `wlr_scene_xdg_surface_create` wyżej, X11 nie ma takiego odpowiednika,
## bo `wlr_xwayland_surface` to nie jest "surface z rolą" w sensie
## xdg-shell -- samą `surface` trzeba dołożyć do sceny osobno).
proc wlrSceneSubsurfaceTreeCreate*(parent: ptr WlrSceneTree, surface: ptr WlrSurface): ptr WlrSceneTree {.importc: "wlr_scene_subsurface_tree_create", header: "wlr/types/wlr_scene.h".}

# ---------------------------------------------------------------------------
# Sesja / przełączanie VT (DRM)
# ---------------------------------------------------------------------------
## Rozbudowa v0.1 ("Aurora"/DRM): `WlrSession` (pole `active`) jest
## zadeklarowane wyżej, w sekcji "Backend / renderer / allocator" (patrz
## komentarz tam) -- tu tylko dostęp do jego `events.*` i same funkcje.
## Patrz `wlcomp/session.nim` po pełny opis, DLACZEGO to jest potrzebne:
## w skrócie, `zde_backend_autocreate` (shim.c) do tej pory NIGDY nie
## oddawał kompozytorowi wskaźnika na `wlr_session`, więc przełączenie
## wirtualnego terminala (Ctrl+Alt+F2 itd.) było niewidoczne dla
## `zde-comp` -- backend DRM przestawał móc robić page-flipy, a
## kompozytor nie miał jak się o tym dowiedzieć ani zareagować po
## powrocie.

type
  WlrSessionEvents* {.importc: "struct wlr_session", header: "wlr/backend/session.h", incompleteStruct.} = object
    active* {.importc: "events.active".}: WlSignal
    destroy* {.importc: "events.destroy".}: WlSignal

proc sessionEvents*(s: ptr WlrSession): ptr WlrSessionEvents {.inline.} = cast[ptr WlrSessionEvents](s)

## `wlr_session_change_vt` -- prosi jądro (przez logind/seatd, w zależności
## od tego, pod czym `zde-comp` akurat działa) o przełączenie na wskazany
## wirtualny terminal. Zwraca `false`, gdy sesja nie istnieje (np.
## zagnieżdżone uruchomienie pod X11/Wayland, gdzie VT w ogóle nie ma
## zastosowania) -- kod wywołujący (`wlcomp/session.nim`) sprawdza to przez
## `server.session != nil`, zanim w ogóle spróbuje.
proc wlrSessionChangeVt*(s: ptr WlrSession, vt: cuint): bool {.importc: "wlr_session_change_vt", header: "wlr/backend/session.h".}

# ---------------------------------------------------------------------------
# Idle / DPMS
# ---------------------------------------------------------------------------
## Rozbudowa v0.1 ("Aurora"/DRM) -- patrz `wlcomp/idle.nim` po pełny opis.
## `wlr_idle_notifier_v1` implementuje protokół `ext-idle-notify-v1` --
## to jest niestabilne/eksperymentalne API wlroots, wymaga makra C
## `WLR_USE_UNSTABLE` -- już globalnie włączonego przez
## `{.passC: "-DWLR_USE_UNSTABLE".}` na górze tego pliku (reszta `wlcomp/`
## używa też innych "unstable" typów wlroots, np. warstw sceny, więc ta
## flaga i tak musiała być włączona wcześniej).
type
  WlrIdleNotifierV1* {.importc: "struct wlr_idle_notifier_v1", header: "wlr/types/wlr_idle_notify_v1.h", incompleteStruct.} = object

proc wlrIdleNotifierV1Create*(display: ptr WlDisplay): ptr WlrIdleNotifierV1 {.importc: "wlr_idle_notifier_v1_create", header: "wlr/types/wlr_idle_notify_v1.h".}
proc wlrIdleNotifierV1SetInhibited*(notifier: ptr WlrIdleNotifierV1, inhibited: bool) {.importc: "wlr_idle_notifier_v1_set_inhibited", header: "wlr/types/wlr_idle_notify_v1.h".}
proc wlrIdleNotifierV1NotifyActivity*(notifier: ptr WlrIdleNotifierV1, seat: ptr WlrSeat) {.importc: "wlr_idle_notifier_v1_notify_activity", header: "wlr/types/wlr_idle_notify_v1.h".}

# ---------------------------------------------------------------------------
# Gesty touchpada (swipe)
# ---------------------------------------------------------------------------
## Rozbudowa v0.1 ("Aurora"/gesty). Patrz `wlcomp/gestures.nim` po pełny
## opis. Swipe 3-palcowy w lewo/prawo przełącza aktywne okno (ten sam
## mechanizm co Alt+Tab, ale gestem).
##
## Runda 34 -- pinch i hold. Kompozytor sam WCIĄŻ nie reaguje na nie
## żadną własną akcją (patrz uczciwa notatka w `gestures.nim` -- brak
## dziś w ZDE oczywistego, jednoznacznego zastosowania: menedżer plików
## i przeglądarka obrazów, gdzie pinch-to-zoom miałby sens, nie istnieją
## jako osobne okna z własnym zoomem), ale oba typy zdarzeń są teraz
## PRZEKAZYWANE DALEJ do klientów przez `wlr_pointer_gestures_v1` --
## dokładnie ten sam re-broadcast, który swipe miał od rundy "Aurora".
## Aplikacje (np. przeglądarka WWW uruchomiona przez XWayland), które
## same nasłuchują tego protokołu, teraz dostają pinch/hold niezależnie
## od tego, że kompozytor nic z nimi własnego nie robi -- to samo
## rozróżnienie "reakcja kompozytora" vs "re-broadcast do klienta", co
## przy swipe.
type
  WlrPointerSwipeBeginEvent* {.importc: "struct wlr_pointer_swipe_begin_event", header: "wlr/types/wlr_pointer.h", incompleteStruct.} = object
    timeMsec* {.importc: "time_msec".}: uint32
    fingers* {.importc: "fingers".}: uint32

  WlrPointerSwipeUpdateEvent* {.importc: "struct wlr_pointer_swipe_update_event", header: "wlr/types/wlr_pointer.h", incompleteStruct.} = object
    timeMsec* {.importc: "time_msec".}: uint32
    fingers* {.importc: "fingers".}: uint32
    dx* {.importc: "dx".}: cdouble
    dy* {.importc: "dy".}: cdouble

  WlrPointerSwipeEndEvent* {.importc: "struct wlr_pointer_swipe_end_event", header: "wlr/types/wlr_pointer.h", incompleteStruct.} = object
    timeMsec* {.importc: "time_msec".}: uint32
    cancelled* {.importc: "cancelled".}: bool

  ## Globalny protokołu `pointer-gestures-unstable-v1` -- opcjonalny,
  ## tylko po to, żeby KLIENCI (aplikacje), które same chcą surowych
  ## gestów, też je dostały. Kompozytor działa (patrz punkt 2 w komentarzu
  ## nad `WlrCursorEvents`) niezależnie od tego, czy jakikolwiek klient
  ## używa tego protokołu -- ten sam wzorzec co `WlrIdleNotifierV1`.
  WlrPointerGesturesV1* {.importc: "struct wlr_pointer_gestures_v1", header: "wlr/types/wlr_pointer_gestures_v1.h", incompleteStruct.} = object

proc wlrPointerGesturesV1Create*(display: ptr WlDisplay): ptr WlrPointerGesturesV1 {.importc: "wlr_pointer_gestures_v1_create", header: "wlr/types/wlr_pointer_gestures_v1.h".}
proc wlrPointerGesturesV1SendSwipeBegin*(g: ptr WlrPointerGesturesV1, seat: ptr WlrSeat, timeMsec, fingers: uint32) {.importc: "wlr_pointer_gestures_v1_send_swipe_begin", header: "wlr/types/wlr_pointer_gestures_v1.h".}
proc wlrPointerGesturesV1SendSwipeUpdate*(g: ptr WlrPointerGesturesV1, seat: ptr WlrSeat, timeMsec: uint32, dx, dy: cdouble) {.importc: "wlr_pointer_gestures_v1_send_swipe_update", header: "wlr/types/wlr_pointer_gestures_v1.h".}
proc wlrPointerGesturesV1SendSwipeEnd*(g: ptr WlrPointerGesturesV1, seat: ptr WlrSeat, timeMsec: uint32, cancelled: bool) {.importc: "wlr_pointer_gestures_v1_send_swipe_end", header: "wlr/types/wlr_pointer_gestures_v1.h".}

## Runda 34 -- pinch/hold: struktury zdarzeń i re-broadcast do klientów,
## patrz duży komentarz wyżej i `wlcomp/gestures.nim`.
type
  WlrPointerPinchBeginEvent* {.importc: "struct wlr_pointer_pinch_begin_event", header: "wlr/types/wlr_pointer.h", incompleteStruct.} = object
    timeMsec* {.importc: "time_msec".}: uint32
    fingers* {.importc: "fingers".}: uint32

  WlrPointerPinchUpdateEvent* {.importc: "struct wlr_pointer_pinch_update_event", header: "wlr/types/wlr_pointer.h", incompleteStruct.} = object
    timeMsec* {.importc: "time_msec".}: uint32
    fingers* {.importc: "fingers".}: uint32
    dx* {.importc: "dx".}: cdouble
    dy* {.importc: "dy".}: cdouble
    scale* {.importc: "scale".}: cdouble
    rotation* {.importc: "rotation".}: cdouble

  WlrPointerPinchEndEvent* {.importc: "struct wlr_pointer_pinch_end_event", header: "wlr/types/wlr_pointer.h", incompleteStruct.} = object
    timeMsec* {.importc: "time_msec".}: uint32
    cancelled* {.importc: "cancelled".}: bool

  WlrPointerHoldBeginEvent* {.importc: "struct wlr_pointer_hold_begin_event", header: "wlr/types/wlr_pointer.h", incompleteStruct.} = object
    timeMsec* {.importc: "time_msec".}: uint32
    fingers* {.importc: "fingers".}: uint32

  WlrPointerHoldEndEvent* {.importc: "struct wlr_pointer_hold_end_event", header: "wlr/types/wlr_pointer.h", incompleteStruct.} = object
    timeMsec* {.importc: "time_msec".}: uint32
    cancelled* {.importc: "cancelled".}: bool

proc wlrPointerGesturesV1SendPinchBegin*(g: ptr WlrPointerGesturesV1, seat: ptr WlrSeat, timeMsec, fingers: uint32) {.importc: "wlr_pointer_gestures_v1_send_pinch_begin", header: "wlr/types/wlr_pointer_gestures_v1.h".}
proc wlrPointerGesturesV1SendPinchUpdate*(g: ptr WlrPointerGesturesV1, seat: ptr WlrSeat, timeMsec: uint32, dx, dy, scale, rotation: cdouble) {.importc: "wlr_pointer_gestures_v1_send_pinch_update", header: "wlr/types/wlr_pointer_gestures_v1.h".}
proc wlrPointerGesturesV1SendPinchEnd*(g: ptr WlrPointerGesturesV1, seat: ptr WlrSeat, timeMsec: uint32, cancelled: bool) {.importc: "wlr_pointer_gestures_v1_send_pinch_end", header: "wlr/types/wlr_pointer_gestures_v1.h".}
proc wlrPointerGesturesV1SendHoldBegin*(g: ptr WlrPointerGesturesV1, seat: ptr WlrSeat, timeMsec, fingers: uint32) {.importc: "wlr_pointer_gestures_v1_send_hold_begin", header: "wlr/types/wlr_pointer_gestures_v1.h".}
proc wlrPointerGesturesV1SendHoldEnd*(g: ptr WlrPointerGesturesV1, seat: ptr WlrSeat, timeMsec: uint32, cancelled: bool) {.importc: "wlr_pointer_gestures_v1_send_hold_end", header: "wlr/types/wlr_pointer_gestures_v1.h".}
