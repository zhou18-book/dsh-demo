import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;

import 'markdown_export.dart';

/// Saves generated Markdown somewhere the user chooses.
///
/// Uses the system save dialog when the platform provides one, so the file can go
/// straight into an Obsidian/Siyuan vault. Falls back to the app's private exports
/// directory when the dialog is unavailable or the user cancels it, and returns
/// whatever path ended up being written so the caller can report it honestly.
Future<String> saveMarkdownFile({
  required String fileName,
  required String content,
}) async {
  final bytes = Uint8List.fromList(utf8.encode(content));

  try {
    final uri = await FilePicker.saveFile(
      fileName: fileName,
      bytes: bytes,
      mimeType: 'text/markdown',
      dialogTitle: '导出 Markdown',
    );
    if (uri != null) {
      // file:// URIs are already on disk; content:// (Android SAF) is too.
      if (uri.scheme == 'file') {
        final path = uri.toFilePath();
        if (await File(path).exists()) return path;
      } else {
        return uri.toString();
      }
    }
  } catch (_) {
    // Dialog unsupported on this platform/permission state: fall through.
  }

  final dir = await MarkdownExport().exportsDirectory();
  final file = File(p.join(dir.path, fileName));
  await file.writeAsString(content, flush: true);
  return file.path;
}
