-- WiFi-only indicator: signal glyph + SSID, event-driven via nmcli monitor.

local QUERY = "nmcli radio wifi; echo ===; nmcli -t -f ACTIVE,SSID,SIGNAL dev wifi list --rescan no"
local MONITOR = "nmcli monitor"

-- Same signal bands as the shell's network_glyphs.cpp.
local function glyphForSignal(signal)
    if signal >= 80 then
        return "wifi"
    elseif signal >= 60 then
        return "wifi-3"
    elseif signal >= 35 then
        return "wifi-2"
    elseif signal >= 15 then
        return "wifi-1"
    end
    return "wifi-0"
end

local function parse(stdout)
    local enabled = stdout:match("^%s*(%S+)") == "enabled"
    local list = stdout:match("===\n(.*)$") or ""
    for line in list:gmatch("[^\n]+") do
        local ssid, signal = line:match("^yes:(.*):(%d+)$")
        if ssid then
            return enabled, ssid, tonumber(signal)
        end
    end
    return enabled, nil, nil
end

-- false = no baseline yet (never notify on startup state).
local lastSsid = false

local function notifyChange(ssid)
    if lastSsid ~= false and lastSsid ~= ssid and noctalia.getConfig("notify_events") then
        if ssid then
            noctalia.notify("WiFi", "Connected to " .. ssid)
        elseif lastSsid then
            noctalia.notify("WiFi", "Disconnected from " .. lastSsid)
        end
    end
    lastSsid = ssid
end

local function render(enabled, ssid, signal)
    if not enabled and noctalia.getConfig("hide_when_off") then
        barWidget.setVisible(false)
        return
    end
    barWidget.setVisible(true)

    if not enabled then
        barWidget.setGlyph("wifi-off")
        barWidget.setText("")
        barWidget.setTooltip("WiFi off")
        return
    end

    if not ssid then
        barWidget.setGlyph("wifi-question")
        barWidget.setText("")
        barWidget.setTooltip("Not connected")
        return
    end

    barWidget.setGlyph(glyphForSignal(signal))
    local parts = {}
    if noctalia.getConfig("show_ssid") then
        table.insert(parts, ssid)
    end
    if noctalia.getConfig("show_signal") then
        table.insert(parts, signal .. "%")
    end
    barWidget.setText(table.concat(parts, " "))
    barWidget.setTooltip({
        { key = ssid, value = signal .. "%" },
    })
end

local function refresh()
    noctalia.runAsync(QUERY, function(r)
        if r.exitCode ~= 0 then
            barWidget.setVisible(false)
            return
        end
        local enabled, ssid, signal = parse(r.stdout)
        notifyChange(ssid)
        render(enabled, ssid, signal)
    end)
end

noctalia.runStream(MONITOR, function(line)
    refresh()
end)

-- Fallback safety net; also refreshes the signal level periodically.
noctalia.setUpdateInterval(30000)

function update()
    refresh()
end

function onConfigChanged()
    refresh()
end

function onClick()
    noctalia.runAsync("noctalia msg panel-toggle control-center network")
end

function onRightClick()
    noctalia.runAsync("nmcli radio wifi | grep -q enabled && nmcli radio wifi off || nmcli radio wifi on")
end

refresh()
