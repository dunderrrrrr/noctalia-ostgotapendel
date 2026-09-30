--!nonstrict
-- Ostgotapendeln Next Train service - resolves the origin/destination stop
-- ids by name via the Trafiklab Stop Lookup API (cached to disk), polls the
-- Trafiklab Timetables departures endpoint for the origin stop, then for
-- each candidate train confirms direction by fetching Trip Details and
-- checking whether the destination stop appears later in that trip's call
-- list (Kimstad is an intermediate stop on the Norrkoping-Linkoping-Mjolby
-- line, not a terminus, so route.destination alone can't tell us direction).
--
-- State published:
--   ostgotapendeln.status = "ok" | "no_key" | "resolving" | "error"
--   ostgotapendeln.error   = "<message>" (when status == "error")
--   ostgotapendeln.origin_name / destination_name = configured names
--   ostgotapendeln.next = { line, destination, scheduled, realtime,
--                            delay_minutes, platform, canceled, minutes_until }
--   ostgotapendeln.upcoming = { <up to 5 of the above>, ... }
--
-- IPC / state cmd: "refresh" forces an immediate poll.

local API_BASE = "https://realtime-api.trafiklab.se/v1"

local function cachePath()
  local dir = noctalia.pluginDataDir()
  if dir == nil then
    return nil
  end
  return dir .. "/cache.json"
end

-- cache.stops: { [name] = stop_id }
-- cache.trip_stop_ids: { [trip_id] = { [stop_id] = true, ... } } (which stops a trip calls at)
local cache = { stops = {}, trip_stop_ids = {} }

local function loadCache()
  local path = cachePath()
  if path == nil then
    return
  end
  local raw = noctalia.readFile(path)
  if raw == nil then
    return
  end
  local decoded = noctalia.json.decode(raw)
  if type(decoded) == "table" then
    cache.stops = decoded.stops or {}
    cache.trip_stop_ids = decoded.trip_stop_ids or {}
  end
end

local function saveCache()
  local path = cachePath()
  if path == nil then
    return
  end
  local encoded = noctalia.json.encode(cache)
  if encoded ~= nil then
    noctalia.writeFile(path, encoded)
  end
end

local function setStatus(status, err)
  noctalia.state.set("ostgotapendeln.status", status)
  noctalia.state.set("ostgotapendeln.error", err)
end

local pendingStop = {} -- names currently being resolved

-- Stop Lookup's /stops/name/{search} does a loose match and can return many
-- stop groups (bus stops, meta-groups, the actual station, ...) for a broad
-- query. Score each candidate so we land on the real train station rather
-- than whichever group happened to sort first.
--
-- area_type dominates the score: only a RIKSHALLPLATS is a valid area_id for
-- the Timetables departures endpoint. META_STOP is a looser grouping (e.g.
-- "Linkoping" bundling the bus terminal with the station) that can share the
-- exact query text without being queryable for departures, so it must never
-- outscore a RIKSHALLPLATS purely on name closeness.
local function scoreStopGroup(group, wantedName)
  local score = 0
  local groupName = tostring(group.name or ""):lower()
  local wanted = wantedName:lower()

  if group.area_type == "RIKSHALLPLATS" then
    score += 1000
  end

  local modes = group.transport_modes
  if type(modes) == "table" then
    for _, mode in ipairs(modes) do
      if tostring(mode):upper() == "TRAIN" then
        score += 100
        break
      end
    end
  end

  if groupName == wanted then
    score += 10
  elseif groupName:find(wanted, 1, true) ~= nil or wanted:find(groupName, 1, true) ~= nil then
    score += 4
  end

  return score
end

-- Resolves a stop name to a stop-group id, using the cache first, then the
-- Stop Lookup API (picking the best-scoring group, not just the first
-- result). Calls cb(id, err).
local function resolveStop(apiKey, name, cb)
  local cached = cache.stops[name]
  if cached ~= nil then
    cb(cached)
    return
  end
  if pendingStop[name] then
    return
  end
  pendingStop[name] = true

  local url = API_BASE .. "/stops/name/" .. noctalia.string.urlEncode(name) .. "?key=" .. noctalia.string.urlEncode(apiKey)
  noctalia.http({ url = url, method = "GET" }, function(res)
    pendingStop[name] = nil
    if not res.ok or res.status ~= 200 then
      cb(nil, `lookup failed (HTTP {res.status})`)
      return
    end
    local decoded = noctalia.json.decode(res.body)
    if type(decoded) ~= "table" or type(decoded.stop_groups) ~= "table" or #decoded.stop_groups == 0 then
      cb(nil, `no stop found for "{name}"`)
      return
    end

    local best = nil
    local bestScore = -1
    for _, group in ipairs(decoded.stop_groups) do
      local score = scoreStopGroup(group, name)
      if score > bestScore then
        bestScore = score
        best = group
      end
    end

    if best == nil or best.id == nil then
      cb(nil, `no stop id for "{name}"`)
      return
    end
    cache.stops[name] = best.id
    saveCache()
    cb(best.id)
  end)
end

-- Trafiklab's timestamps ("2026-09-29T16:30:00") are Europe/Stockholm wall
-- clock time with no offset suffix. os.time() in this runtime builds epoch
-- seconds from broken-out fields as if they were UTC, so feeding it these
-- fields directly is off by Stockholm's UTC offset (+1h CET / +2h CEST).
-- Derive that offset dynamically (so it's correct across the DST switch)
-- by asking noctalia.formatTime what "now" looks like in Stockholm, then
-- diffing that wall-clock reading (interpreted the same naive way) against
-- the real current epoch.
local function stockholmOffsetSeconds()
  local nowEpoch = math.floor(noctalia.nowMs() / 1000)
  local stamp = noctalia.formatTime("%Y-%m-%d %H:%M:%S", nowEpoch, "Europe/Stockholm")
  local y, mo, d, h, mi, s = stamp:match("(%d+)-(%d+)-(%d+) (%d+):(%d+):(%d+)")
  if y == nil then
    return 0
  end
  local naiveLocalAsUtc = os.time({
    year = tonumber(y),
    month = tonumber(mo),
    day = tonumber(d),
    hour = tonumber(h),
    min = tonumber(mi),
    sec = tonumber(s),
  })
  return naiveLocalAsUtc - nowEpoch
end

local function minutesUntil(isoTime)
  if isoTime == nil then
    return nil
  end
  local y, mo, d, h, mi, s = isoTime:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if y == nil then
    return nil
  end
  local naiveTarget = os.time({
    year = tonumber(y),
    month = tonumber(mo),
    day = tonumber(d),
    hour = tonumber(h),
    min = tonumber(mi),
    sec = tonumber(s),
  })
  local target = naiveTarget - stockholmOffsetSeconds()
  local now = math.floor(noctalia.nowMs() / 1000)
  return math.floor((target - now) / 60)
end

-- destName is the configured destination stop (e.g. "Kimstad") - what the
-- user actually cares about. dep.route.destination is the *train's* final
-- terminus (e.g. "Norrkoping" or "Tranas"), which every listed entry passes
-- through en route but isn't the stop the user asked about, so it's kept
-- separately as train_destination for context rather than shown as the
-- headline destination.
local function buildEntry(dep, destName)
  local scheduled = dep.scheduled
  local realtime = dep.realtime or scheduled
  local delaySeconds = dep.delay or 0
  local platform = nil
  if dep.scheduled_platform ~= nil then
    platform = dep.scheduled_platform.designation
  end
  if dep.realtime_platform ~= nil and dep.realtime_platform.designation ~= nil then
    platform = dep.realtime_platform.designation
  end
  local trainDestination = nil
  if dep.route ~= nil and dep.route.destination ~= nil then
    trainDestination = dep.route.destination.name
  end
  local line = nil
  if dep.route ~= nil then
    line = dep.route.designation
  end
  return {
    line = line,
    destination = destName,
    train_destination = trainDestination,
    scheduled = scheduled,
    realtime = realtime,
    delay_minutes = math.floor(delaySeconds / 60),
    platform = platform,
    canceled = dep.canceled == true,
    minutes_until = minutesUntil(realtime),
  }
end

-- route.transport_mode is the human-readable mode string (e.g. "TRAIN",
-- "BUS"); route.transport_mode_code is the numeric GTFS extended route
-- type (rail codes are 100-199). Check the string first - it's
-- unambiguous - and only fall back to the numeric range if the string is
-- missing, since a numeric code must never be compared as if it were text.
local function isTrain(dep)
  if dep.route == nil then
    return false
  end
  if type(dep.route.transport_mode) == "string" then
    return dep.route.transport_mode:upper() == "TRAIN"
  end
  local code = tonumber(dep.route.transport_mode_code)
  if code ~= nil then
    return code >= 100 and code < 200
  end
  return true -- unknown mode: don't drop it
end

-- Fetches (or returns from cache) the trip's stop sequence as
-- { [area_id] = call_index }, 1-based in call order. Calls cb(sequence|nil).
local function tripSequence(apiKey, tripId, startDate, cb)
  local known = cache.trip_stop_ids[tripId]
  if known ~= nil then
    cb(known)
    return
  end

  local url = API_BASE .. "/trips/" .. noctalia.string.urlEncode(tripId) .. "/" .. startDate .. "?key=" .. noctalia.string.urlEncode(apiKey)
  noctalia.http({ url = url, method = "GET" }, function(res)
    if not res.ok or res.status ~= 200 then
      cb(nil)
      return
    end
    local decoded = noctalia.json.decode(res.body)
    if type(decoded) ~= "table" or type(decoded.calls) ~= "table" then
      cb(nil)
      return
    end
    -- area_id is the stop-group id (same space as Stop Lookup / Timetables
    -- area_id), not the per-platform call.stop.id.
    local sequence = {}
    for index, call in ipairs(decoded.calls) do
      if call.stop ~= nil and call.stop.area_id ~= nil then
        sequence[call.stop.area_id] = index
      end
    end
    cache.trip_stop_ids[tripId] = sequence
    saveCache()
    cb(sequence)
  end)
end

-- A trip only counts if it calls at destStopId strictly after originId in
-- its stop sequence - calling at both isn't enough, since a stop between
-- two termini (like Kimstad on the Norrkoping-Linkoping-Tranas line) is
-- passed in both directions by trips that continue past the origin.
local function tripGoesTowards(apiKey, tripId, startDate, originStopId, destStopId, cb)
  tripSequence(apiKey, tripId, startDate, function(sequence)
    if sequence == nil then
      cb(false)
      return
    end
    local originIndex = sequence[originStopId]
    local destIndex = sequence[destStopId]
    cb(originIndex ~= nil and destIndex ~= nil and destIndex > originIndex)
  end)
end

local function publish(entries)
  table.sort(entries, function(a, b)
    return (a.minutes_until or math.huge) < (b.minutes_until or math.huge)
  end)
  local limited = {}
  for i = 1, math.min(5, #entries) do
    table.insert(limited, entries[i])
  end
  noctalia.state.set("ostgotapendeln.upcoming", limited)
  noctalia.state.set("ostgotapendeln.next", limited[1])
  setStatus("ok", nil)
end

local function poll(apiKey, originId, destId, destName)
  local url = API_BASE .. "/departures/" .. noctalia.string.urlEncode(originId) .. "?key=" .. noctalia.string.urlEncode(apiKey)
  noctalia.http({ url = url, method = "GET" }, function(res)
    if not res.ok or res.status ~= 200 then
      setStatus("error", `departures request failed (HTTP {res.status})`)
      return
    end
    local decoded = noctalia.json.decode(res.body)
    if type(decoded) ~= "table" or type(decoded.departures) ~= "table" then
      setStatus("error", "unexpected response from Trafiklab")
      return
    end

    local candidates = {}
    for _, dep in ipairs(decoded.departures) do
      if isTrain(dep) and dep.trip ~= nil and dep.trip.trip_id ~= nil then
        table.insert(candidates, dep)
      end
    end

    if #candidates == 0 then
      publish({})
      return
    end

    local results = {}
    local remaining = #candidates
    local function finish()
      remaining -= 1
      if remaining <= 0 then
        publish(results)
      end
    end

    for _, dep in ipairs(candidates) do
      local startDate = dep.trip.start_date
      if startDate == nil and dep.scheduled ~= nil then
        startDate = dep.scheduled:match("^(%d%d%d%d%-%d%d%-%d%d)")
      end
      if startDate == nil then
        finish()
      else
        tripGoesTowards(apiKey, dep.trip.trip_id, startDate, originId, destId, function(goesTowards)
          if goesTowards then
            table.insert(results, buildEntry(dep, destName))
          end
          finish()
        end)
      end
    end
  end)
end

local originId = nil
local destId = nil

local function tick()
  local apiKey = noctalia.string.trim(noctalia.getConfig("api_key") or "")
  local originName = noctalia.string.trim(noctalia.getConfig("origin_name") or "")
  local destName = noctalia.string.trim(noctalia.getConfig("destination_name") or "")

  noctalia.state.set("ostgotapendeln.origin_name", originName)
  noctalia.state.set("ostgotapendeln.destination_name", destName)

  if apiKey == "" then
    setStatus("no_key", nil)
    return
  end
  if originName == "" or destName == "" then
    setStatus("error", "origin and destination stop names must both be set")
    return
  end

  if originId == nil or destId == nil then
    setStatus("resolving", nil)
    resolveStop(apiKey, originName, function(id, err)
      if id == nil then
        setStatus("error", err or "could not resolve origin stop")
        return
      end
      originId = id
      resolveStop(apiKey, destName, function(id2, err2)
        if id2 == nil then
          setStatus("error", err2 or "could not resolve destination stop")
          return
        end
        destId = id2
        poll(apiKey, originId, destId, destName)
      end)
    end)
    return
  end

  poll(apiKey, originId, destId, destName)
end

function update()
  local pollSeconds = tonumber(noctalia.getConfig("poll_seconds")) or 30
  noctalia.setUpdateInterval(math.max(15, pollSeconds) * 1000)
  tick()
end

local function forceRefresh()
  originId = nil
  destId = nil
  tick()
end

function onIpc(event)
  if event == "refresh" then
    forceRefresh()
  end
end

noctalia.state.watch("ostgotapendeln.cmd", function(cmd)
  if type(cmd) == "table" and cmd.op == "refresh" then
    forceRefresh()
  end
  noctalia.state.set("ostgotapendeln.cmd", nil)
end)

loadCache()
tick()
