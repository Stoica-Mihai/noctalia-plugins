-- AC control panel: power toggle, mode buttons, target temperature slider.
-- Pure UI — the widget entry owns all device I/O. State flows through
-- noctalia.state: the widget publishes "status", this panel sends "command".

local MODE_LIST = { "auto", "cool", "dry", "heat", "fan" }
local MODE_ID = { auto = 1, cool = 2, dry = 3, heat = 4, fan = 5 }

local ERRORS = {
    nocli = "msmart-ng not installed",
    discover = "No AC found on the LAN",
}

local status = nil
local dragTarget = nil -- slider value while dragging, so re-renders don't fight the thumb

local function send(action, value)
    noctalia.state.set("command", { action = action, value = value, seq = os.clock() })
end

local rerender

function setPower(v)
    send("running", v == "true" and 1 or 0)
end

function targetDrag(v)
    dragTarget = math.floor(tonumber(v) + 0.5)
    rerender()
end

function targetCommit(v)
    dragTarget = nil
    send("target", math.floor(tonumber(v) + 0.5))
end

function modeAuto() send("mode", MODE_ID.auto) end
function modeCool() send("mode", MODE_ID.cool) end
function modeDry() send("mode", MODE_ID.dry) end
function modeHeat() send("mode", MODE_ID.heat) end
function modeFan() send("mode", MODE_ID.fan) end
local MODE_FN = { auto = "modeAuto", cool = "modeCool", dry = "modeDry", heat = "modeHeat", fan = "modeFan" }

local function message(text)
    return ui.column({ gap = 8, padding = 4 }, {
        ui.label({ text = "NetHome AC", fontWeight = "semibold" }),
        ui.separator({}),
        ui.label({ text = text }),
    })
end

rerender = function()
    if not status or status.kind == "absent" then
        panel.render(message("AC not reachable"))
        return
    end
    if status.kind == "error" then
        panel.render(message(ERRORS[status.err] or ("Error: " .. tostring(status.err))))
        return
    end

    local d = status.data
    local busy = status.pending ~= nil
    local target = dragTarget or d.target

    -- The device silently ignores mode commands while powered off (accepted,
    -- never applied), so the mode row is disabled when the AC is off.
    local modeButtons = {}
    for _, name in ipairs(MODE_LIST) do
        modeButtons[#modeButtons + 1] = ui.button({
            key = name,
            text = name,
            variant = (d.mode == MODE_ID[name]) and "default" or "ghost",
            enabled = not busy and d.running,
            flexGrow = 1,
            onClick = MODE_FN[name],
        })
    end

    local kids = {
        ui.row({ gap = 10, align = "center" }, {
            ui.label({ text = d.name or "AC", fontSize = 16, fontWeight = "semibold", flexGrow = 1 }),
            ui.toggle({ checked = d.running, enabled = not busy, onChange = "setPower" }),
        }),
        ui.separator({}),
        ui.label({ text = d.running and "Mode" or "Mode (turn on first)" }),
        ui.row({ gap = 6 }, modeButtons),
        ui.label({ text = "Target  " .. target .. "°" }),
        ui.slider({
            min = 16,
            max = 32,
            step = 1,
            value = target,
            enabled = not busy,
            onChange = "targetDrag",
            onDragEnd = "targetCommit",
        }),
    }
    if type(d.indoor) == "number" then
        kids[#kids + 1] = ui.row({ gap = 6 }, {
            ui.label({ text = "Indoor", flexGrow = 1 }),
            ui.label({ text = d.indoor .. "°" }),
        })
    end
    if busy then
        kids[#kids + 1] = ui.label({ text = status.pending, color = "tertiary" })
    end

    panel.render(ui.column({ gap = 10, padding = 4 }, kids))
end

noctalia.state.watch("status", function(s)
    status = s
    rerender()
end)

function onOpen()
    status = noctalia.state.get("status")
    dragTarget = nil
    rerender()
end

rerender()
