-- Drone Finder v3.1 - by michalek.me

local lastBeep = 0
local avg = -120
local beepEnabled = true

-- Touch debounce
local lastTouchTick = 0

local function clamp(x,a,b)
  if x < a then return a elseif x > b then return b else return x end
end

local function readSignal()
  local rssi = getValue("1RSS")
  if rssi and rssi ~= 0 then return rssi, "1RSS" end

  local snr = getValue("RSNR")
  if snr and snr ~= 0 then return (snr*2-120), "RSNR" end

  local rql = getValue("RQly")
  if rql and rql ~= 0 then return (rql-120), "RQly" end

  return -120, "NA"
end

local function readBattery()
  local candidates = { "VFAS", "RxBt", "Batt", "A4" }
  for _,c in ipairs(candidates) do
    local v = getValue(c)
    if v and v ~= 0 then return v end
  end
  return nil
end

local function estimateCells(v)
  if not v then return nil end
  if v < 5 then return 1
  elseif v < 9 then return 2
  elseif v < 13.5 then return 3
  elseif v < 17.5 then return 4
  elseif v < 22 then return 5
  elseif v < 26.5 then return 6
  end
  return nil
end

-- colors
local hasColor = (type(lcd)=="table" and type(lcd.RGB)=="function" and type(lcd.setColor)=="function")
local function RGB(r,g,b) if hasColor then return lcd.RGB(r,g,b) else return 0 end end
local CUSTOM = (lcd and lcd.CUSTOM_COLOR) or 0
local function setC(c) if hasColor then lcd.setColor(CUSTOM, c) end end

local COL = {
  bg      = RGB(18,20,23),
  panel   = RGB(26,29,33),
  border  = RGB(130,135,145),
  text    = RGB(245,245,245),
  subtle  = RGB(200,205,215),

  header  = RGB(60,155,235),
  accent  = RGB(60,155,235),
  inner   = RGB(34,37,42),
  danger  = RGB(255,80,80),

  btnOn   = RGB(28,120,220),
  btnOff  = RGB(18,95,180),
}

local function tw(flags, s)
  if lcd.getTextWidth then return lcd.getTextWidth(flags, s) end
  return #s * 10
end

local function inRect(x,y, rx,ry,rw,rh)
  return x>=rx and x<=(rx+rw) and y>=ry and y<=(ry+rh)
end

local function toggleBeep()
  beepEnabled = not beepEnabled
  playTone(beepEnabled and 900 or 450, 60, 0, 0)
end

-- Smooth thick arc via dots
local function drawArcDots(cx, cy, radius, thickness, degFrom, degTo)
  if not (hasColor and lcd.drawFilledCircle) then return end
  local r = math.floor(thickness/2)
  for a = degFrom, degTo, 2 do
    local rad = math.rad(a - 90)
    local x = cx + math.cos(rad) * radius
    local y = cy + math.sin(rad) * radius
    lcd.drawFilledCircle(x, y, r, CUSTOM)
  end
end

local function drawDonut(cx, cy, outerR, pct)
  pct = clamp(pct,0,100)
  local thickness = 12
  local midR = outerR - math.floor(thickness/2)
  local sweep = math.floor((pct/100)*360)

  setC(COL.accent)
  drawArcDots(cx,cy,midR,thickness,0,sweep)

  setC(COL.inner)
  if hasColor and lcd.drawFilledCircle then
    lcd.drawFilledCircle(cx,cy,outerR-thickness-2,CUSTOM)
  else
    lcd.drawCircle(cx,cy,outerR-thickness-2)
  end
end

