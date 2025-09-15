-- Copyright (C) 2015, 2017 Florian Wesch <fw@dividuum.de>
-- All Rights Reserved.
--
-- Modified node.lua with modern box style and expired showtime removal
-- Modified node.lua with modern box style, rounded corners, and fade-in animations

util.no_globals()

local json = require "json"
local scissors = sys.get_ext "scissors"

local st
local image_files = {}
local loaded_images = {}
local rotation = 0
local bload_threshold = 3600
local bload_fallback = resource.load_image "empty.png"
local screen_idx, screen_cnt
local logo

local function mipmapped_image(filename)
    return resource.load_image(filename, true)
end
util.loaders.jpg = mipmapped_image
util.loaders.png = mipmapped_image

local res = util.resource_loader({
    "font.ttf";
    "threed.png";
    "showtime.png";
}, {})

-- UI colors
local bgfill = resource.create_colored_texture(0.15, 0.15, 0.15, 1)
local fgfill = resource.create_colored_texture(0.25, 0.25, 0.25, 1)
local infofill = resource.create_colored_texture(1, 1, 1, 0.08)

-- Rounded shader
local rounded_shader = resource.create_shader[[
    uniform sampler2D Texture;
    varying vec2 TexCoord;
    uniform vec4 color;
    uniform float radius;
    void main() {
        vec2 pos = TexCoord * 2.0 - 1.0;
        float dist = length(pos);
        if (dist > 1.0) discard;
        gl_FragColor = texture2D(Texture, TexCoord) * color;
    }
]]

local base_time = N.base_time or 0

local function current_offset()
    return (base_time + sys.now()) % 86400 / 60
end

util.data_mapper{
    ["clock/set"] = function(time)
        base_time = tonumber(time) - sys.now()
        N.base_time = base_time
    end;
}

