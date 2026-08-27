local _ = require("gettext")
local callApi = require("call_api")
local InfoMessage = require("ui/widget/infomessage")
local JSON = require("json")
local KoInsightDbReader = require("db_reader")
local KoInsightAnnotationReader = require("annotation_reader")
local KoInsightCoverReader = require("cover_reader")
local logger = require("logger")
local UIManager = require("ui/uimanager")
local const = require("./const")
local Device = require("device")

local API_UPLOAD_LOCATION = "/api/plugin/import"
local API_DEVICE_LOCATION = "/api/plugin/device"
local API_COVER_STATUS_LOCATION = "/api/plugin/covers/status"
local API_COVER_LOCATION = "/api/plugin/covers/"

local KoInsightUpload = {}

function get_headers(body)
  local headers = {
    ["Content-Type"] = "application/json",
    ["Content-Length"] = tostring(#body),
  }
  return headers
end

function render_response_message(response, prefix, default_text)
  local text = prefix .. " " .. default_text
  if response ~= nil and response["message"] ~= nil then
    logger.dbg("[KoInsight] API message received: ", JSON.encode(response))
    text = prefix .. " " .. response["message"]
  end

  UIManager:show(InfoMessage:new({
    text = _(text),
  }))
end

function send_device_data(server_url, silent)
  local url = server_url .. API_DEVICE_LOCATION
  local body = {
    id = G_reader_settings:readSetting("device_id"),
    model = Device.model,
    version = const.VERSION,
  }
  body = JSON.encode(body)

  local ok, response = callApi("POST", url, get_headers(body), body)

  if ok ~= true and not silent then
    render_response_message(response, "Error:", "Unable to register device.")
  end
end

function send_statistics_data(server_url, silent)
  local url = server_url .. API_UPLOAD_LOCATION

  -- Get annotations from currently opened book
  local annotations = KoInsightAnnotationReader.getAnnotationsByBook()

  local annotation_count = 0
  for _, book_annotations in pairs(annotations) do
    annotation_count = annotation_count + #book_annotations
  end

  if annotation_count > 0 then
    logger.info("[KoInsight] Syncing", annotation_count, "annotations")
  end

  local body = {
    stats = KoInsightDbReader.progressData(),
    books = KoInsightDbReader.bookData(),
    annotations = annotations,
    version = const.VERSION,
  }

  body = JSON.encode(body)

  local ok, response = callApi("POST", url, get_headers(body), body)

  if not silent then
    if ok then
      render_response_message(response, "Success:", "Data uploaded.")
    else
      render_response_message(response, "Error:", "Data upload failed.")
    end
  end
end

-- Send annotations for a specific book
function send_book_annotations(server_url, book_md5, annotations, total_pages, book_metadata)
  local url = server_url .. API_UPLOAD_LOCATION
  local device_id = G_reader_settings:readSetting("device_id")

  -- Clean up annotations for JSON serialization
  local cleaned_annotations = KoInsightAnnotationReader.cleanAnnotations(annotations, total_pages)

  -- Use provided book metadata instead of querying database
  -- This allows bulk sync to work even if book isn't in statistics DB yet
  local book_to_send = book_metadata

  -- Fallback: try to get from statistics database if metadata not provided
  if not book_to_send then
    local all_books = KoInsightDbReader.bookData()
    for _, book in ipairs(all_books) do
      if book.md5 == book_md5 then
        book_to_send = book
        break
      end
    end
  end

  -- WARN: We MUST have book metadata to send annotations
  -- The server has a foreign key constraint: annotations.book_md5 -> book.md5
  -- If we don't send book data, annotation insert will fail
  if not book_to_send then
    logger.err(
      "[KoInsight] Cannot sync annotations for book " .. book_md5 .. ": no book metadata available"
    )
    return false, { error = "No book metadata available" }
  end

  -- Create minimal payload
  local annotations_by_book = {}
  annotations_by_book[book_md5] = cleaned_annotations

  local body = {
    stats = {}, -- empty stats on annotations sync path, handled server side
    books = { book_to_send }, -- Always send book metadata for FK constraint
    annotations = annotations_by_book,
    device_id = device_id,
    version = const.VERSION,
  }

  body = JSON.encode(body)
  return callApi("POST", url, get_headers(body), body)
end

-- Bulk sync all books with annotations
function bulk_sync_all_books(server_url, progress_callback)
  logger.info("[KoInsight] Starting bulk sync of all books")

  -- Get all books with annotations from reading history
  local books_with_annotations = KoInsightAnnotationReader.getAllBooksWithAnnotations()

  if #books_with_annotations == 0 then
    logger.info("[KoInsight] No books with annotations found")
    if progress_callback then
      progress_callback({
        phase = "complete",
        total = 0,
        success = 0,
        failed = 0,
        message = "No books with annotations found",
      })
    end
    return
  end

  logger.info("[KoInsight] Found", #books_with_annotations, "books to sync")

  local total_books = #books_with_annotations
  local success_count = 0
  local failed_count = 0

  -- Sync each book one by one
  for i, book_info in ipairs(books_with_annotations) do
    logger.info(
      string.format(
        "[KoInsight] Syncing book %d/%d (MD5: %s, %d annotations)",
        i,
        total_books,
        book_info.md5,
        book_info.annotation_count
      )
    )

    -- Report progress
    if progress_callback then
      progress_callback({
        phase = "syncing",
        current = i,
        total = total_books,
        book_md5 = book_info.md5,
        annotation_count = book_info.annotation_count,
      })
    end

    -- Send annotations for this book
    local ok, response = send_book_annotations(
      server_url,
      book_info.md5,
      book_info.annotations,
      book_info.total_pages,
      book_info.book_metadata -- Pass metadata from sidecar
    )

    if ok then
      success_count = success_count + 1
      logger.info("[KoInsight] Successfully synced book:", book_info.md5)
    else
      failed_count = failed_count + 1
      logger.err("[KoInsight] Failed to sync book:", book_info.md5)
    end

    -- Small delay between requests to avoid overwhelming the server
    -- and to allow UI to update
    if i < total_books then
      UIManager:nextTick(function() end)
    end
  end

  logger.info(
    string.format(
      "[KoInsight] Bulk sync complete: %d/%d books synced successfully, %d failed",
      success_count,
      total_books,
      failed_count
    )
  )

  -- Report completion
  if progress_callback then
    progress_callback({
      phase = "complete",
      total = total_books,
      success = success_count,
      failed = failed_count,
    })
  end
end

function get_cover_headers(body)
  return {
    ["Content-Type"] = "image/png",
    ["Content-Length"] = tostring(#body),
    -- The body is binary, so the plugin version can't travel in it
    ["X-KoInsight-Plugin-Version"] = const.VERSION,
  }
end

-- Ask the server which of the given books have no cover stored yet.
-- Returns a set of md5s, or nil when the server doesn't support cover sync.
function fetch_missing_covers(server_url, md5s)
  local body = JSON.encode({ md5s = md5s, version = const.VERSION })
  local url = server_url .. API_COVER_STATUS_LOCATION

  local ok, response = callApi("POST", url, get_headers(body), body, nil, true)

  if not ok or type(response) ~= "table" or type(response.missing) ~= "table" then
    logger.info("[KoInsight] Cover sync unavailable on this server, skipping covers")
    return nil
  end

  local missing = {}
  for _, md5 in ipairs(response.missing) do
    missing[md5] = true
  end

  return missing
end

-- Extract and upload the cover of a single book.
-- Returns the value to remember for this book ("uploaded" / "no_cover"), or nil on failure.
function send_book_cover(server_url, md5, file_path)
  local data = KoInsightCoverReader.getCoverData(file_path)

  if not data then
    -- Remember it so we don't re-open a coverless (or unreadable) book on every sync
    return "no_cover"
  end

  local ok = callApi(
    "POST",
    server_url .. API_COVER_LOCATION .. md5,
    get_cover_headers(data),
    data,
    nil,
    true
  )

  if not ok then
    logger.warn("[KoInsight] Failed to upload cover for book:", md5)
    return nil
  end

  logger.info("[KoInsight] Uploaded cover for book:", md5)
  return "uploaded"
end

-- Upload covers for all books in the reading history that don't have one on the server yet
function sync_covers(server_url, settings, progress_callback)
  if not settings or not settings:getSyncCoversEnabled() then
    logger.dbg("[KoInsight] Cover sync is disabled, skipping")
    return
  end

  local books = KoInsightAnnotationReader.getAllBooksFromHistory()

  if #books == 0 then
    return
  end

  local handled = settings:getHandledCovers()

  -- Skip books we already handled locally, and de-duplicate the history
  local candidates = {}
  local md5s = {}
  local seen = {}

  for _, book in ipairs(books) do
    if handled[book.md5] == nil and not seen[book.md5] then
      seen[book.md5] = true
      table.insert(candidates, book)
      table.insert(md5s, book.md5)
    end
  end

  if #candidates == 0 then
    logger.info("[KoInsight] All book covers are already synced")
    return
  end

  local missing = fetch_missing_covers(server_url, md5s)

  -- Server doesn't support cover sync (or is unreachable): degrade silently
  if missing == nil then
    return
  end

  local to_upload = {}
  for _, book in ipairs(candidates) do
    if missing[book.md5] then
      table.insert(to_upload, book)
    else
      -- The server already has a cover for this book, no need to look at it again
      handled[book.md5] = "uploaded"
    end
  end

  logger.info("[KoInsight] Uploading covers for", #to_upload, "books")

  local uploaded_count = 0

  for i, book in ipairs(to_upload) do
    if progress_callback then
      progress_callback({
        phase = "covers",
        current = i,
        total = #to_upload,
        book_md5 = book.md5,
      })
    end

    local result = send_book_cover(server_url, book.md5, book.file_path)

    if result then
      handled[book.md5] = result
      if result == "uploaded" then
        uploaded_count = uploaded_count + 1
      end
    end

    -- Allow the UI to update between books
    if i < #to_upload then
      UIManager:nextTick(function() end)
    end
  end

  -- Persist once, to avoid hammering the flash storage during the loop
  settings:setHandledCovers(handled)

  logger.info(
    string.format("[KoInsight] Cover sync complete: %d/%d uploaded", uploaded_count, #to_upload)
  )

  return uploaded_count
end

-- Upload the cover of the currently open book only.
-- Used on the suspend path, where a full history scan would be far too expensive.
function sync_current_book_cover(server_url, settings)
  if not settings or not settings:getSyncCoversEnabled() then
    return
  end

  local md5 = KoInsightAnnotationReader.getCurrentBookMd5()
  local file_path = KoInsightAnnotationReader.getCurrentDocument()

  if not md5 or not file_path or settings:isCoverHandled(md5) then
    return
  end

  local missing = fetch_missing_covers(server_url, { md5 })

  if missing == nil then
    return
  end

  local handled = settings:getHandledCovers()

  if not missing[md5] then
    handled[md5] = "uploaded"
    settings:setHandledCovers(handled)
    return
  end

  local result = send_book_cover(server_url, md5, file_path)

  if result then
    handled[md5] = result
    settings:setHandledCovers(handled)
  end
end

-- Sync current book only (stats + current book annotations)
function KoInsightUpload.syncCurrentBook(server_url, silent, settings)
  if silent == nil then
    silent = false
  end
  if server_url == nil or server_url == "" then
    UIManager:show(InfoMessage:new({
      text = _("Please configure the server URL first."),
    }))
    return
  end

  send_device_data(server_url, silent)
  send_statistics_data(server_url, silent)

  -- Only the current book's cover here: the suspend path must stay cheap
  sync_current_book_cover(server_url, settings)
end

-- Sync all books (stats + all book annotations)
function KoInsightUpload.syncAllBooks(server_url, progress_callback, settings)
  if server_url == nil or server_url == "" then
    UIManager:show(InfoMessage:new({
      text = _("Please configure the server URL first."),
    }))
    return
  end

  send_device_data(server_url, true) -- silent

  -- First, sync all statistics data from the database
  -- This includes all reading progress (page_stat_data) and book metadata
  send_statistics_data(server_url, true) -- silent

  -- Then upload covers for all books. This has to happen after the statistics
  -- sync, because the server only accepts covers for books it already knows about.
  sync_covers(server_url, settings, progress_callback)

  -- Finally, sync all annotations for all books
  bulk_sync_all_books(server_url, progress_callback)
end

-- Forget which covers were already handled and look at every book again.
-- Covers that already exist on the server are kept, so a manually chosen cover survives.
function KoInsightUpload.resyncCovers(server_url, settings, progress_callback)
  if server_url == nil or server_url == "" then
    UIManager:show(InfoMessage:new({
      text = _("Please configure the server URL first."),
    }))
    return
  end

  if settings then
    settings:clearHandledCovers()
  end

  return sync_covers(server_url, settings, progress_callback)
end

return KoInsightUpload
