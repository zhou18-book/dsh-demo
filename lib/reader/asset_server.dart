import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;

/// Serves the reader shell and book files to the WebView over loopback HTTP.
///
/// Why a loopback HTTP server instead of loading the page from the APK directly:
///  * `file://` and custom schemes are not "potentially trustworthy" origins, so
///    `crypto.subtle` is unavailable there and foliate's IDPF font deobfuscation
///    breaks. `http://127.0.0.1` *is* a secure context, which fixes that.
///  * foliate's zip.js loader wants range requests for the EPUB, and a real HTTP
///    server can answer them properly.
///  * a response header is the only place a CSP can be attached before the document
///    starts parsing, which is what makes the EPUB script block airtight.
class AssetServer {
  AssetServer._();

  static final AssetServer instance = AssetServer._();

  static const String _readerPrefix = '/reader/';
  static const String _bookPrefix = '/book/';

  /// Blocks every script that is not part of the reader shell itself.
  ///
  /// EPUB files may legitimately contain JavaScript. Because foliate renders
  /// sections in `blob:` iframes, those iframes inherit this policy, so an inline
  /// `<script>` inside a book is refused. This matters more than usual here: books
  /// will later arrive from OPDS feeds and RSS scrapes we do not control.
  ///
  /// `blob:` is allowed for *styles* only, and it is required: foliate's
  /// `renderer.setStyles()` injects the reading typography as a blob: stylesheet.
  /// Without it the font-size / theme controls fail silently -- the browser refuses
  /// the sheet and nothing at all surfaces in the UI. Found by running on a device:
  /// the WebView console showed `Refused to load the stylesheet 'blob:...'`.
  /// It does not widen the attack surface: a blob URL can only be produced by script,
  /// and `script-src` still permits nothing but our own origin.
  static const String csp = "default-src 'none'; "
      "script-src 'self'; "
      "style-src 'self' 'unsafe-inline' blob:; "
      "img-src 'self' blob: data:; "
      "font-src 'self' blob: data:; "
      "media-src 'self' blob: data:; "
      "connect-src 'self' blob: data:; "
      "frame-src 'self' blob: data:; "
      "child-src 'self' blob: data:; "
      "worker-src 'none'; "
      "object-src 'none'; "
      "base-uri 'none'; "
      "form-action 'none'";

  HttpServer? _server;
  String? _bookDir;

  int get port => _server?.port ?? 0;
  bool get isRunning => _server != null;

