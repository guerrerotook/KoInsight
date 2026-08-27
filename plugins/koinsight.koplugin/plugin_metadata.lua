local DataStorage = require("datastorage")
local logger = require("logger")
local util = require("util")

local DEFAULT_VERSION = "0.0.0-snapshot"
local PLUGIN_DIRECTORY = "koinsight.koplugin"

-- Locate the directory this plugin was loaded from. The plugin can live outside
-- of the default data directory (e.g. on an external SD card), so ask Lua where
-- this very file came from first and only fall back to the default location.
local function resolvePluginPath()
  local source = debug.getinfo(1, "S").source
  local path = source and source:match("@(.*%.koplugin)/")

  if path and util.directoryExists(path) then
    return path
  end

  return DataStorage:getDataDir() .. "/plugins/" .. PLUGIN_DIRECTORY
end

local PluginMetadata = {
  plugin_path = nil,
  meta = nil,
}

function PluginMetadata.getPluginPath()
  if PluginMetadata.plugin_path == nil then
    PluginMetadata.plugin_path = resolvePluginPath()
    logger.dbg("[KoInsight] Resolved plugin path:", PluginMetadata.plugin_path)
  end

  return PluginMetadata.plugin_path
end

-- Read _meta.lua from disk instead of require()-ing it, so that a plugin that
-- just updated itself is not served the stale copy from package.loaded.
function PluginMetadata.getMeta()
  if PluginMetadata.meta == nil then
    local meta_path = PluginMetadata.getPluginPath() .. "/_meta.lua"
    local ok, meta = pcall(dofile, meta_path)

    if ok and type(meta) == "table" then
      PluginMetadata.meta = meta
    else
      logger.err("[KoInsight] Failed to load _meta.lua:", meta or "unknown error")
      PluginMetadata.meta = false
    end
  end

  return PluginMetadata.meta or {}
end

---@return string version The release this plugin was built from, e.g. "0.2.4".
function PluginMetadata.getVersion()
  local version = PluginMetadata.getMeta().version

  if type(version) ~= "string" or version == "" then
    return DEFAULT_VERSION
  end

  return version
end

---@return string|nil repository The "owner/repo" slug releases are pulled from.
function PluginMetadata.getRepository()
  local repository = PluginMetadata.getMeta().repository

  -- Validated here because it is interpolated into the GitHub API URL.
  if type(repository) ~= "string" or not repository:match("^[%w._-]+/[%w._-]+$") then
    return nil
  end

  return repository
end

return PluginMetadata
