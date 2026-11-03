import 'dart:async';
import 'dart:convert' show HtmlEscape;
import 'dart:collection';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'file_browser.dart';

/// What one HTML file's site may cost. A page asks for what it likes, so every
/// number here is a ceiling the server holds it to.
class HtmlSiteLimits {
  const HtmlSiteLimits({
    this.fileBytes = 5 * 1024 * 1024,
    this.totalBytes = 50 * 1024 * 1024,
    this.files = 200,
    this.concurrent = 4,
  });

  /// One file, the HTML itself included.
  final int fileBytes;

  /// Everything the page has loaded, counted once per file.
  final int totalBytes;

  /// How many different files the page may load.
  final int files;

  /// Fetches from the host at one time.
  final int concurrent;
}

/// An HTML file on a host, and the files beside it, served to a web view
/// from 127.0.0.1.
///
/// A page loaded as text has no origin, so its relative stylesheet, script
/// and pictures go nowhere. This gives it one, without opening the host to
/// it: a request is answered only
///
/// * from this machine (a `Host` of `127.0.0.1:<port>`, so a name that a DNS
///   rebinding points here is refused) and under a random token in the path,
///   so another app on the device cannot guess its way in;
/// * with GET or HEAD;
/// * for a file inside the HTML's own folder. `..`, an empty or hidden
///   segment, a separator hidden in an escape and anything outside the token
///   are refused, and so is a symlink anywhere on the way, since where one
///   points cannot be told over the session without trusting it.
///
/// What it fetches goes through the session's [FileBrowser], so a file is as
/// readable as the login that opened the tab can read it. A refusal never
/// reaches the page as anything but a status, and is listed in [problems]
/// for the tab to say.
class HtmlSite {
  HtmlSite._(this._browser, this._server, this._base, this._name, this.limits)
    : token = _newToken() {
    _server.listen(_handle, onError: (Object _) {});
  }

