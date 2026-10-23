require "import"
import "android.widget.*"
import "android.view.*"
import "android.content.Context"
import "android.content.DialogInterface"
import "android.os.*"
import "android.media.AudioTrack"
import "android.media.ToneGenerator"
import "com.androlua.LuaDialog"
import "android.app.DownloadManager"
import "android.net.Uri"
import "java.io.File"
import "java.lang.System"
local TEST = rawget(_G, "CSR_TEST")
local context = activity or service
local mainHandler = Handler(Looper.getMainLooper())
local APP_VERSION = "1.3"

-- Commentary language: "en" (default) or "ur". Change it in Settings.
-- T("urdu text") returns the text in the chosen language. All words are listed at the end of this file.
local LANG = { code = "en", en = {}, ur = {} }
local function T(s)
  local v = LANG[LANG.code][s]
  if v ~= nil then return v end
  return s
end
local applyLanguage
local ARENA = 140
local STEP = 3
local SR = 16000
math.randomseed(os.time())
local function atan2(y, x)
  if x > 0 then
    return math.atan(y / x)
  elseif x < 0 then
    if y >= 0 then return math.atan(y / x) + math.pi end
    return math.atan(y / x) - math.pi
  end
  if y > 0 then return math.pi / 2 end
  if y < 0 then return -math.pi / 2 end
  return 0
end
local function clamp(v, a, b)
  if v < a then return a elseif v > b then return b end
  return v
end
local function n0(x)
  return tostring(math.floor(x + 0.5))
end
local function dist(ax, ay, bx, by)
  local dx, dy = bx - ax, by - ay
  return math.sqrt(dx * dx + dy * dy)
end
local function norm180(a)
  a = a % 360
  if a > 180 then a = a - 360 end
  return a
end
local function bearingTo(ax, ay, bx, by)
  local d = math.deg(atan2(bx - ax, by - ay))
  if d < 0 then d = d + 360 end
  return d
end
local function relAngle(e, x, y)
  return norm180(bearingTo(e.x, e.y, x, y) - e.face)
end
local function dirText(rel)
  local a = math.abs(rel)
  if a <= 45 then return T("سامنے") end
  if a >= 135 then return T("پیچھے") end
  if rel >= 0 then return T("دائیں طرف") end
  return T("بائیں طرف")
end
local function escapeText(rel)
  local a = math.abs(rel)
  if a <= 45 then return T("پیچھے بھاگیں!") end
  if a >= 135 then return T("آگے بھاگیں!") end
  if rel > 0 then return T("بائیں بھاگیں!") end
  return T("دائیں بھاگیں!")
end
local function later(ms, fn)
  if TEST then
    fn()
    return
  end
  mainHandler.postDelayed(Runnable({
    run = function()
      pcall(fn)
    end
  }), ms)
