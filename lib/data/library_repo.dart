import 'package:sqflite/sqflite.dart';

import 'app_db.dart';
import 'models.dart';

class LibraryRepo {
  LibraryRepo({AppDb? db}) : _db = db ?? AppDb.instance;

  final AppDb _db;

  Future<Database> get _d => _db.database;

  /* ------------------------------------------------------------------ books */

  Future<List<Book>> listBooks() async {
    final db = await _d;
    final rows = await db.query(
      'books',
      where: 'deleted = 0',
      orderBy: 'COALESCE(NULLIF(added_at,0), added_at) DESC',
    );
    return rows.map(Book.fromMap).toList();
  }

  Future<Book?> getBook(String id) async {
    final db = await _d;
    final rows = await db.query('books', where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return null;
    return Book.fromMap(rows.first);
  }

  Future<bool> hasBook(String id) async {
    final db = await _d;
    final rows = await db.query('books', columns: ['id'], where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isNotEmpty;
  }

  Future<void> upsertBook(Book book) async {
    final db = await _d;
    await db.insert('books', book.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> touchBook(String id, {String? title, String? author}) async {
    final db = await _d;
    await db.update(
      'books',
      {
        'title': ?title,
        'author': ?author,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
        'dirty': 1,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Upgrades shelf metadata only when the incoming value is actually better, so a
  /// filename-derived title never overwrites a real OPF title and vice versa.
  Future<void> touchBookIfBetter(String id, {String? title, String? author}) async {
    final current = await getBook(id);
    if (current == null) return;
    final betterTitle = (title != null && title.trim().isNotEmpty) ? title.trim() : null;
    final betterAuthor = (author != null && author.trim().isNotEmpty) ? author.trim() : null;
    final titleChanged = betterTitle != null && betterTitle != current.title;
    final authorChanged = betterAuthor != null && betterAuthor != current.author;
    if (!titleChanged && !authorChanged) return;
    await touchBook(id, title: betterTitle, author: betterAuthor);
  }

  /// Soft delete: keeps the tombstone so a future sync can propagate the removal.
  Future<void> deleteBook(String id) async {
    final db = await _d;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.update('books', {'deleted': 1, 'updated_at': now, 'dirty': 1},
        where: 'id = ?', whereArgs: [id]);
    await db.update('annotations', {'deleted': 1, 'updated_at': now, 'dirty': 1},
        where: 'book_id = ?', whereArgs: [id]);
    await db.update('progress', {'deleted': 1, 'updated_at': now, 'dirty': 1},
        where: 'book_id = ?', whereArgs: [id]);
  }

  /* --------------------------------------------------------------- progress */

  Future<ReadingProgress?> getProgress(String bookId) async {
    final db = await _d;
    final rows = await db.query('progress',
        where: 'book_id = ? AND deleted = 0', whereArgs: [bookId], limit: 1);
    if (rows.isEmpty) return null;
    return ReadingProgress.fromMap(rows.first);
  }

  Future<void> saveProgress({
    required String bookId,
    required String cfi,
    required double fraction,
    String? sectionLabel,
  }) async {
    final db = await _d;
    final existing = await getProgress(bookId);
    // Never regress a stored position because of a transient relocate event.
    if (existing != null && cfi == existing.cfi) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.insert(
      'progress',
      ReadingProgress(
        bookId: bookId,
        cfi: cfi,
        fraction: fraction,
        sectionLabel: sectionLabel,
        updatedAt: now,
      ).toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<Map<String, ReadingProgress>> listProgress() async {
    final db = await _d;
    final rows = await db.query('progress', where: 'deleted = 0');
    return {
      for (final r in rows)
        (r['book_id'] as String): ReadingProgress.fromMap(r),
    };
  }

  /* ------------------------------------------------------------ annotations */

  Future<List<Annotation>> listAnnotations(String bookId) async {
    final db = await _d;
    final rows = await db.query(
      'annotations',
      where: 'book_id = ? AND deleted = 0',
      whereArgs: [bookId],
      orderBy: 'created_at ASC',
    );
    return rows.map(Annotation.fromMap).toList();
  }

  Future<List<Annotation>> listAllAnnotations() async {
    final db = await _d;
    final rows = await db.query('annotations',
        where: 'deleted = 0', orderBy: 'created_at ASC');
    return rows.map(Annotation.fromMap).toList();
  }

  Future<Map<String, int>> annotationCounts() async {
    final db = await _d;
    final rows = await db.rawQuery(
      'SELECT book_id, COUNT(*) AS n FROM annotations WHERE deleted = 0 GROUP BY book_id',
    );
    return {
      for (final r in rows) (r['book_id'] as String): (r['n'] as int? ?? 0),
    };
  }

  Future<void> upsertAnnotation(Annotation a) async {
    final db = await _d;
    await db.insert('annotations', a.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> updateAnnotationNote(String id, String? note, {String? color}) async {
    final db = await _d;
    await db.update(
      'annotations',
      {
        'note': note,
        'color': ?color,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
        'dirty': 1,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> deleteAnnotation(String id) async {
    final db = await _d;
    await db.update(
      'annotations',
      {
        'deleted': 1,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
        'dirty': 1,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }
}
