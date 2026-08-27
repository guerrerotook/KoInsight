local https = require("ssl.https")
local http = require("socket.http")
local ltn12 = require("ltn12")
local logger = require("logger")
local socketutil = require("socketutil")
local JSON = require("json")

local PluginMetadata = require("plugin_metadata")

local GithubApi = {
  base_url = "https://api.github.com",
}

local function getUserAgent()
  return "koinsight.koplugin/" .. PluginMetadata.getVersion()
end

-- Perform a GET request against GitHub. When `sink` is given the body is
-- streamed into it (used for downloads) and no JSON decoding happens.
local function request(url, sink)
  local client
  if url:match("^https:") then
    client = https
  elseif url:match("^http:") then
    client = http
  else
    return false, "Unsupported URL scheme"
  end

  local response = {}
  local collect_response = sink == nil

  socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
  local ok, _unused, code = pcall(client.request, {
    url = url,
    method = "GET",
    headers = {
      ["User-Agent"] = getUserAgent(),
      ["Accept"] = "application/vnd.github+json",
    },
    sink = sink or ltn12.sink.table(response),
  })
  socketutil:reset_timeout()

  if not ok then
    logger.err("[KoInsight] GitHub request errored:", url, tostring(_unused))
    return false, "Network error"
  end

  if type(code) ~= "number" then
    logger.err("[KoInsight] GitHub request failed:", url, tostring(code))
    return false, "Network error: " .. tostring(code)
  end

  if code >= 400 then
    logger.err("[KoInsight] GitHub request returned", code, "for", url)
    return false, "GitHub returned HTTP " .. code
  end

  if not collect_response then
    return true
  end

  local body = table.concat(response)
  local decode_ok, decoded = pcall(JSON.decode, body)

  if not decode_ok or type(decoded) ~= "table" then
    logger.err("[KoInsight] GitHub response was not valid JSON:", body)
    return false, "Invalid response from GitHub"
  end

  return true, decoded
end

---@param repository string "owner/repo"
---@return boolean ok
---@return table|string release The release object, or an error message.
function GithubApi.getLatestRelease(repository)
  return request(GithubApi.base_url .. "/repos/" .. repository .. "/releases/latest")
end

---Find the release asset called `name`.
---@return table|nil asset
function GithubApi.findAsset(release, name)
  if type(release) ~= "table" or type(release.assets) ~= "table" then
    return nil
  end

  for _, asset in ipairs(release.assets) do
    if type(asset) == "table" and asset.name == name then
      return asset
    end
  end

  return nil
end

---Stream a release asset to `download_path`.
---@return boolean ok
---@return string|nil error_message
function GithubApi.downloadAsset(asset, download_path, progress_callback)
  if type(asset) ~= "table" or type(asset.browser_download_url) ~= "string" then
    return false, "Release asset has no download URL"
  end

  local file, file_error = io.open(download_path, "wb")
  if not file then
    return false, file_error or "Could not open " .. download_path
  end

  local bytes_total = tonumber(asset.size) or 0
  local bytes_downloaded = 0
  local write_error = nil

  local sink = function(chunk, chunk_error)
    if chunk_error then
      write_error = chunk_error
      return nil, chunk_error
    end

    if not chunk then
      return 1
    end

    local written, err = file:write(chunk)
    if not written then
      write_error = err or "Could not write to " .. download_path
      return nil, write_error
    end

    bytes_downloaded = bytes_downloaded + #chunk
    if progress_callback and bytes_total > 0 then
      progress_callback(bytes_downloaded, bytes_total)
    end

    return 1
  end

  local ok, err = request(asset.browser_download_url, sink)
  file:close()

  if not ok or write_error then
    os.remove(download_path)
    return false, write_error or err
  end

  if bytes_total > 0 and bytes_downloaded ~= bytes_total then
    os.remove(download_path)
    return false, "Download was incomplete"
  end

  return true
end

return GithubApi
