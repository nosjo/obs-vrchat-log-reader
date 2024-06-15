local obs = obslua
local filename = ""
local dst = "                                                                                                       "
local closefile = true;
local activefile
local line = 0
local scenes
local json = require("json")
local ffi = require("ffi")
local curl = require("luajit-curl")
local script_settings
local firstrun = true;
local readytorun = false;
local errors = {
	unknown = 0,
	timeout = 1,
	connect = 2,
	resolve_host = 3
}
local code_map = {
	[curl.CURLE_OPERATION_TIMEDOUT] = {
		errors.timeout, "Connection timed out"
	},
	[curl.CURLE_COULDNT_RESOLVE_HOST] = {
		errors.resolve_host, "Couldn't resolve host"
	},
	[curl.CURLE_COULDNT_CONNECT] = {
		errors.connect, "Couldn't connect to host"
	}
}

function script_description()
	return "Vrchat log reader for getting info on what is going on"
end

local function reading()
	--check if latest file
	local dir = obs.os_opendir(dst)
	local entry
	local newfile = ""
	repeat
		entry = obs.os_readdir(dir)
		if entry and not entry.directory and obs.os_get_path_extension(entry.d_name)==".txt" then
			newfile = entry.d_name
		end
	until not entry
	if newfile ~= filename then
		print("Swapped to new file: " .. newfile)
		filename = newfile
		closefile = true
	end
	obs.os_closedir(dir)
	--file reading
	if closefile then
		print("Opening: " .. dst .. "\\" .. filename)
		activefile = io.open(dst .. "\\" .. filename, "r")
		closefile = false
		line = 0
	end
	if (filename == "") then
		print("Vrchat log file not found at '" .. dst .. "'")
		return
	end
	repeat
		entry = activefile:read()
		if entry and not firstrun then
			line = line + 1
			if string.find(entry, "[Behaviour] OnLeftRoom", nil, true) then
				print("left room")
				local scene = obs.obs_scene_get_source(obs.obs_get_scene_by_name(obs.obs_data_get_string(script_settings, "scene_hop")))
				if (obs.obs_source_get_name(obs.obs_frontend_get_current_scene()) ~= obs.obs_data_get_string(script_settings, "scene_pre")) then
					obs.obs_frontend_set_current_scene(scene)
				end
			elseif string.find(entry, "[Behaviour] Finished entering world.", nil, true) then
				print("joined room")
				local scene = obs.obs_scene_get_source(obs.obs_get_scene_by_name(obs.obs_data_get_string(script_settings, "scene_game")))
				if (obs.obs_source_get_name(obs.obs_frontend_get_current_scene()) ~= obs.obs_data_get_string(script_settings, "scene_pre")) then
					obs.obs_frontend_set_current_scene(scene)
				end
			elseif string.find(entry, "[Behaviour] Destination set: wrld_", nil, true) and obs.obs_data_get_bool(script_settings, "bool_worldna") then
				print("Get name and author")
				local _, strstart = string.find(entry, "[Behaviour] Destination set: wrld_", nil, true)
				entry = string.sub(entry, strstart)
				local strend = string.find(entry, ":", nil, true)
				local id = string.sub(entry, 2, strend - 1)
				print("World id: " .. id)
				--Curl madness
				local handle = curl.curl_easy_init()
				curl.curl_easy_setopt(handle, curl.CURLOPT_URL, "https://api.vrchat.cloud/api/1/worlds/wrld_" .. id)
				curl.curl_easy_setopt(handle, curl.CURLOPT_SSL_VERIFYPEER, 1)
				curl.curl_easy_setopt(handle, curl.CURLOPT_SSL_VERIFYHOST, 2)
				curl.curl_easy_setopt(handle, curl.CURLOPT_HTTPGET, 1)
				curl.curl_easy_setopt(handle, curl.CURLOPT_USERAGENT, "Obs-Vrchat-Log-Reader/1.0.4 (Discord: Nosjo, Email: admin@nosjo.xyz)")
				--curl.curl_easy_setopt(handle, curl.CURLOPT_HTTPHEADER, "apiKey:JlE5Jldo5Jibnk5O5hTx6XVqsJu4WJ26")
				local out_buffer = {}
				local callback = ffi.cast("curl_callback", function(data, size, nmeb, user)
					table.insert(out_buffer, ffi.string(data, size * nmeb))
					return size * nmeb
				end)
				curl.curl_easy_setopt(handle, curl.CURLOPT_WRITEFUNCTION, callback)
				local code = curl.curl_easy_perform(handle)
				if (code ~= curl.CURLE_OK) then
					print("Curl error: " .. tostring(code))
					local num = tonumber(code)
					if (code_map[num]) then
						print(code_map[num][1] .. code_map[num][2])
					end
				else
					local txt = table.concat(out_buffer)
					print("Raw json: " .. txt)
					local arr = json.decode(txt)
					if (not arr.error) then
						print("Setting name and author: " .. arr.name .. " - " .. arr.authorName)
						local source = obs.obs_get_source_by_name(obs.obs_data_get_string(script_settings, "text_name"))
						if source ~= nil then
							local settings = obs.obs_data_create()
							obs.obs_data_set_string(settings, "text", arr.name)
							obs.obs_source_update(source, settings)
							obs.obs_data_release(settings)
							obs.obs_source_release(source)
						end
						local source = obs.obs_get_source_by_name(obs.obs_data_get_string(script_settings, "text_author"))
						if source ~= nil then
							local settings = obs.obs_data_create()
							obs.obs_data_set_string(settings, "text", arr.authorName)
							obs.obs_source_update(source, settings)
							obs.obs_data_release(settings)
							obs.obs_source_release(source)
						end
						local source = obs.obs_get_source_by_name(obs.obs_data_get_string(script_settings, "image_file"))
						if source ~= nil then
							local settings = obs.obs_data_create()
							obs.obs_data_set_string(settings, "url", arr.imageUrl)
							obs.obs_source_update(source, settings)
							obs.obs_data_release(settings)
							obs.obs_source_release(source)
						end
						local source = obs.obs_get_source_by_name(obs.obs_data_get_string(script_settings, "qr_image"))
						if source ~= nil then
							local settings = obs.obs_data_create()
							if (arr.releaseStatus == "public") then
								local size = obs.obs_data_get_string(script_settings, "qr_size")
								obs.obs_data_set_string(settings, "url", "https://api.qrserver.com/v1/create-qr-code/?size=" .. size .. "x" .. size .. "&bgcolor=E4E3E4&data=https://vrchat.com/home/launch?worldId=" .. arr.id)
							else
								obs.obs_data_set_string(settings, "url", "")
							end
							obs.obs_source_update(source, settings)
							obs.obs_data_release(settings)
							obs.obs_source_release(source)
						end
					end
				end
			end
		end
	until not entry
	firstrun = false;