-- Touch: try both getTouchState() and touch-like events
local function handleTouch(btn, event)
  local now = getTime()
  if now - lastTouchTick < 20 then return end -- debounce

  -- 1) getTouchState (if available)
  if getTouchState then
    local t = getTouchState()
    if t then
      local x = t.x or t.X
      local y = t.y or t.Y
      local tapped = (t.tap == true) or (t.event == "tap") or (t.state == "tap") or (t.gesture == "tap")
      local pressed = (t.pressed == true) or (t.down == true) or (t.state == "down") or (t.state == "press")
      if x and y and (tapped or pressed) and inRect(x,y, btn.x,btn.y,btn.w,btn.h) then
        lastTouchTick = now
        toggleBeep()
        return
      end
    end
  end

  -- 2) Touch events fallback (names vary by build, we accept a few)
  if event == EVT_TOUCH_TAP or event == EVT_TOUCH_FIRST or event == EVT_TOUCH_BREAK then
    -- Some builds store touch coords in global vars; if not, we cannot use them here.
    -- Still keep this hook for compatibility (won't break anything).
    -- If your build provides touch coords via globals, we can wire them in later.
  end
end

local function run_func(event)
  -- ENTER fallback always works
  if event == EVT_VIRTUAL_ENTER or event == EVT_ENTER_BREAK then
    toggleBeep()
  end

  local now = getTime()
  local raw, kind = readSignal()

  -- Faster response:
  -- - less smoothing overall
  -- - "fast drop" when signal disappears or collapses
  local alpha = 0.35  -- bigger alpha = faster response
  if raw <= -118 or kind == "NA" then
    -- fast drop to avoid 1-2s lag on power-off
    avg = avg * 0.30 + raw * 0.70
  else
    avg = (1-alpha) * avg + alpha * raw
  end

  local strength = clamp((avg + 110)*(100/70),0,100)

  if beepEnabled then
    if now - lastBeep > clamp(120-strength,10,120) then
      playTone(650+(strength*6),35,0,0)
      lastBeep = now
    end
  end

  local battV = readBattery()
  local cells = estimateCells(battV)
  local perCell = (battV and cells) and (battV/cells) or nil

  local W, H = LCD_W, LCD_H

  lcd.clear()
  if hasColor then
    setC(COL.bg)
    lcd.drawFilledRectangle(0,0,W,H,CUSTOM)
  end

  -- HEADER
  local headerH = 46
  if hasColor then
    setC(COL.header)
    lcd.drawFilledRectangle(0,0,W,headerH,CUSTOM)
  end

  setC(COL.text)
  lcd.drawText(14,5,"Drone Finder",DBLSIZE+CUSTOM)

  -- LEFT PANEL
  local lpX, lpY = 12, headerH+10
  local lpW, lpH = math.floor(W*0.56), H-lpY-12

  if hasColor then
    setC(COL.panel)
    lcd.drawFilledRectangle(lpX,lpY,lpW,lpH,CUSTOM)
  end
  setC(COL.border)
  lcd.drawRectangle(lpX,lpY,lpW,lpH,CUSTOM)

  local y = lpY+16
  local step=20

  setC(COL.text)
  lcd.drawText(lpX+12,y,"Signal Type:",CUSTOM)
  lcd.drawText(lpX+160,y,kind,CUSTOM)

  y=y+step
  lcd.drawText(lpX+12,y,"Raw value:",CUSTOM)
  lcd.drawText(lpX+160,y,string.format("%ddBm",raw),CUSTOM)

  y=y+step
  lcd.drawText(lpX+12,y,"Avg:",CUSTOM)
  lcd.drawText(lpX+160,y,string.format("%ddBm",avg),CUSTOM)

  y=y+step
  lcd.drawText(lpX+12,y,"Battery:",CUSTOM)

  local battColor = COL.subtle
  if perCell and perCell < 3.4 then battColor = COL.danger end
  setC(battColor)
  if battV then
    lcd.drawText(lpX+160,y,string.format("%.2fV (%ds)",battV,cells or 1),CUSTOM)
  else
    lcd.drawText(lpX+160,y,"NA",CUSTOM)
  end

  -- BUTTON (we keep it; touch may work via getTouchState)
  local btn = {
    x = lpX+12,
    y = lpY+lpH-44,
    w = lpW-24,
    h = 32
  }

  handleTouch(btn, event)

  if hasColor then
    setC(beepEnabled and COL.btnOn or COL.btnOff)
    lcd.drawFilledRectangle(btn.x,btn.y,btn.w,btn.h,CUSTOM)
  end

  local label = beepEnabled and "Sound: ON" or "Sound: OFF"
  local wLabel = tw(MIDSIZE,label)

  -- nudge up a bit more
  local textY = btn.y + math.floor((btn.h-18)/2) - 4

  setC(COL.text)
  lcd.drawText(btn.x+math.floor((btn.w-wLabel)/2),textY,label,MIDSIZE+CUSTOM)

  -- DONUT
  local gx = math.floor(W*0.80)
  local gy = math.floor(H*0.64)
  local gr = math.floor(math.min(W,H)*0.30)

  drawDonut(gx,gy,gr,strength)

  -- Percent: centered as one string "96%"
  local pct = math.floor(strength+0.5)
  local pctStr = tostring(pct) .. "%"

  local fontNum = DBLSIZE
  local maxW = gr * 1.20
  if tw(DBLSIZE, "100%") > maxW then
    fontNum = MIDSIZE
  end

  setC(COL.text)
  local wPctAll = tw(fontNum, pctStr)
  -- shift slightly up to look optically centered
  lcd.drawText(gx - math.floor(wPctAll/2), gy - 22, pctStr, fontNum + CUSTOM)

  return 0
end

return { run=run_func }
