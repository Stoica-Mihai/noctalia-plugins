-- Bluetooth glyph + always-visible connected-device count.
-- Event-driven: bluetoothctl monitor stream triggers refreshes; slow fallback
-- poll only as a safety net if the stream dies.

local QUERY = "bluetoothctl show | grep -m1 'Powered:'; echo ===; bluetoothctl devices Connected"
-- tail -f keeps stdin open; bluetoothctl -m quits on stdin EOF.
local MONITOR = "tail -f /dev/null | bluetoothctl -m"

local function parse(stdout)
    local powered = stdout:find("Powered:%s*yes") ~= nil
    local names = {}
    local devices = stdout:match("===\n(.*)$") or ""
    for line in devices:gmatch("[^\n]+") do
        local name = line:match("^Device%s+%S+%s+(.+)$")
        if name then
            table.insert(names, name)
        end
    end
    return powered, names
end

local function render(powered, names)
    local count = #names

    if not powered and barWidget.getConfig("hide_when_off") then
        barWidget.setVisible(false)
        return
    end
    barWidget.setVisible(true)

    if not powered then
        barWidget.setGlyph("bluetooth-off")
        barWidget.setText("")
        barWidget.setTooltip("Bluetooth off")
        return
    end

    if count > 0 then
        barWidget.setGlyph("bluetooth-connected")
        barWidget.setText(tostring(count))
        local rows = {}
        for _, name in ipairs(names) do
            table.insert(rows, { key = name, value = "connected" })
        end
        barWidget.setTooltip(rows)
    else
        barWidget.setGlyph("bluetooth")
        barWidget.setText(barWidget.getConfig("show_zero") and "0" or "")
        barWidget.setTooltip("No devices connected")
    end
end

-- nil until the first successful query so startup state never notifies.
local known = nil

local function notifyDiff(names)
    local current = {}
    for _, name in ipairs(names) do
        current[name] = true
    end
    if known ~= nil and barWidget.getConfig("notify_events") then
        for name in pairs(current) do
            if not known[name] then
                noctalia.notify("Bluetooth", name .. " connected")
            end
        end
        for name in pairs(known) do
            if not current[name] then
                noctalia.notify("Bluetooth", name .. " disconnected")
            end
        end
    end
    known = current
end

local function refresh()
    noctalia.runAsync(QUERY, function(r)
        if r.exitCode ~= 0 then
            barWidget.setVisible(false)
            return
        end
        local powered, names = parse(r.stdout)
        notifyDiff(names)
        render(powered, names)
    end)
end

-- Monitor lines carry ANSI codes; substring match survives them. NEW/DEL fire
-- for non-device objects too — the extra refreshes are one cheap query each.
noctalia.runStream(MONITOR, function(line)
    if line:find("Connected:") or line:find("Powered:") or line:find("NEW") or line:find("DEL") then
        refresh()
    end
end)

noctalia.setUpdateInterval(60000)

function update()
    refresh()
end

function onConfigChanged()
    refresh()
end

function onClick()
    -- Same target as the built-in widget: control center, bluetooth section.
    noctalia.runAsync("noctalia msg panel-toggle control-center bluetooth")
end

function onRightClick()
    noctalia.runAsync("bluetoothctl show | grep -qm1 'Powered: yes' && bluetoothctl power off || bluetoothctl power on")
end

refresh()
