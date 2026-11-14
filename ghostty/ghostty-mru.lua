-- Improved version of the current/previous-tab script from
-- https://github.com/ghostty-org/ghostty/issues/1844#issuecomment-5745176407
--
-- Control+Tab: go to an older tab; Control+Shift+Tab: go to a newer tab;
-- release Control: commit the selection.
--
-- Initially discovers tabs once per window; optionally refreshes discovery on
-- each switching sequence (see below). Visited tabs keep their MRU order;
-- unseen tabs follow Ghostty's native window/tab order. Optionally maintains
-- MRU across multiple Ghostty windows (see below). History resets on reload
-- or app restart.
--
-- Requires Ghostty 1.3.0 or newer with AppleScript support enabled
-- (macos-applescript = true, the default).
--
-- Installation:
--
-- 1. Run brew install hammerspoon
-- 2. Save this script as ~/.hammerspoon/ghostty-mru.lua
-- 3. Add require("ghostty-mru") to ~/.hammerspoon/init.lua
-- 4. Reload Hammerspoon Config
-- 5. Grant Hammerspoon Accessibility and Automation permission for Ghostty
--
-- You may need to restart Hammerspoon after granting permissions.
--
-- Accessibility permission allows observing focus changes. Automation
-- permission allows querying Ghostty's stable window/tab IDs and selecting
-- tabs directly through its native AppleScript interface.
--
-- As in the original script, do not load hs.window.filter from init.lua
-- (Hammerspoon #3754).


-- Enable discovery of background tabs at the start of every switching sequence.
-- Normally, new tabs are created focused, so this extra discovery is not
-- needed. Enable it if you create tabs in the background. Initial discovery
-- runs on the first Control+Tab in each window; cross-window mode initially
-- discovers tabs in all windows.
local discoverBackgroundTabs = false

-- Keep Control+Tab within the current window unless explicitly enabled.
local switchAcrossWindows = false

-- Retry temporarily unavailable known tabs for this many seconds.
local recoveryRetrySeconds = 2


if ghosttyMRU then ghosttyMRU.stop() end
ghosttyMRU = {}
local M = ghosttyMRU
local ax = require("hs.axuielement")
local bundleID = "com.mitchellh.ghostty"
local types = hs.eventtap.event.types
local history, missing, seeded = {}, {}, {}
local session, attachedPID, swallowedTab
local lastError
local snapshotScript = [[
tell application id "com.mitchellh.ghostty"
  return {id of front window, id of selected tab of front window, id of windows, id of tabs of windows}
end tell]]
local focusScript = [[
tell application id "com.mitchellh.ghostty"
  return {id of front window, id of selected tab of front window}
end tell]]

local function run(script)
  local ok, result = hs.osascript.applescript("with timeout of 1 second\n" .. script .. "\nend timeout")
  if ok then lastError = nil; return result end
  -- A failed read must never turn the existing history into an empty snapshot.
  if not lastError then hs.printf("Ghostty MRU: native scripting temporarily unavailable") end
  lastError = true
end

local function promote(id)
  if not id then return end
  for i = #history, 1, -1 do
    if history[i] == id then table.remove(history, i) end
  end
  table.insert(history, 1, id)
  missing[id] = nil
end

local function readSnapshot()
  local result = run(snapshotScript)
  if type(result) ~= "table" or type(result[3]) ~= "table" or type(result[4]) ~= "table" or #result[3] ~= #result[4] then return nil end
  local state = { window = result[1], tab = result[2], windows = {}, owner = {}, order = result[3] }
  for i, id in ipairs(result[3]) do
    local tabs = result[4][i]
    if type(id) ~= "string" or type(tabs) ~= "table" then return nil end
    state.windows[id] = tabs
    for _, tab in ipairs(tabs) do
      if type(tab) ~= "string" then return nil end
      state.owner[tab] = id
    end
  end
  if state.owner[state.tab] ~= state.window then return nil end
  local now = hs.timer.absoluteTime() / 1e9
  for i = #history, 1, -1 do
    local id = history[i]
    if state.owner[id] then
      missing[id] = nil
    else
      missing[id] = missing[id] or now
      if now - missing[id] >= recoveryRetrySeconds then
        table.remove(history, i)
        missing[id] = nil
      end
    end
  end
  for id in pairs(seeded) do
    if not state.windows[id] then seeded[id] = nil end
  end
  return state
end

local function observeFocus()
  if session then return end
  local focus = run(focusScript)
  if type(focus) == "table" then promote(focus[2]) end
end

local function finish()
  if not session then return end
  session = nil
  observeFocus()
end

local function quote(value)
  return '"' .. value:gsub('\\', '\\\\'):gsub('"', '\\"') .. '"'
end

local function selectTab(id, window)
  -- Resolve the ID inside its current owner. A concurrent move makes this fail
  -- safely; it must never silently follow a tab into another window.
  local check = switchAcrossWindows and "" or
    "if id of front window is not " .. quote(window) .. " then return false\n"
  local activate = switchAcrossWindows and "activate window targetWindow\n" or ""
  return run('tell application id "' .. bundleID .. '"\n' .. check ..
    'set targetWindow to window id ' .. quote(window) .. '\n' ..
    'select tab (tab id ' .. quote(id) .. ' of targetWindow)\n' .. activate .. 'return true\nend tell') == true
end

local function step(direction)
  local state = readSnapshot()
  if not state or not state.owner[state.tab] then return false end
  if session and ((not switchAcrossWindows and session.window ~= state.window) or session.expected ~= state.tab) then
    session = nil
  end
  if not session then
    promote(state.tab)
    local known = {}
    for _, id in ipairs(history) do known[id] = true end
    for _, window in ipairs(state.order) do
      local tabs = state.windows[window]
      if (switchAcrossWindows or window == state.window) and (discoverBackgroundTabs or not seeded[window]) then
        for _, id in ipairs(tabs) do
          if not known[id] then history[#history + 1] = id; known[id] = true end
        end
        seeded[window] = true
      end
    end
    local items = {}
    for _, id in ipairs(history) do
      local owner = state.owner[id]
      if owner and (switchAcrossWindows or owner == state.window) then items[#items + 1] = id end
    end
    if #items < 2 then return true end
    session = { items = items, index = 1, window = state.window, expected = state.tab }
  end
  for _ = 1, #session.items do
    session.index = ((session.index - 1 + direction) % #session.items) + 1
    local id = session.items[session.index]
    local owner = state.owner[id]
    if id ~= state.tab and owner and (switchAcrossWindows or owner == state.window) then
      if selectTab(id, owner) then session.expected = id; return true end
      -- Do not try other tabs after an action failure: one keypress must never
      -- become a visible search. A later keypress gets a fresh snapshot.
      session = nil
      return true
    end
  end
  session = nil
  return true
end

local function attach(app)
  if not app or app:bundleID() ~= bundleID then return false end
  local pid = app:pid()
  if attachedPID == pid and M.observer then return true end
  if M.observer then M.observer:stop() end
  M.observer, attachedPID, session = nil, nil, nil
  history, missing, seeded = {}, {}, {}
  local observer
  local ok = pcall(function()
    local element = ax.applicationElement(app)
    observer = ax.observer.new(pid)
    observer:callback(observeFocus)
    observer:addWatcher(element, "AXMainWindowChanged")
    pcall(function() observer:addWatcher(element, "AXFocusedWindowChanged") end)
    observer:start()
  end)
  if not ok then
    if observer then pcall(function() observer:stop() end) end
    return false
  end
  M.observer, attachedPID = observer, pid
  observeFocus()
  return true
end

M.tap = hs.eventtap.new({ types.keyDown, types.keyUp, types.flagsChanged }, function(event)
  local kind, flags = event:getType(), event:getFlags()
  if kind == types.keyUp and event:getKeyCode() == hs.keycodes.map.tab then
    local handled = swallowedTab
    swallowedTab = false
    return handled or false
  end
  if session and not flags.ctrl then finish() end
  if kind ~= types.keyDown or event:getKeyCode() ~= hs.keycodes.map.tab or
    not flags.ctrl or flags.cmd or flags.alt then return false end
  local app = hs.application.frontmostApplication()
  if not attach(app) then return false end
  swallowedTab = step(flags.shift and -1 or 1)
  return swallowedTab
end):start()

M.watcher = hs.application.watcher.new(function(_, event, app)
  local watcher = hs.application.watcher
  if event == watcher.terminated then
    if app and app:pid() == attachedPID then
      if M.observer then M.observer:stop() end
      M.observer, attachedPID, session = nil, nil, nil
      history, missing, seeded = {}, {}, {}
    end
    return
  end
  if not app or app:bundleID() ~= bundleID then return end
  if event == watcher.launched or event == watcher.activated then attach(app)
  elseif event == watcher.deactivated then finish() end
end):start()

M.timer = hs.timer.doEvery(0.1, function()
  if session and not hs.eventtap.checkKeyboardModifiers().ctrl then finish() end
  if next(missing) then readSnapshot() end
end)

function M.stop()
  if M.tap then M.tap:stop() end
  if M.watcher then M.watcher:stop() end
  if M.observer then M.observer:stop() end
  if M.timer then M.timer:stop() end
end

attach(hs.application.get(bundleID))
