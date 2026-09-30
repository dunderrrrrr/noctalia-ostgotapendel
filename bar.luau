--!nonstrict
-- Ostgotapendeln Next Train bar widget - shows minutes until the next train,
-- fed by the shared state published by service.luau. Click forces a refresh.

local status = noctalia.state.get("ostgotapendeln.status") or "resolving"
local nextTrain = noctalia.state.get("ostgotapendeln.next")
local upcoming = noctalia.state.get("ostgotapendeln.upcoming") or {}
local originName = noctalia.state.get("ostgotapendeln.origin_name") or ""
local destName = noctalia.state.get("ostgotapendeln.destination_name") or ""
local errMsg = noctalia.state.get("ostgotapendeln.error")

local function clockTime(dep)
  if dep == nil or dep.realtime == nil then
    return nil
  end
  return dep.realtime:match("T(%d%d:%d%d)")
end

local function buildTooltip()
  if status == "no_key" then
    return noctalia.tr("tooltip.no_key")
  end
  if status == "resolving" then
    return noctalia.tr("tooltip.resolving")
  end
  if status == "error" then
    return noctalia.tr("tooltip.error", { message = errMsg or "" })
  end
  if #upcoming == 0 then
    return noctalia.tr("tooltip.no_departures", { origin = originName })
  end

  local lines = { `{originName} -> {destName}` }
  for _, dep in ipairs(upcoming) do
    local clock = dep.realtime and dep.realtime:match("T(%d%d:%d%d)") or "?"
    local line = dep.line or "?"
    local extra = ""
    if dep.canceled then
      extra = " (" .. noctalia.tr("canceled") .. ")"
    elseif (dep.delay_minutes or 0) > 0 then
      extra = ` (+{dep.delay_minutes} min)`
    end
    local platform = dep.platform and ` [{dep.platform}]` or ""
    table.insert(lines, `{clock}{platform} {line}{extra}`)
  end
  return table.concat(lines, "\n")
end

local function render()
  local showCountdown = noctalia.getConfig("show_countdown")
  if showCountdown == nil then
    showCountdown = true
  end

  barWidget.setGlyph("train")

  if status == "no_key" then
    barWidget.setText(noctalia.tr("bar.no_key"))
  elseif status == "resolving" then
    barWidget.setText(noctalia.tr("bar.resolving"))
  elseif status == "error" then
    barWidget.setText(noctalia.tr("bar.error"))
  elseif nextTrain == nil then
    barWidget.setText(noctalia.tr("bar.none"))
  elseif showCountdown then
    if nextTrain.canceled then
      barWidget.setText(noctalia.tr("bar.canceled"))
    else
      local time = clockTime(nextTrain) or "?"
      local nextTime = clockTime(upcoming[2])
      if nextTime ~= nil then
        barWidget.setText(`{time} {noctalia.tr("bar.next", { time = nextTime })}`)
      else
        barWidget.setText(time)
      end
    end
  else
    barWidget.setText("")
  end

  barWidget.setTooltip(buildTooltip())
end

noctalia.state.watch("ostgotapendeln.status", function(value)
  status = value
  render()
end)
noctalia.state.watch("ostgotapendeln.next", function(value)
  nextTrain = value
  render()
end)
noctalia.state.watch("ostgotapendeln.upcoming", function(value)
  upcoming = value or {}
  render()
end)
noctalia.state.watch("ostgotapendeln.origin_name", function(value)
  originName = value or ""
  render()
end)
noctalia.state.watch("ostgotapendeln.destination_name", function(value)
  destName = value or ""
  render()
end)
noctalia.state.watch("ostgotapendeln.error", function(value)
  errMsg = value
  render()
end)

function update()
  noctalia.setUpdateInterval(15000)
  render()
end

function onClick()
  noctalia.state.set("ostgotapendeln.cmd", { op = "refresh" })
  noctalia.notify(noctalia.tr("title"), noctalia.tr("bar.refreshing"))
end

render()
