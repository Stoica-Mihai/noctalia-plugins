-- Phone file transfer via KDE Connect (second widget of the phone plugin).
-- Left click mounts the phone's storage (SFTP, read-write) and opens it in a
-- file manager — drag files out to pull, drag files in to push, both directions
-- in one window. Only left click is used; noctalia reserves middle/right click.

local DISCOVER = "kdeconnect-cli -a --id-name-only 2>/dev/null | head -1"

local function refresh()
    noctalia.runAsync(DISCOVER .. " | cut -d' ' -f1", function(r)
        local id = (r.stdout or ""):match("%S+")
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
        local mountCheck = "busctl --user call org.kde.kdeconnect "
            .. "/modules/kdeconnect/devices/" .. id .. "/sftp "
            .. "org.kde.kdeconnect.device.sftp isMounted 2>/dev/null | awk '{print $2}'"
        noctalia.runAsync(mountCheck, function(m)
            local mounted = (m.stdout or ""):find("true") ~= nil
            barWidget.setVisible(true)
            barWidget.setGlyph(mounted and "folder" or "device-mobile")
            barWidget.setTooltip({
                { key = "Phone files", value = mounted and "mounted" or "click to open" },
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

-- Left click: discover the device, mount, wait for the storage path, open a
-- file manager there. Self-contained in shell (no dependency on cached state)
-- and detached via setsid so the file manager survives.
function onClick()
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

refresh()
