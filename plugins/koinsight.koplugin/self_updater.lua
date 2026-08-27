local Archiver = require("ffi/archiver")
local DataStorage = require("datastorage")
local logger = require("logger")
local sha256 = require("ffi/sha2").sha256
local util = require("util")
local _ = require("gettext")

local GithubApi = require("github_api")
local PluginMetadata = require("plugin_metadata")

-- Name of the archive attached to every GitHub release by
-- .github/workflows/plugin-release.yaml.
local RELEASE_ASSET_PATTERN = "%.koplugin%.zip$"

---@param version string
---@return table|nil parsed
local function parseVersion(version)
  local major, minor, patch, labels = tostring(version or ""):match("^v?(%d+)%.(%d+)%.(%d+)(.*)$")

  if not major then
    return nil
  end

  return {
    major = tonumber(major),
    minor = tonumber(minor),
    patch = tonumber(patch),
    -- "-beta.1" in "1.2.3-beta.1+build7"; build metadata is ignored, as per semver.
    prerelease = labels:match("^%-([^+]+)"),
  }
end

---@return boolean true when `candidate` is a later version than `current`
local function isNewerVersion(current, candidate)
  local a = parseVersion(current)
  local b = parseVersion(candidate)

  if not b then
    return false
  end
  if not a then
    return true
  end

  if b.major ~= a.major then
    return b.major > a.major
  end
  if b.minor ~= a.minor then
    return b.minor > a.minor
  end
  if b.patch ~= a.patch then
    return b.patch > a.patch
  end

  -- Same x.y.z: a pre-release is older than the final release of that version.
  if a.prerelease and not b.prerelease then
    return true
  end
  if not a.prerelease or not b.prerelease then
    return false
  end
  return b.prerelease > a.prerelease
end

-- Reject archive members that would escape the plugin directory.
local function isUnsafeEntryPath(path)
  if path == "" or path:sub(1, 1) == "/" then
    return true
  end

  for component in path:gmatch("[^/]+") do
    if component == ".." then
      return true
    end
  end

  return false
end

-- GitHub exposes a "sha256:<hex>" digest on release assets. It is not always
-- present (older releases predate the field), so a missing digest is not fatal.
local function verifyDigest(path, digest)
  if type(digest) ~= "string" or digest == "" then
    logger.warn("[KoInsight] Release asset has no digest, skipping verification")
    return true
  end

  local algorithm, expected = digest:match("^(%w+):(%x+)$")

  if algorithm ~= "sha256" then
    logger.warn("[KoInsight] Unsupported asset digest, skipping verification:", digest)
    return true
  end

  local file = io.open(path, "rb")
  if not file then
    return false
  end

  local content = file:read("*a")
  file:close()

  if not content then
    return false
  end

  local actual = sha256(content)
  if actual ~= expected:lower() then
    logger.err("[KoInsight] Digest mismatch:", expected, "~=", actual)
    return false
  end

  return true
end

local SelfUpdater = {
  latest_release = nil,
  pending_restart = false,
}

function SelfUpdater:getCurrentVersion()
  return PluginMetadata.getVersion()
end

function SelfUpdater:getRepository()
  return PluginMetadata.getRepository()
end

function SelfUpdater:isPendingRestart()
  return self.pending_restart
end

---@return string|nil version The tag of the last release seen on GitHub.
function SelfUpdater:getLatestVersion()
  if type(self.latest_release) ~= "table" then
    return nil
  end

  return self.latest_release.tag_name
end

function SelfUpdater:isUpdateAvailable()
  return isNewerVersion(self:getCurrentVersion(), self:getLatestVersion())
end

---Ask GitHub for the latest release. Blocking; run it while online.
---@return boolean ok
---@return string|nil error_message
function SelfUpdater:fetchLatestRelease()
  local repository = self:getRepository()

  if not repository then
    logger.warn("[KoInsight] No repository in _meta.lua, cannot check for updates")
    return false, _("This build does not know where to look for updates.")
  end

  local ok, release = GithubApi.getLatestRelease(repository)

  if not ok then
    return false, release
  end

  if type(release.tag_name) ~= "string" then
    return false, _("GitHub did not report a released version.")
  end

  self.latest_release = release
  logger.info("[KoInsight] Latest release on GitHub:", release.tag_name)

  return true
end

---@return boolean ok
---@return string path_or_error
function SelfUpdater:downloadLatestRelease(progress_callback)
  if not self.latest_release then
    return false, _("No release information available.")
  end

  local asset = GithubApi.findAsset(self.latest_release, RELEASE_ASSET_PATTERN)

  if not asset then
    return false, _("This release does not include a plugin archive.")
  end

  local download_directory = DataStorage:getDataDir() .. "/cache/koinsight"
  local created, create_error = util.makePath(download_directory)

  if not created then
    return false, create_error or _("Could not create the download directory.")
  end

  local download_path = download_directory .. "/koinsight.koplugin-" .. os.time() .. ".zip"
  local ok, download_error = GithubApi.downloadAsset(asset, download_path, progress_callback)

  if not ok then
    return false, download_error or _("Download failed.")
  end

  if not verifyDigest(download_path, asset.digest) then
    util.removeFile(download_path)
    return false, _("The downloaded archive is corrupted.")
  end

  return true, download_path
end

---Unpack the plugin folder from `archive_path` over `target_path`.
---@return boolean ok
---@return string|nil error_message
function SelfUpdater:extractPlugin(archive_path, target_path)
  local reader = Archiver.Reader:new()

  if not reader:open(archive_path) then
    return false, _("Could not open the downloaded archive.")
  end

  -- The archive wraps the plugin in its own folder (koinsight.koplugin/...);
  -- locate that prefix so it can be stripped while extracting.
  local plugin_root = nil
  local entry_paths = {}

  for entry in reader:iterate() do
    if entry.mode == "file" and not isUnsafeEntryPath(entry.path) then
      local directory, filename = util.splitFilePathName(entry.path)

      if filename == "_meta.lua" and (plugin_root == nil or #directory < #plugin_root) then
        plugin_root = directory
      end

      table.insert(entry_paths, entry.path)
    end
  end

  if not plugin_root then
    reader:close()
    return false, _("The downloaded archive does not contain a KOReader plugin.")
  end

  local created, create_error = util.makePath(target_path)
  if not created then
    reader:close()
    return false, create_error or _("Could not create the plugin directory.")
  end

  for _unused, entry_path in ipairs(entry_paths) do
    if entry_path:sub(1, #plugin_root) == plugin_root then
      local relative_path = entry_path:sub(#plugin_root + 1)
      local destination = target_path .. "/" .. relative_path
      local parent = util.splitFilePathName(destination)

      if parent ~= "" then
        util.makePath(parent)
      end

      if not reader:extractToPath(entry_path, destination) then
        reader:close()
        return false, string.format(_("Could not extract %s."), entry_path)
      end
    end
  end

  reader:close()
  return true
end

---Download and install the latest release over the running plugin.
---Blocking; run it while online.
---@return boolean ok
---@return string|nil error_message
function SelfUpdater:install(progress_callback)
  local downloaded, download_path = self:downloadLatestRelease(progress_callback)

  if not downloaded then
    return false, download_path
  end

  local extracted, extract_error = self:extractPlugin(download_path, PluginMetadata.getPluginPath())

  util.removeFile(download_path)

  if not extracted then
    return false, extract_error
  end

  self.pending_restart = true
  logger.info("[KoInsight] Plugin updated, restart pending")

  return true
end

-- Exposed for tests.
SelfUpdater._isNewerVersion = isNewerVersion

return SelfUpdater
