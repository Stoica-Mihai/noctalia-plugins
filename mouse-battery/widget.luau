-- Battery Monitor: aggregates every peripheral battery into one bar widget.
--   * upower devices (game controllers, BT headsets/keyboards, anything with a battery)
--   * Keychron mouse via raw HID (battery.py) — the one thing upower can't see
-- Shows the lowest battery by default; scroll to cycle devices. Low-battery
-- notifications are per-device and persist across restarts (pluginDataDir).

local STATE_FILE = noctalia.pluginDataDir() .. "/notified.json"

local function batteryGlyph(percent, charging)
    if charging then
        return "battery-charging"
    end
    local level = math.floor(percent / 25 + 0.5)
    return "battery-" .. math.clamp(level, 0, 4)
end

-- One shell call gathers all upower batteries + the mouse HID reading.
local function gatherCommand()
    local script = noctalia.pluginDir() .. "/battery.py"
    return "for d in $(upower -e | grep battery); do echo \"DEV $d\"; upower -i \"$d\"; done; "
        .. "echo MOUSE; python3 " .. script .. " 2>/dev/null; true"
end

local function parse(stdout)
    local devices = {}
    local cur = nil
    local inMouse = false
    for line in (stdout .. "\n"):gmatch("(.-)\n") do
        if line:sub(1, 4) == "DEV " then
            cur = { id = line:sub(5), name = "Battery", percent = nil, charging = false }
            table.insert(devices, cur)
            inMouse = false
        elseif line == "MOUSE" then
            cur = nil
            inMouse = true
        elseif inMouse then
            local data = noctalia.json.decode(line)
            if data and data.percent then
                table.insert(devices, {
                    id = "keychron-mouse", name = "Mouse",
                    percent = data.percent, charging = data.charging == true,
                })
            end
        elseif cur then
            local model = line:match("^%s*model:%s*(.+)$")
            local pct = line:match("^%s*percentage:%s*(%d+)")
            local state = line:match("^%s*state:%s*(%S+)")
            if model then cur.name = model end
            if pct then cur.percent = tonumber(pct) end
            if state then cur.charging = (state == "charging" or state == "fully-charged") end
        end
    end
    -- Drop upower entries that never reported a percentage.
    local out = {}
    for _, d in ipairs(devices) do
        if d.percent then table.insert(out, d) end
    end
    table.sort(out, function(a, b) return a.percent < b.percent end)
    return out
end

-- ── persisted per-device low-notify state ──
local notified = {}
do
    local body = noctalia.readFile(STATE_FILE)
    if body then
        local ok = noctalia.json.decode(body)
        if type(ok) == "table" then notified = ok end
    end
end

local function saveNotified()
    noctalia.writeFile(STATE_FILE, noctalia.json.encode(notified))
end

local function checkLow(devices)
    if not noctalia.getConfig("notify_low") then return end
    local threshold = noctalia.getConfig("low_threshold") or 20
    local changed = false
    for _, d in ipairs(devices) do
        if d.charging or d.percent > threshold then
            if notified[d.id] then notified[d.id] = nil; changed = true end
        elseif not notified[d.id] then
            noctalia.notifyError("Battery low", d.name .. " at " .. d.percent .. "%")
            notified[d.id] = true
            changed = true
        end
    end
    if changed then saveNotified() end
end

-- ── display ──
local lastDevices = {}
local selected = 1

local function render()
    local devices = lastDevices
    if #devices == 0 then
        barWidget.setVisible(false)
        return
    end
    barWidget.setVisible(true)
    if selected > #devices then selected = 1 end
    local d = devices[selected]

    barWidget.setGlyph(batteryGlyph(d.percent, d.charging))
    barWidget.setText(noctalia.getConfig("show_percent") and (d.percent .. "%") or "")

    local rows = {}
    for _, dev in ipairs(devices) do
        local marker = (dev == d) and "▸ " or "  "
        local val = dev.percent .. "%" .. (dev.charging and " +" or "")
        table.insert(rows, { key = marker .. dev.name, value = val })
    end
    barWidget.setTooltip(rows)
end

local function poll()
    noctalia.runAsync(gatherCommand(), function(r)
        lastDevices = parse(r.stdout or "")
        checkLow(lastDevices)
        render()
    end)
end

noctalia.setUpdateInterval((noctalia.getConfig("poll_seconds") or 60) * 1000)

function update()
    poll()
end

function onConfigChanged()
    noctalia.setUpdateInterval((noctalia.getConfig("poll_seconds") or 60) * 1000)
    poll()
end

-- Scroll over the widget to cycle which device is shown.
function onScroll(_axis, steps)
    if #lastDevices == 0 then return end
    local dir = steps > 0 and 1 or -1
    selected = ((selected - 1 + dir) % #lastDevices) + 1
    render()
end

poll()
