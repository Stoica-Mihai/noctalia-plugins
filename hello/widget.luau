-- Minimal bar widget: shows "<greeting> HH:MM:SS", refreshed every second.

noctalia.setUpdateInterval(1000)

function update()
    local greeting = barWidget.getConfig("greeting") or "hello"
    barWidget.setText(greeting .. " " .. os.date("%H:%M:%S"))
    barWidget.setTooltip("mcs/hello example plugin")
end

update()