end
local speechLog = {}
local function say(text)
  if not text or text == "" then return end
  if TEST then
    speechLog[#speechLog + 1] = text
    return
  end
  pcall(function() service.speak(text) end)
end
local function getCtx()
  local ok, c = pcall(function() return service.getContext() end)
  if ok and c then return c end
  return context
end
local PREFS = "csr_battle_royale_prefs"
local function saveStorage(key, value)
  pcall(function()
    local sp = getCtx().getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    sp.edit().putString(key, tostring(value)).commit()
  end)
end
local function readStorage(key, defaultVal)
  local result = defaultVal
  pcall(function()
    local sp = getCtx().getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    local value = sp.getString(key, nil)
    if value ~= nil then result = value end
  end)
  return result
end
local DEFAULTS = { auto = "enemy", mode = "turn", tick = 2500, turnStep = 30, diff = 1, bots = 15, vol = 1.0, attack = "sync", lang = "en" }
local settings = {}
for k, v in pairs(DEFAULTS) do settings[k] = v end
local stats = { games = 0, wins = 0, best = 0 }
local function loadSettings()
  for k, dv in pairs(DEFAULTS) do
    local s = readStorage("set_" .. k, nil)
    if s ~= nil then
      if type(dv) == "number" then
        local nv = tonumber(s)
        if nv then settings[k] = nv end
      else
        settings[k] = tostring(s)
      end
    end
  end
  for k, _ in pairs(stats) do
    local nv = tonumber(readStorage("stat_" .. k, "0"))
    if nv then stats[k] = nv end
  end
  if settings.auto == "full" then settings.auto = "enemy" end
  LANG.code = (settings.lang == "ur") and "ur" or "en"
end
local function setSetting(k, v)
  settings[k] = v
  saveStorage("set_" .. k, v)
end
local function saveStats()
  for k, v in pairs(stats) do saveStorage("stat_" .. k, v) end
end
local Snd = { lua = {}, cache = {}, len = {}, base = nil, active = 0, failed = false, warned = false }
local function tone(f, t) return math.sin(2 * math.pi * f * t) end
local function rnd() return math.random() * 2 - 1 end
local function synth(dur, fn)
  local n = math.floor(SR * dur)
  local out = {}
  for i = 1, n do
    local t = (i - 1) / SR
    local v = fn(t, (i - 1) / n)
    if v > 1 then v = 1 elseif v < -1 then v = -1 end
    out[i] = math.floor(v * 28000)
  end
  return out
end
local function shotDef(dur, decay, lowf, lpk, gain)
  local lp = 0
  return synth(dur, function(t)
    lp = lp + lpk * (rnd() - lp)
    local v = lp * 1.8 + tone(lowf * (1 - t * 0.8), t) * 0.9
    return v * math.exp(-t * decay) * gain
  end)
end
local DEFS = {}
DEFS.step = function()
  local lp = 0
  return synth(0.11, function(t)
    lp = lp + 0.25 * (rnd() - lp)
    return (lp * 1.6 + tone(70, t) * 0.8) * math.exp(-t * 38) * 0.9
  end)
end
DEFS.selfstep = function()
  local lp = 0
  return synth(0.09, function(t)
    lp = lp + 0.2 * (rnd() - lp)
    return (lp * 1.2 + tone(60, t) * 0.6) * math.exp(-t * 45) * 0.6
  end)
end
DEFS.runstep = function()
  local lp = 0
  return synth(0.09, function(t)
    lp = lp + 0.3 * (rnd() - lp)
    return (lp * 1.8 + tone(85, t) * 1.0) * math.exp(-t * 34)
  end)
end
DEFS.shot_pistol = function() return shotDef(0.22, 16, 110, 0.6, 0.95) end
DEFS.shot_smg = function() return shotDef(0.14, 26, 140, 0.7, 0.9) end
DEFS.shot_shotgun = function() return shotDef(0.40, 9, 70, 0.4, 1.0) end
DEFS.shot_rifle = function() return shotDef(0.22, 17, 100, 0.5, 1.0) end
DEFS.shot_sniper = function() return shotDef(0.55, 7, 60, 0.35, 1.0) end
DEFS.punch = function() return shotDef(0.12, 30, 90, 0.2, 0.9) end
DEFS.reload = function()
  return synth(0.5, function(t)
    local v = 0
    if t < 0.03 then v = rnd() * math.exp(-t * 150) end
    if t >= 0.22 and t < 0.28 then v = rnd() * math.exp(-(t - 0.22) * 120) end
    return v * 0.9
  end)
end
DEFS.empty = function()
  return synth(0.05, function(t) return rnd() * math.exp(-t * 120) * 0.8 end)
end
DEFS.pickup = function()
  return synth(0.3, function(t)
    local f = (t < 0.12) and 660 or 990
    local tt = (t < 0.12) and t or (t - 0.12)
    return tone(f, t) * math.exp(-tt * 14) * 0.7
  end)
end
DEFS.beacon = function()
  return synth(0.34, function(t)
    local f = (t < 0.14) and 880 or 1320
    local tt = (t < 0.14) and t or (t - 0.14)
    return (tone(f, t) * 0.8 + tone(f * 2, t) * 0.2) * math.exp(-tt * 12) * 0.7
  end)
end
DEFS.explosion = function()
  local lp = 0
  return synth(1.1, function(t)
    lp = lp + 0.08 * (rnd() - lp)
    local crack = rnd() * math.exp(-t * 28) * 0.9
    local boom = (lp * 3.0 + tone(52 * (1 - t * 0.45), t) * 1.3) * math.exp(-t * 4)
    return crack + boom
  end)
end
DEFS.intercept = function()
  local lp = 0
  return synth(0.35, function(t, u)
    lp = lp + 0.4 * (rnd() - lp)
    local f = 2400 - 1800 * u
    local pop = lp * math.exp(-(t - 0.18) * (t - 0.18) * 900) * 1.2
    return (tone(f, t) * 0.6 * math.exp(-t * 7) + pop) * 0.9
  end)
end
DEFS.emp = function()
  local lp = 0
  return synth(0.7, function(t, u)
    lp = lp + 0.5 * (rnd() - lp)
    local f = 160 + 2600 * (u ^ 2)
    return (tone(f, t) * 0.55 + lp * 0.5) * math.sin(math.pi * math.min(1, u * 1.15)) * 0.95
  end)
end
DEFS.lock = function()
  return synth(0.3, function(t)
    local on = (t < 0.09) or (t > 0.15 and t < 0.24)
    if not on then return 0 end
    return (tone(1500, t) * 0.7 + tone(3000, t) * 0.25) * 0.8
  end)
end
DEFS.plane = function()
  local lp = 0
  return synth(0.6, function(t, u)
    lp = lp + 0.15 * (rnd() - lp)
    local prop = 0.6 + 0.4 * math.sin(2 * math.pi * 24 * t)
    local v = (tone(92, t) + tone(184, t) * 0.6 + tone(276, t) * 0.35) * prop * 0.5 + lp * 0.5
    return v * math.min(1, u * 10) * math.min(1, (1 - u) * 10) * 0.9
  end)
end
DEFS.crate = function()
  local lp = 0
  return synth(0.5, function(t)
    lp = lp + 0.2 * (rnd() - lp)
    return tone(70 * (1 - t), t) * math.exp(-t * 10) * 1.0
        + (tone(1800, t) + tone(2700, t) * 0.6) * 0.3 * math.exp(-t * 25)
        + lp * 0.5 * math.exp(-t * 14)
  end)
end
DEFS.siren = function()
  return synth(0.6, function(t, u)
    local ph = 2 * math.pi * (750 * t - 350 / (2 * math.pi * 1.7) * math.cos(2 * math.pi * 1.7 * t))
    return (math.sin(ph) + 0.35 * math.sin(2 * ph)) * 0.55 * math.min(1, u * 12) * math.min(1, (1 - u) * 12)
  end)
end
DEFS.incoming = function()
  local lp = 0
  return synth(0.45, function(t, u)
    lp = lp + (0.1 + 0.5 * u) * (rnd() - lp)
    local f = 1800 - 1500 * u
    return (lp * 1.6 + tone(f, t) * 0.5) * (0.3 + 0.7 * u)
  end)
end
DEFS.shot_rocket = function()
  local lp = 0
  return synth(0.7, function(t)
    lp = lp + 0.25 * (rnd() - lp)
    local thump = tone(95 * (1 - t), t) * math.exp(-t * 12)
    local whoosh = lp * (0.2 + 0.8 * math.min(1, t * 3)) * math.exp(-t * 3.2)
    return (thump + whoosh * 1.7) * 0.9
  end)
end
DEFS.throw = function()
  local lp = 0
  return synth(0.25, function(t, u)
    lp = lp + 0.3 * (rnd() - lp)
    return lp * 1.4 * math.sin(math.pi * u)
  end)
end
DEFS.rain = function()
  local lp = 0
  return synth(0.5, function(t, u)
    lp = lp + 0.5 * (rnd() - lp)
    return lp * 0.35 * math.min(1, u * 8) * math.min(1, (1 - u) * 8)
  end)
end
DEFS.offer = function()
  local lp = 0
  return synth(0.5, function(t, u)
    lp = lp + 0.2 * (rnd() - lp)
    local f = 500 + 1400 * u
    return (tone(f, t) * 0.6 + lp * 0.4) * math.sin(math.pi * u) * 0.9
  end)
end

-- enemy dodge: cloth whoosh and a soft thud
DEFS.dodge = function()
  local lp = 0
  return synth(0.35, function(t)
    lp = lp + 0.35 * (rnd() - lp)
    local sw = lp * math.sin(math.pi * math.min(1, t / 0.25)) * 0.9
    local thud = 0
    if t > 0.2 then thud = tone(110, t - 0.2) * math.exp(-(t - 0.2) * 25) * 0.8 end
    return sw + thud
  end)
end

-- weapon caught: metal click-clack, then a bright rising chime
DEFS.weapon_got = function()
  local lp = 0
  return synth(1.1, function(t)
    lp = lp + 0.5 * (rnd() - lp)
    local v = 0
    if t < 0.06 then
      v = v + (lp * 1.2 + tone(1800, t) * 0.5) * math.exp(-t * 60)
    end
    if t >= 0.10 and t < 0.18 then
      local u = t - 0.10
      v = v + (lp * 1.2 + tone(1200, u) * 0.5) * math.exp(-u * 60)
    end
    local notes = { 523, 659, 784, 1047 }
    for k, f in ipairs(notes) do
      local st = 0.20 + (k - 1) * 0.11
      if t >= st then
        local u = t - st
        v = v + (tone(f, u) * 0.4 + tone(f * 2, u) * 0.12) * math.exp(-u * 5)
      end
    end
    return v * 0.85
  end)
end

-- weapon skipped: a falling slide whistle with a wobble, then a cartoon bonk
DEFS.weapon_skip = function()
  return synth(0.9, function(t)
    local v = 0
    if t < 0.55 then
      local ph = 2 * math.pi * (900 * t - 650 * t * t / 1.1)
      v = v + math.sin(ph + 0.6 * math.sin(2 * math.pi * 9 * t)) * 0.5 * math.min(1, (0.55 - t) * 8)
    end
    if t >= 0.58 then
      local w = t - 0.58
      v = v + math.sin(2 * math.pi * (160 + 60 * math.exp(-w * 18)) * w) * 0.7 * math.exp(-w * 10)
    end
    return v
  end)
end

DEFS.chime = function()
  return synth(0.25, function(t)
    return (tone(1320, t) * 0.7 + tone(1980, t) * 0.3) * math.exp(-t * 14) * 0.7
  end)
end
DEFS.hurt = function()
  local lp = 0
  return synth(0.28, function(t)
    lp = lp + 0.3 * (rnd() - lp)
    return (tone(150, t) * 0.7 + tone(225, t) * 0.4 + lp * 0.6) * math.exp(-t * 9)
  end)
end
DEFS.heal = function()
  return synth(0.45, function(t)
    local ph = 2 * math.pi * (400 * t + 0.5 * (400 / 0.45) * t * t)
    return math.sin(ph) * 0.6 * (1 - t / 0.45)
  end)
end
DEFS.botdown = function()
  return synth(0.4, function(t)
    local ph = 2 * math.pi * (500 * t + 0.5 * ((120 - 500) / 0.4) * t * t)
    return math.sin(ph) * 0.7 * (1 - t / 0.4)
  end)
end
DEFS.wall = function()
  return synth(0.16, function(t)
    return (tone(80, t) * 0.9 + rnd() * 0.2) * math.exp(-t * 22)
  end)
end
DEFS.zonewarn = function()
  return synth(0.7, function(t)
    if (t % 0.35) < 0.15 then return tone(880, t) * 0.6 end
    return 0
  end)
end
DEFS.heartbeat = function()
  return synth(0.5, function(t)
    local v = tone(55, t) * math.exp(-t * 30)
    if t > 0.18 then v = v + tone(50, t) * math.exp(-(t - 0.18) * 30) end
    return v * 0.9
  end)
end
DEFS.whiz = function()
  local lp = 0
  return synth(0.28, function(t, x)
    lp = lp + 0.5 * (rnd() - lp)
    local ph = 2 * math.pi * (2200 * t - 0.5 * (1500 / 0.28) * t * t)
    return (math.sin(ph) * 0.5 + lp * 0.5) * math.sin(math.pi * x)
  end)
end
DEFS.hitmark = function()
  return synth(0.07, function(t) return tone(2200, t) * math.exp(-t * 55) * 0.8 end)
end
DEFS.turn = function()
  return synth(0.08, function(t) return tone(320, t) * math.exp(-t * 35) * 0.5 end)
end
DEFS.zoneping = function()
  return synth(0.5, function(t)
    return tone(440, t) * (0.6 + 0.4 * tone(12, t)) * math.exp(-t * 6) * 0.8
  end)
end
DEFS.rumble = function()
  local lp = 0
  return synth(0.9, function(t, x)
    lp = lp + 0.04 * (rnd() - lp)
    return lp * 6 * math.sin(math.pi * x)
  end)
end
local function arpeggio(notes, noteLen)
  local total = #notes * noteLen
  return synth(total, function(t)
    local idx = math.min(#notes, math.floor(t / noteLen) + 1)
    local tt = t - (idx - 1) * noteLen
    return tone(notes[idx], t) * math.exp(-tt * 6) * 0.7
  end)
end
DEFS.win = function() return arpeggio({ 523, 659, 784, 1047, 1047 }, 0.2) end
DEFS.lose = function() return arpeggio({ 392, 311, 262, 196 }, 0.28) end
local function muffle(src)
  local out = {}
  local win = 8
  for i = 1, #src do
    local s, c = 0, 0
    for j = math.max(1, i - win + 1), i do
      s = s + src[j]
      c = c + 1
    end
    out[i] = math.floor(s / c * 0.85)
  end
  return out
end
local function makeShortArray(n)
  local arr = nil
  local ok = pcall(function() arr = short[n] end)
  if ok and arr then return arr end
  ok = pcall(function()
    local Array = luajava.bindClass("java.lang.reflect.Array")
    local Short = luajava.bindClass("java.lang.Short")
    arr = Array.newInstance(Short.TYPE, n)
  end)
  if ok and arr then return arr end
  return nil
end
local function detectBase()
  local a = makeShortArray(2)
  if not a then return nil end
  local ok0 = pcall(function() a[0] = 1 end)
  local ok2 = pcall(function() a[2] = 1 end)
  if ok0 and not ok2 then return 0 end
  if not ok0 then return 1 end
  return 0
end
local function getSamples(name)
  local src = Snd.lua[name]
  if src then return src end
  local base, muff = name, false
  if name:sub(-2) == "_m" then
    base = name:sub(1, -3)
    muff = true
  end
  local def = DEFS[base]
  if not def then return nil end
  local b = Snd.lua[base]
  if not b then
    b = def()
    Snd.lua[base] = b
  end
  src = muff and muffle(b) or b
  Snd.lua[name] = src
  return src
end
local function getArray(name)
  local arr = Snd.cache[name]
  if arr then return arr, Snd.len[name] end
  local src = getSamples(name)
  if not src then return nil end
  if Snd.base == nil then Snd.base = detectBase() end
  if Snd.base == nil then return nil end
  local n = #src
  arr = makeShortArray(n)
  if not arr then return nil end
  local b = Snd.base - 1
  for i = 1, n do arr[i + b] = src[i] end
  Snd.cache[name] = arr
  Snd.len[name] = n
  return arr, n
end
local function fallbackBeep(name)
  pcall(function()
    local tg = ToneGenerator(3, 80)
    local kind = 24
    if name:find("hurt") then kind = 26 end
    tg.startTone(kind, 90)
    mainHandler.postDelayed(Runnable({ run = function() pcall(function() tg.release() end) end }), 400)
  end)
end
local TESTSND = {}
local function playSound(name, left, right)
  if TEST then
    TESTSND[#TESTSND + 1] = { name = name, l = left, r = right }
    return
  end
  if Snd.active >= 14 then return end
  if Snd.failed then
    fallbackBeep(name)
    return
  end
  local ok, err = pcall(function()
    local arr, n = getArray(name)
    if not arr then error("no sound array") end
    local track = AudioTrack(3, SR, 4, 2, n * 2, 0)
    track.write(arr, 0, n)
    track.setStereoVolume(left, right)
    track.play()
    Snd.active = Snd.active + 1
    local ms = math.floor(n * 1000 / SR) + 250
    mainHandler.postDelayed(Runnable({
      run = function()
        pcall(function() track.stop() end)
        pcall(function() track.release() end)
        Snd.active = Snd.active - 1
      end
    }), ms)
  end)
  if not ok then
    Snd.failed = true
    if not Snd.warned then
      Snd.warned = true
      say(T("اس فون پر خاص آوازیں نہیں چل رہیں۔ سادہ بیپ استعمال ہوں گی۔"))
    end
    fallbackBeep(name)
  end
end
local function panGains(relDeg, vol)
  vol = vol * settings.vol
  local pan = math.sin(math.rad(relDeg))
  local l = vol * math.sqrt((1 - pan) / 2) * 1.414
  local r = vol * math.sqrt((1 + pan) / 2) * 1.414
  return clamp(l, 0, 1), clamp(r, 0, 1)
end
local function distVol(d, maxd, gain)
  if d >= maxd then return 0 end
  local f = 1 - d / maxd
  return gain * (f ^ 1.4)
end
local WEAPONS = {
  { name = "مکے",         range = 3,   dmg = 14, mag = 0,  acc = 0.9,  shots = 1, snd = "punch", desc = "" },
  { name = "پستول",        range = 30,  dmg = 20, mag = 12, acc = 0.75, shots = 1, snd = "shot_pistol", desc = "ہلکا ہتھیار ہے، درمیانے فاصلے تک ٹھیک مار کرتا ہے" },
  { name = "ایس ایم جی",           range = 35,  dmg = 12, mag = 30, acc = 0.55, shots = 3, snd = "shot_smg", desc = "ایک فائر میں تین گولیاں چلتی ہیں، قریب اور درمیانے فاصلے پر بہت اچھی ہے" },
  { name = "شاٹ گن",       range = 14,  dmg = 60, mag = 6,  acc = 0.8,  shots = 1, snd = "shot_shotgun", desc = "بہت قریب کے دشمن پر ایک ہی فائر میں بھاری نقصان کرتی ہے" },
  { name = "اسالٹ رائفل", range = 70,  dmg = 25, mag = 30, acc = 0.65, shots = 2, snd = "shot_rifle", desc = "دور تک مار کرتی ہے، ایک فائر میں دو گولیاں چلتی ہیں" },
  { name = "سنائپر رائفل",  range = 130, dmg = 85, mag = 5,  acc = 0.7,  shots = 1, snd = "shot_sniper", desc = "سب سے دور تک مار کرتی ہے، ایک ہی گولی میں بھاری نقصان" },
  { name = "میزائل لانچر", range = 90, dmg = 90, mag = 2, acc = 0.9, shots = 1, snd = "shot_rocket", splash = true, desc = "میزائل چلاتا ہے جو پھٹ کر آس پاس کے سب دشمنوں کو نقصان پہنچاتا ہے، اپنے قریب نہ چلائیں" },
}
local GUN_WEIGHTS = { { 2, 30 }, { 3, 20 }, { 4, 20 }, { 5, 20 }, { 6, 10 }, { 7, 8 } }
local ITEM_WEIGHTS = { { "ammo", 42 }, { "medkit", 12 }, { "bandage", 16 }, { "armor", 12 }, { "grenade", 14 }, { "defense", 8 }, { "breaker", 7 } }
local function weightedPick(list)
  local total = 0
  for _, e in ipairs(list) do total = total + e[2] end
  local r = math.random() * total
  for _, e in ipairs(list) do
    r = r - e[2]
    if r <= 0 then return e[1] end
  end
  return list[#list][1]
end
local function itemName(it)
  if it.type == "gun" then return WEAPONS[it.w].name end
  if it.type == "ammo" then return T("گولیوں کا ڈبہ") end
  if it.type == "medkit" then return T("میڈیکل کٹ") end
  if it.type == "bandage" then return T("پٹی") end
  if it.type == "armor" then return T("آرمر جیکٹ") end
  if it.type == "grenade" then return T("گرینیڈ") end
  if it.type == "defense" then return T("ڈیفنس سسٹم") end
  if it.type == "breaker" then return T("ڈیفنس بریکر") end
  return T("سامان")
end
local DIFF = { 0.6, 1.0, 1.4 }
local G = nil
local RUN = 0
local PH = { 80, 56, 38, 24, 13, 6, 2 }
local HOLD, SHRINK = 11, 10
local function gunOf(e) return e.weps[e.cur] end
local function findWeapon(e, wi)
  for i, g in ipairs(e.weps) do
    if g.w == wi then return g, i end
  end
  return nil
end
local function newEntity(x, y)
  return { x = x, y = y, face = math.random() * 360, hp = 100, armor = 0, weps = { { w = 1, ammo = 0, reserve = 0 } },
    cur = 1, medkit = 0, bandage = 0, alive = true, kills = 0 }
end
local function addItem(kind, x, y, w)
  G.items[#G.items + 1] = { type = kind, x = clamp(x, 1, ARENA - 1), y = clamp(y, 1, ARENA - 1), w = w }
end
local function randomItem(x, y)
  local kind = weightedPick(ITEM_WEIGHTS)
  addItem(kind, x, y, nil)
end
local function inZone(x, y, margin)
  if not G.zoneOn then return true end
  local z = G.zone
  return dist(z.cx, z.cy, x, y) <= z.r + (margin or 0)
end
local function zoneDmg()
  return 3 + 2 * G.zone.phase
end
local function countBots()
  local c = 0
  for _, b in ipairs(G.bots) do
    if b.alive then c = c + 1 end
  end
  return c
end
local function queueSelf(name, vol, key)
  if not G then return end
  local l, r = panGains(0, vol)
  G.sfx[#G.sfx + 1] = { name = name, l = l, r = r, key = key or -1 }
end
local function queueSpatial(name, x, y, maxd, gain, prio)
  if not G then return end
  local p = G.p
  local d = dist(p.x, p.y, x, y)
  if d >= maxd then return end
  local v = distVol(d, maxd, gain)
  if v < 0.03 then return end
  local rel = relAngle(p, x, y)
  local nm = name
  if math.abs(rel) > 100 then nm = name .. "_m" end
  local l, r = panGains(rel, v)
  G.sfx[#G.sfx + 1] = { name = nm, l = l, r = r, key = d + (prio or 0) }
end
local function flushSfx()
  if not G then return end
  local q = G.sfx
  G.sfx = {}
  table.sort(q, function(a, b) return a.key < b.key end)
  local count = 0
  for i, s in ipairs(q) do
    if i > 9 then break end
    count = count + 1
    local delay = (count - 1) * 140
    if delay == 0 then
      playSound(s.name, s.l, s.r)
    else
      later(delay, function() playSound(s.name, s.l, s.r) end)
    end
  end
end
local function applyDamage(e, dmg)
  local absorb = 0
  if e.armor > 0 then
    absorb = math.min(e.armor, dmg * 0.5)
    e.armor = e.armor - absorb
  end
  local real = dmg - absorb
  e.hp = e.hp - real
  return real
end
local function shotResult(w, d, mul, shots)
  local acc = w.acc * (1 - 0.55 * math.min(1, d / w.range)) * mul
  acc = clamp(acc, 0.05, 0.95)
  local hits = 0
  for _ = 1, shots do
    if math.random() < acc then hits = hits + 1 end
  end
  return hits
end
local function giveItem(e, it, isPlayer)
  if it.type == "gun" then
    local w = WEAPONS[it.w]
    if w.splash and not isPlayer then return false end
    local have = findWeapon(e, it.w)
    if have then
      have.reserve = have.reserve + w.mag
      if isPlayer then
        return T("آپ کے پاس پہلے سے ") .. w.name .. T(" ہے، اس لیے ") .. w.mag .. T(" گولیاں اضافی مل گئیں۔ اب اضافی گولیاں ") .. have.reserve .. T(" ہیں")
      end
      return nil
    end
    e.weps[#e.weps + 1] = { w = it.w, ammo = w.mag, reserve = w.mag }
    if isPlayer then
      e.cur = #e.weps
      return T("آپ نے ") .. w.name .. T(" اٹھا لی اور ہاتھ میں لے لی۔ اس میں ") .. w.mag .. T(" گولیاں بھری ہیں اور ") .. w.mag ..
          T(" اضافی ہیں۔ اس کی مار ") .. w.range .. T(" میٹر تک ہے۔ ") .. w.desc .. T("۔ پرانا ہتھیار لینے کے لیے Switch Weapon بٹن دبائیں")
    end
    return nil
  elseif it.type == "ammo" then
    local any = false
    for _, g in ipairs(e.weps) do
      if g.w > 1 then
        g.reserve = g.reserve + WEAPONS[g.w].mag
        any = true
      end
    end
    if not any then return false end
    if isPlayer then
      local g = gunOf(e)
      local extra = ""
      if g.w > 1 then extra = T(" آپ کے موجودہ ہتھیار کی اضافی گولیاں اب ") .. g.reserve .. T(" ہیں") end
      return T("آپ نے گولیوں کا ڈبہ اٹھا لیا۔ اس سے آپ کے تمام ہتھیاروں کو ایک ایک میگزین کی اضافی گولیاں مل گئیں۔") .. extra
    end
    return nil
  elseif it.type == "medkit" then
    if isPlayer then
      e.medkit = e.medkit + 1
      return T("آپ نے میڈیکل کٹ اٹھا لی۔ یہ 50 صحت واپس دیتی ہے۔ استعمال کے لیے Heal بٹن دبائیں۔ اب آپ کے پاس ") .. e.medkit .. T(" میڈیکل کٹ ہیں")
    end
    e.hp = math.min(100, e.hp + 50)
    return nil
  elseif it.type == "bandage" then
    if isPlayer then
      e.bandage = e.bandage + 1
      return T("آپ نے پٹی اٹھا لی۔ یہ 20 صحت بڑھاتی ہے۔ استعمال کے لیے Heal بٹن دبائیں۔ اب آپ کے پاس ") .. e.bandage .. T(" پٹیاں ہیں")
    end
    e.hp = math.min(100, e.hp + 20)
    return nil
  elseif it.type == "armor" then
    e.armor = math.min(100, e.armor + 50)
    if isPlayer then
      return T("آپ نے آرمر جیکٹ پہن لی۔ یہ دشمن کی گولی کا آدھا نقصان خود سہہ لیتی ہے۔ اب آپ کا آرمر ") .. n0(e.armor) .. T(" ہے")
    end
    return nil
  elseif it.type == "grenade" then
    if isPlayer then
      e.grenades = (e.grenades or 0) + 2
      return T("آپ نے 2 گرینیڈ اٹھا لیے۔ اب آپ کے پاس ") .. e.grenades .. T(" گرینیڈ ہیں۔ پھینکنے کے لیے Throw Grenade بٹن دبائیں")
    end
    return nil
  elseif it.type == "defense" then
    e.defense = (e.defense or 0) + 2
    if isPlayer then
      return T("آپ نے ڈیفنس سسٹم لگا لیا۔ یہ خودکار چلتا ہے اور آنے والے میزائل، گرینیڈ اور دھماکوں کو ہوا میں مار گراتا ہے۔ ڈیفنس چارج اب ") .. e.defense .. T(" ہیں")
    end
    return nil
  elseif it.type == "breaker" then
    if not isPlayer then return false end
    e.breakers = (e.breakers or 0) + 1
    return T("آپ نے ڈیفنس بریکر اٹھا لیا۔ یہ 45 میٹر کے اندر دشمنوں کے ڈیفنس سسٹم تباہ کر دیتا ہے۔ استعمال کے لیے Break Defense بٹن دبائیں۔ اب آپ کے پاس ") .. e.breakers .. T(" بریکر ہیں")
  end
  return false
end
local function checkPickups(e, isPlayer, msgs)
  for i = #G.items, 1, -1 do
    local it = G.items[i]
    if dist(e.x, e.y, it.x, it.y) <= 5 then
      local res = giveItem(e, it, isPlayer)
      if res ~= false then
        table.remove(G.items, i)
        if isPlayer then
          msgs[#msgs + 1] = res
          queueSelf("pickup", 0.8, -2)
        end
      elseif isPlayer then
        msgs[#msgs + 1] = T("یہاں گولیوں کا ڈبہ ہے مگر آپ کے پاس ابھی کوئی ہتھیار نہیں۔ پہلے ہتھیار ڈھونڈیں")
      end
    end
  end
end
local function botChooseGun(b)
  local best = 1
  for i, g in ipairs(b.weps) do
    if g.w > 1 and (g.ammo > 0 or g.reserve > 0) and g.w > b.weps[best].w then best = i end
  end
  b.cur = best
end
local function killBot(b, killer)
  b.alive = false
  b.hp = 0
  if b.elite then
    addItem("medkit", b.x + 1, b.y)
    addItem("armor", b.x - 1, b.y)
    addItem("ammo", b.x, b.y + 1)
  end
  if killer and killer == G.p then G.p.kills = G.p.kills + 1 end
  queueSpatial("botdown", b.x, b.y, 90, 0.9, 1)
end
local function updateZone(msgs)
  if not G.zoneOn then return end
  local z = G.zone
  z.timer = z.timer - 1
  if z.state == "hold" then
    if z.timer == 4 then
      msgs[#msgs + 1] = T("خبردار! محفوظ زون 4 باریوں میں سکڑنے والا ہے")
      queueSelf("zonewarn", 0.7, 5)
    end
    if z.timer <= 0 then
      if z.phase >= #PH then
        z.state = "final"
        z.timer = 9999
        return
      end
      z.state = "shrink"
      z.timer = SHRINK
      z.fromR = z.r
      z.toR = PH[z.phase + 1]
      z.fromCx, z.fromCy = z.cx, z.cy
      local maxOff = math.max(0, z.fromR - z.toR) * 0.6
      local a = math.random() * 2 * math.pi
      local o = math.random() * maxOff
      z.toCx = clamp(z.cx + o * math.sin(a), z.toR, ARENA - z.toR)
      z.toCy = clamp(z.cy + o * math.cos(a), z.toR, ARENA - z.toR)
      msgs[#msgs + 1] = T("محفوظ زون سکڑ رہا ہے۔ نیا دائرہ ") .. n0(z.toR) .. T(" میٹر کا ہوگا")
      queueSelf("rumble", 0.8, 5)
    end
  elseif z.state == "shrink" then
    local f = 1 - math.max(0, z.timer) / SHRINK
    z.r = z.fromR + (z.toR - z.fromR) * f
    z.cx = z.fromCx + (z.toCx - z.fromCx) * f
    z.cy = z.fromCy + (z.toCy - z.fromCy) * f
    if z.timer <= 0 then
      z.r, z.cx, z.cy = z.toR, z.toCx, z.toCy
      z.phase = z.phase + 1
      if z.phase >= #PH then
        z.state = "final"
        z.timer = 9999
      else
        z.state = "hold"
        z.timer = HOLD
      end
    end
  end
end
local function botMove(b, tx, ty)
  local d = dist(b.x, b.y, tx, ty)
  if d < 0.5 then return end
  local step = math.min(STEP, d)
  local jitter = (math.random() - 0.5) * 0.5
  local ang = atan2(tx - b.x, ty - b.y) + jitter
  b.x = clamp(b.x + step * math.sin(ang), 0, ARENA)
  b.y = clamp(b.y + step * math.cos(ang), 0, ARENA)
  queueSpatial("step", b.x, b.y, 45, 0.8, 2)
end
local function botWander(b)
  if not b.heading or math.random() < 0.2 then b.heading = math.random() * 2 * math.pi end
  local nx = b.x + STEP * math.sin(b.heading)
  local ny = b.y + STEP * math.cos(b.heading)
  if nx < 1 or nx > ARENA - 1 or ny < 1 or ny > ARENA - 1 then
    b.heading = math.random() * 2 * math.pi
    return
  end
  b.x, b.y = nx, ny
  queueSpatial("step", b.x, b.y, 45, 0.8, 2)
end
local function botStrafe(b, mult)
  local p = G.p
  local base = bearingTo(b.x, b.y, p.x, p.y)
  local side = (math.random() < 0.5) and 90 or -90
  local len = STEP * (mult or 1)
  local function try(sd)
    local a = math.rad(base + sd)
    return b.x + len * math.sin(a), b.y + len * math.cos(a)
  end
  local nx, ny = try(side)
  if nx < 1 or nx > ARENA - 1 or ny < 1 or ny > ARENA - 1 then nx, ny = try(-side) end
  b.x, b.y = clamp(nx, 1, ARENA - 1), clamp(ny, 1, ARENA - 1)
  queueSpatial("step", b.x, b.y, 45, 0.8, 2)
end
local function botDodgeChance(b, d)
  local c = 0.12 * DIFF[settings.diff]
  if b.aggro then c = c + 0.10 end
  if b.hp < 40 then c = c + 0.05 end
  if b.elite then c = c + 0.08 end
  if d < 8 then c = c * 0.5 end
  if G.practice then c = c * 0.6 end
  return clamp(c, 0, 0.4)
end
local function nearestTarget(b)
  local best, bd = nil, 1e9
  local p = G.p
  if p.alive then
    local d = dist(b.x, b.y, p.x, p.y)
    if d < bd then best, bd = p, d end
  end
  for _, o in ipairs(G.bots) do
    if o ~= b and o.alive then
      local d = dist(b.x, b.y, o.x, o.y)
      if d < bd then best, bd = o, d end
    end
  end
  return best, bd
end
local function nearestItem(b, maxd)
  local best, bd = nil, maxd
  for _, it in ipairs(G.items) do
    local d = dist(b.x, b.y, it.x, it.y)
    if d < bd then best, bd = it, d end
  end
  return best
end
local function botShoot(b, tgt, td, msgs, aim)
  local g = gunOf(b)
  local w = WEAPONS[g.w]
  local used = 1
  if g.w > 1 then
    used = math.min(w.shots, g.ammo)
    g.ammo = g.ammo - used
  end
  queueSpatial(w.snd, b.x, b.y, 130, 1.0, 0)
  local p = G.p
  if tgt ~= p and not G.fireSaid and math.random() < 0.4 then
    local fd = dist(p.x, p.y, b.x, b.y)
    if fd < 100 then
      G.fireSaid = true
      msgs[#msgs + 1] = T("کسی دوسرے دشمن کی فائرنگ کی آواز! ") .. dirText(relAngle(p, b.x, b.y)) .. T("، ") .. n0(fd) .. T(" میٹر دور")
    end
  end
  local mul = (tgt == p) and (DIFF[settings.diff] * 0.4) or 0.6
  if G.practice and tgt == p then mul = mul * 0.7 end
  local dodged, partly = false, false
  if tgt == p and aim then
    local moved = dist(p.x, p.y, aim.x, aim.y)
    if moved >= 8 then
      dodged = true
    elseif moved >= 4 then
      mul = mul * 0.5
      partly = true
    end
  end
  local hits = dodged and 0 or shotResult(w, td, mul, used)
  if tgt == p then b.aggro = true end
  if hits > 0 then
    local dmg = hits * w.dmg
    if tgt == p then
      local lost = applyDamage(p, dmg)
      queueSelf("hurt", 0.9, -3)
      local rel = relAngle(p, b.x, b.y)
      local pre = ""
      if aim then pre = partly and T("آپ کافی نہیں ہٹ سکے۔ ") or T("آپ اپنی جگہ سے ہٹے نہیں۔ ") end
      msgs[#msgs + 1] = pre .. T("دشمن نے ") .. dirText(rel) .. T(" سے آپ کو گولی ماری، ") .. n0(td) .. T(" میٹر دور۔ صحت ") .. n0(lost) .. T(" کم ہوئی، اب صحت ") .. n0(math.max(0, p.hp))
    else
      applyDamage(tgt, dmg)
      if tgt.hp <= 0 then killBot(tgt, b) end
    end
  elseif tgt == p then
    local rel = relAngle(p, b.x, b.y)
    local wl, wr = panGains(rel, 0.9)
    G.sfx[#G.sfx + 1] = { name = "whiz", l = wl, r = wr, key = -3 }
    if dodged then
      msgs[#msgs + 1] = T("دشمن نے ") .. dirText(rel) .. T(" سے فائر کیا مگر آپ وقت پر ہٹ گئے! گولی خالی گئی۔ شاباش")
    else
      msgs[#msgs + 1] = dirText(rel) .. T(" سے فائر ہوا، ") .. n0(td) .. T(" میٹر دور۔ گولی پاس سے گزر گئی")
    end
  end
end
local scheduleAimShot
local function botTurn(b, msgs)
  local p = G.p
  if G.zoneOn and not inZone(b.x, b.y, 2) then
    applyDamage(b, zoneDmg())
    if b.hp <= 0 then
      killBot(b, nil)
      return
    end
    botMove(b, G.zone.cx, G.zone.cy)
    return
  end
  if b.prone and b.prone > 0 then
    b.prone = b.prone - 1
    return
  end
  botChooseGun(b)
  local g = gunOf(b)
  local w = WEAPONS[g.w]
  if b.hp < 40 and (b.medkit > 0 or b.bandage > 0) then
    b.hp = math.min(100, b.hp + 30)
    b.medkit, b.bandage = 0, 0
    return
  end
  if b.engaged then
    b.engaged = false
    b.aggro = true
    local r = math.random()
    if b.hp < 35 and r < 0.5 then
      botMove(b, clamp(b.x * 2 - p.x, 2, ARENA - 2), clamp(b.y * 2 - p.y, 2, ARENA - 2))
      msgs[#msgs + 1] = T("زخمی دشمن پیچھے ہٹ رہا ہے۔ اب وہ ") .. dirText(relAngle(p, b.x, b.y)) .. T("، ") ..
          n0(dist(p.x, p.y, b.x, b.y)) .. T(" میٹر دور ہے")
      return
    elseif r < 0.35 * DIFF[settings.diff] + 0.1 then
      botStrafe(b, 1)
      msgs[#msgs + 1] = T("دشمن نے بچنے کے لیے پہلو بدلا۔ اب وہ ") .. dirText(relAngle(p, b.x, b.y)) .. T("، ") ..
          n0(dist(p.x, p.y, b.x, b.y)) .. T(" میٹر دور ہے")
      return
    end
  end
  if g.w > 1 and g.ammo <= 0 and g.reserve > 0 then
    local take = math.min(w.mag, g.reserve)
    g.ammo = take
    g.reserve = g.reserve - take
    queueSpatial("reload", b.x, b.y, 40, 0.7, 3)
    return
  end
  local target, td = nearestTarget(b)
  local canFight = (g.w > 1 and g.ammo > 0) or (g.w == 1)
  if b.aim then return end
  if target and canFight and td <= w.range then
    local prob = 0.45
    if target == p then
      prob = (b.aggro or td < 25) and 0.7 or 0.3
    end
    if g.w == 1 and td > 3 then prob = 0 end
    if math.random() < prob then
      if target == p and g.w > 1 then
        if settings.attack == "random" then return end
        local n = 0
        for _, o in ipairs(G.bots) do
          if o.alive and o.aim then n = n + 1 end
        end
        if n < 2 then
          local delay = (td < 15) and 4 or 5
          local aim = { x = p.x, y = p.y, rt = true }
          b.aim = aim
          b.aggro = true
          local rel = relAngle(p, b.x, b.y)
          queueSpatial("lock", b.x, b.y, 140, 1.0, -1)
          msgs[#msgs + 1] = escapeText(rel) .. T(" دشمن آپ پر نشانہ لے رہا ہے، ") .. dirText(rel) .. T(" سے، ") ..
              n0(td) .. T(" میٹر دور۔ ") .. delay .. T(" سیکنڈ میں فائر کرے گا")
          scheduleAimShot(G, b, aim, delay)
        end
        return
      end
      botShoot(b, target, td, msgs)
      return
    end
  end
  if target and td <= 45 and g.w > 1 and math.random() < 0.6 then
    if td > w.range * 0.7 then
      botMove(b, target.x, target.y)
    else
      botWander(b)
    end
  else
    local it = nil
    if g.w == 1 or b.hp < 50 or math.random() < 0.3 then it = nearestItem(b, 55) end
    local dropGo = G.drop and G.drop.active and dist(b.x, b.y, G.drop.x, G.drop.y) < 70 and math.random() < 0.55
    if dropGo then
      botMove(b, G.drop.x, G.drop.y)
    elseif it then
      botMove(b, it.x, it.y)
    elseif G.zoneOn and math.random() < 0.15 then
      botMove(b, G.zone.cx, G.zone.cy)
    else
      botWander(b)
    end
  end
  checkPickups(b, false, {})
  if not b.warned and p.alive then
    local d = dist(b.x, b.y, p.x, p.y)
    if d <= 14 then
      b.warned = true
      msgs[#msgs + 1] = T("دشمن قریب ہے! ") .. dirText(relAngle(p, b.x, b.y)) .. T("، ") .. n0(d) .. T(" میٹر دور")
    end
  end
end
local function checkEnd(msgs)
  local p = G.p
  if p.hp <= 0 and p.alive then
    p.alive = false
    G.over = true
    G.result = "lose"
    G.place = countBots() + 1
    msgs[#msgs + 1] = T("آپ مارے گئے۔ آپ ") .. G.place .. T(" نمبر پر رہے، ") .. p.kills .. T(" دشمن مارے")
    return
  end
  if p.alive and countBots() == 0 then
    G.over = true
    G.result = "win"
    G.place = 1
    msgs[#msgs + 1] = T("مبارک ہو! آپ جیت گئے! آپ آخر میں زندہ بچنے والے ہیں، ") .. p.kills .. T(" دشمن مارے")
  end
end
local function placeNear(px, py, dmin, dmax)
  local a = math.random() * 2 * math.pi
  local d = dmin + math.random() * (dmax - dmin)
  return px + d * math.sin(a), py + d * math.cos(a)
end
local STREAK = { [2] = "ڈبل کل!", [3] = "ٹرپل کل!", [4] = "الٹرا کل!", [5] = "بے قابو!" }
local function killBonus(b)
  local p = G.p
  if G.turn - (p.lastKill or -99) <= 6 then p.streak = (p.streak or 1) + 1 else p.streak = 1 end
  p.lastKill = G.turn
  local t = ""
  if p.streak >= 2 then t = (STREAK[math.min(p.streak, 5)]) .. " " end
  if b.elite then
    p.hp = math.min(100, p.hp + 50)
    p.armor = math.min(100, p.armor + 50)
    t = t .. T("ماہر دشمن گرا دیا! بڑا انعام: 50 صحت اور 50 آرمر ملا۔ اس کے گرے ہوئے سامان کو بھی اٹھا لیں")
  else
    p.hp = math.min(100, p.hp + 10)
    t = t .. T("انعام میں 10 صحت ملی")
  end
  queueSelf("chime", 0.9, -4)
  return t
end
local function explodeAt(lx, ly, power, radius, killer)
  local p = G.p
  local r = { hurt = 0, killed = 0, blocked = 0, text = "", selfLost = nil, selfBlocked = false }
  queueSpatial("explosion", lx, ly, 150, 1.0, 0)
  for _, b in ipairs(G.bots) do
    if b.alive then
      local d = dist(lx, ly, b.x, b.y)
      if d <= radius and (b.defense or 0) > 0 and math.random() < 0.8 then
        b.defense = b.defense - 1
        b.aggro = true
        r.blocked = r.blocked + 1
        queueSpatial("intercept", b.x, b.y, 120, 1.0, 0)
      elseif d <= radius then
        applyDamage(b, power * (1 - d / (radius * 1.3)))
        b.aggro = true
        if b.hp <= 0 then
          killBot(b, killer)
          r.killed = r.killed + 1
          if killer == p then r.text = killBonus(b) end
        else
          r.hurt = r.hurt + 1
        end
      elseif d < 50 and math.random() < 0.7 then
        b.aggro = true
      end
    end
  end
  local sd = dist(p.x, p.y, lx, ly)
  if sd <= radius and p.hp > 0 then
    if (p.defense or 0) > 0 and math.random() < 0.85 then
      p.defense = p.defense - 1
      r.selfBlocked = true
      queueSelf("intercept", 1.0, -3)
    else
      r.selfLost = applyDamage(p, power * (1 - sd / (radius * 1.3)))
      queueSelf("hurt", 0.8, -3)
    end
  end
  return r
end
local function blastText(r, skipEmpty)
  local t = ""
  if r.killed > 0 then
    t = r.killed .. T(" دشمن ڈھیر ہو گئے!")
    if r.text ~= "" then t = t .. " " .. r.text end
  end
  if r.hurt > 0 then
    if t ~= "" then t = t .. T("۔ ") end
    t = t .. r.hurt .. T(" دشمن زخمی ہوئے")
  end
  if r.blocked > 0 then
    if t ~= "" then t = t .. T("۔ ") end
    t = t .. r.blocked .. T(" دشمن کے ڈیفنس سسٹم نے حملہ روک لیا")
  end
  if t == "" and not skipEmpty then t = T("کوئی دشمن زد میں نہیں آیا") end
  if r.selfBlocked then
    if t ~= "" then t = t .. T("۔ ") end
    t = t .. T("آپ کے ڈیفنس سسٹم نے حملہ مار گرایا اور آپ کو بچا لیا! باقی ڈیفنس چارج ") .. (G.p.defense or 0)
  end
  if r.selfLost then
    t = t .. T("۔ آپ خود دھماکے کی زد میں آ گئے! صحت ") .. n0(r.selfLost) .. T(" کم ہوئی، اب صحت ") .. n0(math.max(0, G.p.hp))
  end
  return t
end
local function playPlane(x, y)
  if TEST then return end
  local dir = (math.random() < 0.5) and 1 or -1
  for i = 0, 5 do
    later(i * 450, function()
      if not G or G.over then return end
      local deg = dir * (-80 + i * 32)
      local vol = 0.45 + 0.55 * math.sin(math.pi * i / 5)
      local l, r = panGains(deg, vol)
      playSound("plane", l, r)
    end)
  end
  later(2900, function()
    if not G or G.over then return end
    queueSpatial("crate", x, y, 140, 1.0, 0)
    flushSfx()
  end)
end
local function visionScale()
  if G and G.storm and G.storm.active then return 0.45 end
  return 1
end
local function updateEvents(msgs)
  local p = G.p
  local st = G.storm
  if st and st.active then
    queueSelf("rain", 0.35, 5)
    if math.random() < 0.2 then queueSelf("rumble", 0.7, 6) end
    if G.turn >= st.untilTurn then
      st.active = false
      msgs[#msgs + 1] = T("طوفان تھم گیا، نظر صاف ہو گئی ہے")
    end
  elseif (not G.practice) and (G.stormCount or 0) < 3 and G.turn >= (G.nextStorm or 9999) then
    G.stormCount = (G.stormCount or 0) + 1
    G.storm = { active = true, untilTurn = G.turn + 8 + math.floor(math.random() * 5) }
    G.nextStorm = G.turn + 30 + math.floor(math.random() * 10)
    queueSelf("rumble", 0.9, -4)
    msgs[#msgs + 1] = T("طوفان آ گیا! بارش اور دھند سے نظر بہت کم ہو گئی ہے، اب صرف قریب کے دشمن اور سامان اعلان میں آئیں گے۔ آوازوں پر دھیان دیں")
  end
  if G.turn == 3 and G.elite and G.elite.alive then
    msgs[#msgs + 1] = T("خبردار! میدان میں ایک ماہر دشمن ہے جس کے پاس بھاری آرمر اور طاقتور ہتھیار ہے۔ اسے مارنے پر بڑا انعام ملتا ہے")
  end
  local sk = G.strike
  if sk then
    local left = sk.turn - G.turn
    if left > 0 then
      queueSpatial("siren", sk.x, sk.y, 150, 1.0, -1)
      msgs[#msgs + 1] = escapeText(relAngle(p, sk.x, sk.y)) .. T(" سائرن! میزائل ") .. left .. T(" باری میں گرے گا۔ نشانہ ") ..
          dirText(relAngle(p, sk.x, sk.y)) .. T("، ") .. n0(dist(p.x, p.y, sk.x, sk.y)) .. T(" میٹر دور۔ خطرناک دائرہ 12 میٹر ہے")
    else
      queueSpatial("incoming", sk.x, sk.y, 150, 1.0, -3)
      local r = explodeAt(sk.x, sk.y, 100, 12, nil)
      msgs[#msgs + 1] = T("میزائل پھٹ گیا! ") .. ((r.selfLost or r.selfBlocked) and "" or T("آپ بچ گئے! ")) .. blastText(r, true)
      G.strike = nil
    end
  elseif (not G.practice) and (G.strikeCount or 0) < 3 and G.turn >= (G.nextStrike or 9999) then
    local x, y = placeNear(p.x, p.y, 12, 26)
    x, y = clamp(x, 4, ARENA - 4), clamp(y, 4, ARENA - 4)
    G.strikeCount = (G.strikeCount or 0) + 1
    G.strike = { x = x, y = y, turn = G.turn + 3 }
    G.nextStrike = G.turn + 28 + math.floor(math.random() * 10)
    queueSpatial("siren", x, y, 150, 1.0, -1)
    msgs[#msgs + 1] = escapeText(relAngle(p, x, y)) .. T(" خطرے کا سائرن! دشمن کا میزائل حملہ! نشانہ ") ..
        dirText(relAngle(p, x, y)) .. T("، ") .. n0(dist(p.x, p.y, x, y)) .. T(" میٹر دور ہے۔ یہ 3 باریوں میں گرے گا، آس پاس 12 میٹر خطرناک ہیں")
  end
  local th = G.threat
  if th then
    local left = th.turn - G.turn
    local dd = dist(p.x, p.y, th.x, th.y)
    if left > 0 then
      queueSelf("siren", 0.6, -1)
      msgs[#msgs + 1] = T("دوڑیں! ") .. th.name .. T(" آنے میں ") .. left .. T(" باری باقی! دھماکے کی جگہ سے آپ ") .. n0(dd) ..
          T(" میٹر دور ہیں، ") .. (th.R + 2) .. T(" میٹر سے زیادہ دور ہو جائیں، دوڑیں!")
    else
      queueSpatial("incoming", th.x, th.y, 150, 1.0, -3)
      local r = explodeAt(th.x, th.y, th.power, th.R, nil)
      msgs[#msgs + 1] = th.name .. T(" پھٹ گیا! ") .. ((r.selfLost or r.selfBlocked) and "" or T("آپ بچ گئے! ")) .. blastText(r, true)
      G.threat = nil
    end
  elseif (not G.practice) and (not G.strike) and G.turn >= (G.nextThreat or 12) then
    local cand = {}
    for _, b in ipairs(G.bots) do
      if b.alive and b.aggro then
        local bd = dist(p.x, p.y, b.x, b.y)
        if bd >= 18 and bd <= 65 then cand[#cand + 1] = { b = b, d = bd } end
      end
    end
    if #cand > 0 and math.random() < math.min(0.9, 0.45 * DIFF[settings.diff]) then
      local c = cand[math.random(#cand)]
      local rel = relAngle(p, c.b.x, c.b.y)
      local missile = c.b.elite or c.d > 40 or math.random() < 0.5
      local t = { x = p.x, y = p.y, src = c.b }
      if missile then
        t.name, t.R, t.power, t.turn = T("دشمن کا میزائل"), 9, 80, G.turn + 3
        queueSpatial("shot_rocket", c.b.x, c.b.y, 150, 1.0, -1)
      else
        t.name, t.R, t.power, t.turn = T("دشمن کا گرینیڈ"), 6, 60, G.turn + 2
        queueSpatial("throw", c.b.x, c.b.y, 60, 1.0, -1)
      end
      G.threat = t
      G.nextThreat = G.turn + 9 + math.floor(math.random() * 6)
      msgs[#msgs + 1] = escapeText(rel) .. " " .. t.name .. T(" آپ کی طرف داغا گیا، یہ ") .. dirText(rel) .. T(" سے آ رہا ہے، ") ..
          n0(c.d) .. T(" میٹر دور سے۔ آپ کے پاس ") .. (t.turn - G.turn) .. T(" باریاں ہیں، ورنہ نقصان ہو گا")
    end
  end
  local d = G.drop
  if d and d.active then
    local left = 0
    for _, it in ipairs(G.items) do
      if it.drop == d.id then left = left + 1 end
    end
    if left == 0 then
      d.active = false
      msgs[#msgs + 1] = T("سپلائی ڈراپ خالی ہو گیا، سب سامان اٹھا لیا گیا")
      return
    end
    queueSpatial("beacon", d.x, d.y, 130, 0.9, 1)
    if (G.turn - d.turn) % 5 == 0 then
      msgs[#msgs + 1] = T("سپلائی ڈراپ ") .. dirText(relAngle(p, d.x, d.y)) .. T("، ") .. n0(dist(p.x, p.y, d.x, d.y)) .. T(" میٹر دور ہے")
    end
    return
  end
  if (G.dropCount or 0) < 4 and G.turn >= (G.nextDrop or 9999) then
    local x, y
    if G.zoneOn then
      x, y = placeNear(G.zone.cx, G.zone.cy, 0, G.zone.r * 0.8)
    else
      x, y = placeNear(p.x, p.y, 30, 55)
    end
    x, y = clamp(x, 6, ARENA - 6), clamp(y, 6, ARENA - 6)
    G.dropCount = (G.dropCount or 0) + 1
    local id = G.dropCount
    local list = { { "ammo" }, { "medkit" }, { "armor" }, { "defense" }, { "grenade" } }
    for _, e in ipairs(list) do
      local ix, iy = placeNear(x, y, 1, 3)
      addItem(e[1], ix, iy, e[2])
      G.items[#G.items].drop = id
    end
    G.drop = { id = id, x = x, y = y, turn = G.turn, active = true }
    G.nextDrop = G.turn + 16 + math.floor(math.random() * 8)
    queueSelf("chime", 0.9, -4)
    playPlane(x, y)
    msgs[#msgs + 1] = T("ہوائی جہاز کی آواز! سپلائی ڈراپ گرا ہے، اس میں اعلیٰ ہتھیار، گولیاں، آرمر، ڈیفنس سسٹم اور میڈیکل کٹ ہے۔ وہ ") ..
        dirText(relAngle(p, x, y)) .. T("، ") .. n0(dist(p.x, p.y, x, y)) .. T(" میٹر دور ہے۔ بیپ کی آواز کی طرف جائیں، دشمن بھی وہیں آئیں گے")
  end
end
local function worldTurn()
  local msgs = {}
  if not G or G.over then return msgs end
  G.turn = G.turn + 1
  G.fireSaid = false
  local p = G.p
  if p.winded and p.winded > 0 then p.winded = p.winded - 1 end
  updateZone(msgs)
  updateEvents(msgs)
  if G.zoneOn and not inZone(p.x, p.y) then
    local dmg = zoneDmg()
    applyDamage(p, dmg)
    queueSelf("hurt", 0.8, -3)
    msgs[#msgs + 1] = T("آپ محفوظ زون سے باہر ہیں! صحت ") .. n0(dmg) .. T(" کم ہوئی، اب صحت ") .. n0(math.max(0, p.hp))
  end
  for _, b in ipairs(G.bots) do
    if b.alive and p.hp > 0 then botTurn(b, msgs) end
  end
  checkEnd(msgs)
  if not G.over and p.hp > 0 and p.hp <= 30 then queueSelf("heartbeat", 0.7, -1) end
  return msgs
end
local function newGame(practice)
  RUN = RUN + 1
  G = { turn = 0, over = false, paused = false, run = RUN, sfx = {}, items = {}, bots = {}, practice = practice,
    zoneOn = not practice, last = "", kills = 0, dropCount = 0, nextDrop = practice and 6 or 10, stormCount = 0, nextStorm = 22, strikeCount = 0, nextStrike = 16, nextThreat = 12 }
  local p = newEntity(30 + math.random() * (ARENA - 60), 30 + math.random() * (ARENA - 60))
  p.face = math.floor(math.random() * 12) * 30
  G.p = p
  G.zone = { cx = ARENA / 2, cy = ARENA / 2, r = PH[1], phase = 1, state = "hold", timer = HOLD }
  p.weps[2] = { w = 2, ammo = WEAPONS[2].mag, reserve = WEAPONS[2].mag * 3 }
  p.cur = 2
  p.grenades = 2
  local x, y = placeNear(p.x, p.y, 10, 18)
  addItem(math.random() < 0.5 and "medkit" or "bandage", x, y)
  x, y = placeNear(p.x, p.y, 12, 22)
  addItem("armor", x, y)
  x, y = placeNear(p.x, p.y, 15, 25)
  addItem("ammo", x, y)
  x, y = placeNear(p.x, p.y, 12, 24)
  addItem("defense", x, y)
  x, y = placeNear(p.x, p.y, 15, 30)
  addItem("breaker", x, y)
  for _ = 1, 60 do
    randomItem(5 + math.random() * (ARENA - 10), 5 + math.random() * (ARENA - 10))
  end
  local nb = practice and 5 or settings.bots
  for _ = 1, nb do
    local bx, by
    repeat
      bx, by = 5 + math.random() * (ARENA - 10), 5 + math.random() * (ARENA - 10)
    until dist(bx, by, p.x, p.y) > 35
    local b = newEntity(bx, by)
    if math.random() < 0.3 then b.armor = 50 end
    if (not practice) and math.random() < 0.18 then b.defense = 1 end
    if math.random() < 0.35 then
      local wi = 2 + math.floor(math.random() * 4)
      b.weps[2] = { w = wi, ammo = WEAPONS[wi].mag, reserve = WEAPONS[wi].mag }
      b.cur = 2
    end
    G.bots[#G.bots + 1] = b
  end
  if not practice and #G.bots >= 3 then
    local e = G.bots[1]
    e.armor = 100
    e.defense = 2
    e.elite = true
    e.weps[2] = { w = 5, ammo = WEAPONS[5].mag, reserve = WEAPONS[5].mag * 2 }
    e.cur = 2
    G.elite = e
  end
  return G
end
local function weaponLine(e)
  local g = gunOf(e)
  local w = WEAPONS[g.w]
  if g.w == 1 then return T("ہتھیار: کوئی نہیں، صرف مکے") end
  return T("ہتھیار: ") .. w.name .. T("، ") .. g.ammo .. T(" گولیاں بھری ہیں، ") .. g.reserve .. T(" اضافی، مار ") .. w.range .. T(" میٹر تک")
end
local function statusText()
  local p = G.p
  local t = T("صحت ") .. n0(math.max(0, p.hp)) .. T("۔ آرمر ") .. n0(p.armor) .. T("۔ ") .. weaponLine(p) ..
      T("۔ میڈیکل کٹ ") .. p.medkit .. T("، پٹیاں ") .. p.bandage .. T("، گرینیڈ ") .. (p.grenades or 0) .. T("، ڈیفنس چارج ") .. (p.defense or 0) .. T("، ڈیفنس بریکر ") .. (p.breakers or 0) ..
      T("۔ باقی دشمن ") .. countBots() .. T("۔ آپ نے مارے ") .. p.kills .. T("۔ باری ") .. G.turn
  return t
end
local SECTOR_NAMES = { "سامنے", "دائیں طرف", "بائیں طرف", "پیچھے" }
local function sectorOf(rel)
  local a = math.abs(rel)
  if a <= 45 then return 1 end
  if a >= 135 then return 4 end
  if rel > 0 then return 2 end
  return 3
end
-- An enemy announced "ahead" is in your line of fire (the whole front sector, 45 degrees each side).
-- A distance counts as in range when its spoken (rounded) value is within the gun range,
-- so "30 meters" is never refused for a gun with 30 meters of range.
local AIM_HALF = 45
local function inRange(d, range)
  return d < range + 0.5
end

local function aimTarget(maxRange)
  local p = G.p
  local best, bd, brel = nil, 1e9, 0
  for _, b in ipairs(G.bots) do
    if b.alive then
      local d = dist(p.x, p.y, b.x, b.y)
      local rel = relAngle(p, b.x, b.y)
      if (not maxRange or inRange(d, maxRange)) and math.abs(rel) <= AIM_HALF and d < bd then
        best, bd, brel = b, d, rel
      end
    end
  end
  return best, bd, brel
end
local function scanText(maxEnemy, onlyFront)
  local p = G.p
  local w = WEAPONS[gunOf(p).w]
  local buckets = { {}, {}, {}, {} }
  for _, b in ipairs(G.bots) do
    if b.alive then
      local d = dist(p.x, p.y, b.x, b.y)
      if d <= maxEnemy then
        local k = sectorOf(relAngle(p, b.x, b.y))
        local list = buckets[k]
        list[#list + 1] = { d = d, b = b }
      end
    end
  end
  local out = {}
  for k = 1, 4 do
    if not onlyFront or k == 1 then
      local list = buckets[k]
      table.sort(list, function(a, b) return a.d < b.d end)
      local e = list[1]
      if e then
        local s = T("دشمن ") .. n0(e.d) .. T(" میٹر")
        if k == 1 then
          if (e.b.defense or 0) > 0 then s = s .. T("، اس کے پاس ڈیفنس سسٹم ہے") end
          if not inRange(e.d, w.range) then s = s .. T("، بہت دور") end
        end
        out[#out + 1] = SECTOR_NAMES[k] .. ": " .. s
      end
    end
  end
  return table.concat(out, T("۔ "))
end
local function autoScan(onlyFront)
  if settings.auto == "off" then return "" end
  local vs = visionScale()
  local t = scanText(50 * vs, onlyFront)
  if onlyFront then
    local p = G.p
    local nb, nd = nil, 1e9
    for _, b in ipairs(G.bots) do
      if b.alive then
        local d = dist(p.x, p.y, b.x, b.y)
        if d < nd then nb, nd = b, d end
      end
    end
    if nb and nd <= 50 * vs and sectorOf(relAngle(p, nb.x, nb.y)) ~= 1 then
      local extra = T("قریب ترین دشمن ") .. n0(nd) .. T(" میٹر، ") .. dirText(relAngle(p, nb.x, nb.y))
      if t ~= "" then t = t .. T("۔ ") .. extra else t = extra end
    end
  end
  return t
end
local function stepOnce(offset, running)
  local p = G.p
  local ang = math.rad(p.face + offset)
  local nx = p.x + STEP * math.sin(ang)
  local ny = p.y + STEP * math.cos(ang)
  if nx < 0 or nx > ARENA or ny < 0 or ny > ARENA then
    queueSelf("wall", 0.9, -2)
    return false, T("دیوار! جزیرے کا کنارہ آ گیا")
  end
  local was = inZone(p.x, p.y)
  p.x, p.y = nx, ny
  queueSelf(running and "runstep" or "selfstep", running and 0.85 or 0.6, -1)
  local msgs = {}
  checkPickups(p, true, msgs)
  local now = inZone(p.x, p.y)
  if was and not now then msgs[#msgs + 1] = T("آپ محفوظ زون سے نکل گئے!") end
  if (not was) and now then msgs[#msgs + 1] = T("آپ واپس محفوظ زون میں آ گئے") end
  return true, table.concat(msgs, T("۔ "))
end
local function actMove(back)
  local ok, text = stepOnce(back and 180 or 0, false)
  if not ok then return text, false end
  return text, true, function() return autoScan(false) end
end
local function actTurn(delta)
  local p = G.p
  p.face = (p.face + delta) % 360
  queueSelf("turn", 0.6, -1)
  local t = (math.abs(delta) >= 180) and T("پیچھے مڑ گئے") or ((delta < 0) and T("بائیں مڑ گئے") or T("دائیں مڑ گئے"))
  local sc = autoScan(true)
  if sc ~= "" then
    t = t .. T("۔ ") .. sc
  end
  return t, false
end
local function actSide(sign)
  local p = G.p
  p.face = (p.face + sign * 90) % 360
  queueSelf("turn", 0.6, -1)
  local ok, text = stepOnce(0, false)
  local t = (sign < 0) and T("بائیں مڑ گئے") or T("دائیں مڑ گئے")
  if text ~= "" then t = t .. T("۔ ") .. text end
  if not ok then return t, false end
  return t, true, function() return autoScan(false) end
end
local function missHint(w)
  local p = G.p
  local best, bd, brel = nil, 1e9, 0
  for _, b in ipairs(G.bots) do
    if b.alive then
      local d = dist(p.x, p.y, b.x, b.y)
      if d < bd then best, bd, brel = b, d, relAngle(p, b.x, b.y) end
    end
  end
  if not best then return "" end
  if sectorOf(brel) == 1 then
    return T("۔ ") .. T("دشمن ") .. T("سامنے") .. " " .. n0(bd) .. T(" میٹر، بہت دور") ..
        T("۔ ہتھیار کی مار ") .. w.range .. T(" میٹر")
  end
  return T("۔ ") .. T("قریب ترین دشمن ") .. dirText(brel) .. T("، ") .. n0(bd) .. T(" میٹر")
end

-- the enemy tries to save himself from a shot that would have hit: he rolls aside, drops
-- flat or dives behind cover. An enemy who did not know you were there (aware = false)
-- almost never manages it.
local function enemyDodge(b, d, aware)
  local chance = botDodgeChance(b, d)
  if not aware then chance = chance * 0.2 end
  if math.random() >= chance then return nil end
  local p = G.p
  b.aggro = true
  b.engaged = false
  local r = math.random()
  local text
  if r < 0.4 then
    botStrafe(b, 2)
    text = T("گولی چلی مگر دشمن عین وقت پر جھکائی دے کر بچ گیا! اب وہ ")
  elseif r < 0.7 then
    b.prone = 2
    queueSpatial("dodge", b.x, b.y, 90, 1.0, -1)
    return T("دشمن زمین پر لیٹ گیا، گولی اوپر سے گزر گئی")
  else
    botMove(b, clamp(b.x * 2 - p.x, 2, ARENA - 2), clamp(b.y * 2 - p.y, 2, ARENA - 2))
    botMove(b, clamp(b.x * 2 - p.x, 2, ARENA - 2), clamp(b.y * 2 - p.y, 2, ARENA - 2))
    text = T("دشمن پتھر کے پیچھے چھپ گیا! اب وہ ")
  end
  queueSpatial("dodge", b.x, b.y, 90, 1.0, -1)
  return text .. dirText(relAngle(p, b.x, b.y)) .. T("، ") .. n0(dist(p.x, p.y, b.x, b.y)) .. T(" میٹر دور ہے")
end

local function actFire()
  local p = G.p
  local g = gunOf(p)
  local w = WEAPONS[g.w]
  local used = 1
  if g.w > 1 then
    if g.ammo <= 0 then
      queueSelf("empty", 0.8, -1)
      if g.reserve > 0 then return T("میگزین خالی ہے۔ ری لوڈ کریں"), false end
      return T("گولیاں ختم! ہتھیار بدلیں یا گولیاں ڈھونڈیں"), false
    end
    used = math.min(w.shots, g.ammo)
    g.ammo = g.ammo - used
  end
  queueSelf(w.snd, 1.0, -2)
  local best, bd, brel = aimTarget(w.range)
  local aware = best and best.aggro
  for _, b in ipairs(G.bots) do
    if b.alive and dist(p.x, p.y, b.x, b.y) < 45 and math.random() < 0.5 then b.aggro = true end
  end
  if w.splash then
    local lx, ly, where
    if best then
      lx = best.x + (math.random() * 2 - 1) * 2.5
      ly = best.y + (math.random() * 2 - 1) * 2.5
      best.engaged = true
      where = T("دشمن کی طرف گیا جو ") .. n0(bd) .. T(" میٹر دور تھا")
    else
      local a = math.rad(p.face)
      lx = p.x + 40 * math.sin(a)
      ly = p.y + 40 * math.cos(a)
      where = T("سامنے تقریباً 40 میٹر پر گرا")
    end
    lx, ly = clamp(lx, 0, ARENA), clamp(ly, 0, ARENA)
    local r = explodeAt(lx, ly, 90, 8, p)
    local t = T("میزائل چلا، ") .. where .. T("۔ ") .. blastText(r)
    if r.killed > 0 then t = t .. T("۔ باقی دشمن ") .. countBots() end
    return t, true
  end
  if not best then
    local hint = missHint(w)
    if g.w == 1 then return T("آپ نے مکا مارا مگر سامنے کوئی نہیں تھا") .. hint, true end
    return T("فائر کیا مگر سامنے رینج میں کوئی دشمن نہیں تھا") .. hint, true
  end
  local winded = (p.winded or 0) > 0
  local mul = (winded and 0.75 or 1.0) * (1 - 0.25 * math.abs(brel) / AIM_HALF)
  if (best.prone or 0) > 0 then mul = mul * 0.5 end
  local hits = shotResult(w, bd, mul, used)
  best.engaged = true
  if hits > 0 then
    local dodged = enemyDodge(best, bd, aware)
    if dodged then return dodged, true end
  end
  if hits <= 0 then
    local t = T("نشانہ چوک گیا۔ دشمن ") .. n0(bd) .. T(" میٹر دور تھا")
    if winded then t = t .. T("۔ سانس پھولی ہوئی تھی اس لیے نشانہ کمزور رہا") end
    return t, true
  end
  best.aggro = true
  applyDamage(best, hits * w.dmg)
  queueSelf("hitmark", 0.9, -1)
  if best.hp <= 0 then
    killBot(best, p)
    return T("دشمن ڈھیر ہو گیا! ") .. n0(bd) .. T(" میٹر دور تھا۔ ") .. killBonus(best) .. T("۔ باقی دشمن ") .. countBots(), true
  end
  return T("گولی لگ گئی! ") .. n0(bd) .. T(" میٹر دور دشمن زخمی ہو گیا"), true
end
local function actGrenade()
  local p = G.p
  if (p.grenades or 0) <= 0 then return T("آپ کے پاس گرینیڈ نہیں"), false end
  p.grenades = p.grenades - 1
  local tb, td = aimTarget(30)
  local dd = tb and td or 14
  local a = math.rad(p.face)
  local lx = clamp(p.x + dd * math.sin(a), 0, ARENA)
  local ly = clamp(p.y + dd * math.cos(a), 0, ARENA)
  queueSelf("throw", 0.7, -3)
  local r = explodeAt(lx, ly, 70, 7, p)
  local t = T("گرینیڈ ") .. n0(dd) .. T(" میٹر آگے پھٹا۔ ") .. blastText(r)
  if r.killed > 0 then t = t .. T("۔ باقی دشمن ") .. countBots() end
  return t .. T("۔ باقی گرینیڈ ") .. p.grenades, true
end
local function actBreak()
  local p = G.p
  if (p.breakers or 0) <= 0 then return T("آپ کے پاس ڈیفنس بریکر نہیں"), false end
  p.breakers = p.breakers - 1
  queueSelf("emp", 0.9, -3)
  local n = 0
  for _, b in ipairs(G.bots) do
    if b.alive and (b.defense or 0) > 0 and dist(p.x, p.y, b.x, b.y) <= 45 then
      b.defense = 0
      n = n + 1
    end
  end
  local t
  if n > 0 then
    t = T("ڈیفنس بریکر چل گیا! ") .. n .. T(" دشمنوں کا ڈیفنس سسٹم تباہ ہو گیا۔ اب میزائل اور گرینیڈ ان پر پورا اثر کریں گے")
  else
    t = T("ڈیفنس بریکر چلا مگر 45 میٹر کے اندر کسی دشمن کے پاس ڈیفنس سسٹم نہیں تھا")
  end
  return t .. T("۔ باقی بریکر ") .. p.breakers, true
end
local function actReload()
  local p = G.p
  local g = gunOf(p)
  local w = WEAPONS[g.w]
  if g.w == 1 then return T("مکے ری لوڈ نہیں ہوتے"), false end
  if g.ammo >= w.mag then return T("میگزین پہلے سے بھرا ہوا ہے"), false end
  if g.reserve <= 0 then return T("اضافی گولیاں نہیں ہیں"), false end
  local take = math.min(w.mag - g.ammo, g.reserve)
  g.ammo = g.ammo + take
  g.reserve = g.reserve - take
  queueSelf("reload", 0.9, -1)
  return T("ری لوڈ ہو گیا۔ ") .. g.ammo .. T(" گولیاں بھری ہیں، ") .. g.reserve .. T(" اضافی"), true
end
local function actHeal()
  local p = G.p
  if p.hp >= 100 then return T("صحت پہلے ہی پوری ہے"), false end
  local amount, what
  if p.medkit > 0 and (p.hp <= 50 or p.bandage == 0) then
    p.medkit = p.medkit - 1
    amount = 50
    what = T("میڈیکل کٹ استعمال کی، 50 صحت واپس ملی")
  elseif p.bandage > 0 then
    p.bandage = p.bandage - 1
    amount = 20
    what = T("پٹی لگائی، 20 صحت واپس ملی")
  else
    return T("آپ کے پاس علاج کا سامان نہیں"), false
  end
  p.hp = math.min(100, p.hp + amount)
  queueSelf("heal", 0.8, -1)
  return what .. T("۔ اب آپ کی صحت ") .. n0(p.hp) .. T(" ہے۔ باقی میڈیکل کٹ ") .. p.medkit .. T("، پٹیاں ") .. p.bandage, true
end
local function actSwitch()
  local p = G.p
  local list = {}
  for i, g in ipairs(p.weps) do
    if g.w > 1 then list[#list + 1] = i end
  end
  if #list == 0 then
    return T("ہتھیار نہیں۔ جلد آئے گا، اس کی طرف سوائپ کریں"), false
  end
  if #list == 1 then
    p.cur = list[1]
    return T("آپ کے پاس صرف ایک ہتھیار ہے۔ ") .. weaponLine(p) .. T("۔ دوسرا ہتھیار ڈھونڈ کر اٹھائیں"), false
  end
  local pos = 0
  for k, idx in ipairs(list) do
    if idx == p.cur then pos = k end
  end
  p.cur = list[pos % #list + 1]
  local now = 0
  for k, idx in ipairs(list) do
    if idx == p.cur then now = k end
  end
  return T("ہتھیار بدل لیا۔ ") .. weaponLine(p) .. T("۔ آپ کے پاس کل ") .. #list .. T(" ہتھیار ہیں، یہ نمبر ") .. now .. T(" ہے"), false
end
local swipeObserve
local observeView
local activeDialogs = {}
local currentDialog = nil
local function closeAllDialogs()
  for _, d in ipairs(activeDialogs) do pcall(function() d.dismiss() end) end
  activeDialogs = {}
  currentDialog = nil
end
local function newDialog(title)
  local d = LuaDialog()
  d.setTitle(title)
  activeDialogs[#activeDialogs + 1] = d
  currentDialog = d
  return d
end
local function styleButton(ctx, b, text)
  pcall(function() b.setText(text) end)
  pcall(function() b.setContentDescription(text) end)
  pcall(function() b.setTextSize(22) end)
  pcall(function() b.setAllCaps(false) end)
  pcall(function() b.setSingleLine(false) end)
  pcall(function() b.setGravity(17) end)
  pcall(function()
    local density = ctx.getResources().getDisplayMetrics().density
    b.setMinHeight(math.floor(72 * density))
    b.setMinimumHeight(math.floor(72 * density))
  end)
end
local function makeButton(ctx, text, onClick)
  local b = Button(ctx)
  styleButton(ctx, b, text)
  b.setOnClickListener(View.OnClickListener {
    onClick = function()
      local ok, err = pcall(onClick)
      if not ok then say(T("خرابی: ") .. tostring(err)) end
    end
  })
  if observeView then observeView(b) end
  return b
end
local function makeRow(ctx, buttons)
  local r = LinearLayout(ctx)
  r.setOrientation(LinearLayout.HORIZONTAL)
  for _, b in ipairs(buttons) do
    b.setLayoutParams(LinearLayout.LayoutParams(0, -2, 1))
    r.addView(b)
  end
  return r
end
local function makeColumn(ctx)
  local l = LinearLayout(ctx)
  l.setOrientation(LinearLayout.VERTICAL)
  l.setPadding(20, 20, 20, 20)
  return l
end
local function makeText(ctx, text)
  local tv = TextView(ctx)
  tv.setText(text)
  tv.setTextSize(20)
  tv.setPadding(10, 10, 10, 20)
  return tv
end
local function guardBack(dlg, fn)
  local fired = false
  local function handle()
    if fired then return end
    fired = true
    fn()
  end
  pcall(function()
    dlg.setOnCancelListener(DialogInterface.OnCancelListener {
      onCancel = function() handle() end
    })
  end)
  pcall(function()
    dlg.setOnKeyListener(DialogInterface.OnKeyListener {
      onKey = function(d, keyCode, event)
        if keyCode == KeyEvent.KEYCODE_BACK then
          if event.getAction() == KeyEvent.ACTION_UP then handle() end
          return true
        end
        return false
      end
    })
  end)
end
local showMainMenu, showGame, showSettings, showGameOver, showHowTo
local function stopGame()
  if G then
    G.over = true
    G.ended = true
    G.stopped = true
  end
end
local function exitExtension()
  stopGame()
  closeAllDialogs()
  say(T("باہر نکل گئے"))
  pcall(function()
    if service and service.hide then service.hide() end
    if activity and activity.finish then activity.finish() end
  end)
end
local function refreshStatus()
  if not G or not G.statusView then return end
  pcall(function()
    local p = G.p
    local g = gunOf(p)
    local wtxt
    if g.w == 1 then
      wtxt = T("ہتھیار: کوئی نہیں (صرف مکے)")
    else
      wtxt = T("ہتھیار: ") .. WEAPONS[g.w].name .. T("\nگولیاں: ") .. g.ammo .. T(" بھری ہوئی، ") .. g.reserve .. T(" اضافی")
    end
    local shown = T("آپ کی صحت: ") .. n0(math.max(0, p.hp)) .. T(" (100 کا مطلب پوری)\n") ..
      T("آرمر جیکٹ کا بچاؤ: ") .. n0(p.armor) .. "\n" .. wtxt .. "\n" ..
      T("باقی دشمن: ") .. countBots() .. T("\nآپ نے مارے: ") .. p.kills .. T("\nگزری ہوئی باریاں: ") .. G.turn
    if G.statusShown ~= shown then
      G.statusShown = shown
      G.statusView.setText(shown)
    end
  end)
end
local function endGame()
  if not G or G.ended then return end
  local g = G
  g.ended = true
  stats.games = stats.games + 1
  if g.result == "win" then stats.wins = stats.wins + 1 end
  if g.p.kills > stats.best then stats.best = g.p.kills end
  saveStats()
  queueSelf(g.result == "win" and "win" or "lose", 1.0, -10)
  flushSfx()
  later(3200, function()
    if G == g and not g.stopped then showGameOver() end
  end)
end
local function finishTurn(msg, tail)
  local text = msg or ""
  if tail and tail ~= "" then
    if text ~= "" then text = text .. T("۔ ") end
    text = text .. tail
  end
  if G then G.last = text end
  flushSfx()
  say(text)
  refreshStatus()
  if G and G.over then endGame() end
end
local RUNST = { active = false, id = 0, ticks = 0, owner = nil, warned = false }
local RUN_MS, RUN_MAX = 500, 30
local function stopRun(announce, prefix)
  if not RUNST.active then return end
  RUNST.active = false
  RUNST.owner = nil
  if not G or G.over then return end
  G.p.winded = 2
  if announce then
    local msg = T("رک گئے۔ سانس پھولی ہوئی ہے")
    if prefix and prefix ~= "" then msg = prefix .. T("۔ ") .. msg end
    finishTurn(msg, autoScan(false))
  end
end
local function act(fn)
  if not G or G.over or G.paused then return end
  if RUNST.active then stopRun(false) end
  local msg, cost, post = fn()
  local tail = nil
  if cost and settings.mode == "turn" then
    tail = table.concat(worldTurn(), T("۔ "))
  end
  if post and not G.over then
    local sc = post()
    if sc and sc ~= "" then
      if tail and tail ~= "" then tail = tail .. T("۔ ") .. sc else tail = sc end
    end
  end
  finishTurn(msg, tail)
end
local function runTick(myid, offset)
  if not RUNST.active or RUNST.id ~= myid or not G or G.over then return end
  RUNST.ticks = RUNST.ticks + 1
  local parts = {}
  local moved, wall = false, false
  for _ = 1, 2 do
    local ok, text = stepOnce(offset, true)
    if not ok then
      wall = true
      parts[#parts + 1] = text
      break
    end
    moved = true
    if text ~= "" then parts[#parts + 1] = text end
  end
  if moved then
    local p = G.p
    local woke = false
    for _, b in ipairs(G.bots) do
      if b.alive and not b.aggro and dist(p.x, p.y, b.x, b.y) < 40 and math.random() < 0.3 then
        b.aggro = true
        woke = true
      end
    end
    if woke and not RUNST.warned then
      RUNST.warned = true
      parts[#parts + 1] = T("دوڑنے کی آواز سے قریبی دشمن چوکنا ہو گئے")
    end
    if settings.mode == "turn" then
      for _, m in ipairs(worldTurn()) do parts[#parts + 1] = m end
    end
  end
  local text = table.concat(parts, T("۔ "))
  flushSfx()
  if G.over then
    RUNST.active = false
    if text ~= "" then G.last = text end
    say(text)
    refreshStatus()
    endGame()
    return
  end
  if wall then
    stopRun(true, text)
    return
  end
  if text ~= "" then
    G.last = text
    say(text)
  end
  refreshStatus()
  if RUNST.ticks >= (RUNST.max or RUN_MAX) then
    stopRun(true)
    return
  end
  later(RUN_MS, function() runTick(myid, offset) end)
end
local function startRun(offset, owner, turnBy, maxTicks)
  if not G or G.over or G.paused or RUNST.active then return end
  if turnBy then
    G.p.face = (G.p.face + turnBy) % 360
    queueSelf("turn", 0.6, -1)
  end
  RUNST.active = true
  RUNST.id = RUNST.id + 1
  RUNST.ticks = 0
  RUNST.warned = false
  RUNST.max = maxTicks
  RUNST.owner = owner or offset
  runTick(RUNST.id, offset)
end
local function addRun(btn, offset, turnBy)
  pcall(function()
    btn.setOnLongClickListener(View.OnLongClickListener {
      onLongClick = function(v)
        pcall(function()
          if turnBy then startRun(0, offset, turnBy) else startRun(offset) end
        end)
        return true
      end
    })
  end)
  pcall(function()
    btn.setOnTouchListener(View.OnTouchListener {
      onTouch = function(v, e)
        if swipeObserve then swipeObserve(e) end
        local a = e.getAction()
        if a == 1 or a == 3 then
          pcall(function()
            if RUNST.active and RUNST.owner == offset then stopRun(true) end
          end)
        end
        return false
      end
    })
  end)
  return btn
end
scheduleAimShot = function(game, b, aim, delay)
  if TEST then
    b.aim = nil
    return
  end
  later(math.floor(delay * 1000), function()
    if G ~= game or game.over or not b.alive or b.aim ~= aim then return end
    b.aim = nil
    pcall(function()
      local p = game.p
      local g = gunOf(b)
      local w = WEAPONS[g.w]
      local td = dist(p.x, p.y, b.x, b.y)
      if g.w == 1 or g.ammo <= 0 or td > w.range + 8 then return end
      local msgs = {}
      botShoot(b, p, td, msgs, aim)
      checkEnd(msgs)
      finishTurn("", table.concat(msgs, T("۔ ")))
    end)
  end)
end
-- WEAPON ARRIVAL: a weapon (or supplies) flies in from a random side at a random time.
-- Swipe in that direction within OFFER_SECS seconds to catch it, otherwise it is skipped.
local OFFER_SECS = 2
-- the next arrival comes after a random time between these two numbers (milliseconds)
local OFFER_MIN_MS, OFFER_MAX_MS = 20000, 90000

local OFFER_ANGLE = { right = 90, left = -90, ahead = 0, behind = 180 }

local function swipeWord(dir)
  if dir == "right" then return T("دائیں") end
  if dir == "left" then return T("بائیں") end
  if dir == "ahead" then return T("اوپر") end
  return T("نیچے")
end

local function offerSound(dir, vol)
  local name = (dir == "behind") and "offer_m" or "offer"
  local l, r = panGains(OFFER_ANGLE[dir], vol)
  playSound(name, l, r)
end

local function catchWeapon(dir)
  local game = G
  if not game or game.over then return end
  local offer = game.offer
  if not offer then return end
  if dir ~= offer.dir then
    say(T("غلط سمت"))
    return
  end
  game.offer = nil
  local item = { type = offer.kind, w = offer.w }
  giveItem(game.p, item, true)
  queueSelf("weapon_got", 1.0, -4)
  flushSfx()
  local name = (offer.kind == "gun") and WEAPONS[offer.w].name or itemName(item)
  game.last = T("ہتھیار ملا: ") .. name
  say(game.last)
  refreshStatus()
end

-- A swipe is a fast, straight finger move (about 90 dp in a quarter of a second).
-- It is only OBSERVED: touches still go to the buttons, so nothing changes for the
-- screen reader and your focus stays where it is.
local SW = { sx = nil, sy = nil, st = 0, cool = 0, need = 270 }
pcall(function() SW.need = 90 * getCtx().getResources().getDisplayMetrics().density end)

-- no weapon arriving: a swipe makes you run that way for about 2 seconds
local function onSwipe(dir)
  local game = G
  if not game or game.over or not game.inGame then return end
  if game.offer then
    catchWeapon(dir)
    return
  end
  if RUNST.active then stopRun(false) end
  if dir == "ahead" then
    startRun(0, "swipe", nil, 4)
  elseif dir == "behind" then
    startRun(180, "swipe", nil, 4)
  elseif dir == "left" then
    startRun(0, "swipe", -90, 4)
  else
    startRun(0, "swipe", 90, 4)
  end
end

swipeObserve = function(e)
  local x, y = e.getRawX(), e.getRawY()
  local t = System.currentTimeMillis()
  if t < SW.cool then return end
  if SW.sx == nil or t - SW.st > 260 then
    SW.sx, SW.sy, SW.st = x, y, t
    return
  end
  local dx, dy = x - SW.sx, y - SW.sy
  local ax, ay = math.abs(dx), math.abs(dy)
  if (ax >= SW.need and ax >= 2 * ay) or (ay >= SW.need and ay >= 2 * ax) then
    SW.sx = nil
    SW.cool = t + 600
    local dir
    if ax >= ay then
      dir = (dx > 0) and "right" or "left"
    else
      dir = (dy < 0) and "ahead" or "behind"
    end
    pcall(onSwipe, dir)
  end
end

observeView = function(v)
  pcall(function()
    v.setOnHoverListener(View.OnHoverListener {
      onHover = function(_, e)
        swipeObserve(e)
        return false
      end
    })
  end)
  pcall(function()
    v.setOnTouchListener(View.OnTouchListener {
      onTouch = function(_, e)
        swipeObserve(e)
        return false
      end
    })
  end)
end

local function startOffer(game)
  local dirs = { "right", "left", "ahead", "behind" }
  local offer = { dir = dirs[math.random(#dirs)], kind = "gun" }
  local text
  if math.random() < 0.35 then
    offer.kind = weightedPick(ITEM_WEIGHTS)
    text = T("سامان اٹھائیں")
  else
    offer.w = weightedPick(GUN_WEIGHTS)
    text = T("ہتھیار اٹھائیں")
  end
  game.offer = offer
  offerSound(offer.dir, 1.0)
  text = text .. T("، سوائپ ") .. swipeWord(offer.dir)
  game.last = text
  say(text)
  later(1000, function()
    if G == game and game.offer == offer and not game.over then offerSound(offer.dir, 0.8) end
  end)
  later(OFFER_SECS * 1000, function()
    if G ~= game or game.offer ~= offer then return end
    game.offer = nil
    queueSelf("weapon_skip", 0.9, -1)
    flushSfx()
    say(T("ہتھیار چھوٹ گیا"))
  end)
end

local function scheduleOffers(game, first)
  local wait = first and math.random(15000, 35000) or math.random(OFFER_MIN_MS, OFFER_MAX_MS)
  later(wait, function()
    if G ~= game or game.over then return end
    pcall(function()
      if not game.offer and game.p.hp > 0 then startOffer(game) end
    end)
    scheduleOffers(game, false)
  end)
end

local function scheduleAttacks(game)
  if TEST then return end
  later(math.random(3000, 6500), function()
    if G ~= game or game.over then return end
    pcall(function()
      if settings.attack ~= "random" then return end
      local p = game.p
      if p.hp <= 0 then return end
      local n = 0
      for _, o in ipairs(game.bots) do
        if o.alive and o.aim then n = n + 1 end
      end
      if n >= 2 then return end
      local cand = {}
      for _, b in ipairs(game.bots) do
        if b.alive and not b.aim then
          local g = gunOf(b)
          local w = WEAPONS[g.w]
          local d = dist(p.x, p.y, b.x, b.y)
          if g.w > 1 and g.ammo > 0 and d <= w.range then
            cand[#cand + 1] = { b = b, d = d }
          end
        end
      end
      if #cand == 0 or math.random() > 0.9 then return end
      local c = cand[math.random(#cand)]
      local delay = (c.d < 15) and 4 or 5
      local aim = { x = p.x, y = p.y, rt = true }
      c.b.aim = aim
      c.b.aggro = true
      local rel = relAngle(p, c.b.x, c.b.y)
      queueSpatial("lock", c.b.x, c.b.y, 140, 1.0, -1)
      local text = escapeText(rel) .. T(" دشمن آپ پر نشانہ لے رہا ہے، ") .. dirText(rel) .. T(" سے، ") ..
          n0(c.d) .. T(" میٹر دور۔ ") .. delay .. T(" سیکنڈ میں فائر کرے گا")
      game.last = text
      flushSfx()
      say(text)
      scheduleAimShot(game, c.b, aim, delay)
    end)
    if G == game and not game.over then scheduleAttacks(game) end
  end)
end
local function scheduleRT(runId)
  if TEST then return end
  later(settings.tick, function()
    if not G or G.run ~= runId or G.over then return end
    pcall(function()
      local m = worldTurn()
      local text = table.concat(m, T("۔ "))
      if text ~= "" then G.last = text end
      flushSfx()
      say(text)
      refreshStatus()
      if G.over then endGame() end
    end)
    if G and G.run == runId and not G.over then scheduleRT(runId) end
  end)
end
local function startGame(practice)
  closeAllDialogs()
  newGame(practice)
  local intro = (practice and T("پریکٹس موڈ۔ ") or T("میچ شروع ہو گیا۔ ")) .. countBots() .. T(" دشمن جزیرے پر ہیں۔ ") ..
      T("آپ کے پاس پستول ہے، ") .. WEAPONS[2].mag .. T(" گولیاں بھری ہیں۔ ہتھیار خود آئیں گے، ان کی طرف سوائپ کریں")
  G.last = intro
  showGame()
  say(intro)
  if settings.mode == "realtime" then scheduleRT(G.run) end
  scheduleAttacks(G)
  scheduleOffers(G, true)
end
showGame = function()
  local ctx = getCtx()
  local dlg = newDialog(G.practice and "Practice" or "Battle Royale")
  pcall(function() dlg.setCancelable(false) end)
  pcall(function() dlg.setCanceledOnTouchOutside(false) end)
  pcall(function()
    dlg.setOnKeyListener(DialogInterface.OnKeyListener {
      onKey = function(d, keyCode, event)
        if keyCode == KeyEvent.KEYCODE_BACK then
          if event.getAction() == KeyEvent.ACTION_UP then say(T("باہر نکلنے کے لیے Leave Game بٹن دبائیں")) end
          return true
        end
        return false
      end
    })
  end)
  local root = LinearLayout(ctx)
  root.setOrientation(LinearLayout.VERTICAL)
  pcall(function()
    local h = ctx.getResources().getDisplayMetrics().heightPixels
    root.setMinimumHeight(math.floor(h * 0.8))
  end)
  local top = makeColumn(ctx)
  local tv = makeText(ctx, "")
  -- fixed height and hidden from the screen reader: its text changes after every action,
  -- and that used to push the buttons around and take your focus away from the button you pressed
  pcall(function() tv.setLines(8) end)
  pcall(function() tv.setFocusable(false) end)
  pcall(function() tv.setImportantForAccessibility(2) end)
  G.statusView = tv
  top.addView(tv)
  top.addView(makeRow(ctx, {
    makeButton(ctx, "Reload", function() act(actReload) end),
    makeButton(ctx, "Heal", function() act(actHeal) end),
    makeButton(ctx, "Switch Weapon", function() act(actSwitch) end),
  }))
  top.addView(makeRow(ctx, {
    makeButton(ctx, "Throw Grenade", function() act(actGrenade) end),
    makeButton(ctx, "Break Defense", function() act(actBreak) end),
  }))
  top.addView(makeRow(ctx, {
    makeButton(ctx, "My Status", function() act(function() return statusText(), false end) end),
    makeButton(ctx, "Repeat Last Message", function() say(G.last) end),
    makeButton(ctx, "Leave Game", function()
      stopGame()
      dlg.dismiss()
      showMainMenu()
    end),
  }))
  local scroll = ScrollView(ctx)
  scroll.addView(top)
  scroll.setLayoutParams(LinearLayout.LayoutParams(-1, 0, 1))
  root.addView(scroll)
  local bottom = LinearLayout(ctx)
  bottom.setOrientation(LinearLayout.VERTICAL)
  bottom.setPadding(10, 10, 10, 10)
  bottom.setLayoutParams(LinearLayout.LayoutParams(-1, -2))
  bottom.addView(makeRow(ctx, {
    addRun(makeButton(ctx, "Move Forward", function() act(function() return actMove(false) end) end), 0),
  }))
  bottom.addView(makeRow(ctx, {
    addRun(makeButton(ctx, "Turn Left", function() act(function() return actSide(-1) end) end), -90, -90),
    makeButton(ctx, "Fire", function() act(actFire) end),
    addRun(makeButton(ctx, "Turn Right", function() act(function() return actSide(1) end) end), 90, 90),
  }))
  bottom.addView(makeRow(ctx, {
    makeButton(ctx, "Turn Around", function() act(function() return actTurn(180) end) end),
    addRun(makeButton(ctx, "Step Back", function() act(function() return actMove(true) end) end), 180),
  }))
  root.addView(bottom)
  G.inGame = true
  observeView(root)
  observeView(top)
  observeView(scroll)
  observeView(bottom)
  dlg.setView(root)
  dlg.show()
  pcall(function() dlg.getWindow().setLayout(-1, -1) end)
  refreshStatus()
end
showGameOver = function()
  if not G then return end
  closeAllDialogs()
  local ctx = getCtx()
  local dlg = newDialog(G.result == "win" and "You Won!" or "Game Over")
  local col = makeColumn(ctx)
  local text = (G.result == "win" and T("آپ میچ جیت گئے۔") or T("آپ ہار گئے۔")) ..
      T(" آپ کا نمبر ") .. tostring(G.place) .. T("۔ مارے گئے دشمن ") .. G.p.kills .. T("۔ باریاں ") .. G.turn ..
      T("۔\nکل میچ ") .. stats.games .. T("، جیت ") .. stats.wins .. T("، ایک میچ میں سب سے زیادہ دشمن مارے ") .. stats.best
  col.addView(makeText(ctx, text))
  local practice = G.practice
  col.addView(makeButton(ctx, "Play Again", function()
    dlg.dismiss()
    startGame(practice)
  end))
  col.addView(makeButton(ctx, "Back to Main Menu", function()
    dlg.dismiss()
    showMainMenu()
  end))
  dlg.setView(col)
  guardBack(dlg, function()
    pcall(function() dlg.dismiss() end)
    showMainMenu()
  end)
  dlg.show()
  say(text)
end
local HOWTO = "بیٹل رائل آڈیو میں خوش آمدید۔ آپ ایک 140 میٹر کے جزیرے پر اترتے ہیں جہاں دشمن موجود ہیں۔ جو آخر تک زندہ رہے وہ جیتتا ہے۔ " ..
    "ہیڈ فون ضرور لگائیں۔ دشمن کے قدموں اور فائر کی آواز بالکل اسی طرف سے آتی ہے جہاں وہ موجود ہے: بائیں طرف کا دشمن بائیں کان میں سنائی دے گا، " ..
    "پیچھے کی آوازیں دبی ہوئی ہوں گی، اور جتنی آواز تیز ہو دشمن اتنا قریب ہے۔ " ..
    "سمتیں صرف چار ہیں: سامنے، دائیں طرف، بائیں طرف اور پیچھے۔ " ..
    "Move Forward بٹن آپ کے رخ پر 3 میٹر آگے لے جاتا ہے۔ Step Back ایک قدم پیچھے لے جاتا ہے۔ " ..
    "Turn Left اور Turn Right دبانے پر آپ اسی طرف مڑ جاتے ہیں اور ایک قدم چلتے بھی ہیں، یعنی آپ کا چہرہ اسی سمت ہو جاتا ہے۔ Turn Around بغیر چلے پیچھے کی طرف مڑتا ہے۔ " ..
    "آپ پستول کے ساتھ شروع کرتے ہیں۔ باقی ہتھیار اور سامان خود بخود آتے ہیں۔ " ..
    "چلتے وقت گیم خود بتاتی ہے کہ سامنے، دائیں، بائیں اور پیچھے کون سا دشمن کتنے میٹر دور ہے۔ " ..
    "Fire بٹن آپ کے سامنے والے دشمن کو نشانہ بناتا ہے، اس لیے پہلے آواز کی طرف مڑیں۔ " ..
    "محفوظ زون وقت کے ساتھ چھوٹا ہوتا جاتا ہے اور اس سے باہر آپ کی صحت کم ہوتی ہے۔ " ..
    "Reload گولیاں بھرتا ہے، Heal میڈیکل کٹ یا پٹی سے صحت بڑھاتا ہے اور Switch Weapon ہتھیار بدلتا ہے۔ " ..
    "باری باری والے موڈ میں چلنے، فائر، ری لوڈ اور علاج کے بعد دشمن اپنی چال چلتے ہیں۔ Turn Around اور معلومات والے بٹن مفت ہیں۔ " ..
    "اصل وقت والے موڈ میں دشمن خود بخود چلتے رہتے ہیں۔ " ..
    "دوڑنا: Move Forward، Step Back، Turn Left یا Turn Right کو دبائے رکھیں تو آپ دوڑتے ہیں۔ Turn Left اور Turn Right پر پہلے اس طرف مڑتے ہیں پھر سیدھا دوڑتے ہیں۔ انگلی اٹھاتے ہی رک جاتے ہیں۔ " ..
    "دوڑتے ہوئے ایک باری میں 6 میٹر طے ہوتے ہیں اس لیے دشمن سے بچنا آسان ہے، مگر قدموں کی آواز سے قریبی دشمن چوکنا ہو سکتے ہیں اور رکنے کے بعد سانس پھولی ہونے سے اگلا فائر کمزور ہوتا ہے۔ ہتھیار نہ آ رہا ہو تو اوپر، نیچے، بائیں یا دائیں سوائپ کریں تو تقریباً 2 سیکنڈ اس طرف دوڑتے ہیں۔ " ..
    "دشمن بھی بچتے ہیں: وہ ایک طرف لڑھک جاتے ہیں، زمین پر لیٹ جاتے ہیں یا پتھر کے پیچھے چھپ جاتے ہیں۔ جس دشمن کو آپ کے آنے کا پتا نہ ہو وہ بچ نہیں پاتا۔ گیم بتاتی ہے کہ اب وہ کس طرف اور کتنے میٹر دور ہے۔ " ..
    "نشانہ: سامنے کی سمت میں جو دشمن بتایا جائے وہ آپ کی فائر کی لائن میں ہوتا ہے۔ اگر وہ ہتھیار کی مار سے دور ہو تو «بہت دور» بتایا جاتا ہے۔ " ..
    "ہتھیار اور سامان: یہ کسی بھی وقت آتے ہیں۔ گیم «ہتھیار اٹھائیں» یا «سامان اٹھائیں» اور سوائپ کی سمت بتاتی ہے۔ 2 سیکنڈ کے اندر سوائپ کریں تو مل جاتا ہے، ورنہ چھوٹ جاتا ہے۔ " ..
"گرینیڈ: Throw Grenade بٹن سے نشانے والے دشمن پر، یا سامنے تقریباً 14 میٹر پر گرینیڈ پھٹتا ہے اور آس پاس کے سب دشمنوں کو نقصان پہنچاتا ہے۔ اپنے بہت قریب نہ پھینکیں، آپ کو بھی زخم لگ سکتا ہے۔ " ..
    "میزائل لانچر: نایاب ہتھیار، صرف سپلائی ڈراپ یا زمین پر ملتا ہے۔ ایک میزائل پھٹ کر آس پاس کے سب دشمنوں کو نقصان دیتا ہے، مگر اپنے قریب نہ چلائیں۔ " ..
    "جہاز اور میزائل حملہ: سپلائی ڈراپ سے پہلے جہاز کی آواز دائیں بائیں گزرتی ہے۔ کبھی دشمن کا میزائل حملہ ہوتا ہے، سائرن بجتا ہے اور گرنے کی جگہ بتائی جاتی ہے، آپ کے پاس 3 باریاں ہیں، دوڑ کر نکل جائیں۔ " ..
    "دشمن کی فائرنگ: دشمن فوراً فائر نہیں کرتا، پہلے آپ پر نشانہ لیتا ہے اور بیپ کی آواز آتی ہے۔ گیم سب سے پہلے بتاتی ہے کہ کس طرف بھاگنا ہے، پھر باقی تفصیل، مثلاً بائیں بھاگیں، دشمن دائیں سے آ رہا ہے۔ نشانہ لینے کے بعد 4 یا 5 سیکنڈ کے اندر تقریباً 8 میٹر ہٹ گئے تو گولی خالی جاتی ہے، 4 میٹر ہٹے تو نشانہ آدھا رہ جاتا ہے، کھڑے رہے تو گولی لگتی ہے۔ ترتیبات میں دشمن کے حملے کا وقت رکھا ہے، رینڈم ٹائمنگ چنیں تو دشمن کسی بھی وقت نشانہ لے سکتا ہے، چاہے آپ فائر کریں یا نہ کریں۔ " ..
    "ڈیفنس سسٹم: یہ سامان آپ کو خودکار تحفظ دیتا ہے، ہر چارج ایک میزائل، گرینیڈ یا دھماکے کو مار گراتا ہے۔ کچھ دشمنوں کے پاس بھی ڈیفنس ہوتا ہے، نشانے پر ایسا دشمن آئے تو اعلان میں بتایا جاتا ہے، اس پر میزائل اکثر ہوا میں تباہ ہو جاتے ہیں۔ Break Defense بٹن سے 45 میٹر کے اندر دشمنوں کے ڈیفنس تباہ کر دیں۔ " ..
    "حملے سے بچنا: دشمن آپ پر میزائل یا گرینیڈ داغتا ہے تو گیم بتاتی ہے کہ کس سمت سے آ رہا ہے، کدھر بھاگنا ہے اور کتنی باریاں ہیں۔ ہر باری بتایا جاتا ہے کہ دھماکے کی جگہ سے کتنے میٹر دور ہیں۔ وقت ختم ہونے سے پہلے دوڑ کر دور نہ ہوئے تو نقصان ہوتا ہے۔ " ..
    "طوفان: کبھی کبھی بارش اور دھند آتی ہے، تب نظر کم ہو جاتی ہے اور دور کے دشمن اعلان میں نہیں آتے۔ گرج کی آواز بھی آتی ہے۔ " ..
    "سپلائی ڈراپ: میچ کے دوران آسمان سے قیمتی سامان گرتا ہے اور بیپ کی آواز دیتا ہے۔ اس میں آرمر اور علاج کا سامان ہوتا ہے، مگر دشمن بھی وہیں پہنچتے ہیں۔ " ..
    "ماہر دشمن: ایک خطرناک دشمن بھاری آرمر کے ساتھ ہوتا ہے، اسے مارنے پر بڑا انعام ملتا ہے۔ جلدی جلدی دشمن مارنے پر ڈبل اور ٹرپل کل کا انعام بھی ہے۔ " ..
    "پہلے پریکٹس موڈ میں سیکھیں۔"
local HOWTO_EN = table.concat({
  "Welcome to Battle Royale Audio. You land on a 140 meter island with enemies. The last one alive wins. ",
  "Use headphones. Enemy steps and shots come from their real direction: a left enemy is heard in the left ear. ",
  "Sounds behind you are muffled. Louder means closer. ",
  "Directions: ahead, right, left, behind. ",
  "Move Forward goes 3 meters ahead. Step Back goes one step back. ",
  "Turn Left and Turn Right turn you and move one step. Turn Around turns without moving. ",
  "You start with a pistol. Other weapons and supplies arrive by themselves. ",
  "Weapons and supplies arrive at random moments from any side. The game says Pick weapon or Pick supplies and a swipe direction. Swipe that way within 2 seconds, or it is skipped. ",
  "While you move, the game announces enemies ahead, right, left and behind, with distances. ",
  "Fire shoots the enemy in front of you, so turn toward the sound first. ",
  "The safe zone shrinks over time, and you lose health outside it. ",
  "Reload refills ammo, Heal uses a medkit or bandage, Switch Weapon changes your gun. ",
  "In turn-based mode enemies move after your walk, fire, reload and heal. Turn Around and the info buttons are free. ",
  "In real-time mode enemies keep moving by themselves. ",
  "Running: hold Move Forward, Step Back, Turn Left or Turn Right. Left and right turn first, then run straight. Lift your finger to stop. ",
  "Running covers 6 meters per turn, but the noise alerts enemies and you are out of breath afterwards, so your next shot is weaker. When no weapon is arriving you can also swipe up, down, left or right to run that way for about 2 seconds. ",
  "Enemies dodge too: they roll aside, drop flat or dive behind cover, and a surprised enemy cannot dodge. The game tells you where they are now. ",
  "Aim: any enemy announced ahead is in your line of fire. If he is beyond your gun range the game says too far. ",
  "Grenade: Throw Grenade hits the aimed enemy, or about 14 meters ahead, and hurts everyone nearby. You too if you are close. ",
  "Missile launcher: rare. The blast hurts everyone nearby, so do not fire close to yourself. ",
  "Plane and missile strike: a plane flies past before a supply drop. Sometimes an enemy missile strike comes with a siren and the landing spot. You have 3 turns to run away. ",
  "Enemy fire: enemies warn first. The game says which way to run, then the details. Move about 8 meters away in time and the shot misses. 4 meters halves it. Standing still takes the full hit. In Settings, Enemy Attack Timing can make enemies lock on at random moments. ",
  "Defense system: each charge blocks one missile, grenade or blast. Some enemies have it too. Break Defense destroys enemy defenses within 45 meters. ",
  "Dodging attacks: when an enemy fires a missile or grenade the game says where it comes from, which way to run and how many turns you have. Get far from the blast in time or take damage. ",
  "Storm: rain and fog reduce vision, so far enemies are not announced. ",
  "Supply drop: valuable items fall from the sky with a beeping sound. Enemies come too. ",
  "Elite enemy: a heavily armored enemy gives a big reward. Quick kills give double and triple kill bonuses. ",
  "Learn in Practice Mode first.",
})

local function howtoText()
  if LANG.code == "ur" then return HOWTO end
  return HOWTO_EN
end

showHowTo = function()
  closeAllDialogs()
  local ctx = getCtx()
  local dlg = newDialog("How to Play")
  local col = makeColumn(ctx)
  col.addView(makeText(ctx, howtoText()))
  col.addView(makeButton(ctx, "Read Aloud", function() say(howtoText()) end))
  col.addView(makeButton(ctx, "Back", function()
    dlg.dismiss()
    showMainMenu()
  end))
  local scroll = ScrollView(ctx)
  scroll.addView(col)
  dlg.setView(scroll)
  guardBack(dlg, function()
    pcall(function() dlg.dismiss() end)
    showMainMenu()
  end)
  dlg.show()
end
local function cycleButton(ctx, label, key, options)
  local btn = Button(ctx)
  local idx = 1
  for i, o in ipairs(options) do
    if o[1] == settings[key] then idx = i end
  end
  local function refresh()
    styleButton(ctx, btn, label .. ": " .. options[idx][2])
  end
  refresh()
  btn.setOnClickListener(View.OnClickListener {
    onClick = function()
      idx = idx % #options + 1
      setSetting(key, options[idx][1])
      if key == "lang" then
        LANG.code = (options[idx][1] == "ur") and "ur" or "en"
        applyLanguage()
      end
      refresh()
      say(label .. " " .. options[idx][2])
    end
  })
  return btn
end
showSettings = function()
  closeAllDialogs()
  local ctx = getCtx()
  local dlg = newDialog("Settings")
  local col = makeColumn(ctx)
  col.addView(cycleButton(ctx, "Commentary Language", "lang", { { "en", "English" }, { "ur", "Urdu" } }))
  col.addView(cycleButton(ctx, "Game Mode", "mode", { { "turn", "Turn-Based" }, { "realtime", "Real-Time" } }))
  col.addView(cycleButton(ctx, "Real-Time Speed", "tick", { { 4000, "Slow" }, { 2500, "Medium" }, { 1500, "Fast" } }))
  col.addView(cycleButton(ctx, "Auto Announce Enemies", "auto", { { "enemy", "On" }, { "off", "Off" } }))
  col.addView(cycleButton(ctx, "Enemy Attack Timing", "attack", { { "sync", "After My Fire" }, { "random", "Random Timing" } }))
  col.addView(cycleButton(ctx, "Enemy Skill", "diff", { { 1, "Easy" }, { 2, "Medium" }, { 3, "Hard" } }))
  col.addView(cycleButton(ctx, "Number of Enemies", "bots", { { 8, "8" }, { 12, "12" }, { 15, "15" }, { 20, "20" } }))
  col.addView(cycleButton(ctx, "Volume", "vol", { { 1.0, "100 percent" }, { 0.75, "75 percent" }, { 0.5, "50 percent" } }))
  col.addView(makeButton(ctx, "Stereo Sound Test (use headphones)", function()
    playSound("shot_pistol", panGains(-90, 0.9))
    later(700, function() playSound("shot_pistol", panGains(90, 0.9)) end)
    say(T("پہلے بائیں کان میں فائر کی آواز آئے گی، پھر دائیں میں"))
  end))
  col.addView(makeButton(ctx, "Back", function()
    dlg.dismiss()
    showMainMenu()
  end))
  local scroll = ScrollView(ctx)
  scroll.addView(col)
  dlg.setView(scroll)
  guardBack(dlg, function()
    pcall(function() dlg.dismiss() end)
    showMainMenu()
  end)
  dlg.show()
end
local UPDATE_BASE = "https://raw.githubusercontent.com/nabeelhafiz229-afk/Battle-Royale-Audio/main/"
local PLUGIN_PATHS = {
  "/sdcard/解说/Tools/Battle Royale Audio/main.lua",
  "/storage/emulated/0/解说/Tools/Battle Royale Audio/main.lua",
}
local UPD = { busy = false }
local function versionParts(v)
  local t = {}
  for n in tostring(v):gmatch("%d+") do t[#t + 1] = tonumber(n) end
  return t
end
local function isNewer(a, b)
  local x, y = versionParts(a), versionParts(b)
  for i = 1, math.max(#x, #y) do
    local p, q = x[i] or 0, y[i] or 0
    if p ~= q then return p > q end
  end
  return false
end
local function readFile(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local d = f:read("*a")
  f:close()
  return d
end
local function writeFile(path, data)
  local f = io.open(path, "wb")
  if not f then return false end
  local ok = f:write(data)
  f:close()
  return ok ~= nil
end
local function tmpDir()
  local d = nil
  pcall(function() d = getCtx().getExternalFilesDir(nil).getAbsolutePath() end)
  if not d then pcall(function() d = getCtx().getCacheDir().getAbsolutePath() end) end
  return d
end
local function stripBom(d)
  if d:sub(1, 3) == "\239\187\191" then return d:sub(4) end
  return d
end
local function currentVersion()
  local iv = readStorage("installed_version", "")
  if iv ~= "" and isNewer(iv, APP_VERSION) then return iv end
  return APP_VERSION
end
local function validateLua(d)
  if #d < 5000 then return false, T("ڈاؤن لوڈ شدہ فائل صرف ") .. #d .. T(" بائٹ کی ہے") end
  local compile = loadstring or load
  local fn, err = compile(d)
  if not fn then return false, T("فائل میں Lua کی خرابی ہے: ") .. tostring(err):sub(1, 90) end
  if not d:find("showMainMenu", 1, true) then return false, T("یہ فائل اس گیم کی main.lua نہیں لگتی") end
  return true
end
local function fetchFile(name, maxTicks, preferHttp, validate, cb)
  local url = UPDATE_BASE .. name .. "?t=" .. tostring(os.time())
  local done = false
  local lastWhy = nil
  local function finish(ok, text)
    if done then return end
    done = true
    cb(ok, text, lastWhy)
  end
  local function accept(data)
    if data == nil then return false end
    data = stripBom(tostring(data))
    if validate then
      local ok, why = validate(data)
      if not ok then
        lastWhy = why
        return false
      end
    end
    finish(true, data)
    return true
  end
  local function viaHttp(onFail)
    local answered = false
    local function fail()
      if answered then return end
      answered = true
      onFail()
    end
    local ok = pcall(function()
      Http.get(url, function(code, content)
        if answered then return end
        if code == 200 and content ~= nil and accept(content) then
          answered = true
        else
          fail()
        end
      end)
    end)
    if not ok then
      fail()
      return
    end
    later(maxTicks * 700, fail)
  end
  local function viaDM(onFail)
    local answered = false
    local function fail()
      if answered then return end
      answered = true
      onFail()
    end
    local dir = tmpDir()
    local started = pcall(function()
      local ctx = getCtx()
      local dest = dir .. "/upd_" .. name
      pcall(function() File(dest).delete() end)
      local dm = ctx.getSystemService(Context.DOWNLOAD_SERVICE)
      local req = DownloadManager.Request(Uri.parse(url))
      req.setDestinationUri(Uri.fromFile(File(dest)))
      req.setTitle("Battle Royale Audio")
      local id = dm.enqueue(req)
      local ticks = 0
      local function poll()
        if answered then return end
        ticks = ticks + 1
        local status = nil
        pcall(function()
          local c = dm.query(DownloadManager.Query())
          if c then
            while c.moveToNext() do
              if c.getLong(c.getColumnIndex("_id")) == id then
                status = c.getInt(c.getColumnIndex("status"))
                break
              end
            end
            c.close()
          end
        end)
        if status == 8 then
          local data = readFile(dest)
          pcall(function() File(dest).delete() end)
          if accept(data) then
            answered = true
          else
            fail()
          end
        elseif status == 16 or ticks >= maxTicks then
          fail()
        else
          later(700, poll)
        end
      end
      later(700, poll)
    end)
    if not started or not dir then fail() end
  end
  local methods = preferHttp and { viaHttp, viaDM } or { viaDM, viaHttp }
  local idx = 0
  local function nextMethod()
    idx = idx + 1
    local m = methods[idx]
    if not m then
      finish(false, nil)
      return
    end
    m(nextMethod)
  end
  nextMethod()
end
local function restartFrom(path)
  stopGame()
  closeAllDialogs()
  saveStorage("just_updated", "1")
  say(T("اپڈیٹ مکمل ہو گئی۔ ایکسٹینشن دوبارہ کھل رہی ہے"))
  later(700, function()
    local ok, err = pcall(function()
      local loader = loadfile or dofile
      local f, e = loader(path)
      if not f then error(tostring(e)) end
      f()
    end)
    if not ok then
      say(T("اپڈیٹ لگ گئی ہے مگر خود نہیں کھل سکی۔ براہ کرم ایکسٹینشن بند کر کے دوبارہ کھولیں"))
      pcall(showMainMenu)
    end
  end)
end
local function installUpdate(v)
  if UPD.busy then return end
  UPD.busy = true
  say(T("اپڈیٹ ڈاؤن لوڈ ہو رہی ہے، براہ کرم انتظار کریں۔ ایکسٹینشن بند نہ کریں"))
  fetchFile("main.lua", 90, false, validateLua, function(ok, data, why)
    UPD.busy = false
    if not ok or not data then
      local t = T("اپڈیٹ نہیں ہو سکی۔ پرانا ورژن محفوظ ہے")
      if why then t = t .. T("۔ وجہ: ") .. why end
      say(t)
      return
    end
    local path = nil
    for _, pth in ipairs(PLUGIN_PATHS) do
      if readFile(pth) then
        path = pth
        break
      end
    end
    if not path then
      say(T("ایکسٹینشن کی فائل مقررہ جگہ پر نہیں ملی۔ اپڈیٹ نہیں ہو سکی"))
      return
    end
    local old = readFile(path)
    if old then writeFile(path .. ".bak", old) end
    local tmp = path .. ".new"
    local saved = writeFile(tmp, data)
    local back = saved and readFile(tmp)
    if not back or #back ~= #data then
      pcall(os.remove, tmp)
      say(T("نئی فائل محفوظ نہیں ہو سکی۔ پرانا ورژن محفوظ ہے"))
      return
    end
    local renamed = os.rename(tmp, path)
    if not renamed then
      writeFile(path, data)
      pcall(os.remove, tmp)
    end
    local check = readFile(path)
    if not check or #check ~= #data then
      if old then writeFile(path, old) end
      say(T("اپڈیٹ لگاتے ہوئے خرابی ہوئی۔ پرانا ورژن بحال کر دیا گیا ہے"))
      return
    end
    saveStorage("installed_version", v)
    restartFrom(path)
  end)
end
local function showUpdateDialog(v)
  local ctx = getCtx()
  local dlg = newDialog("Update Available")
  local col = makeColumn(ctx)
  local msg = "A new version " .. v .. " is available. Your current version is " .. currentVersion() ..
      ". Do you want to update now? The extension will restart automatically after the update."
  col.addView(makeText(ctx, msg))
  col.addView(makeButton(ctx, "Update Now", function()
    dlg.dismiss()
    installUpdate(v)
  end))
  col.addView(makeButton(ctx, "Later", function() dlg.dismiss() end))
  local scroll = ScrollView(ctx)
  scroll.addView(col)
  dlg.setView(scroll)
  dlg.show()
  say(msg)
end
local function checkForUpdate(manual)
  if UPD.busy then
    if manual then say(T("اپڈیٹ کی جانچ پہلے سے جاری ہے")) end
    return
  end
  UPD.busy = true
  if manual then say(T("اپڈیٹ جانچ رہے ہیں، براہ کرم انتظار کریں")) end
  fetchFile("version.txt", 30, true, nil, function(ok, text)
    UPD.busy = false
    if not ok then
      if manual then say(T("اپڈیٹ کی جانچ نہیں ہو سکی۔ انٹرنیٹ چیک کریں اور دوبارہ کوشش کریں")) end
      return
    end
    local v = tostring(text):match("(%d+[%d%.]*)")
    if not v then
      if manual then say(T("ورژن کی فائل درست نہیں")) end
      return
    end
    if isNewer(v, currentVersion()) then
      if manual then
        showUpdateDialog(v)
      elseif (not G or G.over) and UPD.askedFor ~= v then
        UPD.askedFor = v
        showUpdateDialog(v)
      end
    elseif manual then
      say(T("آپ کے پاس تازہ ترین ورژن ") .. currentVersion() .. T(" ہے"))
    end
  end)
end
showMainMenu = function()
  closeAllDialogs()
  local ctx = getCtx()
  local dlg = newDialog("Battle Royale Audio v" .. currentVersion())
  local col = makeColumn(ctx)
  col.addView(makeButton(ctx, "Start Match", function()
    dlg.dismiss()
    startGame(false)
  end))
  col.addView(makeButton(ctx, "Practice Mode", function()
    dlg.dismiss()
    startGame(true)
  end))
  col.addView(makeButton(ctx, "How to Play", function()
    dlg.dismiss()
    showHowTo()
  end))
  col.addView(makeButton(ctx, "Settings", function()
    dlg.dismiss()
    showSettings()
  end))
  col.addView(makeButton(ctx, "My Stats", function()
    say(T("کھیلے گئے میچ ") .. stats.games .. T("۔ جیت ") .. stats.wins .. T("۔ ایک میچ میں سب سے زیادہ دشمن مارے ") .. stats.best)
  end))
  col.addView(makeButton(ctx, "Check for Updates", function() checkForUpdate(true) end))
  col.addView(makeButton(ctx, "Exit", function() exitExtension() end))
  local scroll = ScrollView(ctx)
  scroll.addView(col)
  dlg.setView(scroll)
  dlg.show()
end

-- ===== WORDS FOR BOTH LANGUAGES =====
-- add(urdu text used in the code, English text, optional shorter Urdu text)
local function fillLanguages()
  local function add(ur, en, shortUr)
    LANG.en[ur] = en
    if shortUr then LANG.ur[ur] = shortUr end
  end
  add("سامنے",
      "ahead")
  add("پیچھے",
      "behind")
  add("دائیں طرف",
      "right")
  add("بائیں طرف",
      "left")
  add("پیچھے بھاگیں!",
      "Run back!")
  add("آگے بھاگیں!",
      "Run forward!")
  add("بائیں بھاگیں!",
      "Run left!")
  add("دائیں بھاگیں!",
      "Run right!")
  add("اس فون پر خاص آوازیں نہیں چل رہیں۔ سادہ بیپ استعمال ہوں گی۔",
      "No special sounds on this phone. Using simple beeps.")
  add("مکے",
      "Fists")
  add("پستول",
      "Pistol")
  add("ہلکا ہتھیار ہے، درمیانے فاصلے تک ٹھیک مار کرتا ہے",
      "Light gun, fine at medium range")
  add("ایس ایم جی",
      "SMG")
  add("ایک فائر میں تین گولیاں چلتی ہیں، قریب اور درمیانے فاصلے پر " ..
      "بہت اچھی ہے",
      "3 shots per fire, great at close and medium range")
  add("شاٹ گن",
      "Shotgun")
  add("بہت قریب کے دشمن پر ایک ہی فائر میں بھاری نقصان کرتی ہے",
      "Heavy damage at very close range")
  add("اسالٹ رائفل",
      "Assault rifle")
  add("دور تک مار کرتی ہے، ایک فائر میں دو گولیاں چلتی ہیں",
      "Long range, 2 shots per fire")
  add("سنائپر رائفل",
      "Sniper rifle")
  add("سب سے دور تک مار کرتی ہے، ایک ہی گولی میں بھاری نقصان",
      "Longest range, one heavy shot")
  add("میزائل لانچر",
      "Missile launcher")
  add("میزائل چلاتا ہے جو پھٹ کر آس پاس کے سب دشمنوں کو نقصان " ..
      "پہنچاتا ہے، اپنے قریب نہ چلائیں",
      "Blast hurts everyone nearby. Not close to yourself")
  add("گولیوں کا ڈبہ",
      "Ammo box")
  add("میڈیکل کٹ",
      "Medkit")
  add("پٹی",
      "Bandage")
  add("آرمر جیکٹ",
      "Armor vest")
  add("گرینیڈ",
      "Grenade")
  add("ڈیفنس سسٹم",
      "Defense system")
  add("ڈیفنس بریکر",
      "Defense breaker")
  add("سامان",
      "Item")
  add("آپ کے پاس پہلے سے ",
      "You already have ")
  add(" ہے، اس لیے ",
      ", so you got ")
  add(" گولیاں اضافی مل گئیں۔ اب اضافی گولیاں ",
      " extra bullets. Spare now ")
  add(" ہیں",
      "")
  add("آپ نے ",
      "Picked up ")
  add(" اٹھا لی اور ہاتھ میں لے لی۔ اس میں ",
      " and equipped. ")
  add(" گولیاں بھری ہیں اور ",
      " loaded, ")
  add(" اضافی ہیں۔ اس کی مار ",
      " spare. Range ")
  add(" میٹر تک ہے۔ ",
      " meters. ")
  add("۔ پرانا ہتھیار لینے کے لیے Switch Weapon بٹن دبائیں",
      ". Press Switch Weapon for the old gun",
      "۔ پرانے ہتھیار کے لیے Switch Weapon دبائیں")
  add(" آپ کے موجودہ ہتھیار کی اضافی گولیاں اب ",
      " Spare for current gun: ")
  add("آپ نے گولیوں کا ڈبہ اٹھا لیا۔ اس سے آپ کے تمام ہتھیاروں کو " ..
      "ایک ایک میگزین کی اضافی گولیاں مل گئیں۔",
      "Ammo box. Every gun got a spare magazine.",
      "گولیوں کا ڈبہ اٹھایا۔ ہر ہتھیار کو ایک اضافی میگزین ملا۔")
  add("آپ نے میڈیکل کٹ اٹھا لی۔ یہ 50 صحت واپس دیتی ہے۔ استعمال کے " ..
      "لیے Heal بٹن دبائیں۔ اب آپ کے پاس ",
      "Medkit: heals 50. Press Heal. You have ",
      "میڈیکل کٹ اٹھائی، 50 صحت دیتی ہے۔ Heal دبائیں۔ کل ")
  add(" میڈیکل کٹ ہیں",
      " medkits")
  add("آپ نے پٹی اٹھا لی۔ یہ 20 صحت بڑھاتی ہے۔ استعمال کے لیے Heal " ..
      "بٹن دبائیں۔ اب آپ کے پاس ",
      "Bandage: heals 20. Press Heal. You have ",
      "پٹی اٹھائی، 20 صحت دیتی ہے۔ Heal دبائیں۔ کل ")
  add(" پٹیاں ہیں",
      " bandages")
  add("آپ نے آرمر جیکٹ پہن لی۔ یہ دشمن کی گولی کا آدھا نقصان خود " ..
      "سہہ لیتی ہے۔ اب آپ کا آرمر ",
      "Armor on: halves enemy damage. Armor now ",
      "آرمر جیکٹ پہنی، آدھا نقصان روکتی ہے۔ آرمر ")
  add(" ہے",
      "")
  add("آپ نے 2 گرینیڈ اٹھا لیے۔ اب آپ کے پاس ",
      "Got 2 grenades. You have ",
      "دو گرینیڈ ملے۔ کل ")
  add(" گرینیڈ ہیں۔ پھینکنے کے لیے Throw Grenade بٹن دبائیں",
      " grenades. Press Throw Grenade",
      " گرینیڈ۔ پھینکنے کے لیے Throw Grenade دبائیں")
  add("آپ نے ڈیفنس سسٹم لگا لیا۔ یہ خودکار چلتا ہے اور آنے والے " ..
      "میزائل، گرینیڈ اور دھماکوں کو ہوا میں مار گراتا ہے۔ ڈیفنس " ..
      "چارج اب ",
      "Defense system on. Blocks missiles, grenades and blasts. " ..
      "Charges: ",
      "ڈیفنس سسٹم لگ گیا، میزائل اور دھماکے روکتا ہے۔ چارج ")
  add("آپ نے ڈیفنس بریکر اٹھا لیا۔ یہ 45 میٹر کے اندر دشمنوں کے " ..
      "ڈیفنس سسٹم تباہ کر دیتا ہے۔ استعمال کے لیے Break Defense بٹن " ..
      "دبائیں۔ اب آپ کے پاس ",
      "Defense breaker: destroys enemy defenses within 45 meters. " ..
      "Press Break Defense. You have ",
      "ڈیفنس بریکر ملا، 45 میٹر میں دشمن کا ڈیفنس توڑتا ہے۔ Break " ..
      "Defense دبائیں۔ کل ")
  add(" بریکر ہیں",
      " breakers")
  add("یہاں گولیوں کا ڈبہ ہے مگر آپ کے پاس ابھی کوئی ہتھیار نہیں۔ " ..
      "پہلے ہتھیار ڈھونڈیں",
      "Ammo box here, but you have no gun. Find a weapon first",
      "گولیوں کا ڈبہ ہے مگر ہتھیار نہیں۔ پہلے ہتھیار ڈھونڈیں")
  add("خبردار! محفوظ زون 4 باریوں میں سکڑنے والا ہے",
      "Warning! Safe zone shrinks in 4 turns")
  add("محفوظ زون سکڑ رہا ہے۔ نیا دائرہ ",
      "Safe zone shrinking. New radius ")
  add(" میٹر کا ہوگا",
      " meters")
  add("کسی دوسرے دشمن کی فائرنگ کی آواز! ",
      "Another enemy shooting from ")
  add("، ",
      ", ")
  add(" میٹر دور",
      " meters away")
  add("آپ کافی نہیں ہٹ سکے۔ ",
      "You did not move enough. ")
  add("آپ اپنی جگہ سے ہٹے نہیں۔ ",
      "You stood still. ")
  add("دشمن نے ",
      "Enemy from ")
  add(" سے آپ کو گولی ماری، ",
      " hit you, ")
  add(" میٹر دور۔ صحت ",
      " meters. Health -")
  add(" کم ہوئی، اب صحت ",
      ", now ")
  add(" سے فائر کیا مگر آپ وقت پر ہٹ گئے! گولی خالی گئی۔ شاباش",
      " fired but you dodged in time! Missed. Well done")
  add(" سے فائر ہوا، ",
      " shot, ")
  add(" میٹر دور۔ گولی پاس سے گزر گئی",
      " meters. Missed you")
  add("زخمی دشمن پیچھے ہٹ رہا ہے۔ اب وہ ",
      "Wounded enemy retreating. Now ")
  add(" میٹر دور ہے",
      " meters away")
  add("دشمن نے بچنے کے لیے پہلو بدلا۔ اب وہ ",
      "Enemy sidestepped. Now ")
  add(" دشمن آپ پر نشانہ لے رہا ہے، ",
      " Enemy aiming at you from ")
  add(" سے، ",
      ", ")
  add(" میٹر دور۔ ",
      " meters. ")
  add(" سیکنڈ میں فائر کرے گا",
      " seconds to fire")
  add("دشمن قریب ہے! ",
      "Enemy close! ")
  add("آپ مارے گئے۔ آپ ",
      "You died. Rank ")
  add(" نمبر پر رہے، ",
      ", kills: ")
  add(" دشمن مارے",
      "")
  add("مبارک ہو! آپ جیت گئے! آپ آخر میں زندہ بچنے والے ہیں، ",
      "You win! Last one standing. Kills: ")
  add("ڈبل کل!",
      "Double kill!")
  add("ٹرپل کل!",
      "Triple kill!")
  add("الٹرا کل!",
      "Ultra kill!")
  add("بے قابو!",
      "Unstoppable!")
  add("ماہر دشمن گرا دیا! بڑا انعام: 50 صحت اور 50 آرمر ملا۔ اس کے " ..
      "گرے ہوئے سامان کو بھی اٹھا لیں",
      "Elite enemy down! Bonus: +50 health, +50 armor. Grab his " ..
      "loot",
      "ماہر دشمن مارا! 50 صحت اور 50 آرمر ملا۔ اس کا سامان اٹھائیں")
  add("انعام میں 10 صحت ملی",
      "Bonus +10 health")
  add(" دشمن ڈھیر ہو گئے!",
      " enemies down!")
  add("۔ ",
      ". ")
  add(" دشمن زخمی ہوئے",
      " enemies wounded")
  add(" دشمن کے ڈیفنس سسٹم نے حملہ روک لیا",
      " enemy defenses blocked it")
  add("کوئی دشمن زد میں نہیں آیا",
      "No enemy hit")
  add("آپ کے ڈیفنس سسٹم نے حملہ مار گرایا اور آپ کو بچا لیا! باقی " ..
      "ڈیفنس چارج ",
      "Your defense blocked it and saved you! Charges left: ",
      "آپ کے ڈیفنس نے حملہ روک لیا! باقی چارج ")
  add("۔ آپ خود دھماکے کی زد میں آ گئے! صحت ",
      ". You were caught in the blast! Health -")
  add("طوفان تھم گیا، نظر صاف ہو گئی ہے",
      "Storm over. Visibility is back")
  add("طوفان آ گیا! بارش اور دھند سے نظر بہت کم ہو گئی ہے، اب صرف " ..
      "قریب کے دشمن اور سامان اعلان میں آئیں گے۔ آوازوں پر دھیان " ..
      "دیں",
      "Storm! Low visibility. Only nearby enemies will be announced",
      "طوفان! نظر کم ہے، صرف قریبی دشمن بتائے جائیں گے")
  add("خبردار! میدان میں ایک ماہر دشمن ہے جس کے پاس بھاری آرمر اور " ..
      "طاقتور ہتھیار ہے۔ اسے مارنے پر بڑا انعام ملتا ہے",
      "Warning! Elite enemy with heavy armor on the island. Big " ..
      "reward",
      "خبردار! جزیرے پر بھاری آرمر والا ماہر دشمن ہے، مارنے پر بڑا " ..
      "انعام")
  add(" سائرن! میزائل ",
      " Siren! Missile lands in ")
  add(" باری میں گرے گا۔ نشانہ ",
      " turns. Target ")
  add(" میٹر دور۔ خطرناک دائرہ 12 میٹر ہے",
      " meters. Danger radius 12")
  add("میزائل پھٹ گیا! ",
      "Missile exploded! ")
  add("آپ بچ گئے! ",
      "You are safe! ")
  add(" خطرے کا سائرن! دشمن کا میزائل حملہ! نشانہ ",
      " Air raid! Enemy missile strike. Target ",
      " سائرن! دشمن کا میزائل حملہ! نشانہ ")
  add(" میٹر دور ہے۔ یہ 3 باریوں میں گرے گا، آس پاس 12 میٹر خطرناک " ..
      "ہیں",
      " meters. Lands in 3 turns. Danger radius 12",
      " میٹر دور۔ 3 باریوں میں گرے گا، دائرہ 12 میٹر")
  add("دوڑیں! ",
      "Run! ")
  add(" آنے میں ",
      " lands in ")
  add(" باری باقی! دھماکے کی جگہ سے آپ ",
      " turns! You are ")
  add(" میٹر دور ہیں، ",
      " meters from the blast. Get beyond ")
  add(" میٹر سے زیادہ دور ہو جائیں، دوڑیں!",
      " meters!")
  add(" پھٹ گیا! ",
      " exploded! ")
  add("دشمن کا میزائل",
      "Enemy missile")
  add("دشمن کا گرینیڈ",
      "Enemy grenade")
  add(" آپ کی طرف داغا گیا، یہ ",
      " incoming from ")
  add(" سے آ رہا ہے، ",
      ", ")
  add(" میٹر دور سے۔ آپ کے پاس ",
      " meters. ")
  add(" باریاں ہیں، ورنہ نقصان ہو گا",
      " turns to get away")
  add("سپلائی ڈراپ خالی ہو گیا، سب سامان اٹھا لیا گیا",
      "Supply drop empty, all looted")
  add("سپلائی ڈراپ ",
      "Supply drop ")
  add("ہوائی جہاز کی آواز! سپلائی ڈراپ گرا ہے، اس میں اعلیٰ ہتھیار، " ..
      "گولیاں، آرمر، ڈیفنس سسٹم اور میڈیکل کٹ ہے۔ وہ ",
      "Plane overhead! Supply drop landed. It is ",
      "جہاز کی آواز! سپلائی ڈراپ گرا ہے۔ وہ ")
  add(" میٹر دور ہے۔ بیپ کی آواز کی طرف جائیں، دشمن بھی وہیں آئیں " ..
      "گے",
      " meters away. Follow the beeps, enemies will come too",
      " میٹر دور ہے۔ بیپ کی طرف جائیں، دشمن بھی آئیں گے")
  add("آپ محفوظ زون سے باہر ہیں! صحت ",
      "Outside safe zone! Health -")
  add("ہتھیار: کوئی نہیں، صرف مکے",
      "Weapon: none, fists only")
  add("ہتھیار: ",
      "Weapon: ")
  add(" گولیاں بھری ہیں، ",
      " loaded, ")
  add(" اضافی، مار ",
      " spare, range ")
  add(" میٹر تک",
      " m")
  add("صحت ",
      "Health ")
  add("۔ آرمر ",
      ". Armor ")
  add("۔ میڈیکل کٹ ",
      ". Medkits ")
  add("، پٹیاں ",
      ", bandages ")
  add("، گرینیڈ ",
      ", grenades ")
  add("، ڈیفنس چارج ",
      ", defense ")
  add("، ڈیفنس بریکر ",
      ", breakers ")
  add("۔ باقی دشمن ",
      ". Enemies left ")
  add("۔ آپ نے مارے ",
      ". Kills ")
  add("۔ باری ",
      ". Turn ")
  add(" میٹر",
      " meters")
  add("دائیں",
      "right")
  add("بائیں",
      "left")
  add("، اس کے پاس ڈیفنس سسٹم ہے",
      ", has defense system")
  add("دشمن ",
      "Enemy ")
  add(" میٹر، ",
      " meters, ")
  add("قریب ترین دشمن ",
      "Nearest enemy ")
  add("دیوار! جزیرے کا کنارہ آ گیا",
      "Wall! Island edge")
  add("آپ محفوظ زون سے نکل گئے!",
      "You left the safe zone!")
  add("آپ واپس محفوظ زون میں آ گئے",
      "Back in the safe zone")
  add("پیچھے مڑ گئے",
      "Turned around")
  add("بائیں مڑ گئے",
      "Turned left")
  add("دائیں مڑ گئے",
      "Turned right")
  add("میگزین خالی ہے۔ ری لوڈ کریں",
      "Magazine empty. Reload")
  add("گولیاں ختم! ہتھیار بدلیں یا گولیاں ڈھونڈیں",
      "Out of ammo! Switch weapon or find ammo")
  add("دشمن کی طرف گیا جو ",
      "toward enemy ")
  add(" میٹر دور تھا",
      " meters away")
  add("سامنے تقریباً 40 میٹر پر گرا",
      "landed about 40 meters ahead")
  add("میزائل چلا، ",
      "Missile fired, ")
  add("آپ نے مکا مارا مگر سامنے کوئی نہیں تھا",
      "Punch hit nothing")
  add("گولی چلی مگر دشمن عین وقت پر جھکائی دے کر بچ گیا! اب وہ ",
      "Shot fired but the enemy dodged! Now ")
  add("نشانہ چوک گیا۔ دشمن ",
      "Missed. Enemy ")
  add("۔ سانس پھولی ہوئی تھی اس لیے نشانہ کمزور رہا",
      ". Out of breath, weak aim")
  add("دشمن ڈھیر ہو گیا! ",
      "Enemy down! ")
  add(" میٹر دور تھا۔ ",
      " meters. ")
  add("گولی لگ گئی! ",
      "Hit! ")
  add(" میٹر دور دشمن زخمی ہو گیا",
      " meters, enemy wounded")
  add("آپ کے پاس گرینیڈ نہیں",
      "You have no grenades")
  add("گرینیڈ ",
      "Grenade ")
  add(" میٹر آگے پھٹا۔ ",
      " meters ahead. ")
  add("۔ باقی گرینیڈ ",
      ". Grenades left ")
  add("آپ کے پاس ڈیفنس بریکر نہیں",
      "You have no defense breaker")
  add("ڈیفنس بریکر چل گیا! ",
      "Breaker fired! ")
  add(" دشمنوں کا ڈیفنس سسٹم تباہ ہو گیا۔ اب میزائل اور گرینیڈ ان " ..
      "پر پورا اثر کریں گے",
      " enemy defenses destroyed",
      " دشمنوں کے ڈیفنس تباہ")
  add("ڈیفنس بریکر چلا مگر 45 میٹر کے اندر کسی دشمن کے پاس ڈیفنس " ..
      "سسٹم نہیں تھا",
      "Breaker fired, but no enemy defense within 45 meters")
  add("۔ باقی بریکر ",
      ". Breakers left ")
  add("مکے ری لوڈ نہیں ہوتے",
      "Fists do not reload")
  add("میگزین پہلے سے بھرا ہوا ہے",
      "Magazine already full")
  add("اضافی گولیاں نہیں ہیں",
      "No spare bullets")
  add("ری لوڈ ہو گیا۔ ",
      "Reloaded. ")
  add(" اضافی",
      " spare")
  add("صحت پہلے ہی پوری ہے",
      "Health already full")
  add("میڈیکل کٹ استعمال کی، 50 صحت واپس ملی",
      "Medkit used, +50 health")
  add("پٹی لگائی، 20 صحت واپس ملی",
      "Bandage used, +20 health")
  add("آپ کے پاس علاج کا سامان نہیں",
      "No healing items")
  add("۔ اب آپ کی صحت ",
      ". Health now ")
  add(" ہے۔ باقی میڈیکل کٹ ",
      ". Medkits left ")
  add("آپ کے پاس صرف ایک ہتھیار ہے۔ ",
      "You have only one weapon. ")
  add("۔ دوسرا ہتھیار ڈھونڈ کر اٹھائیں",
      ". Find another")
  add("ہتھیار بدل لیا۔ ",
      "Switched. ")
  add("۔ آپ کے پاس کل ",
      ". You carry ")
  add(" ہتھیار ہیں، یہ نمبر ",
      " weapons, this is number ")
  add("خرابی: ",
      "Error: ")
  add("باہر نکل گئے",
      "Exited")
  add("ہتھیار: کوئی نہیں (صرف مکے)",
      "Weapon: none (fists)")
  add("\nگولیاں: ",
      "\nAmmo: ")
  add(" بھری ہوئی، ",
      " loaded, ")
  add("آپ کی صحت: ",
      "Health: ")
  add(" (100 کا مطلب پوری)\n",
      " out of 100\n")
  add("آرمر جیکٹ کا بچاؤ: ",
      "Armor: ")
  add("باقی دشمن: ",
      "Enemies left: ")
  add("\nآپ نے مارے: ",
      "\nYour kills: ")
  add("\nگزری ہوئی باریاں: ",
      "\nTurns passed: ")
  add("رک گئے۔ سانس پھولی ہوئی ہے",
      "Stopped. Out of breath")
  add("دوڑنے کی آواز سے قریبی دشمن چوکنا ہو گئے",
      "Running noise alerted nearby enemies")
  add("پریکٹس موڈ۔ ",
      "Practice mode. ")
  add("میچ شروع ہو گیا۔ ",
      "Match started. ")
  add(" دشمن جزیرے پر ہیں۔ ",
      " enemies on the island. ")
  add("آپ کے پاس پستول ہے، ",
      "You have a pistol, ")
  add("باہر نکلنے کے لیے Leave Game بٹن دبائیں",
      "Press Leave Game to exit")
  add("آپ میچ جیت گئے۔",
      "You won the match.")
  add("آپ ہار گئے۔",
      "You lost.")
  add(" آپ کا نمبر ",
      " Rank ")
  add("۔ مارے گئے دشمن ",
      ". Kills ")
  add("۔ باریاں ",
      ". Turns ")
  add("۔\nکل میچ ",
      ".\nMatches played ")
  add("، جیت ",
      ", wins ")
  add("، ایک میچ میں سب سے زیادہ دشمن مارے ",
      ", best kills in one match ")
  add("پہلے بائیں کان میں فائر کی آواز آئے گی، پھر دائیں میں",
      "Fire sound will play in the left ear first, then the right")
  add("ڈاؤن لوڈ شدہ فائل صرف ",
      "Downloaded file is only ")
  add(" بائٹ کی ہے",
      " bytes")
  add("فائل میں Lua کی خرابی ہے: ",
      "File has a Lua error: ")
  add("یہ فائل اس گیم کی main.lua نہیں لگتی",
      "This is not the game's main.lua")
  add("اپڈیٹ مکمل ہو گئی۔ ایکسٹینشن دوبارہ کھل رہی ہے",
      "Update done. Extension restarting")
  add("اپڈیٹ لگ گئی ہے مگر خود نہیں کھل سکی۔ براہ کرم ایکسٹینشن بند " ..
      "کر کے دوبارہ کھولیں",
      "Update installed but could not reopen itself. Close and " ..
      "reopen the extension",
      "اپڈیٹ لگ گئی مگر خود نہیں کھلی۔ ایکسٹینشن دوبارہ کھولیں")
  add("اپڈیٹ ڈاؤن لوڈ ہو رہی ہے، براہ کرم انتظار کریں۔ ایکسٹینشن " ..
      "بند نہ کریں",
      "Downloading update, please wait. Do not close the extension",
      "اپڈیٹ ڈاؤن لوڈ ہو رہی ہے، انتظار کریں")
  add("اپڈیٹ نہیں ہو سکی۔ پرانا ورژن محفوظ ہے",
      "Update failed. Old version is safe")
  add("۔ وجہ: ",
      ". Reason: ")
  add("ایکسٹینشن کی فائل مقررہ جگہ پر نہیں ملی۔ اپڈیٹ نہیں ہو سکی",
      "Extension file not found at the set path. Update failed")
  add("نئی فائل محفوظ نہیں ہو سکی۔ پرانا ورژن محفوظ ہے",
      "Could not save the new file. Old version is safe")
  add("اپڈیٹ لگاتے ہوئے خرابی ہوئی۔ پرانا ورژن بحال کر دیا گیا ہے",
      "Error while installing. Old version restored")
  add("اپڈیٹ کی جانچ پہلے سے جاری ہے",
      "Update check already running")
  add("اپڈیٹ جانچ رہے ہیں، براہ کرم انتظار کریں",
      "Checking for updates, please wait")
  add("اپڈیٹ کی جانچ نہیں ہو سکی۔ انٹرنیٹ چیک کریں اور دوبارہ کوشش " ..
      "کریں",
      "Update check failed. Check internet and try again")
  add("ورژن کی فائل درست نہیں",
      "Version file is not valid")
  add("آپ کے پاس تازہ ترین ورژن ",
      "You have the latest version ")
  add("کھیلے گئے میچ ",
      "Matches played ")
  add("۔ جیت ",
      ". Wins ")
  add("۔ ایک میچ میں سب سے زیادہ دشمن مارے ",
      ". Best kills in one match ")
  add("اپڈیٹ مکمل ہو گئی۔ اب آپ ورژن ",
      "Update done. You are now on version ")
  add(" استعمال کر رہے ہیں",
      "")

  -- weapon arrival texts
  add("ہتھیار اٹھائیں", "Pick weapon")
  add("، بہت دور", ", too far")
  add(" میٹر، بہت دور", " meters, too far")
  add("۔ ہتھیار کی مار ", ". Gun range ")
  add("فائر کیا مگر سامنے رینج میں کوئی دشمن نہیں تھا", "Fired, but no enemy ahead in range")
  add("دشمن زمین پر لیٹ گیا، گولی اوپر سے گزر گئی", "Enemy dropped flat, the bullet flew over")
  add("دشمن پتھر کے پیچھے چھپ گیا! اب وہ ", "Enemy dived behind cover! Now ")
  add("ہتھیار نہیں۔ جلد آئے گا، اس کی طرف سوائپ کریں", "No weapon. One will arrive soon, swipe toward it")
  add("سامان اٹھائیں", "Pick supplies")
  add(" گولیاں بھری ہیں۔ ہتھیار خود آئیں گے، ان کی طرف سوائپ کریں", " bullets loaded. Weapons arrive by themselves: swipe toward them")
  add("، سوائپ ", ", swipe ")
  add("اوپر", "up")
  add("نیچے", "down")
  add("غلط سمت", "Wrong way")
  add("ہتھیار ملا: ", "Got ")
  add("ہتھیار چھوٹ گیا", "Skipped")
  add("یہاں گولیوں کا ڈبہ ہے مگر آپ کے پاس ابھی کوئی ہتھیار نہیں۔ پہلے ہتھیار ڈھونڈیں",
      "Ammo box here, but you have no gun. Wait for a weapon",
      "گولیوں کا ڈبہ ہے مگر ہتھیار نہیں۔ ہتھیار آنے کا انتظار کریں")
  add("۔ دوسرا ہتھیار ڈھونڈ کر اٹھائیں",
      ". Wait for another",
      "۔ دوسرے کا انتظار کریں")
end

local WEAPON_UR = {}
local SECTOR_UR = {}
local STREAK_UR = {}
applyLanguage = function()
  for i, w in ipairs(WEAPONS) do
    if not WEAPON_UR[i] then WEAPON_UR[i] = { w.name, w.desc } end
    w.name = T(WEAPON_UR[i][1])
    w.desc = T(WEAPON_UR[i][2])
  end
  for k, v in pairs(SECTOR_NAMES) do
    SECTOR_UR[k] = SECTOR_UR[k] or v
    SECTOR_NAMES[k] = T(SECTOR_UR[k])
  end
  for k, v in pairs(STREAK) do
    STREAK_UR[k] = STREAK_UR[k] or v
    STREAK[k] = T(STREAK_UR[k])
  end
end

fillLanguages()

if not TEST then
  loadSettings()
  applyLanguage()
  showMainMenu()
  if readStorage("just_updated", "") ~= "" then
    saveStorage("just_updated", "")
    say(T("اپڈیٹ مکمل ہو گئی۔ اب آپ ورژن ") .. currentVersion() .. T(" استعمال کر رہے ہیں"))
  else
    later(3000, function() checkForUpdate(false) end)
  end
end
