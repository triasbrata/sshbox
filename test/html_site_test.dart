import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/files/file_browser.dart';
import 'package:sshbox/src/files/html_site.dart';

/// A [FileBrowser] over a real folder, reporting links as links, which is all
/// the site asks of one.
class _DirBrowser implements FileBrowser {
  int downloads = 0;

  @override
  Future<List<RemoteEntry>> list(String path) async {
    final dir = Directory(path);
    if (!dir.existsSync()) {
      throw const FileBrowserException('no', fault: FileBrowserFault.notFound);
    }
    return [
      for (final e in dir.listSync(followLinks: false))
        RemoteEntry(
          name: e.uri.pathSegments.where((s) => s.isNotEmpty).last,
          path: e.path,
          kind: e is Link
              ? RemoteEntryKind.symlink
              : e is Directory
              ? RemoteEntryKind.directory
              : RemoteEntryKind.file,
          size: e is File ? e.lengthSync() : null,
        ),
    ];
  }

  @override
  Future<void> download(
    String path,
    String localPath, {
    int offset = 0,
    int? length,
    void Function(int received, int total)? onProgress,
    Future<void>? cancel,
  }) async {
    downloads++;
    final bytes = File(path).readAsBytesSync();
    File(localPath).writeAsBytesSync(
      length == null || length >= bytes.length
          ? bytes
          : bytes.sublist(0, length),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  late Directory root, site, outside;
  late _DirBrowser browser;
  HtmlSite? served;

  setUp(() {
    root = Directory.systemTemp.createTempSync('html-site-test');
    site = Directory('${root.path}/site')..createSync();
    outside = Directory('${root.path}/outside')..createSync();
    File('${site.path}/page.html').writeAsStringSync('<h1>hi</h1>');
    File('${site.path}/style.css').writeAsStringSync('h1{color:red}');
    Directory('${site.path}/img').createSync();
    File('${site.path}/img/a.png').writeAsBytesSync([1, 2, 3]);
    File('${site.path}/.env').writeAsStringSync('SECRET');
    File('${outside.path}/secret.txt').writeAsStringSync('TOP SECRET');
    Link('${site.path}/leak.txt').createSync('${outside.path}/secret.txt');
    Link('${site.path}/leakdir').createSync(outside.path);
    Link('${site.path}/same.css').createSync('${site.path}/style.css');
    browser = _DirBrowser();
  });

  tearDown(() async {
    await served?.close();
    served = null;
    root.deleteSync(recursive: true);
  });

  Future<HtmlSite> start([HtmlSiteLimits? limits]) async =>
      served = await HtmlSite.start(
        browser: browser,
        htmlPath: '${site.path}/page.html',
        limits: limits ?? const HtmlSiteLimits(),
      );

  /// A raw request, so the path reaches the server as written, `..` and all.
  Future<(int, String, HttpHeaders)> raw(
    HtmlSite s,
    String path, {
    String method = 'GET',
    String? host,
  }) async {
    final socket = await Socket.connect('127.0.0.1', s.url.port);
    socket.write(
      '$method $path HTTP/1.1\r\nHost: ${host ?? '127.0.0.1:${s.url.port}'}\r\n'
      'Connection: close\r\n\r\n',
    );
    final text = utf8.decode(
      await socket.expand((b) => b).toList(),
      allowMalformed: true,
    );
    socket.destroy();
    final status = int.parse(text.split(' ')[1]);
    return (
      status,
      text.split('\r\n\r\n').skip(1).join('\r\n\r\n'),
      _Head(text),
    );
  }

  Future<(int, String, HttpHeaders)> get(HtmlSite s, String rel) =>
      raw(s, '/${s.token}/$rel');

  test('serves the page, its css and its pictures with their types', () async {
    final s = await start();
    expect(s.url.host, '127.0.0.1');
    expect(s.url.pathSegments, [s.token, 'page.html']);

    final page = await get(s, 'page.html');
    expect(page.$1, 200);
    expect(page.$2, '<h1>hi</h1>');
    expect(page.$3.value('content-type'), 'text/html; charset=utf-8');
    expect(page.$3.value('content-security-policy'), contains("connect-src"));
    expect(page.$3.value('content-security-policy'), contains('https:'));
    // Only connect and form are restricted: remote css, js, pictures and
    // fonts load.
    for (final loads in ['default-src', 'script-src', 'style-src', 'img-src']) {
      expect(page.$3.value('content-security-policy'), isNot(contains(loads)));
    }

    final css = await get(s, 'style.css');
    expect((css.$1, css.$2), (200, 'h1{color:red}'));
    expect(css.$3.value('content-type'), startsWith('text/css'));
    expect(css.$3.value('content-security-policy'), isNull);
    final png = await get(s, 'img/a.png');
    expect(png.$1, 200);
    expect(png.$3.value('content-type'), 'image/png');
    expect(s.problems.value, isEmpty);
  });

  test('HEAD sends no body, anything but GET and HEAD is refused', () async {
    final s = await start();
    final head = await raw(s, '/${s.token}/style.css', method: 'HEAD');
    expect((head.$1, head.$2), (200, ''));
    for (final method in ['POST', 'PUT', 'DELETE']) {
      expect((await raw(s, '/${s.token}/style.css', method: method)).$1, 405);
    }
  });

  group('confinement', () {
    test('a wrong token or none is 404 and says it is outside', () async {
      final s = await start();
      expect((await raw(s, '/page.html')).$1, 404);
      expect((await raw(s, '/not-the-token/page.html')).$1, 404);
      expect((await raw(s, '/${s.token}')).$1, isIn([403, 404]));
      expect(s.problems.value.keys, contains('/page.html'));
      expect((await raw(s, '/favicon.ico')).$1, 404);
      expect(s.problems.value.keys, isNot(contains('/favicon.ico')));
    });

    test('.. is refused however it is spelled', () async {
      final s = await start();
      for (final path in [
        '/${s.token}/../outside/secret.txt',
        '/${s.token}/img/../../outside/secret.txt',
        '/${s.token}/%2e%2e/outside/secret.txt',
        '/${s.token}/%2E%2E%2Foutside%2Fsecret.txt',
        '/${s.token}/..%2foutside/secret.txt',
        '/${s.token}/img/%2e%2e/%2e%2e/outside/secret.txt',
        '/${s.token}/..\\outside\\secret.txt',
        '/${s.token}//etc/passwd',
        '/${s.token}/%00',
        '/${s.token}/page.html%00.png',
      ]) {
        final r = await raw(s, path);
        expect(r.$1, isIn([403, 404]), reason: path);
        expect(r.$2, isNot(contains('TOP SECRET')), reason: path);
        expect(r.$2, isNot(contains('<h1>')), reason: path);
      }
    });

    test('an absolute path is not read from the host', () async {
      final s = await start();
      final r = await get(s, Uri.encodeComponent('${outside.path}/secret.txt'));
      expect(r.$1, isIn([403, 404]));
      expect(r.$2, isNot(contains('TOP SECRET')));
      final plain = await raw(s, '/${s.token}${outside.path}/secret.txt');
      expect(plain.$1, isIn([403, 404]));
      expect(plain.$2, isNot(contains('TOP SECRET')));
    });

    test(
      'a symlink out of the folder, to a file or a folder, is refused',
      () async {
        final s = await start();
        final file = await get(s, 'leak.txt');
        expect(file.$1, 403);
        expect(file.$2, isNot(contains('TOP SECRET')));
        final dir = await get(s, 'leakdir/secret.txt');
        expect(dir.$1, 403);
        expect(dir.$2, isNot(contains('TOP SECRET')));
        expect(s.problems.value['/${s.token}/leak.txt'], contains('link'));
      },
    );

    test('even a link that stays inside is not followed', () async {
      final s = await start();
      expect((await get(s, 'same.css')).$1, 403);
    });

    test('hidden files are refused, and so is a folder', () async {
      final s = await start();
      final env = await get(s, '.env');
      expect(env.$1, 403);
      expect(env.$2, isNot(contains('SECRET')));
      expect((await get(s, 'img')).$1, 404);
      expect((await get(s, 'img/')).$1, 403);
      expect((await get(s, 'nope.js')).$1, 404);
      expect(s.problems.value['/${s.token}/nope.js'], 'missing');
    });

    test('a name that reaches the site through DNS is refused', () async {
      final s = await start();
      final r = await raw(
        s,
        '/${s.token}/page.html',
        host: 'evil.example:${s.url.port}',
      );
      expect(r.$1, 403);
      expect(r.$2, isNot(contains('<h1>')));
      expect(
        (await raw(s, '/${s.token}/page.html', host: '127.0.0.1')).$1,
        403,
      );
    });
  });

  group('limits', () {
    test('a file over the limit is 413 and named, and never fetched', () async {
      File('${site.path}/big.js').writeAsBytesSync(List.filled(2000, 1));
      final s = await start(const HtmlSiteLimits(fileBytes: 1000));
      final r = await get(s, 'big.js');
      expect(r.$1, 413);
      expect(s.problems.value['/${s.token}/big.js'], contains('too big'));
      expect(s.problems.value['/${s.token}/big.js'], contains('1000 B'));
      expect(browser.downloads, 0);
    });

    test('the total and the file count are held', () async {
      for (var i = 0; i < 3; i++) {
        File('${site.path}/f$i.js').writeAsBytesSync(List.filled(100, 1));
      }
      final total = await start(
        const HtmlSiteLimits(totalBytes: 250, files: 100),
      );
      expect((await get(total, 'f0.js')).$1, 200);
      expect((await get(total, 'f1.js')).$1, 200);
      expect((await get(total, 'f2.js')).$1, 413);
      // A file already counted is not counted again.
      expect((await get(total, 'f0.js')).$1, 200);
      expect(total.problems.value.values.single, contains('in all'));
      await total.close();

      final count = await start(const HtmlSiteLimits(files: 2));
      expect((await get(count, 'f0.js')).$1, 200);
      expect((await get(count, 'f1.js')).$1, 200);
      expect((await get(count, 'f2.js')).$1, 429);
      expect(count.problems.value.values.single, contains('2 files'));
    });

    test('a listing that lies about the size is caught by the bytes', () async {
      final s = await start(const HtmlSiteLimits(fileBytes: 10));
      // The listing says 5, the file has grown by the time it is read.
      File('${site.path}/grow.js').writeAsBytesSync(List.filled(5, 1));
      browser = _LyingBrowser(browser);
      served = null;
      await s.close();
      final t = served = await HtmlSite.start(
        browser: browser,
        htmlPath: '${site.path}/page.html',
        limits: const HtmlSiteLimits(fileBytes: 10),
      );
      File('${site.path}/grow.js').writeAsBytesSync(List.filled(500, 1));
      final r = await get(t, 'grow.js');
      expect(r.$1, 413);
    });

    test('Reload gives the budget back and forgets the problems', () async {
      final s = await start(const HtmlSiteLimits(files: 1));
      expect((await get(s, 'style.css')).$1, 200);
      expect((await get(s, 'page.html')).$1, 429);
      expect(s.problems.value, isNotEmpty);
      s.reset();
      expect(s.problems.value, isEmpty);
      expect((await get(s, 'page.html')).$1, 200);
    });

    test('many at once all arrive', () async {
      for (var i = 0; i < 12; i++) {
        File('${site.path}/p$i.js').writeAsStringSync('$i');
      }
      final s = await start(const HtmlSiteLimits(concurrent: 2));
      final all = await Future.wait([
        for (var i = 0; i < 12; i++) get(s, 'p$i.js'),
      ]);
      expect(all.map((r) => r.$2), [for (var i = 0; i < 12; i++) '$i']);
    });
  });

  test('a page too big says so in the page, not as a bare status', () async {
    File('${site.path}/page.html').writeAsBytesSync(List.filled(2000, 65));
    final s = await start(const HtmlSiteLimits(fileBytes: 1000));
    final r = await get(s, 'page.html');
    expect(r.$1, 413);
    expect(r.$3.value('content-type'), startsWith('text/html'));
    expect(r.$2, contains('Could not open page.html'));
    expect(r.$2, contains('too big'));
  });

  test('every extension is served as its own type', () async {
    const types = {
      'html': 'text/html; charset=utf-8',
      'HTM': 'text/html; charset=utf-8',
      'css': 'text/css; charset=utf-8',
      'js': 'text/javascript; charset=utf-8',
      'mjs': 'text/javascript; charset=utf-8',
      'json': 'application/json; charset=utf-8',
      'map': 'application/json; charset=utf-8',
      'txt': 'text/plain; charset=utf-8',
      'svg': 'image/svg+xml',
      'png': 'image/png',
      'jpg': 'image/jpeg',
      'jpeg': 'image/jpeg',
      'gif': 'image/gif',
      'webp': 'image/webp',
      'avif': 'image/avif',
      'ico': 'image/x-icon',
      'bmp': 'image/bmp',
      'woff': 'font/woff',
      'woff2': 'font/woff2',
      'ttf': 'font/ttf',
      'otf': 'font/otf',
      'wasm': 'application/wasm',
      'mp3': 'audio/mpeg',
      'mp4': 'video/mp4',
      'webm': 'video/webm',
      'xyz': 'application/octet-stream',
      'noextension': 'application/octet-stream',
    };
    for (final name in types.keys) {
      File('${site.path}/f.$name').writeAsStringSync('x');
    }
    File('${site.path}/noextension').writeAsStringSync('x');
    final s = await start();
    for (final MapEntry(:key, :value) in types.entries) {
      final file = key == 'noextension' ? key : 'f.$key';
      expect(
        (await get(s, file)).$3.value('content-type'),
        value,
        reason: file,
      );
    }
  });

  group('a host that fails', () {
    test('a read that throws is a 500, said and not leaked', () async {
      final s = served = await HtmlSite.start(
        browser: _FailingBrowser(StateError('disk on fire: /secret/path')),
        htmlPath: '${site.path}/page.html',
      );
      final r = await get(s, 'style.css');
      expect(r.$1, 500);
      expect(r.$2, isNot(contains('secret')));
      expect(s.problems.value['/${s.token}/style.css'], 'could not be read');
    });

    test('a refusal from the host is a 502, a vanished file a 404', () async {
      var s = served = await HtmlSite.start(
        browser: _FailingBrowser(const FileBrowserException('no')),
        htmlPath: '${site.path}/page.html',
      );
      expect((await get(s, 'style.css')).$1, 502);
      await s.close();
      s = served = await HtmlSite.start(
        browser: _FailingBrowser(
          const FileBrowserException('gone', fault: FileBrowserFault.notFound),
        ),
        htmlPath: '${site.path}/page.html',
      );
      expect((await get(s, 'style.css')).$1, 404);
    });
  });

  test('closing stops it listening', () async {
    final s = await start();
    final port = s.url.port;
    await s.close();
    served = null;
    await expectLater(
      Socket.connect('127.0.0.1', port),
      throwsA(isA<SocketException>()),
    );
  });

  test('a missing folder is 404, a failing host 502', () async {
    final s = await start();
    expect((await get(s, 'img/none.png')).$1, 404);
    site.deleteSync(recursive: true);
    // The listing was cached before; a Reload sees the folder gone.
    s.reset();
    expect((await get(s, 'page.html')).$1, 404);
  });
}

class _LyingBrowser extends _DirBrowser {
  _LyingBrowser(this.inner);
  final _DirBrowser inner;

  @override
  Future<List<RemoteEntry>> list(String path) async => [
    for (final e in await inner.list(path))
      RemoteEntry(
        name: e.name,
        path: e.path,
        kind: e.kind,
        size: e.kind == RemoteEntryKind.file ? 5 : e.size,
      ),
  ];
}

/// The response's header block, parsed just enough to read values.
class _Head implements HttpHeaders {
  _Head(String text) {
    for (final line in text.split('\r\n\r\n').first.split('\r\n').skip(1)) {
      final cut = line.indexOf(':');
      if (cut > 0) {
        _values[line.substring(0, cut).toLowerCase()] = line
            .substring(cut + 1)
            .trim();
      }
    }
  }
  final _values = <String, String>{};

  @override
  String? value(String name) => _values[name.toLowerCase()];

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

/// Lists as a real folder does and throws when a file is read.
class _FailingBrowser extends _DirBrowser {
  _FailingBrowser(this.error);
  final Object error;

  @override
  Future<void> download(
    String path,
    String localPath, {
    int offset = 0,
    int? length,
    void Function(int received, int total)? onProgress,
    Future<void>? cancel,
  }) async => throw error;
}
