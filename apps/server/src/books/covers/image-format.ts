const PNG_MAGIC = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
const JPEG_MAGIC = Buffer.from([0xff, 0xd8, 0xff]);
const GIF_MAGIC = Buffer.from('GIF8', 'ascii');

/**
 * Detects the image format from the file's magic bytes and returns the matching
 * file extension, or null when the buffer is not a supported image.
 *
 * Sniffing the content is safer than trusting a client-provided content type or filename.
 */
export function detectImageExtension(data: unknown): string | null {
  if (!Buffer.isBuffer(data)) {
    return null;
  }

  // `equals` also compares lengths, so a buffer shorter than the magic never matches
  if (data.subarray(0, PNG_MAGIC.length).equals(PNG_MAGIC)) {
    return '.png';
  }

  if (data.subarray(0, JPEG_MAGIC.length).equals(JPEG_MAGIC)) {
    return '.jpg';
  }

  if (data.subarray(0, GIF_MAGIC.length).equals(GIF_MAGIC)) {
    return '.gif';
  }

  return null;
}
