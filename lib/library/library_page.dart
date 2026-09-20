import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../data/library_repo.dart';
import '../data/models.dart';
import '../export/export_action.dart';
import '../export/markdown_export.dart';
import '../reader/reader_page.dart';
import '../version.dart';
import 'import_service.dart';

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  final LibraryRepo _repo = LibraryRepo();
  final ImportService _importer = ImportService();
  final MarkdownExport _exporter = MarkdownExport();

  List<Book> _books = const [];
  Map<String, int> _counts = const {};
  Map<String, ReadingProgress> _progress = const {};

  bool _loading = true;
  bool _importing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final books = await _repo.listBooks();
    final counts = await _repo.annotationCounts();
    final progress = await _repo.listProgress();
    if (!mounted) return;
    setState(() {
      _books = books;
      _counts = counts;
      _progress = progress;
      _loading = false;
    });
  }

  /* ------------------------------------------------------------------ actions */

  Future<void> _import() async {
    List<PlatformFile> picked;
    try {
      // file_picker 13 exposes static methods; there is no FilePicker.platform any more.
      picked = await FilePicker.pickFiles(
        dialogTitle: '选择 EPUB 文件',
        type: FileType.custom,
        allowedExtensions: const ['epub'],
      );
    } catch (error) {
      _toast('无法打开文件选择器：$error');
      return;
    }
    if (picked.isEmpty) return;

    setState(() => _importing = true);
    var added = 0;
    var duplicates = 0;
    final failures = <String>[];

    for (final file in picked) {
      final path = file.path;
      if (path == null) {
        failures.add('${file.name}: 无法读取路径');
        continue;
      }
      try {
        final result = await _importer.importFile(path);
        if (result.duplicate) {
          duplicates++;
        } else {
          added++;
        }
      } catch (error) {
        failures.add('${file.name}: $error');
      }
    }

    await _load();
    if (!mounted) return;
    setState(() => _importing = false);

    final parts = <String>[
      if (added > 0) '已导入 $added 本',
      if (duplicates > 0) '跳过 $duplicates 本重复',
      if (failures.isNotEmpty) '失败 ${failures.length} 本',
    ];
    _toast(parts.isEmpty ? '没有导入任何书' : parts.join('，'));

    if (failures.isNotEmpty) {
      // Surface the first real reason instead of swallowing it.
      debugPrint('[import] ${failures.join('\n')}');
    }
  }

  Future<void> _open(Book book) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => ReaderPage(book: book)),
    );
    await _load();
  }

  Future<void> _delete(Book book) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('从书架移除？'),
        content: Text('《${book.title}》及其高亮批注会一并移除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _repo.deleteBook(book.id);
    await _load();
  }

  Future<void> _exportBook(Book book) async {
    final annotations = await _repo.listAnnotations(book.id);
    final progress = await _repo.getProgress(book.id);
    final content = _exporter.render(
      book: book,
      annotations: annotations,
      progress: progress,
    );
    final path = await saveMarkdownFile(
      fileName: MarkdownExport.fileNameFor(book.title),
      content: content,
    );
    _toast('已导出 ${annotations.length} 条到\n$path');
  }

  Future<void> _exportAll() async {
    final all = await _repo.listAllAnnotations();
    if (all.isEmpty) {
      _toast('还没有任何高亮');
      return;
    }
    final grouped = <String, List<Annotation>>{};
    for (final a in all) {
      grouped.putIfAbsent(a.bookId, () => []).add(a);
    }
    final withNotes = _books.where((b) => grouped.containsKey(b.id)).toList();
    final content = _exporter.renderCombined(
      books: withNotes,
      annotationsByBook: grouped,
    );
    final path = await saveMarkdownFile(
      fileName: '全部读书笔记.md',
      content: content,
    );
    _toast('已导出 ${all.length} 条到\n$path');
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message), duration: const Duration(seconds: 5)));
  }

  /* ----------------------------------------------------------------------- UI */

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('书架'),
            Text('v$appVersion', style: TextStyle(fontSize: 11)),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '导出全部笔记',
            onPressed: _books.isEmpty ? null : _exportAll,
            icon: const Icon(Icons.file_download_outlined),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _importing ? null : _import,
        icon: _importing
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.add),
        label: Text(_importing ? '导入中…' : '导入 EPUB'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _books.isEmpty
              ? _EmptyLibrary(onImport: _import)
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.builder(
                    padding: const EdgeInsets.only(bottom: 96, top: 4),
                    itemCount: _books.length,
                    itemBuilder: (context, index) {
                      final book = _books[index];
                      return _BookTile(
                        book: book,
                        highlightCount: _counts[book.id] ?? 0,
                        progress: _progress[book.id],
                        onTap: () => _open(book),
                        onExport: () => _exportBook(book),
                        onDelete: () => _delete(book),
                      );
                    },
                  ),
                ),
    );
  }
}

class _BookTile extends StatelessWidget {
  const _BookTile({
    required this.book,
    required this.highlightCount,
    required this.progress,
    required this.onTap,
    required this.onExport,
    required this.onDelete,
  });

  final Book book;
  final int highlightCount;
  final ReadingProgress? progress;
  final VoidCallback onTap;
  final VoidCallback onExport;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final fraction = progress?.fraction ?? 0;
    return ListTile(
      onTap: onTap,
      leading: CircleAvatar(
        backgroundColor: Theme.of(context).colorScheme.primaryContainer,
        child: Text(
          book.title.isEmpty ? '?' : book.title.substring(0, 1),
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      title: Text(book.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            [
              if ((book.author ?? '').trim().isNotEmpty) book.author!.trim(),
              if (highlightCount > 0) '$highlightCount 条高亮',
              if (fraction > 0) '已读 ${(fraction * 100).toStringAsFixed(0)}%',
            ].join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12),
          ),
          if (fraction > 0) ...[
            const SizedBox(height: 4),
            LinearProgressIndicator(value: fraction.clamp(0, 1), minHeight: 3),
          ],
        ],
      ),
      trailing: PopupMenuButton<String>(
        onSelected: (value) {
          if (value == 'export') onExport();
          if (value == 'delete') onDelete();
        },
        itemBuilder: (context) => const [
          PopupMenuItem(value: 'export', child: Text('导出笔记')),
          PopupMenuItem(value: 'delete', child: Text('从书架移除')),
        ],
      ),
    );
  }
}

class _EmptyLibrary extends StatelessWidget {
  const _EmptyLibrary({required this.onImport});

  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.menu_book_outlined, size: 64, color: Colors.grey),
            const SizedBox(height: 16),
            const Text('书架还是空的', style: TextStyle(fontSize: 18)),
            const SizedBox(height: 8),
            const Text(
              '导入无 DRM 的 EPUB 文件即可开始阅读。\n带 DRM 的书（京东读书、掌阅、Kindle 等）无法打开。',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey, height: 1.5),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: onImport,
              icon: const Icon(Icons.add),
              label: const Text('导入 EPUB'),
            ),
          ],
        ),
      ),
    );
  }
}
