import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/models.dart';

/// Exports highlights and notes as Markdown.
///
/// One file per book, with YAML front matter so the output drops straight into an
/// Obsidian / Siyuan vault without post-processing. Re-exporting overwrites the same
/// filename, so pointing it at a vault folder keeps the note in sync rather than
/// piling up copies.
class MarkdownExport {
  static const String _frontMatterSource = 'ebook_reader';

  Future<Directory> exportsDirectory() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(base.path, 'exports'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<File> exportBook({
    required Book book,
    required List<Annotation> annotations,
    required ReadingProgress? progress,
  }) async {
    final dir = await exportsDirectory();
    final file = File(p.join(dir.path, '${_sanitizeFileName(book.title)}.md'));
    await file.writeAsString(
      render(book: book, annotations: annotations, progress: progress),
      flush: true,
    );
    return file;
  }

  String render({
    required Book book,
    required List<Annotation> annotations,
    required ReadingProgress? progress,
  }) {
    final sorted = [...annotations]..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    final buffer = StringBuffer();

    buffer.writeln('---');
    buffer.writeln('title: ${_yaml(book.title)}');
    if ((book.author ?? '').trim().isNotEmpty) {
      buffer.writeln('author: ${_yaml(book.author!.trim())}');
    }
    buffer.writeln('source: $_frontMatterSource');
    buffer.writeln('book_id: ${book.id}');
    buffer.writeln('exported: ${DateTime.now().toIso8601String()}');
    buffer.writeln('highlights: ${sorted.length}');
    if (progress != null) {
      buffer.writeln('reading_progress: ${(progress.fraction * 100).toStringAsFixed(1)}%');
      if ((progress.sectionLabel ?? '').isNotEmpty) {
        buffer.writeln('reading_position: ${_yaml(progress.sectionLabel!)}');
      }
    }
    buffer.writeln('---');
    buffer.writeln();

    buffer.writeln('# ${book.title}');
    buffer.writeln();

    if (sorted.isEmpty) {
      buffer.writeln('_这本书还没有高亮或批注。_');
      buffer.writeln();
      return buffer.toString();
    }

    for (final a in sorted) {
      // Collapse the whitespace foliate's selection text tends to carry.
      final text = a.text.replaceAll(RegExp(r'\s+'), ' ').trim();
      buffer.writeln('> $text');
      buffer.writeln();
      final note = (a.note ?? '').trim();
      if (note.isNotEmpty) {
        for (final line in note.split('\n')) {
          buffer.writeln(line);
        }
        buffer.writeln();
      }
      buffer.writeln(
        '<sub>${_formatDate(a.createdAt)} · 颜色 ${HighlightColors.labels[a.color] ?? a.color} · '
        '`${a.cfi}`</sub>',
      );
      buffer.writeln();
      buffer.writeln('---');
      buffer.writeln();
    }

    return buffer.toString();
  }

  /// Writes the combined "all notes" file, overwriting on each run.
  Future<File> exportCombined({
    required List<Book> books,
    required Map<String, List<Annotation>> annotationsByBook,
  }) async {
    final dir = await exportsDirectory();
    final file = File(p.join(dir.path, '全部读书笔记.md'));
    await file.writeAsString(
      renderCombined(books: books, annotationsByBook: annotationsByBook),
      flush: true,
    );
    return file;
  }

  /// All books in one file, ordered by highlight time — useful as a reading log.
  String renderCombined({
    required List<Book> books,
    required Map<String, List<Annotation>> annotationsByBook,
  }) {
    final buffer = StringBuffer();
    buffer.writeln('---');
    buffer.writeln('title: 全部读书笔记');
    buffer.writeln('source: $_frontMatterSource');
    buffer.writeln('exported: ${DateTime.now().toIso8601String()}');
    buffer.writeln('books: ${books.length}');
    buffer.writeln('---');
    buffer.writeln();
    for (final book in books) {
      final list = annotationsByBook[book.id] ?? const <Annotation>[];
      if (list.isEmpty) continue;
      buffer.writeln('## ${book.title}');
      buffer.writeln();
      if ((book.author ?? '').trim().isNotEmpty) {
        buffer.writeln('*${book.author!.trim()}*');
        buffer.writeln();
      }
      for (final a in list) {
        final text = a.text.replaceAll(RegExp(r'\s+'), ' ').trim();
        buffer.writeln('> $text');
        buffer.writeln();
        final note = (a.note ?? '').trim();
        if (note.isNotEmpty) {
          buffer.writeln(note);
          buffer.writeln();
        }
      }
      buffer.writeln('---');
      buffer.writeln();
    }
    return buffer.toString();
  }

  static String _formatDate(int epochMillis) {
    final d = DateTime.fromMillisecondsSinceEpoch(epochMillis);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  /// Quotes and escapes for a single-line YAML scalar.
  static String _yaml(String raw) {
    final escaped = raw
        .replaceAll('\\', r'\\')
        .replaceAll('"', r'\"')
        .replaceAll('\n', ' ')
        .replaceAll('\r', ' ')
        .trim();
    return '"$escaped"';
  }

  /// Public helper so UI code can propose a filename without duplicating the
  /// sanitising rules.
  static String fileNameFor(String title) => '${_sanitizeFileName(title)}.md';

  static String _sanitizeFileName(String raw) {    var name = raw.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_').trim();
    name = name.replaceAll(RegExp(r'\s+'), ' ');
    if (name.isEmpty) name = 'untitled';
    if (name.length > 80) name = name.substring(0, 80).trim();
    // Windows refuses these as file names even with an extension.
    if (RegExp(r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$', caseSensitive: false).hasMatch(name)) {
      name = '${name}_book';
    }
    return name;
  }
}
