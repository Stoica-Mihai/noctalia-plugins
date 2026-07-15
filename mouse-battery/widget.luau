-- Keychron mouse battery: polls battery.py (raw HID read) and shows glyph + percent.

local function glyphFor(percent, charging)
    if charging then
        return "battery-charging"
    end
    local level = math.floor(percent / 25 + 0.5)
    return "battery-" .. math.clamp(level, 0, 4)
end

-- One notification per below-threshold episode; re-arms above threshold or on charge.
local lowNotified = false

local function checkLow(percent, charging)
    local threshold = barWidget.getConfig("low_threshold") or 20
    if charging or percent > threshold then
        lowNotified = false
        return
    end
    if not lowNotified and barWidget.getConfig("notify_low") then
        noctalia.notifyError("Mouse battery low", percent .. "% remaining")
        lowNotified = true
    end
end

local function poll()
    local script = noctalia.pluginDir() .. "/battery.py"
    noctalia.runAsync("python3 " .. script, function(r)
        if r.exitCode ~= 0 or r.stdout == "" then
            barWidget.setVisible(false)
            return
        end
        local data = noctalia.json.decode(r.stdout)
        if not data or data.error or not data.percent then
            barWidget.setVisible(false)
            return
        end
        checkLow(data.percent, data.charging)
        barWidget.setVisible(true)
        barWidget.setGlyph(glyphFor(data.percent, data.charging))
        if barWidget.getConfig("show_percent") then
            barWidget.setText(data.percent .. "%")
        else
            barWidget.setText("")
        end
        barWidget.setTooltip({
            { key = "Mouse battery", value = data.percent .. "%" },
            { key = "Charging", value = data.charging and "yes" or "no" },
        })
    end)
end

noctalia.setUpdateInterval((barWidget.getConfig("poll_seconds") or 60) * 1000)

function update()
    poll()
end

function onConfigChanged()
    noctalia.setUpdateInterval((barWidget.getConfig("poll_seconds") or 60) * 1000)
    poll()
end

poll()
