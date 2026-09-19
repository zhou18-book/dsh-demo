import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:xml/xml.dart';

import '../data/library_repo.dart';
import '../data/models.dart';

class ImportResult {
  const ImportResult({required this.book, required this.duplicate});

  final Book book;

  /// True when this exact file (by content hash) was already on the shelf.
  final bool duplicate;
}

/// Imports EPUB files into the app's private book directory.
///
/// Only DRM-free EPUB is supported. Encrypted books (Adobe ADEPT, Readium LCP, or
/// the vendor schemes used by Kindle/JD/Zhangyue) cannot be parsed, and this project
/// does not attempt to break them.
class ImportService {
  ImportService({LibraryRepo? repo}) : _repo = repo ?? LibraryRepo();

  final LibraryRepo _repo;

  Future<Directory> booksDirectory() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'books'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<ImportResult> importFile(String sourcePath) async {
    final source = File(sourcePath);
    if (!await source.exists()) {
      throw const FormatException('选择的文件不存在');
    }

    final bytes = await source.readAsBytes();
    if (bytes.length < 4 || bytes[0] != 0x50 || bytes[1] != 0x4B) {
      throw const FormatException('这不是一个有效的 EPUB 文件（应为 ZIP 容器）');
    }

    final id = sha256.convert(bytes).toString();
    final existing = await _repo.getBook(id);
    if (existing != null && !existing.deleted) {
      return ImportResult(book: existing, duplicate: true);
    }

    final dir = await booksDirectory();
    final dest = File(p.join(dir.path, '$id.epub'));
    if (!await dest.exists()) {
      await dest.writeAsBytes(bytes, flush: true);
    }

    final meta = _extractMetadata(bytes);
    final now = DateTime.now().millisecondsSinceEpoch;
    final fallbackTitle = p.basenameWithoutExtension(sourcePath).trim();

    final book = Book(
      id: id,
      title: meta.title ?? (fallbackTitle.isEmpty ? '未命名' : fallbackTitle),
      author: meta.author,
      filePath: dest.path,
      addedAt: now,
      updatedAt: now,
    );
    await _repo.upsertBook(book);
    return ImportResult(book: book, duplicate: false);
  }

  /// Records metadata that the reader learned from foliate, so the shelf entry
  /// improves after the first successful open even if the OPF parse missed it.
  Future<void> applyDiscoveredMetadata(
    String bookId, {
    String? title,
    String? author,
  }) async {
    if ((title == null || title.isEmpty) && (author == null || author.isEmpty)) return;
    final current = await _repo.getBook(bookId);
    if (current == null) return;
    final betterTitle =
        (title != null && title.trim().isNotEmpty) ? title.trim() : current.title;
    final betterAuthor =
        (author != null && author.trim().isNotEmpty) ? author.trim() : current.author;
    if (betterTitle == current.title && betterAuthor == current.author) return;
    await _repo.touchBook(bookId, title: betterTitle, author: betterAuthor);
  }

  /* ------------------------------------------------------------- OPF parsing */

  static _EpubMeta _extractMetadata(Uint8List bytes) {
    Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes, verify: false);
    } catch (_) {
      return const _EpubMeta();
    }

    String? opfPath;
    final container = _readEntry(archive, 'META-INF/container.xml');
    if (container != null) {
      final match = RegExp(r'full-path\s*=\s*"([^"]+)"').firstMatch(container);
      opfPath = match?.group(1);
    }
    opfPath ??= archive.files
        .map((f) => f.name)
        .firstWhere((n) => n.toLowerCase().endsWith('.opf'), orElse: () => '');
    if (opfPath.isEmpty) return const _EpubMeta();

    final opfText = _readEntry(archive, opfPath);
    if (opfText == null) return const _EpubMeta();

    try {
      final doc = XmlDocument.parse(opfText);
      final title = _firstElementText(doc, 'title');
      final creator = _firstElementText(doc, 'creator');
      final language = _firstElementText(doc, 'language');
      return _EpubMeta(title: title, author: creator, language: language);
    } catch (_) {
      return const _EpubMeta();
    }
  }

  /// Matches on local name so both `dc:title` and a namespaced `title` work.
  static String? _firstElementText(XmlDocument doc, String localName) {
    for (final element in doc.descendantElements) {
      if (element.name.local == localName) {
        final text = element.innerText.trim();
        if (text.isNotEmpty) return text;
      }
    }
    return null;
  }

  static String? _readEntry(Archive archive, String name) {
    final file = archive.findFile(name);
    if (file == null) return null;
    // Widened to List<int> on purpose: archive's content type has changed between
    // major versions, and utf8/latin1 decoding accepts any byte list.
    final List<int> raw = file.content;
    try {
      return utf8.decode(raw);
    } catch (_) {
      return latin1.decode(raw, allowInvalid: true);
    }
  }
}

class _EpubMeta {
  const _EpubMeta({this.title, this.author, this.language});

  final String? title;
  final String? author;
  final String? language;
}
