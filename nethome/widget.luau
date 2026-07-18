-- Midea AC via NetHome Plus: indoor temp in the bar, click toggles power.
-- One-time cloud discover caches ip/token/key to ~/.cache/noctalia-nethome/,
-- then every poll and command is a direct LAN exchange. V2-protocol devices
-- have no token/key (LAN is unauthenticated); the CLI still demands truthy
-- values, so dummies are passed.
local GATHER = [[
CACHE_DIR="$HOME/.cache/noctalia-nethome"
CACHE="$CACHE_DIR/device.env"

command -v midea-beautiful-air-cli >/dev/null 2>&1 || { echo '{"error":"nocli"}'; exit 0; }

field() { echo "$1" | sed -n "s/^  $2 *= *//p" | head -1; }
jesc() { echo "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
num() { case "$1" in ''|None) echo null ;; *) echo "$1" ;; esac; }
tok() { case "$1" in None) echo "" ;; *) echo "$1" ;; esac; }

if [ ! -s "$CACHE" ]; then
  if [ -z "$NH_ACCOUNT" ] || [ -z "$NH_PASSWORD" ]; then echo '{"error":"setup"}'; exit 0; fi
  out=$(timeout 60 midea-beautiful-air-cli discover --account "$NH_ACCOUNT" --password "$NH_PASSWORD" --credentials 2>/dev/null)
  ip=$(field "$out" addr); token=$(tok "$(field "$out" token)"); key=$(tok "$(field "$out" key)"); name=$(field "$out" name)
  if [ -z "$ip" ] || [ "$ip" = "Unknown" ]; then echo '{"error":"discover"}'; exit 0; fi
  umask 077; mkdir -p "$CACHE_DIR"
  printf 'IP=%q\nTOKEN=%q\nKEY=%q\nNAME=%q\n' "$ip" "$token" "$key" "$name" > "$CACHE"
fi

. "$CACHE"
out=$(timeout 25 midea-beautiful-air-cli status --ip "$IP" --token "${TOKEN:-0}" --key "${KEY:-0}" 2>/dev/null)
running=$(field "$out" running)
[ -z "$running" ] && { echo '{"error":"absent"}'; exit 0; }
low=$(echo "$running" | tr '[:upper:]' '[:lower:]')
printf '{"name":"%s","running":%s,"indoor":%s,"target":%s,"mode":%s}\n' \
  "$(jesc "${NAME:-AC}")" "$low" "$(num "$(field "$out" indoor)")" "$(num "$(field "$out" target)")" "$(num "$(field "$out" mode)")"
]]

-- The CLI's `set` is broken upstream (0.10.7 rejects its own pushtoken/deviceid
-- defaults as "not applicable options"), so power is toggled through the lib
-- with the venv's own python, resolved from the CLI shim.
local TOGGLE = [[
CACHE="$HOME/.cache/noctalia-nethome/device.env"
[ -s "$CACHE" ] || exit 0
. "$CACHE"
py="$(dirname "$(readlink -f "$(command -v midea-beautiful-air-cli)")")/python"
timeout 40 "$py" -c "
import sys, logging
logging.disable(logging.ERROR)
from midea_beautiful import appliance_state
a = appliance_state(address=sys.argv[1], token=sys.argv[2], key=sys.argv[3])
a.set_state(running=sys.argv[4] == '1')
" "$IP" "${TOKEN:-0}" "${KEY:-0}" "$NH_RUNNING" >/dev/null 2>&1
]]

local MODES = { [1] = "auto", [2] = "cool", [3] = "dry", [4] = "heat", [5] = "fan" }

local ERRORS = {
    nocli = "midea-beautiful-air-cli not found — uv tool install midea-beautiful-air",
    setup = "Set NetHome Plus account and password in the widget settings",
    discover = "NetHome Plus login/discover failed — check credentials and LAN",
}

local lastRunning = nil
local discoverNotified = false

local function shq(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- env prefix so credentials never get interpolated into the script body
local function withCreds(script)
    local account = noctalia.getConfig("account") or ""
    local password = noctalia.getConfig("password") or ""
    return "NH_ACCOUNT=" .. shq(account) .. " NH_PASSWORD=" .. shq(password) .. " " .. script
end

local function render(data)
    if not data or data.error or type(data.running) ~= "boolean" then
        lastRunning = nil
        local err = data and data.error
        if err == "discover" and not discoverNotified then
            noctalia.notifyError("NetHome AC", ERRORS.discover)
            discoverNotified = true
        end
        if err == "absent" or not err then
            if noctalia.getConfig("hide_when_absent") then
                barWidget.setVisible(false)
                return
            end
            barWidget.setVisible(true)
            barWidget.setGlyph("snowflake")
            barWidget.setText("")
            barWidget.setTooltip("AC not reachable")
            return
        end
        barWidget.setVisible(true)
        barWidget.setGlyph("snowflake")
        barWidget.setText("")
        barWidget.setTooltip(ERRORS[err] or ("NetHome error: " .. tostring(err)))
        return
    end

    discoverNotified = false
    lastRunning = data.running
    barWidget.setVisible(true)
    barWidget.setGlyph("snowflake")

    local showTemp = noctalia.getConfig("show_temp")
    local hasIndoor = type(data.indoor) == "number"
    barWidget.setText((showTemp and hasIndoor and data.running) and (data.indoor .. "°") or "")

    local rows = {
        { key = data.name or "AC", value = data.running and "on" or "off" },
    }
    if hasIndoor then
        rows[#rows + 1] = { key = "Indoor", value = data.indoor .. "°" }
    end
    if type(data.target) == "number" then
        rows[#rows + 1] = { key = "Target", value = data.target .. "°" }
    end
    if data.running and MODES[data.mode] then
        rows[#rows + 1] = { key = "Mode", value = MODES[data.mode] }
    end
    barWidget.setTooltip(rows)
end

-- Fast poll until first status (discover + slow V2 status can take ~40s), then settle.
local settled = false
local warmDeadline = os.time() + 60

local function poll()
    noctalia.runAsync(withCreds(GATHER), function(r)
        local data = nil
        local line = (r.stdout or ""):match("({.-})")
        if line then data = noctalia.json.decode(line) end
        render(data)
        if not settled and ((data and data.error == nil) or os.time() >= warmDeadline) then
            settled = true
            local secs = noctalia.getConfig("poll_interval") or 30
            noctalia.setUpdateInterval(secs * 1000)
        end
    end)
end

noctalia.setUpdateInterval(3000)

function update()
    poll()
end

-- Credential change invalidates the cached device; other settings just re-poll.
local lastCreds = nil

function onConfigChanged()
    local creds = (noctalia.getConfig("account") or "") .. "\n" .. (noctalia.getConfig("password") or "")
    if lastCreds ~= nil and creds ~= lastCreds then
        noctalia.runAsync('rm -f "$HOME/.cache/noctalia-nethome/device.env"', function()
            poll()
        end)
    else
        if settled then
            local secs = noctalia.getConfig("poll_interval") or 30
            noctalia.setUpdateInterval(secs * 1000)
        end
        poll()
    end
    lastCreds = creds
end

-- Left click toggles power from the last known state, then re-polls.
function onClick()
    if lastRunning == nil then return end
    local target = lastRunning and "0" or "1"
    noctalia.runAsync("NH_RUNNING=" .. target .. " " .. TOGGLE, function()
        poll()
    end)
end

lastCreds = (noctalia.getConfig("account") or "") .. "\n" .. (noctalia.getConfig("password") or "")
poll()