end

local function init()
	print("init")
	readytorun = true
	obs.os_get_config_path(dst, #dst, "LocalLow\\VRChat\\VRChat")
	dst = dst:gsub('%Roaming\\', '')
	dst = dst:gsub('[%c%s]', '')
	scenes =  obs.obs_frontend_get_scenes()
	if obs.obs_data_get_bool(script_settings, "bool_enabled") then
		obs.timer_add(reading, 1000)
	end
end

function script_update(settings)
	script_settings = settings
	if readytorun then
		obs.timer_remove(reading)
		if obs.obs_data_get_bool(script_settings, "bool_enabled") then
			obs.timer_add(reading, 1000)
			print("Enabled")
			local folder = obs.obs_data_get_string(script_settings, "log_folder")
			if folder ~= "" then
				dst = folder
			end
		else
			print("Disabled")
		end
	end
end

function script_properties()
    local props = obs.obs_properties_create()
	obs.obs_properties_add_bool(props, "bool_enabled", "Enabled")
	obs.obs_properties_add_bool(props, "bool_worldna", "Get world name/author")
	obs.obs_properties_add_text(props, "text_name", "Name of World text:", obs.OBS_TEXT_DEFAULT)
	obs.obs_properties_add_text(props, "text_author", "Name of Author text:", obs.OBS_TEXT_DEFAULT)
	obs.obs_properties_add_text(props, "image_file", "Name of Image field:", obs.OBS_TEXT_DEFAULT)
	obs.obs_properties_add_text(props, "qr_image", "Name of QR image field:", obs.OBS_TEXT_DEFAULT);
	obs.obs_properties_add_text(props, "qr_size", "QR image size in pixels:", obs.OBS_TEXT_DEFAULT);
	obs.obs_properties_add_text(props, "scene_pre", "Name of Pre scene:", obs.OBS_TEXT_DEFAULT)
	obs.obs_properties_add_text(props, "scene_game", "Name of Game scene:", obs.OBS_TEXT_DEFAULT)
	obs.obs_properties_add_text(props, "scene_hop", "Name of Hop scene:", obs.OBS_TEXT_DEFAULT)
	obs.obs_properties_add_text(props, "log_folder", "Vrchat log file folder:", obs.OBS_TEXT_DEFAULT)
	return props
end

function script_load(settings)
	init()
end