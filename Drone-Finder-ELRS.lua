-- Drone Finder v3.6 - by michalek.me
-- Premium UI fixes: percent ALWAYS inside the circle + remove toggle background block
-- Radiomaster TX15 / EdgeTX 3.0.0

local app_ver = "3.6"

local lastUpdate = 0
local lastBeep = 0
local lastDetect = 0
local lastUI = 0

local updateEveryTicks = 2
local detectEveryTicks = 100
local uiEveryTicks = 15

local beepEnabled = true
local raw, kind = -120, "NA"
local avg = -120
local signalPercent = 0
local battV, battSrc = nil, "NA"

local alphaNormal = 0.40
local alphaDrop = 0.88

local have = { rssi=false, snr=false, rql=false, vfas=false, rxbt=false, batt=false, a4=false }

local FS = { FONT_38=XXLSIZE, FONT_16=DBLSIZE, FONT_12=MIDSIZE, FONT_8=0, FONT_6=SMLSIZE }

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

local function textWidth(flags, s)
  if lcd and lcd.getTextWidth then
    return lcd.getTextWidth(flags, s)
  end
  return #s * 12
end

local function build_ui()
  if not lvgl then return end
  lvgl.clear()

  local W, H = LCD_W, LCD_H
  local headerH = 46
  local margin = 12

  -- Premium colors
  local bg      = lcd.RGB(18,20,23)
  local panelBg = lcd.RGB(26,29,33)
  local header  = lcd.RGB(60,155,235)
  local accent  = lcd.RGB(60,155,235)
  local ringBg  = lcd.RGB(120,130,140)
  local disc    = lcd.RGB(32,36,41)
  local shadow  = lcd.RGB(10,12,14)

  local panelX = margin
  local panelY = headerH + 10
  local panelW = math.floor(W * 0.48)
  local panelH = H - panelY - margin
  if panelX + panelW > W - margin then panelW = (W - margin) - panelX end

  local gaugeR = math.floor(math.min(W, H) * 0.30)
  local gx = W - margin - gaugeR
  local gy = math.floor(H * 0.58)

  local startA = 120
  local endA   = 120 + math.floor(300 * signalPercent / 100)
  local ringTh = 22

  -- Percent: ALWAYS inside the circle (safe inner radius clamp)
  local pctStr = tostring(signalPercent) .. "%"
  local pctFont = FS.FONT_16 -- premium, consistent, prevents overflow

  local pctW = textWidth(pctFont, pctStr)

  -- safe inner zone (avoid ring)
  local innerSafe = math.floor(gaugeR * 0.62)
  local leftLimit  = gx - innerSafe
  local rightLimit = gx + innerSafe - pctW

  -- centered + slightly left for aesthetics
  local desiredX = gx - math.floor(pctW / 2) - 18
  local pctX = clamp(desiredX, leftLimit, rightLimit)

  -- slightly up to feel centered optically
  local pctY = gy - 30

  lvgl.build({
    {type="rectangle", x=0, y=0, w=W, h=H, color=bg, filled=true},

    {type="rectangle", x=0, y=0, w=W, h=headerH, color=header, filled=true},
    {type="label", x=14, y=6, text="Drone Finder", color=WHITE, font=FS.FONT_16},
    {type="label", x=W-44, y=14, text="v"..app_ver, color=WHITE, font=FS.FONT_6},

    {type="rectangle", x=panelX, y=panelY, w=panelW, h=panelH, color=panelBg, filled=true},

    {type="label", x=panelX+14, y=panelY+16, text="Signal Type:", color=WHITE, font=FS.FONT_8},
    {type="label", x=panelX+160, y=panelY+16, text=tostring(kind), color=WHITE, font=FS.FONT_8},

    {type="label", x=panelX+14, y=panelY+36, text="Raw value:", color=WHITE, font=FS.FONT_8},
    {type="label", x=panelX+160, y=panelY+36, text=tostring(raw).."dBm", color=WHITE, font=FS.FONT_8},

    {type="label", x=panelX+14, y=panelY+56, text="Avg:", color=WHITE, font=FS.FONT_8},
    {type="label", x=panelX+160, y=panelY+56, text=tostring(math.floor(avg)).."dBm", color=WHITE, font=FS.FONT_8},

    {type="label", x=panelX+14, y=panelY+76, text="Battery:", color=WHITE, font=FS.FONT_8},
    {type="label", x=panelX+160, y=panelY+76,
      text=(function()
        if not battV then return "NA" end
        local cells = estimateCells(battV)
        if cells then return string.format("%.2fV (%ds)", battV, cells) end
        return string.format("%.2fV", battV)
      end)(),
      color=(function()
        if not battV then return WHITE end
        local cells = estimateCells(battV)
        if not cells then return WHITE end
        if (battV / cells) < 3.40 then return RED end
        return WHITE
      end)(),
      font=FS.FONT_8
    },

    -- Sound (no extra block)
    {type="label", x=panelX+14, y=panelY+panelH-44, text="Sound:", color=WHITE, font=FS.FONT_12},
    {type="toggle", x=panelX+120, y=panelY+panelH-48,
      get=function() return beepEnabled end,
      set=function(val) beepEnabled = (val==1) end
    },

    -- Premium gauge stack
    {type="arc", x=gx, y=gy,
      radius=gaugeR-2,
      thickness=(gaugeR*2),
      startAngle=0, endAngle=360,
      opacity=255,
      bgStartAngle=0, bgEndAngle=0, bgOpacity=0,
      color=disc,
      rounded=false
    },

    {type="arc", x=gx+2, y=gy+2,
      radius=gaugeR,
      thickness=ringTh,
      startAngle=startA, endAngle=(startA + 300),
      opacity=80,
      bgStartAngle=0, bgEndAngle=0, bgOpacity=0,
      color=shadow,
      rounded=false
    },

    {type="arc", x=gx, y=gy,
      radius=gaugeR,
      thickness=ringTh,
      startAngle=startA, endAngle=(startA + 300),
      opacity=255,
      bgStartAngle=0, bgEndAngle=0, bgOpacity=0,
      color=ringBg,
      rounded=false
    },

    {type="arc", x=gx, y=gy,
      radius=gaugeR,
      thickness=ringTh,
      startAngle=startA, endAngle=endA,
      opacity=255,
      bgStartAngle=0, bgEndAngle=0, bgOpacity=0,
      color=accent,
      rounded=false
    },

    {type="label", x=pctX, y=pctY,
      text=pctStr,
      color=WHITE,
      font=pctFont
    },
  })
end

local function init()
  if not lvgl then return 0 end
  detectSensors()
  build_ui()
  return 0
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
    build_ui()
  end

  return 0
end

return { init=init, run=run }
