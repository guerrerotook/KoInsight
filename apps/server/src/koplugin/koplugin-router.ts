import { KoReaderAnnotation } from '@koinsight/common/types/annotation';
import { KoReaderBook } from '@koinsight/common/types/book';
import { Device } from '@koinsight/common/types/device';
import { PageStat } from '@koinsight/common/types/page-stat';
import archiver from 'archiver';
import express, { NextFunction, Request, Response, Router } from 'express';
import path from 'path';
import { CoversService } from '../books/covers/covers-service';
import { detectImageExtension } from '../books/covers/image-format';
import { BooksRepository } from '../books/books-repository';
import { DeviceRepository } from '../devices/device-repository';
import { UploadService } from '../upload/upload-service';

// Router for KoInsight koreader plugin
const router = Router();

export const REQUIRED_PLUGIN_VERSION = '0.4.0';

export const MAX_COVER_SIZE_BYTES = 10 * 1024 * 1024;

/**
 * The plugin sends its version in the JSON body, but requests with a binary body
 * (cover uploads) can only pass it via a header or the query string.
 */
const getPluginVersion = (req: Request): string | undefined => {
  const headerVersion = req.get('x-koinsight-plugin-version');
  if (headerVersion) {
    return headerVersion;
  }

  if (typeof req.query.version === 'string') {
    return req.query.version;
  }

  return req.body && typeof req.body === 'object' ? req.body.version : undefined;
};

const rejectOldPluginVersion = (req: Request, res: Response, next: NextFunction) => {
  const version = getPluginVersion(req);

  if (!version || version !== REQUIRED_PLUGIN_VERSION) {
    res.status(400).json({
      error: `Unsupported plugin version. Version must be ${REQUIRED_PLUGIN_VERSION}. Please update your KOReader koinsight.koplugin`,
    });
    return;
  }

  next();
};

router.post('/device', rejectOldPluginVersion, async (req, res) => {
  const { id, model } = req.body;

  if (!id || !model) {
    res.status(400).json({ error: 'Missing device ID or model' });
    return;
  }

  const device: Device = { id, model };

  try {
    console.debug('Registering device:', device);
    await DeviceRepository.insertIfNotExists(device);
    res.status(200).json({ message: 'Device registered successfully' });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Error registering device' });
  }
});

router.post('/import', rejectOldPluginVersion, async (req, res) => {
  const contentLength = req.headers['content-length'];
  console.warn(`[${req.method}] ${req.url} — Content-Length: ${contentLength || 'unknown'} bytes`);

  const koreaderBooks: KoReaderBook[] = req.body.books;
  const newPageStats: PageStat[] = req.body.stats;
  const annotations: Record<string, KoReaderAnnotation[]> = req.body.annotations || {};
  const deviceId: string | undefined = req.body.device_id; // For annotation sync path

  try {
    console.debug('Importing books:', koreaderBooks);
    console.debug('Importing page stats:', newPageStats);
    console.debug(
      'Importing annotations:',
      Object.keys(annotations).length,
      'books with annotations'
    );

    await UploadService.uploadStatisticData(koreaderBooks, newPageStats, annotations, deviceId);
    res.status(200).json({ message: 'Upload successful' });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Error importing data' });
  }
});

// TODO: implement check in koreader plugin
router.get('/health', rejectOldPluginVersion, async (_, res) => {
  res.status(200).json({ message: 'Plugin is healthy' });
});

/**
 * Returns the subset of the given book md5s that have no cover stored yet.
 * The plugin uses this to only extract and upload the covers that are actually missing.
 */
router.post('/covers/status', rejectOldPluginVersion, async (req, res) => {
  const md5s: unknown = req.body?.md5s;

  if (!Array.isArray(md5s)) {
    res.status(400).json({ error: 'Missing md5s' });
    return;
  }

  try {
    const validMd5s = md5s.filter((md5) => CoversService.isValidMd5(md5)) as string[];
    const missing = await CoversService.getMissingMd5s(validMd5s);

    res.status(200).json({ missing });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Error checking covers' });
  }
});

/**
 * Uploads a book cover extracted by the KOReader plugin, identified by the book md5.
 * The body is the raw image data.
 */
router.post(
  '/covers/:md5',
  rejectOldPluginVersion,
  express.raw({ type: ['image/png', 'image/jpeg', 'image/gif'], limit: MAX_COVER_SIZE_BYTES }),
  async (req, res) => {
    const { md5 } = req.params;

    // The md5 becomes part of a filename, so it must be strictly validated
    if (!CoversService.isValidMd5(md5)) {
      res.status(400).json({ error: 'Invalid book md5' });
      return;
    }

    const data = req.body;

    if (!Buffer.isBuffer(data) || data.length === 0) {
      res.status(400).json({ error: 'Missing cover data' });
      return;
    }

    // Trust the actual content, not the declared content type
    const extension = detectImageExtension(data);

    if (!extension) {
      res.status(400).json({ error: 'Unsupported image format' });
      return;
    }

    try {
      const book = await BooksRepository.getByMd5(md5);

      if (!book) {
        res.status(404).json({ error: 'Book not found' });
        return;
      }

      const force = req.query.force === 'true';

      if (!force && (await CoversService.existsForMd5(md5))) {
        res.status(200).json({ message: 'Cover already exists' });
        return;
      }

      await CoversService.saveForMd5(md5, data, extension);
      res.status(200).json({ message: 'Cover uploaded' });
    } catch (err) {
      console.error(err);
      res.status(500).json({ error: 'Error uploading cover' });
    }
  }
);
router.get('/download', (_, res) => {
  const folderPath = path.join(__dirname, '../../../../', 'plugins');
  const archive = archiver('zip', { zlib: { level: 9 } });

  res.setHeader('Content-Type', 'application/zip');
  res.setHeader('Content-Disposition', 'attachment; filename=koinsight.plugin.zip');

  archive.on('error', (err) => {
    console.error('Archive error:', err);
    res.status(500).send('Error creating zip');
  });

  // Pipe the archive directly to the response
  archive.pipe(res);

  // Add folder contents to the archive
  archive.directory(folderPath, false);

  archive.finalize();
});

// The plugin only understands JSON responses, so make sure body parser errors
// (e.g. a cover that exceeds the size limit) don't fall through to the default HTML handler.
router.use((err: any, _req: Request, res: Response, next: NextFunction) => {
  if (err?.type === 'entity.too.large') {
    res.status(413).json({ error: 'Cover too large' });
    return;
  }

  next(err);
});

export { router as kopluginRouter };
