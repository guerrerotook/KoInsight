local Archiver = require("ffi/archiver")
local DataStorage = require("datastorage")
local ffiutil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local sha256 = require("ffi/sha2").sha256
local util = require("util")
local _ = require("gettext")

local GithubApi = require("github_api")
local PluginMetadata = require("plugin_metadata")

-- Name of the archive attached to every GitHub release by
-- .github/workflows/plugin-release.yaml.
local RELEASE_ASSET_NAME = "koinsight.koplugin.zip"

-- Files an archive must contain for KOReader to consider it a working plugin.
local REQUIRED_PLUGIN_FILES = { "_meta.lua", "main.lua" }

---Split "beta.1" into { "beta", "1" }.
---@return table|nil identifiers nil when an identifier is empty or malformed.
local function splitIdentifiers(labels)
  local identifiers = {}
  local position = 1

  while true do
    local separator = labels:find(".", position, true)
    local identifier = labels:sub(position, separator and separator - 1 or nil)

    if not identifier:match("^[0-9A-Za-z-]+$") then
      return nil
    end

    table.insert(identifiers, identifier)

    if not separator then
      return identifiers
    end

    position = separator + 1
  end
end

---@return table|nil parsed nil when `version` is not valid semver.
local function parseVersion(version)
  local major, minor, patch, labels = tostring(version or ""):match("^v?(%d+)%.(%d+)%.(%d+)(.*)$")

  if not major then
    return nil
  end

  local prerelease = nil

  if labels ~= "" then
    -- Only an optional "-<pre-release>" and/or "+<build>" may follow x.y.z.
    local prerelease_labels, build_labels = labels:match("^%-([^+]*)%+?(.*)$")

    if prerelease_labels then
      prerelease = splitIdentifiers(prerelease_labels)
      if not prerelease then
        return nil
      end
    else
      build_labels = labels:match("^%+(.*)$")
      if not build_labels then
        return nil
      end
    end

    -- Build metadata does not affect precedence, but still has to be well formed.
    if build_labels ~= "" and not splitIdentifiers(build_labels) then
      return nil
    end
  end

  return {
    major = tonumber(major),
    minor = tonumber(minor),
    patch = tonumber(patch),
    prerelease = prerelease,
  }
end

---Compare pre-release identifiers as defined by semver: numeric identifiers are
---compared numerically and rank below alphanumeric ones, a longer set of
---identifiers wins ties, and a version without a pre-release outranks one with.
---@return number -1 when `a` ranks below `b`, 0 when equal, 1 when above.
local function comparePrerelease(a, b)
  if a == nil and b == nil then
    return 0
  end
  if a == nil then
    return 1
  end
  if b == nil then
    return -1
  end

  for index = 1, math.max(#a, #b) do
    local a_identifier, b_identifier = a[index], b[index]

    if a_identifier == nil then
      return -1
    end
    if b_identifier == nil then
      return 1
    end

    local a_number = tonumber(a_identifier:match("^%d+$"))
    local b_number = tonumber(b_identifier:match("^%d+$"))

    if a_number and b_number then
      if a_number ~= b_number then
        return a_number < b_number and -1 or 1
      end
    elseif a_number then
      return -1
    elseif b_number then
      return 1
    elseif a_identifier ~= b_identifier then
      return a_identifier < b_identifier and -1 or 1
    end
  end

  return 0
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

  return comparePrerelease(a.prerelease, b.prerelease) < 0
end

-- Reject archive members that would escape the directory being extracted to.
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

function SelfUpdater:getCacheDirectory()
  return DataStorage:getDataDir() .. "/cache/koinsight"
end

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

  local asset = GithubApi.findAsset(self.latest_release, RELEASE_ASSET_NAME)

  if not asset then
    return false, _("This release does not include a plugin archive.")
  end

  local created, create_error = util.makePath(self:getCacheDirectory())

  if not created then
    return false, create_error or _("Could not create the download directory.")
  end

  local download_path = self:getCacheDirectory() .. "/" .. RELEASE_ASSET_NAME
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

---Unpack the plugin folder out of `archive_path` into the empty `staging_path`.
---@return boolean ok
---@return table|string relative_paths The unpacked files, or an error message.
function SelfUpdater:extractPlugin(archive_path, staging_path)
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

  if reader.err or not plugin_root then
    reader:close()
    return false, _("The downloaded archive does not contain a KOReader plugin.")
  end

  local relative_paths = {}

  for _unused, entry_path in ipairs(entry_paths) do
    if entry_path:sub(1, #plugin_root) == plugin_root then
      table.insert(relative_paths, entry_path:sub(#plugin_root + 1))
    end
  end

  for _unused, required in ipairs(REQUIRED_PLUGIN_FILES) do
    local found = false
    for _unused2, relative_path in ipairs(relative_paths) do
      found = found or relative_path == required
    end

    if not found then
      reader:close()
      return false, _("The downloaded archive is not a complete KoInsight plugin.")
    end
  end

  local created, create_error = util.makePath(staging_path)
  if not created then
    reader:close()
    return false, create_error or _("Could not create the staging directory.")
  end

  for _unused, relative_path in ipairs(relative_paths) do
    local destination = staging_path .. "/" .. relative_path
    local parent = util.splitFilePathName(destination)

    if parent ~= "" then
      util.makePath(parent)
    end

    if not reader:extractToPath(plugin_root .. relative_path, destination) then
      reader:close()
      return false, string.format(_("Could not extract %s."), relative_path)
    end
  end

  reader:close()
  return true, relative_paths
end

---Move the staged files over the installed plugin. Copying from local disk is
---far less likely to fail halfway than unpacking straight into the live folder.
---@return boolean ok
---@return string|nil error_message
function SelfUpdater:installStagedFiles(staging_path, relative_paths, target_path)
  local created, create_error = util.makePath(target_path)

  if not created then
    return false, create_error or _("Could not create the plugin directory.")
  end

  for _unused, relative_path in ipairs(relative_paths) do
    local destination = target_path .. "/" .. relative_path
    local parent = util.splitFilePathName(destination)

    if parent ~= "" then
      util.makePath(parent)
    end

    local copy_error = ffiutil.copyFile(staging_path .. "/" .. relative_path, destination)

    if copy_error then
      return false, string.format(_("Could not install %s."), relative_path)
    end
  end

  return true
end

function SelfUpdater:removeStaging(staging_path, relative_paths)
  for _unused, relative_path in ipairs(relative_paths or {}) do
    util.removeFile(staging_path .. "/" .. relative_path)
  end

  -- Only ever holds the flat contents of the plugin archive, so a plain rmdir
  -- is enough; anything left behind is harmless and gets overwritten next time.
  local removed, remove_error = lfs.rmdir(staging_path)

  if not removed then
    logger.dbg("[KoInsight] Could not clean up", staging_path, remove_error)
  end
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

  local staging_path = self:getCacheDirectory() .. "/staging"
  local extracted, relative_paths = self:extractPlugin(download_path, staging_path)

  util.removeFile(download_path)

  if not extracted then
    self:removeStaging(staging_path)
    return false, relative_paths
  end

  local installed, install_error =
    self:installStagedFiles(staging_path, relative_paths, PluginMetadata.getPluginPath())

  self:removeStaging(staging_path, relative_paths)

  if not installed then
    return false, install_error
  end

  self.pending_restart = true
  logger.info("[KoInsight] Plugin updated, restart pending")

  return true
end

-- Exposed for tests.
SelfUpdater._isNewerVersion = isNewerVersion

return SelfUpdater
