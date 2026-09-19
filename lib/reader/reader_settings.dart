import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Reading appearance preferences, persisted as a small JSON file.
///
/// Kept deliberately dependency-free (no shared_preferences) because the whole
/// payload is a handful of scalars.
class ReaderSettings {
  ReaderSettings({
    this.fontSize = 18,
    this.lineHeight = 1.7,
    this.theme = ReaderTheme.light,
  });

  double fontSize;
  double lineHeight;
  String theme;

  static const double minFontSize = 12;
  static const double maxFontSize = 34;

  ReaderTheme get palette => ReaderTheme.of(theme);

  Map<String, Object?> toJson() => {
        'fontSize': fontSize,
        'lineHeight': lineHeight,
        'theme': theme,
      };

  static ReaderSettings fromJson(Map<String, dynamic> json) => ReaderSettings(
        fontSize: (json['fontSize'] as num?)?.toDouble() ?? 18,
        lineHeight: (json['lineHeight'] as num?)?.toDouble() ?? 1.7,
        theme: (json['theme'] as String?) ?? ReaderTheme.light,
      );

  Future<File> _file() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'settings'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return File(p.join(dir.path, 'reader.json'));
  }

  static Future<ReaderSettings> load() async {
    final probe = ReaderSettings();
    try {
      final file = await probe._file();
      if (!await file.exists()) return probe;
      final raw = await file.readAsString();
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return ReaderSettings.fromJson(json);
    } catch (_) {
      return probe;
    }
  }

  Future<void> save() async {
    try {
      final file = await _file();
      await file.writeAsString(jsonEncode(toJson()), flush: true);
    } catch (_) {
      // Preferences are not worth failing a reading session over.
    }
  }

  /// Payload for `dshReader.applyStyles`.
  Map<String, Object?> toStylesPayload() => {
        'fontSize': fontSize,
        'lineHeight': lineHeight,
        'color': palette.foreground,
        'background': palette.background,
        'linkColor': palette.link,
        'textAlign': 'justify',
        'highlightOpacity': 0.45,
      };

  /// Payload for `dshReader.applyLayout`.
  Map<String, Object?> toLayoutPayload({double viewWidth = 0, double viewHeight = 0}) => {
        'flow': 'paginated',
        'gap': 8,
        'margin': viewHeight > 0 ? (viewHeight * 0.035).clamp(12, 64) : 24,
        if (viewWidth > 720) 'maxInlineSize': 640,
      };
}

class ReaderTheme {
  const ReaderTheme({
    required this.id,
    required this.label,
    required this.background,
    required this.foreground,
    required this.link,
  });

  final String id;
  final String label;
  final String background;
  final String foreground;
  final String link;

  static const light = 'light';
  static const sepia = 'sepia';
  static const dark = 'dark';

  static const _all = <String, ReaderTheme>{
    light: ReaderTheme(
      id: light,
      label: '浅色',
      background: '#ffffff',
      foreground: '#1a1a1a',
      link: '#1565c0',
    ),
    sepia: ReaderTheme(
      id: sepia,
      label: '羊皮纸',
      background: '#f5ecd9',
      foreground: '#3a2f1f',
      link: '#8d6e2f',
    ),
    dark: ReaderTheme(
      id: dark,
      label: '深色',
      background: '#121212',
      foreground: '#cfcfcf',
      link: '#82b1ff',
    ),
  };

  static ReaderTheme of(String id) => _all[id] ?? _all[light]!;

  static List<ReaderTheme> get values => _all.values.toList(growable: false);

  /// Flutter-side colour for the scaffold so there is no flash between frames.
  int get argb {
    final hex = background.replaceFirst('#', '');
    return int.parse('FF$hex', radix: 16);
  }
}
