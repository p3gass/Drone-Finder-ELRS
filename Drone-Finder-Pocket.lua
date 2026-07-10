-- Drone Finder v4.0 - Pocket Edition
-- Rewritten for RadioMaster Pocket (128x64 monochrome LCD, EdgeTX, buttons only)
-- Based on Drone Finder v3.6 by michalek.me (originally built for TX15's LVGL color UI)
--
-- WHY THIS REWRITE EXISTS:
-- The Pocket has a 1.6" 128x64 monochrome LCD with no touchscreen. It does not support
-- lvgl (that API only exists on color touchscreen EdgeTX radios like the TX15/TX16S/Zorro).
-- This version uses the standard lcd.draw* API that works on every EdgeTX mono radio.

local app_ver = "4.0"

local lastUpdate = 0
local lastBeep = 0
local lastDetect = 0
local lastUI = 0

-- Ticks are 1/100s. Mono text/rect draws are cheap vs. LVGL composites, but we still
-- throttle redraws to avoid flicker and needless work.
local updateEveryTicks = 5      -- 50ms  - read signal/battery
local detectEveryTicks = 200    -- 2s    - re-scan available sensors
local uiEveryTicks = 10         -- 100ms - redraw screen

local beepEnabled = true
local raw, kind = -120, "NA"
local avg = -120
local signalPercent = 0
local battV, battSrc = nil, "NA"

local alphaNormal = 0.40
local alphaDrop = 0.88

local have = { rssi=false, snr=false, rql=false, vfas=false, rxbt=false, batt=false, a4=false }

local function clamp(x,a,b)
  if x < a then return a elseif x > b then return b else return x end
end

local function detectSensors()
  have.rssi = (getFieldInfo("1RSS") ~= nil)
  have.snr  = (getFieldInfo("RSNR") ~= nil)
  have.rql  = (getFieldInfo("RQly") ~= nil)

  have.vfas = (getFieldInfo("VFAS") ~= nil)
  have.rxbt = (getFieldInfo("RxBt") ~= nil)
  have.batt = (getFieldInfo("Batt") ~= nil)
  have.a4   = (getFieldInfo("A4")   ~= nil)
end

local function readSignal()
  local v
  if have.rssi then
    v = getValue("1RSS")
    if v and v ~= 0 then return v, "1RSS" end
  end
  if have.snr then
    v = getValue("RSNR")
    if v and v ~= 0 then return (v*2-120), "RSNR" end
  end
  if have.rql then
    v = getValue("RQly")
    if v and v ~= 0 then return (v-120), "RQly" end
  end
  return -120, "NA"
end

local function readBattery()
  local v
  if have.vfas then v = getValue("VFAS"); if v and v ~= 0 then return v, "VFAS" end end
  if have.rxbt then v = getValue("RxBt"); if v and v ~= 0 then return v, "RxBt" end end
  if have.batt then v = getValue("Batt"); if v and v ~= 0 then return v, "Batt" end end
  if have.a4   then v = getValue("A4");   if v and v ~= 0 then return v, "A4" end end
  return nil, "NA"
end

local function estimateCells(v)
  if not v then return nil end
  if v < 5.0 then return 1 end
  if v < 8.8 then return 2 end
  if v < 13.2 then return 3 end
  if v < 17.6 then return 4 end
  if v < 22.0 then return 5 end
  if v < 26.4 then return 6 end
  return nil
end

-- ===== Display (128x64 monochrome, buttons/scroll wheel only) =====
local function drawScreen()
  local W, H = LCD_W, LCD_H  -- 128, 64 on Pocket; keeps script portable to other mono radios

  lcd.clear()

  -- Header bar (inverted block + white-on-black text)
  lcd.drawFilledRectangle(0, 0, W, 9)
  lcd.drawText(2, 1, "DRONE FINDER", SMLSIZE + INVERS)
  lcd.drawText(W - 2, 1, "v" .. app_ver, SMLSIZE + INVERS + RIGHT)

  -- Signal type + raw dBm
  lcd.drawText(0, 11, "sig: " .. kind, SMLSIZE)
  lcd.drawText(W - 2, 11, raw .. "dBm", SMLSIZE + RIGHT)

  -- Smoothed average
  lcd.drawText(0, 20, "avg: " .. math.floor(avg) .. "dBm", SMLSIZE)

  -- Sound toggle state (right-aligned, same row as avg to save vertical space)
  lcd.drawText(W - 2, 20, beepEnabled and "SND:ON" or "SND:OFF", SMLSIZE + RIGHT)

  -- Battery, with blinking inverted warning if under 3.40V/cell
  local battText = "batt: NA"
  local battFlags = SMLSIZE
  if battV then
    local cells = estimateCells(battV)
    if cells then
      battText = string.format("batt: %.2fV (%ds)", battV, cells)
      if (battV / cells) < 3.40 then
        battFlags = SMLSIZE + BLINK + INVERS
      end
    else
      battText = string.format("batt: %.2fV", battV)
    end
  end
  lcd.drawText(0, 29, battText, battFlags)

  -- Signal gauge: horizontal bar with percent centered on top
  local gx, gy, gw, gh = 2, 39, W - 4, 18
  lcd.drawRectangle(gx, gy, gw, gh)
  local fillW = math.floor((gw - 2) * signalPercent / 100)
  if fillW > 0 then
    lcd.drawFilledRectangle(gx + 1, gy + 1, fillW, gh - 2)
  end
  lcd.drawText(W / 2, gy + 1, signalPercent .. "%", MIDSIZE + CENTER + INVERS)

  -- Footer hint (Pocket has no touch, so this is the only way to reach the toggle)
  lcd.drawText(0, H - 8, "ENT: toggle sound", SMLSIZE)
end

local function init()
  detectSensors()
end

local function run(event)
  local now = getTime()

  if event == EVT_VIRTUAL_ENTER or event == EVT_ENTER_BREAK then
    beepEnabled = not beepEnabled
  end

  if now - lastDetect >= detectEveryTicks then
    lastDetect = now
    detectSensors()
  end

  if now - lastUpdate >= updateEveryTicks then
    lastUpdate = now

    raw, kind = readSignal()
    battV, battSrc = readBattery()

    if kind == "NA" or raw <= -118 then
      avg = avg*(1-alphaDrop) + raw*alphaDrop
    else
      avg = avg*(1-alphaNormal) + raw*alphaNormal
    end

    local s = clamp((avg + 110) * (100/70), 0, 100)
    signalPercent = math.floor(s + 0.5)

    if beepEnabled then
      local period = clamp(120 - signalPercent, 10, 120)
      if now - lastBeep >= period then
        playTone(650 + (signalPercent * 6), 35, 0, 0)
        lastBeep = now
      end
    end
  end

  if now - lastUI >= uiEveryTicks then
    lastUI = now
    drawScreen()
  end

  return 0
end

return { init=init, run=run }
