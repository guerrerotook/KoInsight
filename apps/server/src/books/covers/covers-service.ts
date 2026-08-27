import { Book } from '@koinsight/common/types';
import { existsSync, mkdirSync, promises, rename, rmSync } from 'fs';
import path from 'path';
import { appConfig } from '../../config';

const MD5_PATTERN = /^[a-f0-9]{32}$/i;

export class CoversService {
  static isValidMd5(md5: unknown): md5 is string {
    return typeof md5 === 'string' && MD5_PATTERN.test(md5);
  }

  private static ensureCoversDir() {
    if (!existsSync(appConfig.coversPath)) {
      mkdirSync(appConfig.coversPath, { recursive: true });
    }
  }

  private static async findFileForMd5(md5: string): Promise<string | null> {
    this.ensureCoversDir();
    const files = await promises.readdir(appConfig.coversPath);
    return files.find((f) => f.startsWith(md5)) ?? null;
  }

  static async get(book: Book): Promise<string | null> {
    return this.getByMd5(book.md5);
  }

  static async getByMd5(md5: string): Promise<string | null> {
    const file = await this.findFileForMd5(md5);

    if (file) {
      return `${appConfig.coversPath}/${file}`;
    } else {
      return null;
    }
  }

  static async existsForMd5(md5: string): Promise<boolean> {
    return (await this.findFileForMd5(md5)) !== null;
  }

  /**
   * Returns the md5s that have no cover stored yet.
   * Reads the covers directory once, instead of once per md5.
   */
  static async getMissingMd5s(md5s: string[]): Promise<string[]> {
    this.ensureCoversDir();
    const files = await promises.readdir(appConfig.coversPath);
    const stored = new Set(files.map((file) => path.parse(file).name));

    return md5s.filter((md5) => !stored.has(md5));
  }

  static async deleteExisting(book: Book) {
    return this.deleteExistingByMd5(book.md5);
  }

  static async deleteExistingByMd5(md5: string) {
    const file = await this.findFileForMd5(md5);

    if (file) {
      const filePath = `${appConfig.coversPath}/${file}`;
      rmSync(filePath, { force: true });
    }
  }

  static async upload(book: Book, file: Express.Multer.File) {
    this.ensureCoversDir();

    const extension = path.extname(file.originalname) || '';
    const newFilename = `${book.md5}${extension}`;
    const newPath = path.join(path.dirname(file.path), newFilename);
    await rename(file.path, newPath, () => {});
  }

  /**
   * Stores raw image bytes as the cover for the given book md5.
   * Used by the KOReader plugin sync, which uploads covers extracted from the book files.
   */
  static async saveForMd5(md5: string, data: Buffer, extension: string): Promise<string> {
    if (!this.isValidMd5(md5)) {
      throw new Error('Invalid book md5');
    }

    this.ensureCoversDir();
    await this.deleteExistingByMd5(md5);

    const filePath = path.join(appConfig.coversPath, `${md5}${extension}`);
    await promises.writeFile(filePath, data);

    return filePath;
  }
}
