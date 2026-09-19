import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:webview_flutter/webview_flutter.dart';

import '../data/library_repo.dart';
import '../data/models.dart';
import '../export/export_action.dart';
import '../export/markdown_export.dart';
import 'asset_server.dart';
import 'reader_settings.dart';

class ReaderPage extends StatefulWidget {
  const ReaderPage({super.key, required this.book});

  final Book book;

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _Selection {
  const _Selection({required this.cfi, required this.text});

  final String cfi;
  final String text;
}

class _TocEntry {
  const _TocEntry(this.label, this.href);

  final String label;
  final String href;
}

class _ReaderPageState extends State<ReaderPage> {
  final LibraryRepo _repo = LibraryRepo();
  final MarkdownExport _exporter = MarkdownExport();
  final Random _random = Random();

  WebViewController? _controller;
  ReaderSettings _settings = ReaderSettings();

  List<Annotation> _annotations = const [];
  List<_TocEntry> _toc = const [];
  ReadingProgress? _savedProgress;
  _Selection? _selection;

  bool _bridgeReady = false;
  bool _bookOpened = false;
  String? _fatalError;

  double _fraction = 0;
  String? _positionLabel;

  String? _pendingCfi;
  double _pendingFraction = 0;
  String? _pendingLabel;
  Timer? _progressDebounce;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  @override
  void dispose() {
    _progressDebounce?.cancel();
    // Best-effort flush; the page is going away so we cannot await here.
    _flushProgress();
    super.dispose();
  }

  /* -------------------------------------------------------------------- boot */

  Future<void> _boot() async {
    final book = widget.book;
    final settings = await ReaderSettings.load();
    final progress = await _repo.getProgress(book.id);
    final annotations = await _repo.listAnnotations(book.id);

    final port = await AssetServer.instance
        .ensureStarted(bookDir: p.dirname(book.filePath));

    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Color(settings.palette.argb))
      ..addJavaScriptChannel('DshBridge', onMessageReceived: _onJsMessage)
      ..setNavigationDelegate(
        NavigationDelegate(
          onWebResourceError: (error) {
            if (error.isForMainFrame ?? false) {
              _fail('页面加载失败：${error.description}');
            }
          },
        ),
      )
      ..loadRequest(
        Uri.parse('http://127.0.0.1:$port/reader/host.html'),
      );

