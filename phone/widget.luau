-- Phone widget via KDE Connect: shows phone battery, click to ring.
-- Battery comes from the KDE Connect daemon over dbus; the phone needs the
-- KDE Connect app paired. Phone notifications are bridged by the daemon itself
-- into the system notification service — this widget doesn't handle those.

-- KDE Connect keeps a device flagged reachable for ~2 min after an abrupt
-- network drop (dead TCP socket not yet timed out), so its own flag is unreliable
-- for presence. Instead: take the daemon's device id + ip, then do a 1s TCP probe
-- to the KDE Connect port — a fresh connect fails fast when the phone is really
-- gone. Only emit battery JSON when the probe says the phone is actually there.
local GATHER = [[
line=$(kdeconnect-cli -a 2>/dev/null | head -1)
id=$(echo "$line" | grep -oE '[0-9a-f]{32}' | head -1)
ip=$(echo "$line" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)
if [ -n "$id" ] && [ -n "$ip" ]; then
  timeout 1 bash -c "exec 3<>/dev/tcp/$ip/1716" 2>/dev/null
  if [ $? -ne 124 ]; then
    name=$(echo "$line" | sed -n 's/^- \(.*\): [0-9a-f]\{32\}.*/\1/p')
    base="/modules/kdeconnect/devices/$id/battery"
    charge=$(busctl --user get-property org.kde.kdeconnect "$base" org.kde.kdeconnect.device.battery charge 2>/dev/null | awk '{print $2}')
    charging=$(busctl --user get-property org.kde.kdeconnect "$base" org.kde.kdeconnect.device.battery isCharging 2>/dev/null | awk '{print $2}')
    printf '{"id":"%s","name":"%s","charge":%s,"charging":%s}\n' "$id" "$name" "${charge:-null}" "${charging:-false}"
  fi
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

-- Notify on files received from the phone. The standalone daemon has no applet
-- to post these, so the widget does it. shareReceived carries the file URL.
noctalia.runStream(
    "dbus-monitor --session \"interface='org.kde.kdeconnect.device.share',member='shareReceived'\"",
    function(line)
        -- dbus-monitor emits its own NameAcquired/NameLost signals carrying bus
        -- names like ":1.1316" — ignore anything that isn't a real file path/URL.
        local url = line:match('string "(.-)"')
        if url and url:find("/") and not url:find("^:") and noctalia.getConfig("notify_received") then
            local name = noctalia.string.urlDecode(url:match("([^/]+)$") or url)
            noctalia.notify("Phone", "Received " .. name)
        end
    end
)

noctalia.setUpdateInterval(30000)

function update()
    poll()
end

function onConfigChanged()
    poll()
end

-- Left click does either action, per the click_action setting.
function onClick()
    local action = noctalia.getConfig("click_action") or "files"
    if action == "ring" then
        if phoneId then
            noctalia.runAsync("kdeconnect-cli --ring -d " .. phoneId)
        end
        return
    end
    if action == "files" then
        -- Discover in-shell (no dependency on cached id), mount, open a file
        -- manager at the phone's storage; detached via setsid so it survives.
        local sub = noctalia.getConfig("storage_subpath") or "storage/emulated/0"
        local cmd = table.concat({
            "id=$(kdeconnect-cli -a --id-name-only 2>/dev/null | head -1 | cut -d' ' -f1)",
            "[ -z \"$id\" ] && exit 0",
            "kdeconnect-cli --mount -d \"$id\"",
            "mp=$(kdeconnect-cli --get-mount-point -d \"$id\" 2>/dev/null)",
            "store=\"$mp/" .. sub .. "\"",
            "for i in $(seq 1 30); do ls \"$store\" >/dev/null 2>&1 && break; sleep 0.5; done",
            "for fm in nautilus dolphin thunar nemo pcmanfm caja; do "
                .. "command -v \"$fm\" >/dev/null 2>&1 && exec setsid -f \"$fm\" \"$store\"; done",
            "exec setsid -f xdg-open \"$store\"",
        }, "; ")
        noctalia.runAsync(cmd)
    end
end

poll()