  /// Serves [htmlPath]'s folder on a free loopback port.
  static Future<HtmlSite> start({
    required FileBrowser browser,
    required String htmlPath,
    HtmlSiteLimits limits = const HtmlSiteLimits(),
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    return HtmlSite._(
      browser,
      server,
      RemotePath.parent(htmlPath),
      RemotePath.basename(htmlPath),
      limits,
    );
  }

  final FileBrowser _browser;
  final HttpServer _server;
  final String _base;
  final String _name;
  final HtmlSiteLimits limits;

  /// The random part of every address, from the system's secure generator.
  final String token;

  /// What the page asked for and did not get, by address, and why. Cleared by
  /// [reset]. A tab shows it so a missing file is said and not a blank space.
  final ValueNotifier<Map<String, String>> problems = ValueNotifier(const {});

  /// The most [problems] kept; a page asking for thousands is not listed
  /// thousands of times.
  static const _problemCap = 50;

  /// Where the page itself is.
  Uri get url => Uri(
    scheme: 'http',
    host: '127.0.0.1',
    port: _server.port,
    pathSegments: [token, _name],
  );

  final _listings = <String, List<RemoteEntry>>{};
  final _seen = <String, int>{};
  var _total = 0;
  var _busy = 0;
  final _waiting = Queue<Completer<void>>();
  var _closed = false;

  static String _newToken() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  /// Forgets what was listed, loaded and refused, for Reload: the files on
  /// the host may have changed, and a page that is loading again starts with
  /// a clean budget.
  void reset() {
    _listings.clear();
    _seen.clear();
    _total = 0;
    problems.value = const {};
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _server.close(force: true);
    problems.dispose();
  }

  void _problem(String what, String why) {
    if (_closed) return;
    final now = problems.value;
    if (now.containsKey(what) || now.length >= _problemCap) return;
    problems.value = {...now, what: why};
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    response.headers
      ..set('X-Content-Type-Options', 'nosniff')
      ..set('Referrer-Policy', 'no-referrer')
      ..set('Cache-Control', 'no-store')
      ..set('Cross-Origin-Resource-Policy', 'same-origin');
    Future<void> refuse(int status, String text, [String? why]) async {
      if (why != null) _problem(request.uri.path, why);
      response.statusCode = status;
      final at = request.uri.pathSegments;
      if (at.length == 2 && at.first == token && at[1] == _name) {
        // The page itself: said in the page, never a bare status.
        response.headers.contentType = ContentType.html;
        response.write(
          '<!doctype html><meta name="viewport" content="width=device-width">'
          '<p>Could not open ${const HtmlEscape().convert(_name)}: '
          '${const HtmlEscape().convert(why ?? text)}.</p>',
        );
      } else {
        response.headers.contentType = ContentType.text;
        response.write(text);
      }
      await response.close();
    }

    try {
      if (request.method != 'GET' && request.method != 'HEAD') {
        return await refuse(405, 'Only GET and HEAD');
      }
      if (request.headers.value('host') != '127.0.0.1:${_server.port}') {
        return await refuse(403, 'Wrong host');
      }
      final segments = request.uri.pathSegments;
      if (segments.isEmpty || segments.first != token) {
        // A path from the site's root, `/logo.png`, reaches nothing: the
        // page's own folder is under the token. Said, since it is the usual
        // reason a page looks bare — but not for a browser's own favicon.
        return await refuse(
          404,
          'Not found',
          request.uri.path == '/favicon.ico'
              ? null
              : 'outside the page\'s folder',
        );
      }
      final rel = segments.skip(1).toList();
      final bad =
          rel.isEmpty ||
          rel.any(
            (s) =>
                s.isEmpty ||
                s == '.' ||
                s == '..' ||
                s.contains('/') ||
                s.contains('\\') ||
                s.contains('\u0000'),
          );
      if (bad) return await refuse(403, 'Refused', 'outside the folder');
      if (rel.any((s) => s.startsWith('.'))) {
        return await refuse(403, 'Refused', 'hidden file');
      }

      final shown = rel.join('/');
      final entry = await _find(rel);
      if (entry == null) return await refuse(404, 'Not found', 'missing');
      if (entry.kind == RemoteEntryKind.symlink) {
        return await refuse(403, 'Refused', 'a link, not followed');
      }
      if (entry.kind != RemoteEntryKind.file) {
        return await refuse(404, 'Not found', 'missing');
      }
      final size = entry.size ?? 0;
      if (size > limits.fileBytes) {
        return await refuse(
          413,
          'Too big',
          'too big (${formatBytes(size)}, the limit is '
              '${formatBytes(limits.fileBytes)})',
        );
      }
      if (!_seen.containsKey(entry.path)) {
        if (_seen.length >= limits.files) {
          return await refuse(
            429,
            'Too many files',
            'over ${limits.files} files',
          );
        }
        if (_total + size > limits.totalBytes) {
          return await refuse(
            413,
            'Too much',
            'over ${formatBytes(limits.totalBytes)} in all',
          );
        }
        _seen[entry.path] = size;
        _total += size;
      }

      final bytes = await _fetch(entry.path);
      if (bytes == null) {
        return await refuse(413, 'Too big', 'too big ($shown)');
      }
      final type = _contentType(entry.name);
      response.statusCode = 200;
      response.headers.set('Content-Type', type);
      if (type.startsWith('text/html')) {
        // Remote styles, scripts, pictures and fonts load as in any browser,
        // but a page cannot reach the plain-http services of this device by
        // fetch, XHR or WebSocket, nor post a form to one: connect-src keeps
        // 'self' and https. Nothing else is restricted.
        response.headers.set(
          'Content-Security-Policy',
          "connect-src 'self' https: wss: data: blob:; "
              "form-action 'self' https:",
        );
      }
      response.contentLength = bytes.length;
      if (request.method != 'HEAD') response.add(bytes);
      await response.close();
    } on FileBrowserException catch (error) {
      final missing = error.fault == FileBrowserFault.notFound;
      await refuse(
        missing ? 404 : 502,
        missing ? 'Not found' : 'Could not read it',
        missing ? 'missing' : 'could not be read',
      );
    } catch (_) {
      try {
        await refuse(500, 'Failed', 'could not be read');
      } catch (_) {}
    }
  }

  /// The entry at [rel] under the page's folder, walking down one listing at
  /// a time so a link in the way is met rather than followed. Null where
  /// nothing is.
  Future<RemoteEntry?> _find(List<String> rel) async {
    var dir = _base;
    for (var i = 0; i < rel.length; i++) {
      final entries = await _list(dir);
      final entry = entries.where((e) => e.name == rel[i]).firstOrNull;
      if (entry == null) return null;
      if (i == rel.length - 1) return entry;
      // A link is as good as outside whatever it points at.
      if (entry.kind == RemoteEntryKind.symlink) return entry;
      if (entry.kind != RemoteEntryKind.directory) return null;
      dir = RemotePath.join(dir, entry.name);
    }
    return null;
  }

  Future<List<RemoteEntry>> _list(String dir) async =>
      _listings[dir] ??= await _browser.list(dir);

  /// The file's bytes, or null when it came out bigger than the limit however
  /// small the listing said it was.
  Future<Uint8List?> _fetch(String path) async {
    if (_busy >= limits.concurrent) {
      final turn = Completer<void>();
      _waiting.add(turn);
      await turn.future;
    } else {
      _busy++;
    }
    final scratch = await Directory.systemTemp.createTemp('jeansh-html-');
    try {
      final copy = File('${scratch.path}/f');
      await _browser.download(path, copy.path, length: limits.fileBytes + 1);
      final bytes = await copy.readAsBytes();
      return bytes.length > limits.fileBytes ? null : bytes;
    } finally {
      await scratch.delete(recursive: true).catchError((_) => scratch);
      if (_waiting.isEmpty) {
        _busy--;
      } else {
        _waiting.removeFirst().complete();
      }
    }
  }

  static String _contentType(String name) {
    final dot = name.lastIndexOf('.');
    final ext = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
    return switch (ext) {
      'html' || 'htm' => 'text/html; charset=utf-8',
      'css' => 'text/css; charset=utf-8',
      'js' || 'mjs' => 'text/javascript; charset=utf-8',
      'json' || 'map' => 'application/json; charset=utf-8',
      'txt' => 'text/plain; charset=utf-8',
      'svg' => 'image/svg+xml',
      'png' => 'image/png',
      'jpg' || 'jpeg' => 'image/jpeg',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      'avif' => 'image/avif',
      'ico' => 'image/x-icon',
      'bmp' => 'image/bmp',
      'woff' => 'font/woff',
      'woff2' => 'font/woff2',
      'ttf' => 'font/ttf',
      'otf' => 'font/otf',
      'wasm' => 'application/wasm',
      'mp3' => 'audio/mpeg',
      'mp4' => 'video/mp4',
      'webm' => 'video/webm',
      _ => 'application/octet-stream',
    };
  }
}
