import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// SQLite schema.
///
/// Deliberately sync-ready even though the MVP is offline-only:
///  * natural keys (content hash for books, UUID for annotations) so two devices
///    converge on the same row instead of duplicating;
///  * `updated_at` for last-write-wins;
///  * `deleted` tombstones rather than hard deletes, so a delete can propagate;
///  * `dirty` so a future push only uploads rows that actually changed.
class AppDb {
  AppDb._();

  static final AppDb instance = AppDb._();

  static const _dbName = 'ebook_reader.db';
  static const _schemaVersion = 1;

  Database? _db;

  Future<Database> get database async => _db ??= await _open();

  Future<Database> _open() async {
    final dir = await getDatabasesPath();
    final path = p.join(dir, _dbName);
    return openDatabase(
      path,
      version: _schemaVersion,
      onCreate: _onCreate,
      onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE books (
        id          TEXT PRIMARY KEY,
        title       TEXT NOT NULL,
        author      TEXT,
        file_path   TEXT NOT NULL,
        cover_path  TEXT,
        added_at    INTEGER NOT NULL,
        updated_at  INTEGER NOT NULL,
        deleted     INTEGER NOT NULL DEFAULT 0,
        dirty       INTEGER NOT NULL DEFAULT 1
      )
    ''');

    await db.execute('''
      CREATE TABLE progress (
        book_id       TEXT PRIMARY KEY,
        cfi           TEXT NOT NULL,
        fraction      REAL NOT NULL DEFAULT 0,
        section_label TEXT,
        updated_at    INTEGER NOT NULL,
        deleted       INTEGER NOT NULL DEFAULT 0,
        dirty         INTEGER NOT NULL DEFAULT 1,
        FOREIGN KEY (book_id) REFERENCES books (id) ON DELETE CASCADE
      )
    ''');

    await db.execute('''
      CREATE TABLE annotations (
        id         TEXT PRIMARY KEY,
        book_id    TEXT NOT NULL,
        cfi        TEXT NOT NULL,
        text       TEXT NOT NULL DEFAULT '',
        color      TEXT NOT NULL DEFAULT '#ffd54f',
        note       TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        deleted    INTEGER NOT NULL DEFAULT 0,
        dirty      INTEGER NOT NULL DEFAULT 1,
        FOREIGN KEY (book_id) REFERENCES books (id) ON DELETE CASCADE
      )
    ''');

    await db.execute(
      'CREATE INDEX idx_annotations_book ON annotations (book_id, deleted, created_at)',
    );
    await db.execute('CREATE INDEX idx_books_deleted ON books (deleted, added_at)');
    await db.execute('CREATE INDEX idx_dirty_annotations ON annotations (dirty)');
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
