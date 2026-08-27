local DataStorage = require("datastorage")
local logger = require("logger")

local KoInsightCoverReader = {}

-- The web UI only renders thumbnails, so there is no point in shipping
-- full resolution covers over Wi-Fi from an e-ink device.
local MAX_COVER_DIMENSION = 500

-- NOTE:
-- Same lazy-loading pattern as annotation_reader: this module is used both inside
-- the reader and outside of it (bulk sync), where ReaderUI may not exist yet.
local ReaderUI_ok, ReaderUI = nil, nil
local function get_live_ui()
  if ReaderUI_ok == nil then
    ReaderUI_ok, ReaderUI = pcall(require, "apps/reader/readerui")
  end
  return (ReaderUI_ok and ReaderUI and ReaderUI.instance) or nil
end

-- Loaded on demand so that a failure to load them can never break plugin startup
local function get_document_registry()
  local ok, DocumentRegistry = pcall(require, "document/documentregistry")
  return ok and DocumentRegistry or nil
end

local function get_render_image()
  local ok, RenderImage = pcall(require, "ui/renderimage")
  return ok and RenderImage or nil
end

local function temp_cover_path()
  return DataStorage:getDataDir() .. "/cache/koinsight_cover.png"
end

-- Encode a blitbuffer to PNG bytes through a temporary file
local function bb_to_png_bytes(bb)
  local path = temp_cover_path()
  os.remove(path)

  local ok, err = pcall(function()
    bb:writePNG(path)
  end)

  if not ok then
    logger.warn("[KoInsight] Unable to encode cover to PNG:", err)
    os.remove(path)
    return nil
  end

  local file = io.open(path, "rb")
  if not file then
    logger.warn("[KoInsight] Unable to read encoded cover from:", path)
    os.remove(path)
    return nil
  end

  local data = file:read("*a")
  file:close()
  os.remove(path)

  return data
end

-- Returns a downscaled copy of the cover, or nil when no scaling is needed.
-- The caller is responsible for freeing both the original and the returned buffer.
local function scale_cover(bb)
  local RenderImage = get_render_image()

  if not RenderImage then
    return nil
  end

  local width, height = bb:getWidth(), bb:getHeight()

  if not width or not height or width == 0 or height == 0 then
    return nil
  end

  local longest_side = math.max(width, height)
  if longest_side <= MAX_COVER_DIMENSION then
    return nil
  end

  local factor = MAX_COVER_DIMENSION / longest_side
  local scaled = RenderImage:scaleBlitBuffer(
    bb,
    math.max(1, math.floor(width * factor + 0.5)),
    math.max(1, math.floor(height * factor + 0.5)),
    false -- never free the original here, we do it ourselves
  )

  if scaled == bb then
    return nil
  end

  return scaled
end

local function free_bb(bb)
  if bb then
    pcall(function()
      bb:free()
    end)
  end
end

local function extract_cover(file_path)
  local ui = get_live_ui()
  local document = nil
  local close_document = false

  -- Reuse the live document when the book is currently open, instead of reopening it
  if ui and ui.document and ui.document.file == file_path then
    document = ui.document
  else
    local DocumentRegistry = get_document_registry()

    if not DocumentRegistry then
      return nil
    end

    document = DocumentRegistry:openDocument(file_path)
    close_document = document ~= nil

    if document and document.loadDocument then
      -- CreDocument: metadata is enough to get to the cover
      document:loadDocument(false)
    end
  end

  if not document then
    logger.dbg("[KoInsight] Could not open document for cover extraction:", file_path)
    return nil
  end

  local ok, cover_bb = pcall(document.getCoverPageImage, document)

  -- IMPORTANT: always close documents we opened ourselves, even on failure.
  -- Leaking documents during a bulk loop will run a low-memory device out of RAM.
  if close_document then
    pcall(function()
      document:close()
    end)
  end

  if not ok or not cover_bb then
    logger.dbg("[KoInsight] No cover image available for:", file_path)
    return nil
  end

  local scaled_bb = scale_cover(cover_bb)
  local data = bb_to_png_bytes(scaled_bb or cover_bb)

  free_bb(scaled_bb)
  free_bb(cover_bb)

  if not data or #data == 0 then
    return nil
  end

  return data
end

-- Get the cover of a book as image bytes.
-- Returns data, format - or nil when the book has no (readable) cover.
function KoInsightCoverReader.getCoverData(file_path)
  if not file_path then
    return nil
  end

  local ok, data = pcall(extract_cover, file_path)

  if not ok then
    logger.warn("[KoInsight] Error extracting cover for:", file_path, data)
    return nil
  end

  if not data then
    return nil
  end

  logger.dbg("[KoInsight] Extracted cover of", #data, "bytes for:", file_path)
  return data, "png"
end

return KoInsightCoverReader
