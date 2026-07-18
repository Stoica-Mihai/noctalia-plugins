-- Midea AC in the bar: indoor temp, click opens the control panel. This
-- entry owns all device I/O — polling, commands, pending confirmation — and
-- shares with the panel through noctalia.state: it publishes "status" and
-- executes "command" requests.
--
-- Everything runs on msmart-ng over the LAN. Discovery is a UDP broadcast
-- (no cloud, no account): V2 devices have no LAN auth at all. The device
-- REQUIRES the B5 capabilities handshake before it accepts control commands
-- — msmart-ng performs it on the command path.
--
-- The wifi module is fragile: single protocol session at a time, wedges
-- under pressure (once needed a mains power-cycle), occasionally times out.
-- Hence: hard floor between sessions, busy-vs-absent TCP probe, last-good
-- state kept through flaky polls, command retries with confirmation.

-- Broadcast-discovers the first AC on the LAN and caches ip/id/ssid.
-- Prints {"ok":true} when the cache is ready, {"error":...} otherwise.
local DISCOVER = [[
CACHE_DIR="$HOME/.cache/noctalia-nethome"
CACHE="$CACHE_DIR/device.env"

command -v msmart-ng >/dev/null 2>&1 || { echo '{"error":"nocli"}'; exit 0; }
[ -s "$CACHE" ] && grep -q '^ID=' "$CACHE" && { echo '{"ok":true}'; exit 0; }

umask 077; mkdir -p "$CACHE_DIR"
py="$(dirname "$(readlink -f "$(command -v msmart-ng)")")/python"
out=$("$py" -c "
import asyncio
from msmart.discover import Discover
from msmart.device import AirConditioner

async def main():
    for d in await Discover.discover(discovery_packets=2):
        if isinstance(d, AirConditioner):
            print(d.ip, d.id, d.name or 'AC')
            return

asyncio.run(main())
" 2>"$CACHE_DIR/discover.log")
set -- $out
if [ -z "$1" ] || [ -z "$2" ]; then echo '{"error":"discover"}'; exit 0; fi
ip=$1; id=$2; shift 2; name=$*
printf 'IP=%q\nID=%q\nNAME=%q\n' "$ip" "$id" "${name:-AC}" > "$CACHE"
echo '{"ok":true}'
]]

-- LAN status from the cached device. Prints one JSON line.
-- LAN status via msmart refresh (~1.3s). Prints one JSON line; on protocol
-- failure a TCP probe splits device-busy (present) from truly gone.
local STATUS = [[
CACHE="$HOME/.cache/noctalia-nethome/device.env"
[ -s "$CACHE" ] || { echo '{"error":"absent"}'; exit 0; }
. "$CACHE"
[ -z "$ID" ] && { echo '{"error":"absent"}'; exit 0; }

py="$(dirname "$(readlink -f "$(command -v msmart-ng)")")/python"
out=$("$py" -c "
import asyncio, json, sys
from msmart.device import AirConditioner as AC

async def main():
    d = AC(ip=sys.argv[1], port=6444, device_id=int(sys.argv[2]))
    await d.refresh()
    print(json.dumps({'name': sys.argv[3], 'running': bool(d.power_state),
                      'indoor': d.indoor_temperature, 'target': d.target_temperature,
                      'mode': int(d.operational_mode)}))

asyncio.run(main())
" "$IP" "$ID" "${NAME:-AC}" 2>/dev/null)
if [ -z "$out" ]; then
  if timeout 1 bash -c "exec 3<>/dev/tcp/$IP/6444" 2>/dev/null; then
    echo '{"error":"busy"}'
  else
    echo '{"error":"absent"}'
  fi
  exit 0
fi
echo "$out"
]]

-- Applies NH_SET ("running=1", "mode=2", "target_temperature=21"). The
-- capabilities handshake before apply is mandatory — without it the device
-- accepts the frame and ignores it.
local SET = [[
CACHE="$HOME/.cache/noctalia-nethome/device.env"
[ -s "$CACHE" ] || exit 0
. "$CACHE"
[ -z "$ID" ] && exit 0
py="$(dirname "$(readlink -f "$(command -v msmart-ng)")")/python"
"$py" -c "
import asyncio, sys
from msmart.device import AirConditioner as AC

async def main():
    d = AC(ip=sys.argv[1], port=6444, device_id=int(sys.argv[2]))
    await d.get_capabilities()
    # apply() sends the FULL state back, and this device sometimes answers
    # refresh with a zeroed frame — applying on top of that pushes power=off
    # and garbage target. Never apply over an invalid refresh.
    for _ in range(3):
        await d.refresh()
        if d.target_temperature and 16 <= d.target_temperature <= 32:
            break
        await asyncio.sleep(1)
    else:
        sys.exit(1)
    for kv in sys.argv[3].split(','):
        k, v = kv.split('=')
        if k == 'running':
            d.power_state = v == '1'
        elif k == 'target_temperature':
            d.target_temperature = float(v)
        elif k == 'mode':
            d.operational_mode = AC.OperationalMode(int(v))
    await d.apply()

asyncio.run(main())
" "$IP" "$ID" "$NH_SET" >/dev/null 2>&1
]]

local MODES = { [1] = "auto", [2] = "cool", [3] = "dry", [4] = "heat", [5] = "fan" }

local ERRORS = {
    nocli = "msmart-ng not found — uv tool install msmart-ng",
    discover = "No AC found on the LAN",
}

-- Last good frame + consecutive bad polls; hide only past FAIL_LIMIT.
local FAIL_LIMIT = 3
local lastGood = nil
local fails = 0
local configErr = nil
local discoverNotified = false

-- In-flight command awaiting confirmation by a status frame matching the
-- commanded field. The device flakily drops set commands (all protocol
-- retries exhausted), so the command is re-sent — up to MAX_ATTEMPTS — each
-- time a status frame comes back still unconfirmed.
local pending = nil -- { label, match = { key, value }, kv, attempts, inFlight, deadline }
local PENDING_TIMEOUT = 60
local MAX_ATTEMPTS = 3
-- Braille cell spinner: constant single-char footprint, dots orbit the 2x4 grid.
local SPIN = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local spinIx = 0

local settled = false
local warmDeadline = os.time() + 90
local polling = false
-- The wifi module wedges under session pressure (needed a mains power-cycle
-- once): keep a hard floor between protocol sessions and re-discover only
-- after a long absent streak (e.g. the device came back on a new IP).
local MIN_POLL_GAP = 8
local lastPollDone = 0
local absentStreak = 0
local REDISCOVER_AFTER = 10

local function shq(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- Zeroed flaky-device frames carry target=0; real Midea targets are 16-32.
local function validFrame(d)
    return d ~= nil and d.error == nil and type(d.running) == "boolean"
        and type(d.target) == "number" and d.target >= 16 and d.target <= 32
end

local function matches(d, m)
    if m.key == "running" then
        return d.running == (m.value == 1)
    end
    return d[m.key] == m.value
end

local fireSet -- defined after poll; re-sends the pending command

-- Panel-facing snapshot of everything the widget knows.
local function publish()
    local p = pending and pending.label or nil
    if lastGood then
        noctalia.state.set("status", { kind = "data", data = lastGood, pending = p })
    elseif configErr then
        noctalia.state.set("status", { kind = "error", err = configErr, pending = p })
    else
        noctalia.state.set("status", { kind = "absent", pending = p })
    end
end

-- One tick source: fast while pending (spinner), warm-up 3s, else poll_interval.
local function applyInterval()
    if pending then
        noctalia.setUpdateInterval(250)
    elseif settled then
        noctalia.setUpdateInterval((noctalia.getConfig("poll_interval") or 30) * 1000)
    else
        noctalia.setUpdateInterval(3000)
    end
end

local function renderData(d)
    barWidget.setVisible(true)
    barWidget.setGlyph("snowflake")
    barWidget.setGlyphColor("on_surface")

    local showTemp = noctalia.getConfig("show_temp")
    local hasIndoor = type(d.indoor) == "number"
    barWidget.setText((showTemp and hasIndoor and d.running) and (d.indoor .. "°") or "")

    local rows = {
        { key = d.name or "AC", value = d.running and "on" or "off" },
    }
    if hasIndoor then
        rows[#rows + 1] = { key = "Indoor", value = d.indoor .. "°" }
    end
    rows[#rows + 1] = { key = "Target", value = d.target .. "°" }
    if d.running and MODES[d.mode] then
        rows[#rows + 1] = { key = "Mode", value = MODES[d.mode] }
    end
    barWidget.setTooltip(rows)
end

local function renderPending()
    barWidget.setVisible(true)
    barWidget.setGlyph("snowflake")
    barWidget.setGlyphColor("tertiary")
    spinIx = spinIx % #SPIN + 1
    barWidget.setText(SPIN[spinIx])
    barWidget.setTooltip(pending.label)
end

local function renderAbsent()
    if noctalia.getConfig("hide_when_absent") then
        barWidget.setVisible(false)
        return
    end
    barWidget.setVisible(true)
    barWidget.setGlyph("snowflake")
    barWidget.setGlyphColor("on_surface")
    barWidget.setText("")
    barWidget.setTooltip("AC not reachable")
end

local function renderConfigError(err)
    barWidget.setVisible(true)
    barWidget.setGlyph("snowflake")
    barWidget.setGlyphColor("on_surface")
    barWidget.setText("")
    barWidget.setTooltip(ERRORS[err] or ("NetHome error: " .. tostring(err)))
end

-- Routes a poll result: good frame renders and resets the failure streak,
-- config errors render immediately, flaky results keep the last good frame
-- until FAIL_LIMIT consecutive misses. While a command is pending, only a
-- frame matching the commanded field clears it; stale frames are stored but
-- the pending display stays. Returns true for a good frame.
local function onResult(d)
    if validFrame(d) then
        local cfgName = noctalia.getConfig("device_name") or ""
        if cfgName ~= "" then d.name = cfgName end
        lastGood = d
        fails = 0
        absentStreak = 0
        configErr = nil
        discoverNotified = false
        if pending then
            if matches(d, pending.match) then
                pending = nil
                applyInterval()
                renderData(d)
            elseif not pending.inFlight then
                fireSet()
            end
            publish()
            return true
        end
        renderData(d)
        publish()
        return true
    end

    local err = d and d.error
    -- Busy = the AC answers TCP but refused the protocol session (another
    -- client, or mid-command). It is present: never hide, keep last state.
    if err == "busy" then
        fails = 0
        absentStreak = 0
        if not lastGood then
            barWidget.setVisible(true)
            barWidget.setGlyph("snowflake")
            barWidget.setGlyphColor("outline")
            barWidget.setText("")
            barWidget.setTooltip("AC busy, retrying…")
        end
        return false
    end
    if err == "nocli" or err == "discover" then
        lastGood = nil
        fails = 0
        configErr = err
        pending = nil
        applyInterval()
        if err == "discover" and not discoverNotified then
            noctalia.notifyError("NetHome AC", ERRORS.discover)
            discoverNotified = true
        end
        renderConfigError(err)
        publish()
        return false
    end

    fails = fails + 1
    absentStreak = absentStreak + 1
    if absentStreak == REDISCOVER_AFTER then
        noctalia.runAsync('rm -f "$HOME/.cache/noctalia-nethome/device.env"')
    end
    if (lastGood or pending) and fails < FAIL_LIMIT then
        return false
    end
    pending = nil
    lastGood = nil
    configErr = nil
    applyInterval()
    renderAbsent()
    publish()
    return false
end

local function decode(stdout)
    local line = (stdout or ""):match("({.-})")
    if line then return noctalia.json.decode(line) end
    return nil
end

local function settle(gotData)
    if not settled and (gotData or os.time() >= warmDeadline) then
        settled = true
        applyInterval()
    end
end

local function poll()
    if polling or os.time() - lastPollDone < MIN_POLL_GAP then return end
    polling = true
    noctalia.runAsync(DISCOVER, function(r)
        local d = decode(r.stdout)
        if not d or d.error then
            polling = false
            lastPollDone = os.time()
            settle(onResult(d))
            return
        end
        noctalia.runAsync(STATUS, function(r2)
            polling = false
            lastPollDone = os.time()
            settle(onResult(decode(r2.stdout)))
        end, 15000)
    end, 20000)
end

-- Sends (or re-sends) the pending command, then polls for confirmation.
fireSet = function()
    if not pending or pending.attempts >= MAX_ATTEMPTS then return end
    pending.attempts = pending.attempts + 1
    pending.inFlight = true
    noctalia.runAsync("NH_SET=" .. shq(pending.kv) .. " " .. SET, function()
        if pending then pending.inFlight = false end
        poll()
    end, 60000)
end

-- Executes a panel command: sends it to the device and shows the pending
-- spinner until a status frame confirms the commanded field.
local function runCommand(action, value)
    if pending or not lastGood or type(value) ~= "number" then return end
    local kv, label, match
    if action == "running" then
        kv = "running=" .. value
        label = value == 1 and "Turning on…" or "Turning off…"
        match = { key = "running", value = value }
    elseif action == "mode" and MODES[value] then
        -- modes are only clickable while on; pin running so a lying refresh
        -- can't power the unit off as a side effect
        kv = "running=1,mode=" .. value
        label = "Mode " .. MODES[value] .. "…"
        match = { key = "mode", value = value }
    elseif action == "target" and value >= 16 and value <= 32 then
        kv = "running=" .. (lastGood.running and 1 or 0) .. ",target_temperature=" .. value
        label = "Target " .. value .. "°…"
        match = { key = "target", value = value }
    else
        return
    end
    pending = { label = label, match = match, kv = kv, attempts = 0, deadline = os.time() + PENDING_TIMEOUT }
    applyInterval()
    renderPending()
    publish()
    fireSet()
end

noctalia.state.watch("command", function(cmd)
    if type(cmd) == "table" and cmd.action then
        runCommand(cmd.action, tonumber(cmd.value))
    end
end)

noctalia.setUpdateInterval(3000)

function update()
    if pending then
        if os.time() >= pending.deadline then
            pending = nil
            applyInterval()
            noctalia.notify("NetHome AC", "Command not confirmed")
            if lastGood then renderData(lastGood) else renderAbsent() end
            publish()
        else
            renderPending()
        end
    end
    poll()
end

function onConfigChanged()
    applyInterval()
    if lastGood then renderData(lastGood) end
    publish()
    poll()
end

-- Left click opens the control panel (power/mode/temperature live there).
function onClick()
    noctalia.togglePanel("mcs/nethome:controls")
end

-- Appearance tweaks reload this entry with a fresh runtime; the state store
-- survives in the shell process, so restore the last frame instead of sitting
-- invisible until the first slow poll lands. True cold start shows the glyph
-- with a connecting hint rather than nothing.
local restored = noctalia.state.get("status")
if restored and restored.kind == "data" and validFrame(restored.data) then
    lastGood = restored.data
    renderData(lastGood)
else
    barWidget.setVisible(true)
    barWidget.setGlyph("snowflake")
    barWidget.setGlyphColor("outline")
    barWidget.setText("")
    barWidget.setTooltip("Connecting to AC…")
end
publish()
poll()
