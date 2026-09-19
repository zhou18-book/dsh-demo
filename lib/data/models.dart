/// Data models.
///
/// Every mutable record carries `updatedAt`, a `deleted` tombstone flag and a `dirty`
/// flag. The MVP never syncs, but the schema is already shaped for the later
/// Supabase "last write wins by updated_at" merge: a client pushes rows where
/// dirty = 1 and pulls rows whose updated_at is newer than its watermark, applying
/// deletions instead of hard-deleting locally.
library;

class Book {
  const Book({
    required this.id,
    required this.title,
    this.author,
    required this.filePath,
    this.coverPath,
    required this.addedAt,
    required this.updatedAt,
    this.deleted = false,
    this.dirty = true,
  });

  /// SHA-256 of the EPUB bytes. Doubles as the content-addressed dedupe key, so
  /// importing the same file twice is a no-op instead of a duplicate shelf entry.
  final String id;
  final String title;
  final String? author;
  final String filePath;
  final String? coverPath;
  final int addedAt;
  final int updatedAt;
  final bool deleted;
  final bool dirty;

  Book copyWith({
    String? title,
    String? author,
    String? filePath,
    String? coverPath,
    int? updatedAt,
    bool? deleted,
    bool? dirty,
  }) {
    return Book(
      id: id,
      title: title ?? this.title,
      author: author ?? this.author,
      filePath: filePath ?? this.filePath,
      coverPath: coverPath ?? this.coverPath,
      addedAt: addedAt,
      updatedAt: updatedAt ?? this.updatedAt,
      deleted: deleted ?? this.deleted,
      dirty: dirty ?? this.dirty,
    );
  }

  Map<String, Object?> toMap() => {
        'id': id,
        'title': title,
        'author': author,
        'file_path': filePath,
        'cover_path': coverPath,
        'added_at': addedAt,
        'updated_at': updatedAt,
        'deleted': deleted ? 1 : 0,
        'dirty': dirty ? 1 : 0,
      };

  factory Book.fromMap(Map<String, Object?> m) => Book(
        id: m['id']! as String,
        title: (m['title'] as String?) ?? '未命名',
        author: m['author'] as String?,
        filePath: (m['file_path'] as String?) ?? '',
        coverPath: m['cover_path'] as String?,
        addedAt: (m['added_at'] as int?) ?? 0,
        updatedAt: (m['updated_at'] as int?) ?? 0,
        deleted: (m['deleted'] as int? ?? 0) == 1,
        dirty: (m['dirty'] as int? ?? 1) == 1,
      );
}

class ReadingProgress {
  const ReadingProgress({
    required this.bookId,
    required this.cfi,
    required this.fraction,
    this.sectionLabel,
    required this.updatedAt,
    this.deleted = false,
    this.dirty = true,
  });

  final String bookId;

  /// EPUB Canonical Fragment Identifier. Stable across devices and across font
  /// size / layout changes, which is exactly why it is the sync anchor.
  final String cfi;

  /// 0..1 within the whole book.
  final double fraction;
  final String? sectionLabel;
  final int updatedAt;
  final bool deleted;
  final bool dirty;

  ReadingProgress copyWith({
    String? cfi,
    double? fraction,
    String? sectionLabel,
    int? updatedAt,
    bool? deleted,
    bool? dirty,
  }) {
    return ReadingProgress(
      bookId: bookId,
      cfi: cfi ?? this.cfi,
      fraction: fraction ?? this.fraction,
      sectionLabel: sectionLabel ?? this.sectionLabel,
      updatedAt: updatedAt ?? this.updatedAt,
      deleted: deleted ?? this.deleted,
      dirty: dirty ?? this.dirty,
    );
  }

  Map<String, Object?> toMap() => {
        'book_id': bookId,
        'cfi': cfi,
        'fraction': fraction,
        'section_label': sectionLabel,
        'updated_at': updatedAt,
        'deleted': deleted ? 1 : 0,
        'dirty': dirty ? 1 : 0,
      };

  factory ReadingProgress.fromMap(Map<String, Object?> m) => ReadingProgress(
        bookId: m['book_id']! as String,
        cfi: (m['cfi'] as String?) ?? '',
        fraction: (m['fraction'] as num?)?.toDouble() ?? 0,
        sectionLabel: m['section_label'] as String?,
        updatedAt: (m['updated_at'] as int?) ?? 0,
        deleted: (m['deleted'] as int? ?? 0) == 1,
        dirty: (m['dirty'] as int? ?? 1) == 1,
      );
}

/// Four-colour highlighter, optionally carrying a one-line note.
class Annotation {
  const Annotation({
    required this.id,
    required this.bookId,
    required this.cfi,
    required this.text,
    required this.color,
    this.note,
    required this.createdAt,
    required this.updatedAt,
    this.deleted = false,
    this.dirty = true,
  });

  final String id;
  final String bookId;
  final String cfi;
  final String text;
  final String color;
  final String? note;
  final int createdAt;
  final int updatedAt;
  final bool deleted;
  final bool dirty;

  Annotation copyWith({
    String? text,
    String? color,
    String? note,
    bool clearNote = false,
    int? updatedAt,
    bool? deleted,
    bool? dirty,
  }) {
    return Annotation(
      id: id,
      bookId: bookId,
      cfi: cfi,
      text: text ?? this.text,
      color: color ?? this.color,
      note: clearNote ? null : (note ?? this.note),
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      deleted: deleted ?? this.deleted,
      dirty: dirty ?? this.dirty,
    );
  }

  Map<String, Object?> toMap() => {
        'id': id,
        'book_id': bookId,
        'cfi': cfi,
        'text': text,
        'color': color,
        'note': note,
        'created_at': createdAt,
        'updated_at': updatedAt,
        'deleted': deleted ? 1 : 0,
        'dirty': dirty ? 1 : 0,
      };

  factory Annotation.fromMap(Map<String, Object?> m) => Annotation(
        id: m['id']! as String,
        bookId: m['book_id']! as String,
        cfi: (m['cfi'] as String?) ?? '',
        text: (m['text'] as String?) ?? '',
        color: (m['color'] as String?) ?? '#ffd54f',
        note: m['note'] as String?,
        createdAt: (m['created_at'] as int?) ?? 0,
        updatedAt: (m['updated_at'] as int?) ?? 0,
        deleted: (m['deleted'] as int? ?? 0) == 1,
        dirty: (m['dirty'] as int? ?? 1) == 1,
      );

  /// Shape handed to the WebView bridge (foliate expects `value` to hold the CFI).
  Map<String, Object?> toBridgeJson() => {
        'id': id,
        'value': cfi,
        'text': text,
        'color': color,
        'note': note,
      };
}

/// Palette offered by the highlight toolbar.
class HighlightColors {
  static const yellow = '#ffd54f';
  static const green = '#aed581';
  static const blue = '#81d4fa';
  static const pink = '#f48fb1';

  static const all = <String>[yellow, green, blue, pink];

  static const labels = <String, String>{
    yellow: '黄',
    green: '绿',
    blue: '蓝',
    pink: '粉',
  };
}
