-- Phone widget via KDE Connect: shows phone battery, click to ring.
-- Battery comes from the KDE Connect daemon over dbus; the phone needs the
-- KDE Connect app paired. Phone notifications are bridged by the daemon itself
-- into the system notification service — this widget doesn't handle those.

-- Reads the first paired+reachable device, then its battery via busctl.
local GATHER = [[
id=$(kdeconnect-cli -a --id-name-only 2>/dev/null | head -1 | cut -d' ' -f1)
if [ -n "$id" ]; then
  name=$(kdeconnect-cli -a --id-name-only 2>/dev/null | head -1 | cut -d' ' -f2-)
  base="/modules/kdeconnect/devices/$id/battery"
  charge=$(busctl --user get-property org.kde.kdeconnect "$base" org.kde.kdeconnect.device.battery charge 2>/dev/null | awk '{print $2}')
  charging=$(busctl --user get-property org.kde.kdeconnect "$base" org.kde.kdeconnect.device.battery isCharging 2>/dev/null | awk '{print $2}')
  printf '{"id":"%s","name":"%s","charge":%s,"charging":%s}\n' "$id" "$name" "${charge:-null}" "${charging:-false}"
fi
]]

local phoneId = nil
local lowNotified = false

local function checkLow(charge, charging)
    if not noctalia.getConfig("notify_low") then return end
    local threshold = noctalia.getConfig("low_threshold") or 15
    if charging or charge > threshold then
        lowNotified = false
    elseif not lowNotified then
        noctalia.notifyError("Phone battery low", charge .. "% remaining")
        lowNotified = true
    end
end

local function render(data)
    if not data or not data.id then
        phoneId = nil
        if noctalia.getConfig("hide_when_absent") then
            barWidget.setVisible(false)
        else
            barWidget.setVisible(true)
            barWidget.setGlyph("device-mobile")
            barWidget.setText("")
            barWidget.setTooltip("Phone not connected")
        end
        return
    end

    phoneId = data.id
    barWidget.setVisible(true)
    barWidget.setGlyph("device-mobile")

    if type(data.charge) ~= "number" then
        barWidget.setText("")
        barWidget.setTooltip(data.name .. " (no battery data)")
        return
    end

    checkLow(data.charge, data.charging == true)
    barWidget.setText(noctalia.getConfig("show_percent") and (data.charge .. "%") or "")
    barWidget.setTooltip({
        { key = data.name, value = data.charge .. "%" .. (data.charging and " +" or "") },
    })
end

local function poll()
    noctalia.runAsync(GATHER, function(r)
        local data = nil
        local line = (r.stdout or ""):match("({.-})")
        if line then data = noctalia.json.decode(line) end
        render(data)
    end)
end

-- Event-driven: KDE Connect emits dbus signals on battery change and
-- reachability change → refresh immediately. Poll below is the fallback.
noctalia.runStream(
    "dbus-monitor --session \"type='signal',interface='org.kde.kdeconnect.device.battery'\" "
        .. "\"type='signal',interface='org.kde.kdeconnect.device'\"",
    function(line)
        if line:find("refreshed") or line:find("eachable") then
            poll()
        end
    end
)

noctalia.setUpdateInterval(60000)

function update()
    poll()
end

function onConfigChanged()
    poll()
end

function onClick()
    if phoneId and noctalia.getConfig("ring_on_click") then
        noctalia.runAsync("kdeconnect-cli --ring -d " .. phoneId)
    end
end

poll()
