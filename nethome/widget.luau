-- Midea AC via NetHome Plus: indoor temp in the bar, click opens the control
-- panel. This entry owns all device I/O — polling, commands, and pending
-- confirmation — and shares with the panel through noctalia.state: it
-- publishes "status" and executes "command" requests.
--
-- One-time cloud discover caches ip/token/key to ~/.cache/noctalia-nethome/,
-- then every poll and command is a direct LAN exchange. V2-protocol devices
-- have no token/key (LAN is unauthenticated); the CLI still demands truthy
-- values, so dummies are passed.
--
-- Discover (~40-60s) and status (~11s on devices that never answer the
-- capabilities query) run as separate runAsync calls: each needs its own
-- timeout budget, and runAsync defaults to 5s.
--
-- V2 devices are flaky: polls sometimes time out and sometimes return a
-- zeroed frame (running=False, target=0, indoor=denormal). A single bad poll
-- must not flap the widget, so results go through a validity check and the
-- last good state is kept until several polls in a row fail.

-- Ensures the device cache exists. Prints {"ok":true} when cache is ready,
-- an {"error":...} JSON otherwise. Discover stderr lands in discover.log.
local DISCOVER = [[
CACHE_DIR="$HOME/.cache/noctalia-nethome"
CACHE="$CACHE_DIR/device.env"

command -v midea-beautiful-air-cli >/dev/null 2>&1 || { echo '{"error":"nocli"}'; exit 0; }
[ -s "$CACHE" ] && { echo '{"ok":true}'; exit 0; }

field() { echo "$1" | sed -n "s/^  $2 *= *//p" | head -1; }
tok() { case "$1" in None) echo "" ;; *) echo "$1" ;; esac; }

if [ -z "$NH_ACCOUNT" ] || [ -z "$NH_PASSWORD" ]; then echo '{"error":"setup"}'; exit 0; fi
umask 077; mkdir -p "$CACHE_DIR"
out=$(midea-beautiful-air-cli discover --account "$NH_ACCOUNT" --password "$NH_PASSWORD" --credentials 2>"$CACHE_DIR/discover.log")
ip=$(field "$out" addr); token=$(tok "$(field "$out" token)"); key=$(tok "$(field "$out" key)"); name=$(field "$out" name)
if [ -z "$ip" ] || [ "$ip" = "Unknown" ]; then echo '{"error":"discover"}'; exit 0; fi
printf 'IP=%q\nTOKEN=%q\nKEY=%q\nNAME=%q\n' "$ip" "$token" "$key" "$name" > "$CACHE"
echo '{"ok":true}'
]]

-- LAN status from the cached device. Prints one JSON line.
local STATUS = [[
CACHE="$HOME/.cache/noctalia-nethome/device.env"
[ -s "$CACHE" ] || { echo '{"error":"absent"}'; exit 0; }
. "$CACHE"

field() { echo "$1" | sed -n "s/^  $2 *= *//p" | head -1; }
jesc() { echo "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
num() { case "$1" in ''|None) echo null ;; *) echo "$1" ;; esac; }

out=$(midea-beautiful-air-cli status --ip "$IP" --token "${TOKEN:-0}" --key "${KEY:-0}" 2>/dev/null)
running=$(field "$out" running)
if [ -z "$running" ]; then
  # Protocol failed — TCP probe splits device-busy (present, refuses another
  # session) from truly gone.
  if timeout 1 bash -c "exec 3<>/dev/tcp/$IP/6444" 2>/dev/null; then
    echo '{"error":"busy"}'
  else
    echo '{"error":"absent"}'
  fi
  exit 0
fi
low=$(echo "$running" | tr '[:upper:]' '[:lower:]')
printf '{"name":"%s","running":%s,"indoor":%s,"target":%s,"mode":%s}\n' \
  "$(jesc "${NAME:-AC}")" "$low" "$(num "$(field "$out" indoor)")" "$(num "$(field "$out" target)")" "$(num "$(field "$out" mode)")"
]]