  Future<int> ensureStarted({required String bookDir}) async {
    _bookDir = bookDir;
    final existing = _server;
    if (existing != null) return existing.port;

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(
      _handle,
      onError: (Object error) {
        // A malformed request from the WebView must not kill the server.
        // ignore: avoid_print
        print('[AssetServer] request error: $error');
      },
    );
    _server = server;
    return server.port;
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  Uri readerUri({String file = 'host.html'}) =>
      Uri.parse('http://127.0.0.1:$port$_readerPrefix$file');

  Uri bookUri(String bookId) => Uri.parse('http://127.0.0.1:$port$_bookPrefix$bookId');

  /* ------------------------------------------------------------------ routing */

  Future<void> _handle(HttpRequest req) async {
    try {
      final path = req.uri.path;
      if (path.startsWith(_readerPrefix)) {
        await _serveReaderAsset(req, path.substring(_readerPrefix.length));
      } else if (path.startsWith(_bookPrefix)) {
        await _serveBook(req, path.substring(_bookPrefix.length));
      } else {
        await _notFound(req, 'no route for $path');
      }
    } catch (error) {
      try {
        await _notFound(req, '$error');
      } catch (_) {
        // Response already started or socket gone; nothing useful left to do.
      }
    }
  }

  void _securityHeaders(HttpResponse res) {
    res.headers.set('Content-Security-Policy', csp);
    res.headers.set('X-Content-Type-Options', 'nosniff');
    res.headers.set('Referrer-Policy', 'no-referrer');
    res.headers.set('Cache-Control', 'no-store');
  }

  Future<void> _notFound(HttpRequest req, String reason) async {
    final res = req.response;
    _securityHeaders(res);
    res.statusCode = HttpStatus.notFound;
    res.headers.contentType = ContentType.text;
    res.write('404 $reason');
    await res.close();
  }

  /* ----------------------------------------------------------- reader assets */

  Future<void> _serveReaderAsset(HttpRequest req, String relative) async {
    // Reject traversal outright; asset keys are relative POSIX paths.
    if (relative.contains('..') || relative.startsWith('/')) {
      await _notFound(req, 'illegal path');
      return;
    }
    final assetKey = 'assets/reader/$relative';
    ByteData data;
    try {
      data = await rootBundle.load(assetKey);
    } catch (_) {
      await _notFound(req, 'missing asset $assetKey');
      return;
    }

    final res = req.response;
    _securityHeaders(res);
    res.statusCode = HttpStatus.ok;
    res.headers.contentType = _contentTypeFor(relative);
    res.headers.set('Content-Length', '${data.lengthInBytes}');
    res.add(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
    await res.close();
  }

  /* -------------------------------------------------------------- book bytes */

  Future<void> _serveBook(HttpRequest req, String bookId) async {
    if (bookId.isEmpty || bookId.contains('..') || bookId.contains('/')) {
      await _notFound(req, 'illegal book id');
      return;
    }
    final dir = _bookDir;
    if (dir == null) {
      await _notFound(req, 'book directory not configured');
      return;
    }
    final file = File('$dir${Platform.pathSeparator}$bookId.epub');
    if (!await file.exists()) {
      await _notFound(req, 'no such book $bookId');
      return;
    }

    final total = await file.length();
    final res = req.response;
    _securityHeaders(res);
    res.headers.contentType = ContentType('application', 'epub+zip');
    res.headers.set('Accept-Ranges', 'bytes');

    final rangeHeader = req.headers.value(HttpHeaders.rangeHeader);
    final range = _parseRange(rangeHeader, total);

    if (range == null) {
      res.statusCode = HttpStatus.ok;
      res.headers.set('Content-Length', '$total');
      await res.addStream(file.openRead());
      await res.close();
      return;
    }

    final (start, end) = range;
    final length = end - start + 1;
    res.statusCode = HttpStatus.partialContent;
    res.headers.set('Content-Range', 'bytes $start-$end/$total');
    res.headers.set('Content-Length', '$length');
    await res.addStream(file.openRead(start, end + 1));
    await res.close();
  }

  /// Returns an inclusive (start, end) pair, or null when the whole file is wanted.
  /// Only single-range requests are supported, which is all zip.js issues.
  static (int, int)? _parseRange(String? header, int total) {
    if (header == null || !header.startsWith('bytes=')) return null;
    final spec = header.substring('bytes='.length).split(',').first.trim();
    final dash = spec.indexOf('-');
    if (dash < 0) return null;

    final rawStart = spec.substring(0, dash).trim();
    final rawEnd = spec.substring(dash + 1).trim();

    int start;
    int end;
    if (rawStart.isEmpty) {
      // Suffix form: bytes=-N means the last N bytes.
      final suffix = int.tryParse(rawEnd);
      if (suffix == null || suffix <= 0) return null;
      start = (total - suffix).clamp(0, total);
      end = total - 1;
    } else {
      start = int.tryParse(rawStart) ?? 0;
      end = rawEnd.isEmpty ? total - 1 : (int.tryParse(rawEnd) ?? total - 1);
    }
    if (start < 0) start = 0;
    if (end >= total) end = total - 1;
    if (start > end || start >= total) return null;
    return (start, end);
  }

  static ContentType _contentTypeFor(String path) {
    final dot = path.lastIndexOf('.');
    final ext = dot < 0 ? '' : path.substring(dot + 1).toLowerCase();
    switch (ext) {
      case 'html':
        return ContentType.html;
      case 'css':
        return ContentType('text', 'css', charset: 'utf-8');
      case 'js':
      case 'mjs':
        return ContentType('text', 'javascript', charset: 'utf-8');
      case 'json':
        return ContentType('application', 'json', charset: 'utf-8');
      case 'svg':
        return ContentType('image', 'svg+xml');
      case 'png':
        return ContentType('image', 'png');
      case 'jpg':
      case 'jpeg':
        return ContentType('image', 'jpeg');
      case 'gif':
        return ContentType('image', 'gif');
      case 'webp':
        return ContentType('image', 'webp');
      case 'woff':
        return ContentType('font', 'woff');
      case 'woff2':
        return ContentType('font', 'woff2');
      case 'ttf':
        return ContentType('font', 'ttf');
      case 'otf':
        return ContentType('font', 'otf');
      case 'mp3':
        return ContentType('audio', 'mpeg');
      case 'mp4':
        return ContentType('video', 'mp4');
      default:
        return ContentType.binary;
    }
  }
}
