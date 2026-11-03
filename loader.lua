-- Scrdsx Solutions loader: fetches each module from src/ and runs them. No bundle needed.
-- Set getgenv().ScrdsxBase to the folder URL (ending in /) that holds loader.lua and src/.
-- Set getgenv().ScrdsxLocal = "BackflipFarm/" to read from the executor workspace instead.
local env = getgenv and getgenv() or _G
local BASE = env.ScrdsxBase or "http://localhost:8000/"
local LOCAL = env.ScrdsxLocal
local MODULES = { "ui", "farm", "loading", "main" } -- main last

local sources, cache = {}, {}

local function fetch(name)
	local path = "src/" .. name .. ".lua"
	if LOCAL then return readfile(LOCAL .. path) end
	return game:HttpGet(BASE .. path .. "?t=" .. os.time()) -- bust caches while developing
end

local function req(name)
	if cache[name] == nil then
		local src = sources[name]
		assert(src, "unknown module: " .. tostring(name))
		-- inject `require` on the first line so error line numbers stay correct
		local fn, err = loadstring("local require = ...;" .. src, "=" .. name)
		assert(fn, name .. ": " .. tostring(err))
		cache[name] = fn(req)
		if cache[name] == nil then cache[name] = true end
	end
	return cache[name]
end

for _, name in ipairs(MODULES) do
	local ok, res = pcall(fetch, name)
	assert(ok, "failed to load " .. name .. ": " .. tostring(res))
	sources[name] = res
end

return req("main")
