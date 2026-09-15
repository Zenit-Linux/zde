import wlroots
import types

## Rozbudowa v0.1 ("Aurora"/DRM). Kontekst problemu, który ten plik
## naprawia:
##
## Gdy `zde-comp` działa na prawdziwym DRM/KMS (czyli z prawdziwej konsoli
## tekstowej, nie zagnieżdżone pod X11/Wayland), wlroots automatycznie
## tworzy dla niego `wlr_session` (przez logind, jeśli dostępny, inaczej
## `seatd`) -- to ONA odpowiada za to, że `zde-comp` w ogóle ma prawo
## dotykać `/dev/dri/card0` bez roota. Konsekwencja: system MOŻE w każdej
## chwili odebrać kompozytorowi tę sesję (użytkownik naciska
## Ctrl+Alt+F2, przełącza się na inny VT) i oddać ją z powrotem
## (Ctrl+Alt+F1). Bez obsługi tego zdarzenia:
##
## 1. Kompozytor nie wie, że stracił dostęp do GPU -- nie jest to fatalne
##    sam w sobie (DRM/logind i tak odmówią page-flipów), ale
## 2. PO POWROCIE na VT kompozytora `zde-comp` zostaje z zamrożonym,
##    czarnym/ostatnią klatką ekranem NA ZAWSZE, bo pętla renderowania
##    (`onOutputFrame` w `output.nim`) sama się nie wznawia -- czeka na
##    zdarzenie `frame`, które nie przyjdzie, dopóki ktoś jawnie nie
##    poprosi o nową klatkę (`wlr_output_schedule_frame`).
##
## `hookSessionActive` (wołane raz z `main.nim`, PO `wlrBackendAutocreate`)
## naprawia dokładnie punkt 2. Do tej pory `zde-comp` w ogóle nie miał
## uchwytu do `wlr_session` (patrz zmiana w `shim.c`/`shim.h`), więc nie
## było NA CZYM się podłączyć.

proc onSessionActive(listener: ptr WlListener, data: pointer) {.cdecl.} =
  let server = containerOf(listener, Server, ServerObj, sessionActiveL)
  if server.session == nil: return
  if server.session.active:
    stderr.writeLine("zde-comp: sesja aktywna (powrót na VT kompozytora) -- wznawiam renderowanie")
    ## "Budzimy" WSZYSTKIE wyjścia -- patrz duży komentarz przy
    ## `wlrOutputScheduleFrame` w `wlroots.nim`. Bez tego ekran zostałby
    ## zamrożony na ostatniej klatce sprzed przełączenia VT, mimo że GPU
    ## jest już z powrotem dostępne.
    for output in server.outputs:
      wlrOutputScheduleFrame(output.wlrOutput)
  else:
    stderr.writeLine("zde-comp: sesja nieaktywna (przełączono na inny VT)")
    ## Nic więcej nie trzeba tu robić -- sam DRM/logind już odmawia
    ## kompozytorowi page-flipów, dopóki VT nie wróci. `onOutputFrame`
    ## po prostu przestaje być wołane (kernel nie potwierdza page-flipu),
    ## co samo w sobie zatrzymuje pętlę renderowania bez naszego udziału.

proc hookSessionActive*(server: Server) =
  ## Bezpieczne do wołania zawsze -- gdy `server.session == nil`
  ## (zagnieżdżone uruchomienie pod X11/Wayland, gdzie VT nie mają
  ## zastosowania), po prostu nic nie podłącza.
  if server.session == nil:
    stderr.writeLine("zde-comp: brak wlr_session (uruchomienie zagnieżdżone) -- przełączanie VT nieaktywne")
    return
  zdeSignalAdd(addr sessionEvents(server.session).active, addr server.sessionActiveL, onSessionActive)

const
  ## Bitowe wartości z `enum wlr_keyboard_modifier` (wlroots), stabilne od
  ## dawna w API -- te same liczby, których używa też libxkbcommon
  ## (`XKB_MOD_NAME_CTRL`/`ALT`/`SHIFT` mapują się na te same bity w tej
  ## kolejności deklaracji w wlroots). Eksportowane (`*`) -- używane też z
  ## `wlcomp/input.nim` do przełącznika Alt+Tab (patrz `cycleToPreviousToplevel`
  ## w `wlcomp/toplevel.nim`), nie tylko tutaj do VT-switch.
  WlrModifierShift* = 1'u32 shl 0
  WlrModifierCtrl* = 1'u32 shl 2
  WlrModifierAlt* = 1'u32 shl 3
  ## Kod klawisza F1 w standardzie evdev/`<linux/input-event-codes.h>`
  ## (`KEY_F1`) -- `event.keycode` z `wlr_keyboard_key_event` to RAW kod
  ## sprzętowy (evdev), nie keysym po przejściu przez xkb, więc porównanie
  ## wprost do tej stałej działa niezależnie od ustawionego układu
  ## klawiatury (a przełączanie VT z definicji powinno działać zawsze,
  ## nawet gdyby układ klawiatury był akurat błędnie skonfigurowany).
  EvdevKeyF1 = 59'u32
  EvdevKeyF11 = 87'u32
  EvdevKeyF12 = 88'u32

proc vtNumberForKeycode(keycode: uint32): cuint =
  ## Zwraca numer VT (1-12) dla klawisza F1-F12, albo 0, gdy to nie jest
  ## żaden z nich. Konwencja Ctrl+Alt+F<n> -> VT<n> jest tu SZTYWNA -- to
  ## ten sam, powszechnie przyjęty skrót co w Xorgu i innych kompozytorach
  ## wlroots (sway, tinywl).
  if keycode >= EvdevKeyF1 and keycode < EvdevKeyF1 + 10:
    cuint(keycode - EvdevKeyF1 + 1)
  elif keycode == EvdevKeyF11:
    11
  elif keycode == EvdevKeyF12:
    12
  else:
    0

proc tryHandleVtSwitch*(server: Server, wlrKb: ptr WlrKeyboard, keycode: uint32, pressed: bool): bool =
  ## Wołane z `onKeyboardKey` (`input.nim`) PRZED przekazaniem klawisza do
  ## klienta -- gdy zwróci `true`, `input.nim` NIE przekazuje zdarzenia
  ## dalej (skrót jest "połknięty" przez kompozytor, tak jak każdy inny
  ## globalny skrót WM/kompozytora -- klient pod fokusem nigdy się o nim
  ## nie dowiaduje, dokładnie jak w Xorgu/innych DE).
  if not pressed or server.session == nil:
    return false
  let vt = vtNumberForKeycode(keycode)
  if vt == 0:
    return false
  let mods = wlrKeyboardGetModifiers(wlrKb)
  if (mods and WlrModifierCtrl) == 0 or (mods and WlrModifierAlt) == 0:
    return false
  stderr.writeLine("zde-comp: Ctrl+Alt+F" & $vt & " -- przełączam na VT" & $vt)
  discard wlrSessionChangeVt(server.session, vt)
  true
