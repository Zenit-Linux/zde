import std/[strutils, strformat, posix]
import fidget
import ../../comp/comp

const HistoryLen = 60  ## ile próbek trzymamy do wykresu (jedna na klatkę tick)

type
  CpuSample = object
    idle, total: uint64

  SysMonState* = ref object of RootObj
    lastCpu: CpuSample
    cpuPercent*: float32
    cpuHistory*: seq[float32]
    memTotalKb*, memAvailKb*: uint64
    ## Rozbudowa v0.2 (użycie dysku): monitor systemu dotąd pokazywał
    ## TYLKO CPU i RAM -- dysk (chyba najbardziej oczywista trzecia
    ## rzecz, jakiej ktoś by oczekiwał od "Monitora systemu", zaraz obok
    ## CPU/RAM) był całkowicie pominięty, mimo że dane są równie łatwo
    ## dostępne co `/proc/stat`/`/proc/meminfo` -- tu przez `statvfs(2)`
    ## na "/", standardowe POSIX-owe wywołanie używane przez `df` i
    ## każdy inny monitor dysku.
    diskTotalKb*, diskUsedKb*: uint64
    lastPoll*: float

proc readCpuSample(): CpuSample =
  ## Pierwsza linia /proc/stat: "cpu  user nice system idle iowait irq softirq steal guest guest_nice"
  try:
    let line = readFile("/proc/stat").splitLines()[0]
    let parts = line.splitWhitespace()
    if parts.len < 5 or parts[0] != "cpu":
      return CpuSample(idle: 0, total: 0)
    var total: uint64 = 0
    for i in 1 ..< parts.len:
      total += parseUInt(parts[i]).uint64
    let idle = parseUInt(parts[4]).uint64  # pole "idle"
    result = CpuSample(idle: idle, total: total)
  except CatchableError:
    result = CpuSample(idle: 0, total: 0)

proc readMemInfo(): tuple[totalKb, availKb: uint64] =
  var totalKb, availKb: uint64 = 0
  try:
    for line in lines("/proc/meminfo"):
      if line.startsWith("MemTotal:"):
        totalKb = parseUInt(line.splitWhitespace()[1]).uint64
      elif line.startsWith("MemAvailable:"):
        availKb = parseUInt(line.splitWhitespace()[1]).uint64
  except CatchableError:
    discard
  (totalKb, availKb)

proc readDiskInfo(path: string): tuple[totalKb, usedKb: uint64] =
  ## `statvfs(2)` na `path` (zawsze "/" -- patrz `poll` niżej; przestrzeń
  ## dyskowa danego punktu montowania jest tym, co użytkownicy zwykle
  ## mają na myśli mówiąc "ile miejsca zostało", nawet gdy `/home` albo
  ## `/var` są osobnymi montowaniami -- pokazywanie WYŁĄCZNIE "/" jest
  ## uproszczeniem świadomie zaakceptowanym tutaj, tak jak np. karta
  ## "Przechowywanie" w GNOME Ustawieniach domyślnie też pokazuje
  ## montowanie główne jako pierwsze/najważniejsze). Zwraca (0, 0) po
  ## cichu przy błędzie (np. brak uprawnień, bardzo nietypowy system
  ## plików) -- dokładnie ten sam styl obrony co `readCpuSample`/
  ## `readMemInfo` wyżej, żeby jedna nieudana próba nie wywalała całego
  ## okna monitora.
  var st: Statvfs
  if statvfs(path.cstring, st) != 0:
    return (0'u64, 0'u64)
  let frsize = st.f_frsize.uint64
  let totalKb = (st.f_blocks.uint64 * frsize) div 1024
  let freeKb = (st.f_bavail.uint64 * frsize) div 1024
  (totalKb, totalKb - freeKb)

proc newSysMonState*(): SysMonState =
  result = SysMonState(cpuHistory: @[], cpuPercent: 0, lastPoll: 0)
  result.lastCpu = readCpuSample()
  (result.memTotalKb, result.memAvailKb) = readMemInfo()
  (result.diskTotalKb, result.diskUsedKb) = readDiskInfo("/")

proc poll*(sm: SysMonState) =
  ## Wołane co jakiś czas z tick() shellu (nie musi być co klatkę -- co
  ## sekundę w zupełności wystarczy dla czytelnego wykresu).
  let sample = readCpuSample()
  let dTotal = sample.total.float64 - sm.lastCpu.total.float64
  let dIdle = sample.idle.float64 - sm.lastCpu.idle.float64
  if dTotal > 0:
    sm.cpuPercent = float32(clamp((dTotal - dIdle) / dTotal * 100.0, 0.0, 100.0))
  sm.lastCpu = sample

  sm.cpuHistory.add(sm.cpuPercent)
  if sm.cpuHistory.len > HistoryLen:
    let overflow = sm.cpuHistory.len - HistoryLen
    sm.cpuHistory = sm.cpuHistory[overflow ..^ 1]

  (sm.memTotalKb, sm.memAvailKb) = readMemInfo()
  (sm.diskTotalKb, sm.diskUsedKb) = readDiskInfo("/")