    if (!mounted) return;
    setState(() {
      _settings = settings;
      _savedProgress = progress;
      _annotations = annotations;
      _fraction = progress?.fraction ?? 0;
      _positionLabel = progress?.sectionLabel;
      _controller = controller;
    });
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() => _fatalError = message);
  }

  /* ----------------------------------------------------------- bridge plumbing */

  void _js(String expression) {
    _controller?.runJavaScript(expression);
  }

  /// Calls a method on the JS `dshReader` object with pre-encoded arguments.
  void _call(String methodAndArgs) {
    _js('window.dshReader.$methodAndArgs');
  }

  void _onJsMessage(JavaScriptMessage message) {
    Map<String, dynamic> data;
    try {
      data = jsonDecode(message.message) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    switch (data['type'] as String?) {
      case 'ready':
        _onBridgeReady();
        break;
      case 'opened':
        _onBookOpened(data);
        break;
      case 'toc':
        _onToc(data);
        break;
      case 'relocate':
        _onRelocate(data);
        break;
      case 'selection':
        _onSelection(data);
        break;
      case 'selectionCleared':
        if (mounted && _selection != null) setState(() => _selection = null);
        break;
      case 'annotationTapped':
        _onAnnotationTapped(data);
        break;
      case 'error':
        _fail(data['message']?.toString() ?? '渲染出错');
        break;
      case 'scriptError':
        debugPrint('[reader js] ${data['message']}');
        break;
      default:
        break;
    }
  }

  void _onBridgeReady() {
    _bridgeReady = true;
    final url = AssetServer.instance.bookUri(widget.book.id).toString();
    _call('open(${jsonEncode(url)})');
  }

  Future<void> _onBookOpened(Map<String, dynamic> data) async {
    if (!mounted) return;
    setState(() => _bookOpened = true);

    // foliate read the real title/author out of the OPF; upgrade the shelf entry if
    // our own parse came up short.
    final title = data['title'] as String?;
    await _repo.touchBookIfBetter(widget.book.id, title: title, author: null);

    _pushAppearance();
    _pushAnnotations();

    final cfi = _savedProgress?.cfi;
    if (cfi != null && cfi.isNotEmpty) {
      _call('restore(${jsonEncode(cfi)})');
    } else {
      _call('restore(null)');
    }
  }

  void _onToc(Map<String, dynamic> data) {
    final raw = (data['items'] as List?) ?? const [];
    final entries = <_TocEntry>[];
    for (final item in raw) {
      if (item is Map && item['label'] != null && item['href'] != null) {
        entries.add(_TocEntry(item['label'].toString(), item['href'].toString()));
      }
    }
    if (mounted) setState(() => _toc = entries);
  }

  void _onRelocate(Map<String, dynamic> data) {
    final cfi = data['cfi'] as String?;
    final fraction = (data['fraction'] as num?)?.toDouble();
    final label = (data['tocLabel'] as String?) ??
        (data['pageLabel'] as String?) ??
        _locationLabel(data);

    setState(() {
      if (fraction != null) _fraction = fraction.clamp(0, 1);
      if (label != null && label.isNotEmpty) _positionLabel = label;
    });

    if (cfi == null || cfi.isEmpty) return;
    _pendingCfi = cfi;
    _pendingFraction = _fraction;
    _pendingLabel = _positionLabel;

    _progressDebounce?.cancel();
    _progressDebounce = Timer(const Duration(milliseconds: 900), _flushProgress);
  }

  static String? _locationLabel(Map<String, dynamic> data) {
    final current = data['locationCurrent'];
    final total = data['locationTotal'];
    if (current == null) return null;
    return total == null ? '位置 $current' : '位置 $current/$total';
  }

  Future<void> _flushProgress() async {
    final cfi = _pendingCfi;
    if (cfi == null || cfi.isEmpty) return;
    _pendingCfi = null;
    await _repo.saveProgress(
      bookId: widget.book.id,
      cfi: cfi,
      fraction: _pendingFraction,
      sectionLabel: _pendingLabel,
    );
  }

  void _onSelection(Map<String, dynamic> data) {
    final cfi = data['cfi'] as String?;
    final text = data['text'] as String?;
    if (cfi == null || text == null || text.trim().isEmpty) return;
    if (!mounted) return;
    setState(() => _selection = _Selection(cfi: cfi, text: text.trim()));
  }

  /* -------------------------------------------------------------- appearance */

  void _pushAppearance() {
    if (!_bridgeReady) return;
    final size = MediaQuery.sizeOf(context);
    _call('applyStyles(${jsonEncode(_settings.toStylesPayload())})');
    _call(
      'applyLayout(${jsonEncode(_settings.toLayoutPayload(
        viewWidth: size.width,
        viewHeight: size.height,
      ))})',
    );
  }

  void _pushAnnotations() {
    if (!_bridgeReady) return;
    final payload = _annotations.map((a) => a.toBridgeJson()).toList();
    _call('setAnnotations(${jsonEncode(payload)})');
  }

  String _newAnnotationId() {
    final a = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
    final b = _random.nextInt(1 << 32).toRadixString(16);
    return '$a-$b';
  }

  /* --------------------------------------------------------------- highlight */

  Future<void> _createHighlight(String color) async {
    final selection = _selection;
    if (selection == null) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    final annotation = Annotation(
      id: _newAnnotationId(),
      bookId: widget.book.id,
      cfi: selection.cfi,
      text: selection.text,
      color: color,
      createdAt: now,
      updatedAt: now,
    );

    await _repo.upsertAnnotation(annotation);
    if (!mounted) return;
    setState(() {
      _annotations = [..._annotations, annotation];
      _selection = null;
    });
    _call('clearSelection()');
    _pushAnnotations();

    if (mounted) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            content: Text('已高亮 ${_shorten(selection.text, 24)}'),
            duration: const Duration(seconds: 2),
            action: SnackBarAction(
              label: '写批注',
              onPressed: () => _editNote(annotation),
            ),
          ),
        );
    }
  }

  Future<void> _editNote(Annotation annotation) async {
    final controller = TextEditingController(text: annotation.note ?? '');
    final result = await showModalBottomSheet<String?>(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 16,
            bottom: MediaQuery.viewInsetsOf(context).bottom + 16,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                annotation.text,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                maxLines: 5,
                minLines: 2,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: '写点想法…',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, '__delete__'),
                    child: const Text('删除高亮'),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () => Navigator.pop(context, controller.text),
                    child: const Text('保存'),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
    controller.dispose();

    if (result == null) return;

    if (result == '__delete__') {
      await _deleteAnnotation(annotation);
      return;
    }

    final note = result.trim();
    await _repo.updateAnnotationNote(annotation.id, note.isEmpty ? null : note);
    if (!mounted) return;
    setState(() {
      _annotations = _annotations
          .map((a) => a.id == annotation.id
              ? a.copyWith(note: note.isEmpty ? null : note, clearNote: note.isEmpty)
              : a)
          .toList();
    });
    _pushAnnotations();
  }

  Future<void> _deleteAnnotation(Annotation annotation) async {
    await _repo.deleteAnnotation(annotation.id);
    if (!mounted) return;
    setState(() {
      _annotations = _annotations.where((a) => a.id != annotation.id).toList();
    });
    _call('removeAnnotation(${jsonEncode(annotation.id)})');
    _pushAnnotations();
  }

  void _onAnnotationTapped(Map<String, dynamic> data) {
    final id = data['id'] as String?;
    if (id == null) return;
    final match = _annotations.where((a) => a.id == id).toList();
    if (match.isEmpty) return;
    _editNote(match.first);
  }

  /* ------------------------------------------------------------ reader chrome */

  Future<void> _showNoteList() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.6,
          maxChildSize: 0.92,
          builder: (context, scrollController) {
            final list = [..._annotations]
              ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
            if (list.isEmpty) {
              return const Center(child: Text('还没有高亮'));
            }
            return ListView.separated(
              controller: scrollController,
              itemCount: list.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final a = list[index];
                return ListTile(
                  leading: Container(
                    width: 14,
                    height: 14,
                    margin: const EdgeInsets.only(top: 4),
                    decoration: BoxDecoration(
                      color: _parseHexColor(a.color),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                  title: Text(
                    a.text,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: (a.note ?? '').isEmpty ? null : Text(a.note!),
                  onTap: () {
                    Navigator.pop(context);
                    _call('revealAnnotation(${jsonEncode(a.id)})');
                  },
                  onLongPress: () => _editNote(a),
                );
              },
            );
          },
        );
      },
    );
  }

  Future<void> _openToc() async {
    if (_toc.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('这本书没有目录')),
      );
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      builder: (context) {
        return SafeArea(
          child: ListView.builder(
            itemCount: _toc.length,
            itemBuilder: (context, index) {
              final entry = _toc[index];
              return ListTile(
                dense: true,
                title: Text(entry.label),
                onTap: () {
                  Navigator.pop(context);
                  _call('goTo(${jsonEncode(entry.href)})');
                },
              );
            },
          ),
        );
      },
    );
  }

  Future<void> _openSettings() async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            void apply(VoidCallback mutate) {
              mutate();
              setSheetState(() {});
              setState(() {});
              _settings.save();
              _pushAppearance();
            }

            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('字号 ${_settings.fontSize.toStringAsFixed(0)}',
                        style: Theme.of(context).textTheme.titleSmall),
                    Row(
                      children: [
                        IconButton(
                          onPressed: _settings.fontSize <= ReaderSettings.minFontSize
                              ? null
                              : () => apply(() => _settings.fontSize -= 1),
                          icon: const Icon(Icons.text_decrease),
                        ),
                        Expanded(
                          child: Slider(
                            min: ReaderSettings.minFontSize,
                            max: ReaderSettings.maxFontSize,
                            divisions:
                                (ReaderSettings.maxFontSize - ReaderSettings.minFontSize)
                                    .round(),
                            value: _settings.fontSize,
                            onChanged: (v) => apply(() => _settings.fontSize = v),
                          ),
                        ),
                        IconButton(
                          onPressed: _settings.fontSize >= ReaderSettings.maxFontSize
                              ? null
                              : () => apply(() => _settings.fontSize += 1),
                          icon: const Icon(Icons.text_increase),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text('主题', style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final theme in ReaderTheme.values)
                          ChoiceChip(
                            label: Text(theme.label),
                            selected: _settings.theme == theme.id,
                            onSelected: (_) => apply(() => _settings.theme = theme.id),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _export() async {
    await _flushProgress();
    final progress = await _repo.getProgress(widget.book.id);
    final annotations = await _repo.listAnnotations(widget.book.id);
    final book = await _repo.getBook(widget.book.id) ?? widget.book;

    final content = _exporter.render(
      book: book,
      annotations: annotations,
      progress: progress,
    );
    final path = await saveMarkdownFile(
      fileName: MarkdownExport.fileNameFor(book.title),
      content: content,
    );

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已导出 ${annotations.length} 条到\n$path'),
        duration: const Duration(seconds: 6),
      ),
    );
  }

  static Color _parseHexColor(String hex) {
    final cleaned = hex.replaceFirst('#', '');
    final value = int.tryParse(cleaned, radix: 16);
    if (value == null) return const Color(0xFFFFD54F);
    return Color(cleaned.length <= 6 ? 0xFF000000 | value : value);
  }

  /* --------------------------------------------------------------------- UI */

  @override
  Widget build(BuildContext context) {
    final palette = _settings.palette;
    final onBackground = _parseHexColor(palette.foreground);

    return Scaffold(
      backgroundColor: Color(palette.argb),
      appBar: AppBar(
        backgroundColor: Color(palette.argb),
        foregroundColor: onBackground,
        elevation: 0,
        title: Text(
          widget.book.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 16),
        ),
        actions: [
          IconButton(
            tooltip: '目录',
            onPressed: _bookOpened ? _openToc : null,
            icon: const Icon(Icons.list_alt),
          ),
          IconButton(
            tooltip: '笔记',
            onPressed: _bookOpened ? _showNoteList : null,
            icon: Badge(
              isLabelVisible: _annotations.isNotEmpty,
              label: Text('${_annotations.length}'),
              child: const Icon(Icons.bookmark_border),
            ),
          ),
          IconButton(
            tooltip: '导出 Markdown',
            onPressed: _bookOpened ? _export : null,
            icon: const Icon(Icons.ios_share),
          ),
          IconButton(
            tooltip: '显示设置',
            onPressed: _bookOpened ? _openSettings : null,
            icon: const Icon(Icons.text_fields),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(18),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              _positionLabel == null
                  ? '${(_fraction * 100).toStringAsFixed(1)}%'
                  : '$_positionLabel · ${(_fraction * 100).toStringAsFixed(1)}%',
              style: TextStyle(fontSize: 11, color: onBackground.withValues(alpha: 0.6)),
            ),
          ),
        ),
      ),
      body: _fatalError != null
          ? _ErrorView(message: _fatalError!, onRetry: _retry)
          : Stack(
              children: [
                if (_controller != null)
                  WebViewWidget(controller: _controller!)
                else
                  const Center(child: CircularProgressIndicator()),
                if (!_bookOpened && _fatalError == null && _controller != null)
                  const Positioned(
                    left: 0,
                    right: 0,
                    bottom: 24,
                    child: Center(child: Text('正在解析…', style: TextStyle(color: Colors.grey))),
                  ),
                if (_selection != null)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: _HighlightToolbar(
                      onPick: _createHighlight,
                      onCancel: () {
                        setState(() => _selection = null);
                        _call('clearSelection()');
                      },
                    ),
                  ),
              ],
            ),
    );
  }

  void _retry() {
    final controller = _controller;
    if (controller == null) return;
    setState(() {
      _fatalError = null;
      _bookOpened = false;
      _bridgeReady = false;
    });
    controller.reload();
  }
}

class _HighlightToolbar extends StatelessWidget {
  const _HighlightToolbar({required this.onPick, required this.onCancel});

  final Future<void> Function(String color) onPick;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 8,
      color: Theme.of(context).colorScheme.surface,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              for (final color in HighlightColors.all)
                IconButton(
                  tooltip: HighlightColors.labels[color],
                  onPressed: () => onPick(color),
                  icon: Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      color: _ReaderPageState._parseHexColor(color),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.black12),
                    ),
                  ),
                ),
              IconButton(
                tooltip: '取消',
                onPressed: onCancel,
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 48),
            const SizedBox(height: 16),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 20),
            FilledButton(onPressed: onRetry, child: const Text('重试')),
          ],
        ),
      ),
    );
  }
}

String _shorten(String value, int max) {
  if (value.length <= max) return value;
  return '${value.substring(0, max)}…';
}
