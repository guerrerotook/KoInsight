# Changelog

## [Unreleased]

### New Features

Plugin Self-Update: The KOReader plugin can now update itself. "Check for plugin update" in the KoInsight menu looks up the newest release of this repository, downloads the `koinsight.koplugin.zip` attached to it, verifies its SHA-256 checksum and unpacks it over the installed plugin. KOReader has to be restarted to load the new version.

Plugin Release Archive: Publishing a GitHub release now automatically builds `koinsight.koplugin.zip` and attaches it to that release, so the self-updater (and anyone who prefers to install by hand) always has an up-to-date bundle.

Book Cover Sync: The KOReader plugin now extracts the cover embedded in each of your book files and uploads it during a full sync ("Synchronize data"), so covers no longer have to be added manually book by book. Covers are downscaled on the device before upload, and a book is only looked at once. A cover you picked yourself in the web UI is never overwritten. Cover sync can be turned off with the "Sync book covers" option, and "Re-upload book covers" re-checks every book.

Bulk Annotation Sync: The "Synchronize data" button now syncs all annotations from all books in your reading history at once (previously only the currently open book). Sync on suspend still syncs statistics and annotations for the currently open book only (keeping suspend snappy).

### Bug Fixes

Fixed Book Duplicates: Some users saw the same book twice in KoInsight, one with statistics, one with annotations. We now match books using their unique MD5 checksum instead of title.

If you have duplicates, either:

1. Delete your database and re-sync (recommended - clean start)
2. Manually delete duplicate books in the web interface (the faulty one)

New syncs won't create duplicates. If you still see duplicates, you most likely have duplicates in your KoReader statistics database and KoInsight makes those visible.

### Breaking Changes

Plugin version 0.4.0 required. Update it before syncing.

---

## [0.2.2] - 2026-01-11

### Added

- Annotation sync support for currently open book
- Mark deleted annotations in the database

### Fixed

- Annotations now properly marked as deleted when removed in KoReader
- Docker build issues

## [0.2.0] - 2026-01-11

### Added

- Plugin versioning system
- Server validates plugin version before accepting data

### Changed

- **BREAKING:** Server now requires specific plugin version

---

## Earlier Versions

See git history for changes prior to v0.2.0.

[Unreleased]: https://github.com/GeorgeSG/koinsight/compare/v0.2.2...HEAD
[0.2.2]: https://github.com/GeorgeSG/koinsight/compare/v0.2.0...v0.2.2
[0.2.0]: https://github.com/GeorgeSG/koinsight/releases/tag/v0.2.0
