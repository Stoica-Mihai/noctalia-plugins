-- Sets the wallpaper from a per-weather-condition folder, driven by noctalia's
-- own weather cache (~/.cache/noctalia/weather.json) — no extra API calls.

local CACHE = "~/.cache/noctalia/weather.json"
local EXTS = { jpg = true, jpeg = true, png = true, webp = true }

math.randomseed(os.time())

-- WMO weather code + day flag -> wallpaper folder name.
local function category(code, isDay)
    if code >= 95 then
        return "storm"
    elseif code >= 71 and code <= 77 or code == 85 or code == 86 then
        return "snow"
    elseif code >= 51 and code <= 67 or code >= 80 and code <= 82 then
        return "rain"
    elseif code == 45 or code == 48 then
        return "fog"
    elseif code >= 2 and code <= 3 then
        return "cloudy"
    end
    return isDay and "clear-day" or "clear-night"
end

local function imagesIn(dir)
    local names = noctalia.listDir(dir)
    if not names then
        return {}
    end
    local out = {}
    for _, name in ipairs(names) do
        local ext = name:match("%.([A-Za-z]+)$")
        if ext and EXTS[ext:lower()] then
            table.insert(out, dir .. "/" .. name)
        end
    end
    return out
end

local lastCategory = nil
local lastWallpaper = nil

local function apply(cat)
    local root = noctalia.getConfig("wallpapers_dir")
    if not root or root == "" then
        return
    end
    local pool = imagesIn(root .. "/" .. cat)
    if #pool == 0 then
        pool = imagesIn(root .. "/default")
    end
    if #pool == 0 then
        noctalia.log("weather wallpaper: no images for '" .. cat .. "' and no default/ fallback")
        return
    end
    local pick = pool[math.random(#pool)]
    if pick == lastWallpaper and #pool > 1 then
        pick = pool[math.random(#pool)]
    end
    lastWallpaper = pick
    noctalia.setWallpaper(pick)
    noctalia.log("weather wallpaper: '" .. cat .. "' -> " .. pick)
end

local function check()
    local body = noctalia.readFile(CACHE)
    if not body then
        return
    end
    local data = noctalia.json.decode(body)
    local current = data and data.snapshot and data.snapshot.current
    if not current or not current.weather_code then
        return
    end
    local cat = category(current.weather_code, current.is_day)
    if cat ~= lastCategory or noctalia.getConfig("rotate_within_condition") then
        lastCategory = cat
        apply(cat)
    end
end

noctalia.setUpdateInterval((noctalia.getConfig("check_minutes") or 5) * 60 * 1000)

function update()
    check()
end

function onConfigChanged()
    noctalia.setUpdateInterval((noctalia.getConfig("check_minutes") or 5) * 60 * 1000)
    lastCategory = nil
    check()
end

check()
