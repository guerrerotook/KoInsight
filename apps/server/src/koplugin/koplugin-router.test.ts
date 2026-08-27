import express from 'express';
import { existsSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'fs';
import { tmpdir } from 'os';
import path from 'path';
import request from 'supertest';
import { appConfig } from '../config';
import { createBook } from '../db/factories/book-factory';
import { createDevice } from '../db/factories/device-factory';
import { fakeKoReaderAnnotation } from '../db/factories/koreader-annotation-factory';
import { db } from '../knex';
import { kopluginRouter, MAX_COVER_SIZE_BYTES, REQUIRED_PLUGIN_VERSION } from './koplugin-router';

const PNG_BYTES = Buffer.concat([
  Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
  Buffer.from('fake png contents'),
]);

describe('koplugin-router', () => {
  const app = express();
  app.use(express.json());
  app.use('/koplugin', kopluginRouter);

  describe('POST /koplugin/device', () => {
    it('registers a device', async () => {
      const response = await request(app)
        .post('/koplugin/device')
        .send({ id: 'device-123', model: 'Kindle Paperwhite', version: REQUIRED_PLUGIN_VERSION });

      expect(response.status).toBe(200);
      expect(response.body).toEqual({ message: 'Device registered successfully' });

      const device = await db('device').where({ id: 'device-123' }).first();
      expect(device).toEqual(
        expect.objectContaining({
          id: 'device-123',
          model: 'Kindle Paperwhite',
        })
      );
    });

    it('returns 400 when device ID is missing', async () => {
      const response = await request(app)
        .post('/koplugin/device')
        .send({ model: 'Kindle', version: REQUIRED_PLUGIN_VERSION });

      expect(response.status).toBe(400);
      expect(response.body).toEqual({ error: 'Missing device ID or model' });
    });

    it('returns 400 when model is missing', async () => {
      const response = await request(app)
        .post('/koplugin/device')
        .send({ id: 'device-123', version: REQUIRED_PLUGIN_VERSION });

      expect(response.status).toBe(400);
      expect(response.body).toEqual({ error: 'Missing device ID or model' });
    });

    it('returns 400 when plugin version is incorrect', async () => {
      const response = await request(app)
        .post('/koplugin/device')
        .send({ id: 'device-123', model: 'Kindle', version: '0.1.0' });

      expect(response.status).toBe(400);
      expect(response.body.error).toContain('Unsupported plugin version');
    });

    it('returns 400 when plugin version is missing', async () => {
      const response = await request(app)
        .post('/koplugin/device')
        .send({ id: 'device-123', model: 'Kindle' });

      expect(response.status).toBe(400);
      expect(response.body.error).toContain('Unsupported plugin version');
    });
  });

  describe('POST /koplugin/import', () => {
    it('imports books and stats', async () => {
      const bookMd5 = 'abc123def456';
      const device = await createDevice(db);

      const response = await request(app)
        .post('/koplugin/import')
        .send({
          version: REQUIRED_PLUGIN_VERSION,
          books: [
            {
              md5: bookMd5,
              title: 'Test Book',
              authors: 'Test Author',
              series: 'Test Series',
              language: 'en',
              pages: 100,
              total_read_time: 60,
              total_read_pages: 1,
            },
          ],
          stats: [
            {
              book_md5: bookMd5,
              device_id: device.id,
              start_time: 1000,
              duration: 60,
              page: 1,
              total_pages: 100,
            },
          ],
          annotations: {},
        });

      expect(response.status).toBe(200);
      expect(response.body).toEqual({ message: 'Upload successful' });

      const book = await db('book').where({ md5: bookMd5 }).first();
      expect(book).toEqual(
        expect.objectContaining({
          md5: bookMd5,
          title: 'Test Book',
          authors: 'Test Author',
        })
      );

      const stat = await db('page_stat').where({ book_md5: bookMd5 }).first();
      expect(stat).toEqual(
        expect.objectContaining({
          book_md5: bookMd5,
          duration: 60,
          page: 1,
        })
      );
    });

    it('imports books with annotations', async () => {
      const bookMd5 = 'def789ghi012';
      const device = await createDevice(db);

      const response = await request(app)
        .post('/koplugin/import')
        .send({
          version: REQUIRED_PLUGIN_VERSION,
          books: [
            {
              md5: bookMd5,
              title: 'Annotated Book',
              authors: 'Test Author',
              language: 'en',
              pages: 200,
              total_read_time: 120,
              total_read_pages: 50,
            },
          ],
          stats: [
            {
              book_md5: bookMd5,
              device_id: device.id,
              start_time: 2000,
              duration: 120,
              page: 10,
              total_pages: 200,
            },
          ],
          annotations: {
            [bookMd5]: [
              fakeKoReaderAnnotation({
                chapter: 'Chapter 1',
                page: 10,
                pageno: 10,
                datetime: '2024-01-15T10:30:00',
                text: 'This is a highlight',
                note: 'Important passage',
              }),
              fakeKoReaderAnnotation({
                chapter: 'Chapter 2',
                page: 25,
                pageno: 25,
                datetime: '2024-01-15T11:00:00',
                text: 'Another highlight',
              }),
            ],
          },
        });

      expect(response.status).toBe(200);
      expect(response.body).toEqual({ message: 'Upload successful' });

      const book = await db('book').where({ md5: bookMd5 }).first();
      expect(book).toEqual(
        expect.objectContaining({
          md5: bookMd5,
          title: 'Annotated Book',
        })
      );

      const annotations = await db('annotation').where({ book_md5: bookMd5 });
      expect(annotations).toHaveLength(2);
      expect(annotations[0]).toEqual(
        expect.objectContaining({
          book_md5: bookMd5,
          device_id: device.id,
          page_ref: '10',
          text: 'This is a highlight',
          note: 'Important passage',
        })
      );
      expect(annotations[1]).toEqual(
        expect.objectContaining({
          page_ref: '25',
          text: 'Another highlight',
          note: null,
        })
      );
    });

    it('returns 400 when plugin version is incorrect', async () => {
      const response = await request(app).post('/koplugin/import').send({
        version: '0.1.0',
        books: [],
        stats: [],
      });

      expect(response.status).toBe(400);
      expect(response.body.error).toContain('Unsupported plugin version');
    });
  });

  describe('GET /koplugin/health', () => {
    it('returns health status', async () => {
      const response = await request(app)
        .get('/koplugin/health')
        .send({ version: REQUIRED_PLUGIN_VERSION });

      expect(response.status).toBe(200);
      expect(response.body).toEqual({ message: 'Plugin is healthy' });
    });

    it('returns 400 when plugin version is incorrect', async () => {
      const response = await request(app).get('/koplugin/health').send({ version: '0.1.0' });

      expect(response.status).toBe(400);
      expect(response.body.error).toContain('Unsupported plugin version');
    });
  });

  describe('GET /koplugin/download', () => {
    it('returns a zip file', async () => {
      const response = await request(app).get('/koplugin/download');

      expect(response.status).toBe(200);
      expect(response.headers['content-type']).toBe('application/zip');
      expect(response.headers['content-disposition']).toContain('koinsight.plugin.zip');
    });
  });

  describe('covers', () => {
    const originalCoversPath = appConfig.coversPath;
    let coversPath: string;

    beforeEach(() => {
      coversPath = mkdtempSync(path.join(tmpdir(), 'koinsight-covers-'));
      appConfig.coversPath = coversPath;
    });

    afterEach(() => {
      rmSync(coversPath, { recursive: true, force: true });
      appConfig.coversPath = originalCoversPath;
    });

    describe('POST /koplugin/covers/status', () => {
      it('returns only the md5s without a stored cover', async () => {
        const withCover = 'a'.repeat(32);
        const withoutCover = 'b'.repeat(32);
        writeFileSync(path.join(coversPath, `${withCover}.png`), PNG_BYTES);

        const response = await request(app)
          .post('/koplugin/covers/status')
          .send({ version: REQUIRED_PLUGIN_VERSION, md5s: [withCover, withoutCover] });

        expect(response.status).toBe(200);
        expect(response.body).toEqual({ missing: [withoutCover] });
      });

      it('ignores invalid md5s', async () => {
        const response = await request(app)
          .post('/koplugin/covers/status')
          .send({ version: REQUIRED_PLUGIN_VERSION, md5s: ['not-an-md5', '../../etc/passwd'] });

        expect(response.status).toBe(200);
        expect(response.body).toEqual({ missing: [] });
      });

      it('returns 400 when md5s are missing', async () => {
        const response = await request(app)
          .post('/koplugin/covers/status')
          .send({ version: REQUIRED_PLUGIN_VERSION });

        expect(response.status).toBe(400);
        expect(response.body).toEqual({ error: 'Missing md5s' });
      });

      it('returns 400 when plugin version is incorrect', async () => {
        const response = await request(app)
          .post('/koplugin/covers/status')
          .send({ version: '0.1.0', md5s: [] });

        expect(response.status).toBe(400);
        expect(response.body.error).toContain('Unsupported plugin version');
      });
    });

    describe('POST /koplugin/covers/:md5', () => {
      const postCover = (md5: string, body: Buffer, query = '') =>
        request(app)
          .post(`/koplugin/covers/${md5}${query}`)
          .set('X-KoInsight-Plugin-Version', REQUIRED_PLUGIN_VERSION)
          .set('Content-Type', 'image/png')
          .send(body);

      it('stores the uploaded cover under the book md5', async () => {
        const book = await createBook(db, { md5: 'c'.repeat(32) });

        const response = await postCover(book.md5, PNG_BYTES);

        expect(response.status).toBe(200);
        expect(response.body).toEqual({ message: 'Cover uploaded' });

        const storedPath = path.join(coversPath, `${book.md5}.png`);
        expect(existsSync(storedPath)).toBe(true);
        expect(readFileSync(storedPath)).toEqual(PNG_BYTES);
      });

      it('does not overwrite an existing cover', async () => {
        const book = await createBook(db, { md5: 'd'.repeat(32) });
        const existing = path.join(coversPath, `${book.md5}.jpg`);
        writeFileSync(existing, Buffer.from('existing cover'));

        const response = await postCover(book.md5, PNG_BYTES);

        expect(response.status).toBe(200);
        expect(response.body).toEqual({ message: 'Cover already exists' });
        expect(readFileSync(existing).toString()).toBe('existing cover');
      });

      it('overwrites an existing cover when forced', async () => {
        const book = await createBook(db, { md5: 'e'.repeat(32) });
        writeFileSync(path.join(coversPath, `${book.md5}.jpg`), Buffer.from('existing cover'));

        const response = await postCover(book.md5, PNG_BYTES, '?force=true');

        expect(response.status).toBe(200);
        expect(response.body).toEqual({ message: 'Cover uploaded' });
        expect(readdirSync(coversPath)).toEqual([`${book.md5}.png`]);
      });

      it('returns 400 for an md5 that could escape the covers directory', async () => {
        const response = await postCover('..%2f..%2fescaped', PNG_BYTES);

        expect(response.status).toBe(400);
        expect(response.body).toEqual({ error: 'Invalid book md5' });
        expect(readdirSync(coversPath)).toEqual([]);
      });

      it('returns 400 for an md5 that is not 32 hex characters', async () => {
        const response = await postCover('z'.repeat(32), PNG_BYTES);

        expect(response.status).toBe(400);
        expect(response.body).toEqual({ error: 'Invalid book md5' });
      });

      it('returns 400 when the body is not a supported image', async () => {
        const book = await createBook(db, { md5: 'f'.repeat(32) });

        const response = await postCover(book.md5, Buffer.from('<html>not an image</html>'));

        expect(response.status).toBe(400);
        expect(response.body).toEqual({ error: 'Unsupported image format' });
        expect(readdirSync(coversPath)).toEqual([]);
      });

      it('returns 400 when the body is empty', async () => {
        const book = await createBook(db, { md5: '0'.repeat(32) });

        const response = await postCover(book.md5, Buffer.alloc(0));

        expect(response.status).toBe(400);
        expect(response.body).toEqual({ error: 'Missing cover data' });
      });

      it('returns 404 for an unknown book', async () => {
        const response = await postCover('1'.repeat(32), PNG_BYTES);

        expect(response.status).toBe(404);
        expect(response.body).toEqual({ error: 'Book not found' });
        expect(readdirSync(coversPath)).toEqual([]);
      });

      it('returns 413 when the cover is too large', async () => {
        const book = await createBook(db, { md5: '2'.repeat(32) });
        const tooLarge = Buffer.concat([PNG_BYTES, Buffer.alloc(MAX_COVER_SIZE_BYTES)]);

        const response = await postCover(book.md5, tooLarge);

        expect(response.status).toBe(413);
        expect(response.body).toEqual({ error: 'Cover too large' });
        expect(readdirSync(coversPath)).toEqual([]);
      });

      it('returns 400 when plugin version is incorrect', async () => {
        const book = await createBook(db, { md5: '3'.repeat(32) });

        const response = await request(app)
          .post(`/koplugin/covers/${book.md5}`)
          .set('X-KoInsight-Plugin-Version', '0.1.0')
          .set('Content-Type', 'image/png')
          .send(PNG_BYTES);

        expect(response.status).toBe(400);
        expect(response.body.error).toContain('Unsupported plugin version');
      });

      it('accepts the plugin version from the query string', async () => {
        const book = await createBook(db, { md5: '4'.repeat(32) });

        const response = await request(app)
          .post(`/koplugin/covers/${book.md5}?version=${REQUIRED_PLUGIN_VERSION}`)
          .set('Content-Type', 'image/png')
          .send(PNG_BYTES);

        expect(response.status).toBe(200);
        expect(response.body).toEqual({ message: 'Cover uploaded' });
      });
    });
  });
});
