--[[
_   _ ____ _  _ ____ _  _ ___  ____
 \_/  |  | |  | |    |  | |__] |___
  |   |__| |__| |___ |__| |__] |___

Github Repository: https://github.com/Commandcracker/YouCube
License: GPL-3.0
]]

local _VERSION = "0.0.0-poc.1.1.2"

-- Libraries - OpenLibrarieLoader v1.0.1 --

--TODO: Optional libs:
-- For something like a JSON lib that is only needed for older CC Versions or
-- optional logging.lua support

local function is_lib(libs, lib)
    for i = 1, #libs do
        local value = libs[i]
        if value == lib or value .. ".lua" == lib then
            return true, value
        end
    end
    return false
end

local libs = { "youcubeapi", "numberformatter", "semver", "argparse", "string_pack" }
local lib_paths = { ".", "./lib", "./apis", "./modules", "/", "/lib", "/apis", "/modules" }

-- LevelOS Support
if _G.lOS then
    lib_paths[#lib_paths + 1] = "/Program_Files/YouCube/lib"
end

local function load_lib(lib)
    if require then
        return require(lib:gsub(".lua", ""))
    end
    return dofile(lib)
end

for i_path = 1, #lib_paths do
    local path = lib_paths[i_path]
    if fs.exists(path) then
        local files = fs.list(path)
        for i_file = 1, #files do
            local found, lib = is_lib(libs, files[i_file])
            if found and lib ~= nil and libs[lib] == nil then
                libs[lib] = load_lib(path .. "/" .. files[i_file])
            end
        end
    end
end

for i = 1, #libs do
    local lib = libs[i]
    if libs[lib] == nil then
        error(('Library "%s" not found.'):format(lib))
    end
end

-- args --

local function get_program_name()
    if arg then
        return arg[0]
    end
    return fs.getName(shell.getRunningProgram()):gsub("[\\.].*$", "")
end

-- stylua: ignore start

local parser = libs.argparse {
    help_max_width = ({ term.getSize() })[1],
    name = get_program_name()
}
    :description "Official YouCube client for accessing media from services like YouTube"

parser:argument "URL"
    :args "*"
    :description "URL or search term."

parser:flag "-v" "--verbose"
    :description "Enables verbose output."
    :target "verbose"
    :action "store_true"

parser:option "-V" "--volume"
    :description "Sets the volume of the audio. A value from 0-100"
    :target "volume"

parser:option "-s" "--server"
    :description "The server that YC should use."
    :target "server"
    :args(1)

parser:flag "--nv" "--no-video"
    :description "Disables video."
    :target "no_video"
    :action "store_true"

parser:flag "--na" "--no-audio"
    :description "Disables audio."
    :target "no_audio"
    :action "store_true"

parser:flag "--sh" "--shuffle"
    :description "Shuffles audio before playing"
    :target "shuffle"
    :action "store_true"

parser:flag "-l" "--loop"
    :description "Loops the media."
    :target "loop"
    :action "store_true"

parser:flag "--lp" "--loop-playlist"
    :description "Loops the playlist."
    :target "loop_playlist"
    :action "store_true"

parser:option "--fps"
    :description "Force sanjuuni to use a specified frame rate"
    :target "force_fps"

parser:flag "--no-hls"
    :description "Disables HTTP Live Streaming (HLS) mode, using legacy WebSocket instead."
    :target "no_hls"
    :action "store_true"

-- stylua: ignore end

local args = parser:parse({ ... })

local use_hls = not args.no_hls

if args.force_fps then
    args.force_fps = tonumber(args.force_fps)
end

if args.volume then
    args.volume = tonumber(args.volume)
    if args.volume == nil then
        parser:error("Volume must be a number")
    end

    if args.volume > 100 then
        parser:error("Volume cant be over 100")
    end

    if args.volume < 0 then
        parser:error("Volume cant be below 0")
    end
    args.volume = args.volume / 100
end

if #args.URL > 0 then
    args.URL = table.concat(args.URL, " ")
else
    args.URL = nil
end

if args.no_video and args.no_audio then
    parser:error("Nothing will happen, when audio and video is disabled!")
end

-- CraftOS-PC support --

if periphemu then
    periphemu.create("top", "speaker")
    -- Fuck the max websocket message police
    config.set("http_max_websocket_message", 2 ^ 30)
end

local function get_audiodevices()
    local audiodevices = {}

    local speakers = { peripheral.find("speaker") }
    for i = 1, #speakers do
        if speakers[i].speakStream then
            audiodevices[#audiodevices + 1] = libs.youcubeapi.HQSpeaker.new(speakers[i])
        else
            audiodevices[#audiodevices + 1] = libs.youcubeapi.Speaker.new(speakers[i])
        end
    end

    local tapes = { peripheral.find("tape_drive") }
    for i = 1, #tapes do
        audiodevices[#audiodevices + 1] = libs.youcubeapi.Tape.new(tapes[i])
    end

    if #audiodevices == 0 then
        -- Disable audio when no audiodevice is found
        args.no_audio = true
        return audiodevices
    end

    -- Validate audiodevices
    local last_error
    local valid_audiodevices = {}

    for i = 1, #audiodevices do
        local audiodevice = audiodevices[i]
        local _error = audiodevice:validate()
        if _error == nil then
            valid_audiodevices[#valid_audiodevices + 1] = audiodevice
        else
            last_error = _error
        end
    end

    if #valid_audiodevices == 0 then
        error(last_error)
    end

    return valid_audiodevices
end

-- main --

local youcubeapi = libs.youcubeapi.API.new()
local audiodevices = get_audiodevices()

local function get_video_display()
    local gpu = peripheral and peripheral.find and peripheral.find("directgpu")
    if gpu then
        local multiplier = settings.get("youcube.directgpu.resolution_multiplier") or 1
        local ok, display_id = pcall(gpu.autoDetectAndCreateDisplayWithResolution, multiplier)
        if not ok or not display_id then
            ok, display_id = pcall(gpu.autoDetectAndCreateDisplay)
        end

        if ok and display_id then
            local info_ok, info = pcall(gpu.getDisplayInfo, display_id)
            if info_ok and info and info.pixelWidth and info.pixelHeight then
                return {
                    type = "directgpu",
                    gpu = gpu,
                    display_id = display_id,
                    width = info.pixelWidth,
                    height = info.pixelHeight,
                }
            end
        end
    end

    if peripheral and peripheral.getType and peripheral.getType("back") == "monitor" then
        local display = peripheral.wrap("back")
        if display then
            return display
        end
    end
    return term
end

local video_display = get_video_display()

local function reset_video_display()
    if video_display.type == "directgpu" then
        video_display.gpu.clear(video_display.display_id, 0, 0, 0)
        video_display.gpu.updateDisplay(video_display.display_id)
    else
        libs.youcubeapi.reset_term(video_display)
    end
end

local function get_video_size()
    if video_display.type == "directgpu" then
        local info_ok, info = pcall(video_display.gpu.getDisplayInfo, video_display.display_id)
        if info_ok and info and info.pixelWidth and info.pixelHeight then
            video_display.width = info.pixelWidth
            video_display.height = info.pixelHeight
        end
        local w = math.floor(video_display.width / 2)
        local h = math.floor(video_display.height / 3)
        return math.min(w, 328), math.min(h, 108)
    end
    return video_display.getSize()
end

-- update check --

local function get_versions()
    local url = "https://raw.githubusercontent.com/CC-YouCube/installer/main/versions.json"

    -- Check if the URL is valid
    local ok, err = http.checkURL(url)
    if not ok then
        printError("Invalid Update URL.", '"' .. url .. '" ', err)
        return
    end

    local response, http_err = http.get(url, nil, true)
    if not response then
        printError('Failed to retreat data from update URL. "' .. url .. '" (' .. http_err .. ")")
        return
    end

    local sResponse = response.readAll()
    response.close()

    return textutils.unserialiseJSON(sResponse)
end

local function write_colored(text, color)
    term.setTextColor(color)
    term.write(text)
end

local function new_line()
    local w, h = term.getSize()
    local x, y = term.getCursorPos()
    if y + 1 <= h then
        term.setCursorPos(1, y + 1)
    else
        term.setCursorPos(1, h)
        term.scroll(1)
    end
end

local function write_outdated(current, latest)
    if libs.semver(current) ^ libs.semver(latest) then
        term.setTextColor(colors.yellow)
    else
        term.setTextColor(colors.red)
    end

    term.write(current)
    write_colored(" -> ", colors.lightGray)
    write_colored(latest, colors.lime)
    term.setTextColor(colors.white)
    new_line()
end

local function can_update(name, current, latest)
    if libs.semver(current) < libs.semver(latest) then
        term.write(name .. " ")
        write_outdated(current, latest)
    end
end

local function update_checker()
    local versions = get_versions()
    if versions == nil then
        return
    end

    can_update("youcube", _VERSION, versions.client.version)
    can_update("youcubeapi", libs.youcubeapi._VERSION, versions.client.libraries.youcubeapi.version)
    can_update("numberformatter", libs.numberformatter._VERSION, versions.client.libraries.numberformatter.version)
    can_update("semver", tostring(libs.semver._VERSION), versions.client.libraries.semver.version)
    can_update("argparse", libs.argparse.version, versions.client.libraries.argparse.version)

    local handshake = youcubeapi:handshake()

    if libs.semver(handshake.server.version) < libs.semver(versions.server.version) then
        print("Tell the server owner to update their server!")
        write_outdated(handshake.server.version, versions.server.version)
    end

    if not libs.semver(libs.youcubeapi._API_VERSION) ^ libs.semver(handshake.api.version) then
        print("Client is not compatible with server")
        write_colored(libs.youcubeapi._API_VERSION, colors.red)
        write_colored(" ^ ", colors.lightGray)
        write_colored(handshake.api.version, colors.red)
        term.setTextColor(colors.white)
        new_line()
    end

    if libs.semver(libs.youcubeapi._API_VERSION) < libs.semver(versions.api.version) then
        print("Your client is using an outdated API version")
        write_outdated(libs.youcubeapi._API_VERSION, versions.api.version)
    end

    if libs.semver(handshake.api.version) < libs.semver(versions.api.version) then
        print("The server is using an outdated API version")
        write_outdated(libs.youcubeapi._API_VERSION, versions.api.version)
    end
end

local function play_audio(buffer, title)
    for i = 1, #audiodevices do
        local audiodevice = audiodevices[i]
        audiodevice:reset()
        audiodevice:setLabel(title)
        audiodevice:setVolume(args.volume)
    end

    while true do
        local chunk = buffer:next()

        -- Adjust buffer size on first chunk
        if buffer.filler.chunkindex == 1 then
            buffer.size = math.ceil(1024 / (#chunk / 16))
        end

        if chunk == "" then
            local play_functions = {}
            for i = 1, #audiodevices do
                local audiodevice = audiodevices[i]
                play_functions[#play_functions + 1] = function()
                    audiodevice:play()
                end
            end

            parallel.waitForAll(table.unpack(play_functions))
            return
        end

        local write_functions = {}
        for i = 1, #audiodevices do
            local audiodevice = audiodevices[i]
            table.insert(write_functions, function()
                audiodevice:write(chunk)
            end)
        end

        parallel.waitForAll(table.unpack(write_functions))
    end
end

local function play_audio_stereo(buffer_left, buffer_right, title)
    local left_device, right_device
    for i = 1, #audiodevices do
        local side = audiodevices[i].speaker and peripheral.getName(audiodevices[i].speaker)
        if side == "left" then
            left_device = audiodevices[i]
        elseif side == "right" then
            right_device = audiodevices[i]
        end
    end

    left_device:reset()
    left_device:setLabel(title)
    left_device:setVolume(args.volume)

    right_device:reset()
    right_device:setLabel(title)
    right_device:setVolume(args.volume)

    while true do
        local chunk_left = buffer_left:next()
        local chunk_right = buffer_right:next()

        -- Adjust buffer size on first chunk
        if buffer_left.filler.chunkindex == 1 then
            buffer_left.size = math.ceil(1024 / (#chunk_left / 16))
        end
        if buffer_right.filler.chunkindex == 1 then
            buffer_right.size = math.ceil(1024 / (#chunk_right / 16))
        end

        if chunk_left == "" or chunk_right == "" then
            parallel.waitForAll(
                function() left_device:play() end,
                function() right_device:play() end
            )
            return
        end

        parallel.waitForAll(
            -- Left speaker plays right channel, right speaker plays left channel
            function() left_device:write(chunk_right) end,
            function() right_device:write(chunk_left) end
        )
    end
end

local function can_play_hq_audio()
    for i = 1, #audiodevices do
        if audiodevices[i].playUrl then
            return true
        end
    end
    return false
end

local function play_hq_audio(url, title)
    local play_functions = {}
    for i = 1, #audiodevices do
        local audiodevice = audiodevices[i]
        if audiodevice.playUrl then
            audiodevice:reset()
            audiodevice:setLabel(title)
            audiodevice:setVolume(args.volume)
            play_functions[#play_functions + 1] = function()
                audiodevice:playUrl(url)
            end
        end
    end
    parallel.waitForAll(table.unpack(play_functions))
end

-- #region playback controll vars
local back_buffer = {}
local max_back = settings.get("youcube.max_back") or 32
local queue = {}
local restart = false
-- #endregion

-- keys
local skip_key = settings.get("youcube.keys.skip") or keys.d
local restart_key = settings.get("youcube.keys.restart") or keys.r
local back_key = settings.get("youcube.keys.back") or keys.a

local function play(url)
    restart = false
    youcubeapi:close()
    youcubeapi:detect_bestest_server(args.server, args.verbose)
    print("Requesting media ...")

    local data
    local hls_video_width, hls_video_height
    if use_hls and not args.no_video then
        local width, height = get_video_size()
        hls_video_width = width * 2
        hls_video_height = height * 3
        youcubeapi:request_media(url, width, height, can_play_hq_audio())
    else
        if not args.no_video then
            local width, height = get_video_size()
            youcubeapi:request_media(url, width, height, can_play_hq_audio())
        else
            youcubeapi:request_media(url, nil, nil, can_play_hq_audio())
        end
    end

    local x, y = term.getCursorPos()
    repeat
        data = youcubeapi:receive()
        if data.action == "status" then
            os.queueEvent("youcube:status", data)
            term.setCursorPos(x, y)
            term.clearLine()
            term.write("Status: ")
            write_colored(data.message, colors.green)
            term.setTextColor(colors.white)
        else
            new_line()
        end
    until data.action == "media" or data.action == "error"

    if not data or data.action == "error" then
        error(data and data.message or "An error occurred during HLS request")
    end

    local media_data = data
    if use_hls and not args.no_video then
        hls_video_width = data.video_width or hls_video_width
        hls_video_height = data.video_height or hls_video_height
        youcubeapi:ensure_video(
            url,
            data.id,
            hls_video_width,
            hls_video_height,
            can_play_hq_audio()
        )

        repeat
            data = youcubeapi:receive()
            if data.action == "status" then
                os.queueEvent("youcube:status", data)
                term.setCursorPos(x, y)
                term.clearLine()
                term.write("Status: ")
                write_colored(data.message, colors.green)
                term.setTextColor(colors.white)
            else
                new_line()
            end
        until data.action == "video_ready" or data.action == "error"

        if data.action == "error" then
            error(data.message or "Failed to ensure HLS video frame source")
        end
        media_data.video_width = data.video_width
        media_data.video_height = data.video_height
        media_data.video_segments_count = data.video_segments_count
        data = media_data
    end

    term.write("Playing: ")
    term.setTextColor(colors.lime)
    print(data.title)
    term.setTextColor(colors.white)

    if data.like_count then
        print("Likes: " .. libs.numberformatter.compact(data.like_count))
    end

    if data.view_count then
        print("Views: " .. libs.numberformatter.compact(data.view_count))
    end

    if not args.no_video then
        -- wait, that the user can see the video info
        sleep(2)
    end

    local left_speaker_attached = false
    local right_speaker_attached = false
    for i = 1, #audiodevices do
        local side = audiodevices[i].speaker and peripheral.getName(audiodevices[i].speaker)
        if side == "left" then
            left_speaker_attached = true
        elseif side == "right" then
            right_speaker_attached = true
        end
    end

    local use_stereo = left_speaker_attached and right_speaker_attached and not args.no_audio

    local video_buffer, audio_buffer, audio_buffer_left, audio_buffer_right
    if use_hls then
        hls_video_width = data.video_width or hls_video_width
        hls_video_height = data.video_height or hls_video_height
        if not hls_video_width or not hls_video_height then
            local w, h = get_video_size()
            hls_video_width = w * 2
            hls_video_height = h * 3
        end
        youcubeapi.is_directgpu = (video_display.type == "directgpu")
        if youcubeapi.is_directgpu then
            youcubeapi.display_width = video_display.width
            youcubeapi.display_height = video_display.height
        end
        video_buffer = libs.youcubeapi.Buffer.new(
            libs.youcubeapi.HLSVideoFiller.new(
                youcubeapi,
                data.id,
                hls_video_width,
                hls_video_height,
                data.video_segments_count
            ),
            60
        )
        if use_stereo then
            audio_buffer_left = libs.youcubeapi.Buffer.new(
                libs.youcubeapi.HLSAudioFiller.new(youcubeapi, data.id .. "_left"),
                32
            )
            audio_buffer_right = libs.youcubeapi.Buffer.new(
                libs.youcubeapi.HLSAudioFiller.new(youcubeapi, data.id .. "_right"),
                32
            )
        else
            audio_buffer = libs.youcubeapi.Buffer.new(
                libs.youcubeapi.HLSAudioFiller.new(youcubeapi, data.id),
                32
            )
        end
    else
        video_buffer = libs.youcubeapi.Buffer.new(
            libs.youcubeapi.VideoFiller.new(youcubeapi, data.id, get_video_size()),
            60
        )
        if use_stereo then
            audio_buffer_left = libs.youcubeapi.Buffer.new(
                libs.youcubeapi.AudioFiller.new(youcubeapi, data.id .. "_left"),
                32
            )
            audio_buffer_right = libs.youcubeapi.Buffer.new(
                libs.youcubeapi.AudioFiller.new(youcubeapi, data.id .. "_right"),
                32
            )
        else
            audio_buffer = libs.youcubeapi.Buffer.new(
                libs.youcubeapi.AudioFiller.new(youcubeapi, data.id),
                32
            )
        end
    end

    -- Pre-fill video and audio buffers to prevent dry starvation on start
    if not args.no_video and video_buffer then
        for i = 1, 30 do
            video_buffer:fill()
        end
    end
    if not args.no_audio then
        if use_stereo then
            if audio_buffer_left and audio_buffer_right then
                for i = 1, 10 do
                    audio_buffer_left:fill()
                    audio_buffer_right:fill()
                end
            end
        else
            if audio_buffer then
                for i = 1, 10 do
                    audio_buffer:fill()
                end
            end
        end
    end

    if args.verbose then
        term.clear()
        term.setCursorPos(1, 1)
        term.write("[DEBUG MODE]")
    end

    local function fill_audio_buffers()
        while true do
            local filled = false
            if not args.no_audio then
                if use_stereo then
                    local filled_l, filled_r
                    parallel.waitForAll(
                        function() filled_l = audio_buffer_left:fill() end,
                        function() filled_r = audio_buffer_right:fill() end
                    )
                    filled = filled_l or filled_r
                else
                    filled = audio_buffer:fill()
                end
            end

            if args.verbose then
                term.setCursorPos(1, ({ term.getSize() })[2])
                term.clearLine()
                if use_stereo then
                    term.write("Audio_Buffer_L: " .. #audio_buffer_left.buffer .. " R: " .. #audio_buffer_right.buffer)
                else
                    term.write("Audio_Buffer: " .. #audio_buffer.buffer)
                end
            end

            if not filled then
                sleep(0.05)
            end
        end
    end

    local function fill_video_buffer()
        while true do
            local filled = false
            if not args.no_video then
                filled = video_buffer:fill()
            end
            if not filled then
                sleep(0.05)
            end
        end
    end

    local function _play_video()
        if not args.no_video then
            local string_unpack
            if not string.unpack then
                string_unpack = libs.string_pack.unpack
            end

            os.queueEvent("youcube:vid_playing", data)
            libs.youcubeapi.play_vid(video_buffer, args.force_fps, string_unpack, video_display)
            os.queueEvent("youcube:vid_eof", data)
        end
    end

    local function _play_audio()
        if not args.no_audio then
            os.queueEvent("youcube:audio_playing", data)
            if data.audio_url and can_play_hq_audio() then
                play_hq_audio(data.audio_url, data.title)
            else
                if use_stereo then
                    play_audio_stereo(audio_buffer_left, audio_buffer_right, data.title)
                else
                    play_audio(audio_buffer, data.title)
                end
            end
            os.queueEvent("youcube:audio_eof", data)
        end
    end

    local function _terminate_handler()
        while true do
            local event = os.pullEventRaw()
            if event == "terminate" then
                reset_video_display()
                error("Terminated")
            end
        end
    end

    local function _play_media()
        os.queueEvent("youcube:playing")
        parallel.waitForAll(
            _play_video,
            _play_audio,
            fill_audio_buffers,
            fill_video_buffer,
            _terminate_handler
        )
    end

    local function _hotkey_handler()
        while true do
            local _, key = os.pullEvent("key")

            if key == skip_key then
                back_buffer[#back_buffer + 1] = url --finished playing, push the value to the back buffer
                if #back_buffer > max_back then
                    back_buffer[1] = nil --remove it from the front of the buffer
                end
                if not args.no_video then
                    reset_video_display()
                end
                break
            end

            if key == restart_key then
                queue[#queue + 1] = url --add the current song to upcoming
                if not args.no_video then
                    reset_video_display()
                end
                restart = true
                break
            end
        end
    end

    parallel.waitForAny(_play_media, _hotkey_handler)

    if data.playlist_videos then
        return data.playlist_videos
    end
end

local function shuffle_playlist(playlist)
    local shuffled = {}
    for i = 1, #queue do
        local pos = math.random(1, #shuffled + 1)
        shuffled[pos] = queue[i]
    end
    return shuffled
end

local function play_playlist(playlist)
    queue = playlist
    if args.shuffle then
        queue = shuffle_playlist(queue)
    end
    while #queue ~= 0 do
        local pl = table.remove(queue)

        local function handle_back_hotkey()
            while true do
                local _, key = os.pullEvent("key")
                if key == back_key then
                    queue[#queue + 1] = pl --add the current song to upcoming
                    local prev = table.remove(back_buffer)
                    if prev then --nil/false check
                        queue[#queue + 1] = prev --add previous song to upcoming
                    end
                    if not args.no_video then
                        reset_video_display()
                    end
                    break
                end
            end
        end

        parallel.waitForAny(handle_back_hotkey, function()
            play(pl) --play the url
        end)
    end
end

local function main()
    youcubeapi:detect_bestest_server(args.server, args.verbose)
    pcall(update_checker)

    if not args.URL then
        print("Enter Url or Search Term:")
        term.setTextColor(colors.lightGray)
        args.URL = read()
        term.setTextColor(colors.white)
    end

    local playlist_videos = play(args.URL)

    if args.loop == true then
        while true do
            play(args.URL)
        end
    end
    if playlist_videos then
        if args.loop_playlist == true then
            while true do
                if playlist_videos then
                    play_playlist(playlist_videos)
                end
            end
        end
        play_playlist(playlist_videos)
    end

    while restart do
        play(args.URL)
    end

    youcubeapi.websocket.close()

    if not args.no_video then
        reset_video_display()
    end

    os.queueEvent("youcube:playback_ended")
end

main()