local bload = (function()
    local function strip(s) return s:match "^%s*(.-)%s*$" end
    local function hhmm(s)
        local h, m = tonumber(s:sub(1,2)), tonumber(s:sub(3,4))
        return {
            hour = h, minute = m, offset = h*60 + m,
            string = ((h-1)%12+1)..":"..("%02d"):format(m)..(h<12 and "am" or "")
        }
    end
    local function tobool(s) return tonumber(s) == 1 end
    local function convert(names, conv, ...) local r={} for i=1,#conv do r[names[i]]=conv[i]((...)[i]) end return r end

    local sorted_movies = {}
    local movies_on_screen = 1
    local bload_data, date

    local function parse()
        if not (bload_data and date) then return end
        local movies = {}
        for line in bload_data:gmatch("[^\r\n]+") do
            local row = convert({"screen", "show", "showtime", "runtime", "sold", "seats", "threed", "mpaa", "name"},
                {strip, tonumber, hhmm, tonumber, tonumber, tonumber, tobool, strip, strip},
                line:match("(..) (..) (....) (...)  (....) (....) (.) (....)(.*)")
            )
            if not movies[row.name] then movies[row.name] = {} end
            table.insert(movies[row.name], row)
        end

        local tmp = {}
        for name, shows in pairs(movies) do
            table.sort(shows, function(a,b) return a.showtime.offset < b.showtime.offset end)
            table.insert(tmp, {
                name = name,
                image = name:gsub('[^%w]', ''):lower(),
                mpaa = shows[1].mpaa,
                threed = shows[1].threed,
                shows = shows
            })
        end
        table.sort(tmp, function(a,b) return a.name < b.name end)
        
        movies_on_screen = math.ceil(#tmp / screen_cnt)
        local s,e = movies_on_screen*(screen_idx-1)+1, movies_on_screen*screen_idx
        sorted_movies = {}
        for i=s,e do if tmp[i] then table.insert(sorted_movies, tmp[i]) end end
    end

    return {
        set_bload = function(b) if b ~= bload_data then bload_data = b; parse() end end,
        set_date = function(d) if d ~= date then date = d; parse() end end,
        get_sorted_movies = function() return sorted_movies end,
        get_movies_on_screen = function() return movies_on_screen end
    }
end)()

util.json_watch("config.json", function(config)
    image_files, loaded_images = {}, {}
    gl.setup(1920, 1080)
    
    rotation = config.rotation or 0
    local setup_rot = config.__metadata.device_data.rotation
    if setup_rot and setup_rot ~= -1 then rotation = setup_rot end

    st = util.screen_transform(rotation)
    for _,img in ipairs(config.images) do
        image_files[img.file.filename:lower():gsub('.jpg',''):gsub('[^%w]','')] = resource.open_file(img.file.asset_name)
    end
    bload_threshold = config.bload_threshold
    bload_fallback = resource.load_image(config.bload_fallback.asset_name)

    local split = config.__metadata.device_data.split
    screen_idx, screen_cnt = split and split[1] or 1, split and split[2] or 1

    logo = resource.load_image{file = config.logo.asset_name, mipmap = true}
    bload.force_parse()
    node.gc()
end)

util.file_watch("BLOAD.txt", bload.set_bload)
util.data_mapper{ ["date/set"] = function(date) bload.set_date(date) end }

local function show_bload()
    local movies = bload.get_sorted_movies()
    local cols = 3
    local rows = math.ceil(#movies / cols)
    local cw, ch = WIDTH / cols, HEIGHT / rows
    local now = current_offset()
    local alpha = math.min(1, sys.now() % 2) -- simple fade pulse

    for idx = 1, #movies do
        local x = (idx-1)%cols * cw
        local y = math.floor((idx-1)/cols) * ch
        local m = movies[idx]

        rounded_shader:use{color={1,1,1,alpha}, radius=0.03}
        bgfill:draw(x+5, y+5, x+cw-5, y+ch-5)
        rounded_shader:deactivate()

        local img_y = y + 5
        local split = math.min(ch-160, ch*0.55)
        local img = loaded_images[m.image]
        if not img and image_files[m.image] then
            loaded_images[m.image] = resource.load_image{file = image_files[m.image]:copy()}
            img = loaded_images[m.image]
        end
        if img then
            img:draw(x+5, y+5, x+cw-5, y+split)
        else
            local size, width = 60, 9999
            while width > cw - 10 do size = size - 5; width = res.font:width(m.name, size) end
            res.font:write(x+(cw-width)/2, y+(split-size)/2, m.name, size, 1,1,1,alpha)
        end

        infofill:draw(x+1, split, x+cw-1, split+40)
        local w = res.font:width(m.mpaa, 30)
        local ix = x + (cw - (w + (m.threed and 70 or 0))) / 2
        res.font:write(ix, split+5, m.mpaa, 30, 1,1,1,alpha)
        if m.threed then res.threed:draw(ix + w + 10, split+5, ix + w + 60, split+35) end

        fgfill:draw(x+1, split+41, x+cw-1, y+ch-5)
        local time_x, time_y = x+10, split+45
        local font_size = 36
        local show_w = cw / 3
        for _, show in ipairs(m.shows) do
            if now <= show.showtime.offset + 15 then
                local tw = res.font:width(show.showtime.string, font_size)
                local color = {1,1,1,alpha}
                if show.seats == 0 then color = {1,.2,.2,alpha} elseif show.seats <= 20 then color = {1,.8,.2,alpha} end
                res.font:write(time_x + (show_w - tw)/2, time_y, show.showtime.string, font_size, unpack(color))
                time_x = time_x + show_w
                if time_x + show_w > x+cw then time_x = x+10; time_y = time_y + font_size + 10 end
            end
        end
    end
end

local bload_age = 0
util.data_mapper{ ["age/set"] = function(age) bload_age = tonumber(age) end }

function node.render()
    gl.clear(0,0,0,1)
    st()
    if bload_age > bload_threshold then
        util.draw_correct(bload_fallback, 0, 0, WIDTH, HEIGHT)
    else
        show_bload()
    end
end