proc memUsedPercent(sm: SysMonState): float32 =
  if sm.memTotalKb == 0: return 0
  float32((sm.memTotalKb.float64 - sm.memAvailKb.float64) / sm.memTotalKb.float64 * 100.0)

proc diskUsedPercent(sm: SysMonState): float32 =
  if sm.diskTotalKb == 0: return 0
  float32(sm.diskUsedKb.float64 / sm.diskTotalKb.float64 * 100.0)

proc humanKb(kb: uint64): string =
  ## Rozbudowa v0.2: ten sam błąd formatowania co w `apps/calculator/calculator.nim`
  ## (`formatNumber`, patrz komentarz tam po pełne wyjaśnienie) --
  ## `&"{x:.0f}"` zostawia kropkę na końcu nawet przy zerze miejsc po
  ## przecinku. Zauważone tym razem na PIERWSZYM realnym zrzucie ekranu
  ## tej rundy ("511. MB", nie "511 MB") -- nie przez osobny,
  ## wyspecjalizowany test, tylko przez uważne spojrzenie na zwykły
  ## zrzut ekranu z rzeczywistymi danymi. Gałąź `:.1f` (GB, z jedną
  ## cyfrą po przecinku) NIE ma tego problemu -- kropka tam jest
  ## znacząca (oddziela cyfrę dziesiętną), nie nadmiarowa.
  let mb = kb.float64 / 1024.0
  if mb >= 1024.0:
    result = &"{mb / 1024.0:.1f} GB"
  else:
    result = (&"{mb:.0f}").strip(chars = {'.'}) & " MB"

proc drawBar(idPrefix: string, x, y, w, h: float32, percent: float32, color: string) =
  rectangle idPrefix & "-bg":
    box x, y, w, h
    fill "#20262e"
    cornerRadius h / 2
  let fillW = max(h, w * clamp(percent / 100.0, 0.0, 1.0))
  rectangle idPrefix & "-fill":
    box x, y, fillW, h
    fill color
    cornerRadius h / 2

proc drawSysMonitor*(sm: SysMonState, win: ZdeWindow) =
  let pad = 16.0'f32

  frame "sysmon-root":
    box 0, 0, win.size.x, win.size.y
    fill "#12161c"

    text "cpu-label":
      box pad, pad, win.size.x - pad * 2, 20
      font "sans-serif", 13, 600, 20, hLeft, vTop
      fill "#8a94a3"
      characters "CPU"

    text "cpu-value":
      box pad, pad, win.size.x - pad * 2, 20
      font "monospace", 13, 600, 20, hRight, vTop
      fill "#e8ecf0"
      characters $(sm.cpuPercent.int) & "%"

    drawBar("cpu-bar", pad, pad + 24, win.size.x - pad * 2, 14, sm.cpuPercent, "#5fb0ff")

    # -- mini-wykres historii CPU (słupki) -----------------------------------
    let graphY = pad + 52
    let graphH = 70.0'f32
    let graphW = win.size.x - pad * 2
    rectangle "graph-bg":
      box pad, graphY, graphW, graphH
      fill "#181d24"
      cornerRadius 4
    if sm.cpuHistory.len > 1:
      let barW = graphW / HistoryLen.float32
      for i, v in sm.cpuHistory:
        let bh = max(1.0'f32, graphH * clamp(v / 100.0, 0.0, 1.0))
        rectangle "graph-bar-" & $i:
          box pad + i.float32 * barW, graphY + graphH - bh, max(1.0, barW - 1), bh
          fill "#5fb0ff"

    # -- RAM ------------------------------------------------------------------
    let ramY = graphY + graphH + 24
    text "ram-label":
      box pad, ramY, win.size.x - pad * 2, 20
      font "sans-serif", 13, 600, 20, hLeft, vTop
      fill "#8a94a3"
      characters "Pamięć RAM"

    text "ram-value":
      box pad, ramY, win.size.x - pad * 2, 20
      font "monospace", 12, 500, 20, hRight, vTop
      fill "#e8ecf0"
      characters humanKb(sm.memTotalKb - sm.memAvailKb) & " / " & humanKb(sm.memTotalKb)

    drawBar("ram-bar", pad, ramY + 24, win.size.x - pad * 2, 14, memUsedPercent(sm), "#7fd88f")

    # -- Dysk (rozbudowa v0.2) -------------------------------------------------
    let diskY = ramY + 24 + 14 + 24
    text "disk-label":
      box pad, diskY, win.size.x - pad * 2, 20
      font "sans-serif", 13, 600, 20, hLeft, vTop
      fill "#8a94a3"
      characters "Dysk (/)"

    text "disk-value":
      box pad, diskY, win.size.x - pad * 2, 20
      font "monospace", 12, 500, 20, hRight, vTop
      fill "#e8ecf0"
      characters humanKb(sm.diskUsedKb) & " / " & humanKb(sm.diskTotalKb)

    drawBar("disk-bar", pad, diskY + 24, win.size.x - pad * 2, 14, diskUsedPercent(sm), "#d78a3d")
