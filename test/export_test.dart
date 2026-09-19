import 'package:ebook_reader/data/models.dart';
import 'package:ebook_reader/export/markdown_export.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pure-Dart tests for the export path.
///
/// Deliberately does not pump the app widget: the library screen opens SQLite in
/// initState, which needs a real device binding, and a widget smoke test that mocked
/// all of that would assert far less than these do.
void main() {
  final book = Book(
    id: 'abc123',
    title: '测试书: 副标题', // the colon must be quoted for YAML
    author: '某作者',
    filePath: '/tmp/x.epub',
    addedAt: 0,
    updatedAt: 0,
  );

  group('MarkdownExport.render', () {
    test('emits front matter and one blockquote per highlight', () {
      final annotations = [
        Annotation(
          id: 'a1',
          bookId: 'abc123',
          cfi: 'epubcfi(/6/4!/4/2/2)',
          text: '第一段  被选中的\n文字',
          color: HighlightColors.yellow,
          createdAt: DateTime(2026, 9, 19, 10, 30).millisecondsSinceEpoch,
          updatedAt: 0,
        ),
        Annotation(
          id: 'a2',
          bookId: 'abc123',
          cfi: 'epubcfi(/6/4!/4/6/2)',
          text: '第二段',
          color: HighlightColors.blue,
          note: '这是批注',
          createdAt: DateTime(2026, 9, 19, 11, 0).millisecondsSinceEpoch,
          updatedAt: 0,
        ),
      ];

      final out = MarkdownExport().render(
        book: book,
        annotations: annotations,
        progress: null,
      );

      expect(out, startsWith('---\n'));
      expect(out, contains('title: "测试书: 副标题"'));
      expect(out, contains('author: "某作者"'));
      expect(out, contains('highlights: 2'));
      // Selection whitespace is collapsed so the quote stays one line.
      expect(out, contains('> 第一段 被选中的 文字'));
      expect(out, contains('这是批注'));
      // The CFI must survive into the export; it is the only durable anchor.
      expect(out, contains('epubcfi(/6/4!/4/2/2)'));
    });

    test('reports reading progress when present', () {
      final out = MarkdownExport().render(
        book: book,
        annotations: const [],
        progress: ReadingProgress(
          bookId: 'abc123',
          cfi: 'epubcfi(/6/4!/4/8/2)',
          fraction: 0.4213,
          sectionLabel: '第三章',
          updatedAt: 0,
        ),
      );
      expect(out, contains('reading_progress: 42.1%'));
      expect(out, contains('reading_position: "第三章"'));
    });

    test('states plainly when there is nothing highlighted', () {
      final out = MarkdownExport().render(
        book: book,
        annotations: const [],
        progress: null,
      );
      expect(out, contains('还没有高亮或批注'));
    });
  });

  group('MarkdownExport.fileNameFor', () {
    test('strips characters Windows and Android reject', () {
      expect(
        MarkdownExport.fileNameFor('a/b\\c:d*e?f"g<h>i|j'),
        'a_b_c_d_e_f_g_h_i_j.md',
      );
    });

    test('falls back for a blank title', () {
      expect(MarkdownExport.fileNameFor('   '), 'untitled.md');
    });

    test('escapes reserved Windows device names', () {
      expect(MarkdownExport.fileNameFor('CON'), 'CON_book.md');
    });
  });
}