-- Applies NH_SET ("running=1", "mode=2", "target_temperature=21") to the
-- device. The CLI's `set` is broken upstream (0.10.7 rejects its own
-- pushtoken/deviceid defaults as "not applicable options"), so commands go
-- through the lib with the venv's own python, resolved from the CLI shim.
local SET = [[
CACHE="$HOME/.cache/noctalia-nethome/device.env"
[ -s "$CACHE" ] || exit 0
. "$CACHE"
py="$(dirname "$(readlink -f "$(command -v midea-beautiful-air-cli)")")/python"
"$py" -c "
import sys, logging
logging.disable(logging.ERROR)
from midea_beautiful import appliance_state
a = appliance_state(address=sys.argv[1], token=sys.argv[2], key=sys.argv[3])
kw = {}
for kv in sys.argv[4].split(','):
    k, v = kv.split('=')
    if k == 'running':
        kw[k] = v == '1'
    elif k == 'target_temperature':
        kw[k] = float(v)
    else:
        kw[k] = int(v)
a.set_state(**kw)
" "$IP" "${TOKEN:-0}" "${KEY:-0}" "$NH_SET" >/dev/null 2>&1
]]

local MODES = { [1] = "auto", [2] = "cool", [3] = "dry", [4] = "heat", [5] = "fan" }

local ERRORS = {
    nocli = "midea-beautiful-air-cli not found — uv tool install midea-beautiful-air",
    setup = "Set NetHome Plus account and password in the widget settings",
    discover = "NetHome Plus login/discover failed — check credentials and LAN",
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

local function shq(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- env prefix so credentials never get interpolated into the script body
local function withCreds(script)
    local account = noctalia.getConfig("account") or ""
    local password = noctalia.getConfig("password") or ""
    return "NH_ACCOUNT=" .. shq(account) .. " NH_PASSWORD=" .. shq(password) .. " " .. script
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
        lastGood = d
        fails = 0
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
        if not lastGood then
            barWidget.setVisible(true)
            barWidget.setGlyph("snowflake")
            barWidget.setGlyphColor("outline")
            barWidget.setText("")
            barWidget.setTooltip("AC busy, retrying…")
        end
        return false
    end
    if err == "nocli" or err == "setup" or err == "discover" then
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
    if polling then return end
    polling = true
    noctalia.runAsync(withCreds(DISCOVER), function(r)
        local d = decode(r.stdout)
        if not d or d.error then
            polling = false
            settle(onResult(d))
            return
        end
        noctalia.runAsync(STATUS, function(r2)
            polling = false
            settle(onResult(decode(r2.stdout)))
        end, 30000)
    end, 60000)
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
        kv = "mode=" .. value
        label = "Mode " .. MODES[value] .. "…"
        match = { key = "mode", value = value }
    elseif action == "target" and value >= 16 and value <= 32 then
        kv = "target_temperature=" .. value
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

-- Credential change invalidates the cached device; other settings just re-poll.
local lastCreds = nil

function onConfigChanged()
    local creds = (noctalia.getConfig("account") or "") .. "\n" .. (noctalia.getConfig("password") or "")
    if lastCreds ~= nil and creds ~= lastCreds then
        lastGood = nil
        fails = 0
        configErr = nil
        pending = nil
        discoverNotified = false
        applyInterval()
        publish()
        noctalia.runAsync('rm -f "$HOME/.cache/noctalia-nethome/device.env"', function()
            poll()
        end)
    else
        applyInterval()
        poll()
    end
    lastCreds = creds
end

-- Left click opens the control panel (power/mode/temperature live there).
function onClick()
    noctalia.togglePanel("mcs/nethome:controls")
end

lastCreds = (noctalia.getConfig("account") or "") .. "\n" .. (noctalia.getConfig("password") or "")

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
