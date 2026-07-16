-- Phone file transfer via KDE Connect (second widget of the phone plugin).
--   left click : mount phone storage (SFTP) + open it in a file manager
--   right click: pick files via zenity and send them to the phone
--   middle click: unmount
-- The SFTP mount is read-write, so the file manager handles both directions;
-- right-click send is the quick push without opening anything.

local phoneId = nil

-- First paired + reachable device: "<id> <name>".
local DISCOVER =
    "kdeconnect-cli -a --id-name-only 2>/dev/null | head -1"

local function refresh()
    noctalia.runAsync(DISCOVER .. " | cut -d' ' -f1", function(r)
        local id = (r.stdout or ""):match("%S+")
        phoneId = id
        if not id then
            if noctalia.getConfig("hide_when_absent") then
                barWidget.setVisible(false)
            else
                barWidget.setVisible(true)
                barWidget.setGlyph("device-mobile")
                barWidget.setTooltip("Phone not connected")
            end
            return
        end
        -- Reflect mount state in the glyph.
        local mountCheck = "busctl --user call org.kde.kdeconnect "
            .. "/modules/kdeconnect/devices/" .. id .. "/sftp "
            .. "org.kde.kdeconnect.device.sftp isMounted 2>/dev/null | awk '{print $2}'"
        noctalia.runAsync(mountCheck, function(m)
            local mounted = (m.stdout or ""):find("true") ~= nil
            barWidget.setVisible(true)
            barWidget.setGlyph(mounted and "folder" or "device-mobile")
            barWidget.setTooltip({
                { key = "Phone files", value = mounted and "mounted" or "not mounted" },
                { key = "Left click", value = "browse" },
                { key = "Right click", value = "send files" },
                { key = "Middle click", value = "unmount" },
            })
        end)
    end)
end

noctalia.setUpdateInterval(60000)

function update()
    refresh()
end

function onConfigChanged()
    refresh()
end

-- Left click: mount, wait for the storage path, open it in a file manager.
function onClick()
    if not phoneId then return end
    local sub = noctalia.getConfig("storage_subpath") or "storage/emulated/0"
    local id = phoneId
    local cmd = table.concat({
        "kdeconnect-cli --mount -d " .. id,
        "mp=$(kdeconnect-cli --get-mount-point -d " .. id .. " 2>/dev/null)",
        "store=\"$mp/" .. sub .. "\"",
        "for i in $(seq 1 20); do ls \"$store\" >/dev/null 2>&1 && break; sleep 0.5; done",
        "for fm in nautilus dolphin thunar nemo pcmanfm caja; do "
            .. "command -v $fm >/dev/null 2>&1 && { \"$fm\" \"$store\" & exit 0; }; done",
        "xdg-open \"$store\"",
    }, "; ")
    noctalia.runAsync(cmd, function() refresh() end)
end

-- Right click: zenity multi-select → send each file to the phone.
function onRightClick()
    if not phoneId then return end
    local id = phoneId
    local cmd = "sel=$(zenity --file-selection --multiple --separator='\\n' "
        .. "--title='Send to phone' 2>/dev/null) || exit 0; "
        .. "printf '%s\\n' \"$sel\" | while IFS= read -r f; do "
        .. "[ -n \"$f\" ] && kdeconnect-cli --share \"$f\" -d " .. id .. "; done"
    noctalia.runAsync(cmd)
end

-- Middle click: unmount.
function onMiddleClick()
    if not phoneId then return end
    noctalia.runAsync(
        "busctl --user call org.kde.kdeconnect /modules/kdeconnect/devices/"
            .. phoneId .. "/sftp org.kde.kdeconnect.device.sftp unmount 2>/dev/null",
        function() refresh() end
    )
end

refresh()
