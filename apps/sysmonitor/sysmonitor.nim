import std/[strutils, strformat]
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

proc newSysMonState*(): SysMonState =
  result = SysMonState(cpuHistory: @[], cpuPercent: 0, lastPoll: 0)
  result.lastCpu = readCpuSample()
  (result.memTotalKb, result.memAvailKb) = readMemInfo()

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

proc memUsedPercent(sm: SysMonState): float32 =
  if sm.memTotalKb == 0: return 0
  float32((sm.memTotalKb.float64 - sm.memAvailKb.float64) / sm.memTotalKb.float64 * 100.0)

proc humanKb(kb: uint64): string =
  let mb = kb.float64 / 1024.0
  if mb >= 1024.0:
    result = &"{mb / 1024.0:.1f} GB"
  else:
    result = &"{mb:.0f} MB"

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
