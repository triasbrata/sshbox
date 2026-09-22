import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../files/file_browser.dart' show formatBytes;
import 'install.dart';

export 'install.dart' show UpdateException;

/// Where the desktop builds are served from, baked in at build time with
/// `--dart-define JEANSH_UPDATE_HOST=https://…` (see tools/build_desktop.sh
/// and tools/build_apple.sh). The feed gives a path under it and nothing
/// else, so which host a build downloads from is decided when it is built
/// and never by whoever writes the feed.
///
/// Empty — a debug build, or a release built without it — turns the whole
/// updater off, and Settings says so rather than half-working.
const updateHost = String.fromEnvironment('JEANSH_UPDATE_HOST');

/// This build's own `X.Y.Z+N`, baked the same way, since the version lives in
/// pubspec.yaml and CI writes it into each build's own copy. Empty turns the
/// updater off too: nothing can be compared.
const buildVersion = String.fromEnvironment('JEANSH_VERSION');

/// The feed: the newest GitHub release's `latest.json`, which this URL
/// redirects to. Metadata only — no build is ever downloaded from GitHub.
///
/// A profile or debug build can be pointed at another with
/// `--dart-define JEANSH_UPDATE_FEED=…`, which is how an update is tried end
/// to end against a feed served on this machine. A release build never
/// reads it.
const updateFeed = kReleaseMode
    ? _releaseFeed
    : String.fromEnvironment('JEANSH_UPDATE_FEED', defaultValue: _releaseFeed);
const _releaseFeed =
    'https://github.com/triasbrata/sshbox/releases/latest/download/latest.json';

/// The largest a build in the feed may say it is. The desktop builds run to
/// tens of megabytes, so this is room to grow many times over and still a
/// bound on what one tap can pull onto the disk.
const maxUpdateSize = 512 * 1024 * 1024;

/// What the feed calls this platform's build, and '' where there are no
/// desktop builds to update (Android goes through Play, iOS through the App
/// Store).
String get updatePlatform => switch (defaultTargetPlatform) {
  TargetPlatform.linux => 'linux',
  TargetPlatform.windows => 'windows',
  TargetPlatform.macOS => 'macos',
  _ => '',
};

/// One platform's build, as the feed describes it.
class Update {
  const Update({
    required this.version,
    required this.build,
    required this.path,
    required this.size,
    required this.sha256,
  });

  /// The version name, `X.Y.Z`, and the build number after it.
  final String version;
  final int build;

  /// Where the file sits under the baked host, e.g.
  /// `desktop/linux/Jeansh-1.0.63+67-linux-x64.tar.gz`.
  final String path;

  /// Its size in bytes, which the progress bar counts against, and its
  /// SHA-256 in hex, which the download is checked against.
  final int size;
  final String sha256;

  String get label => '$version+$build';

  /// The file's own name, which it keeps in the user's Downloads.
  String get name => path.split('/').last;

  /// Where to fetch it from: [host], with [path] under it.
  Uri url(String host) {
    final base = host.endsWith('/')
        ? host.substring(0, host.length - 1)
        : host;
    return Uri.parse('$base/$path');
  }
}

/// Fetches a URL and gives back what comes back, which a test stands in for
/// so nothing in one ever reaches the network.
typedef Fetch = Future<Stream<List<int>>> Function(Uri url);

/// The desktop's updater: reads the feed, says whether what it names is newer
/// than this build, brings the file down and checks it, and puts it in place
/// of this copy — see [restartInto].
class Updater {
  Updater({
    Fetch? fetch,
    this.host = updateHost,
    this.version = buildVersion,
    this.feed = updateFeed,
    this.downloads,
    Install? install,
    void Function()? quit,
  }) : _fetch = fetch ?? _get,
       install =
           install ?? Install.of(Platform.resolvedExecutable, updatePlatform),
       _quit = quit ?? (() => exit(0));

  final Fetch _fetch;
  final String host;
  final String version;
  final String feed;

  /// Where a download lands, for a test that must not write to the user's own
  /// Downloads. Null is [downloadsFolder].
  final Directory? downloads;

  /// Where this copy is installed, which an update replaces; null where it is
  /// not laid out the way a release unpacks.
  final Install? install;

  /// Quits this copy, for the helper that swaps the update in to do so.
  final void Function() _quit;

  /// Why this copy cannot put an update in its own place, or null if it can.
  /// Where it cannot, the download is handed over in the Downloads instead.
  String? get installRefusal => install == null
      ? 'This copy of Jeansh is not laid out the way a release unpacks, so '
            'it cannot replace itself.'
      : install!.refusal;

  /// Puts [archive], [update]'s build as [download] brought it down, in place
  /// of this copy and quits, for the helper to swap it in and start it.
  /// Throws [UpdateException] with this copy untouched: the swap is the
  /// helper's, and last.
  ///
  /// The file is held to the feed's SHA-256 again here, where it is
  /// installed, so nothing but a build the feed describes is ever unpacked,
  /// whoever hands it over.
  Future<void> restartInto(Update update, File archive) async {
    final install = this.install;
    if (install == null) throw UpdateException(installRefusal!);
    final Digest digest;
    try {
      digest = await sha256.bind(archive.openRead()).first;
    } on FileSystemException catch (error) {
      throw UpdateException('Could not read ${update.name}: ${error.message}');
    }
    if (digest.toString() != update.sha256.toLowerCase()) {
      throw UpdateException(
        '${update.name} is not the file the release describes, so it was not '
        'installed.',
      );
    }
    final staged = await install.stage(archive);
    await install.handOff(staged);
    // Unpacked and on its way in: the archive has done its work.
    _remove(archive);
    _quit();
  }

  /// Whether this build takes updates at all: a host and a version baked in,
  /// on a platform that has desktop builds.
  bool get enabled =>
      host.isNotEmpty && version.isNotEmpty && updatePlatform.isNotEmpty;

  /// When the last check was, so the one at startup happens once a day.
  static const checkedKey = 'sshbox.update.checked';
  static const checkEvery = Duration(days: 1);

  /// The newest release if it is newer than this build, null if it is not.
  /// Throws [UpdateException] for a feed that cannot be read.
  Future<Update?> check() async {
    if (!enabled) return null;
    final update = parseFeed(await _read(Uri.parse(feed)), updatePlatform);
    return isNewer(update.label, version) ? update : null;
  }

  /// [check], but at most once every [checkEvery]: what the app does when it
  /// starts. Null when it has been checked today.
  Future<Update?> checkDaily() async {
    if (!enabled) return null;
    final prefs = await SharedPreferences.getInstance();
    final last = prefs.getInt(checkedKey) ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - last < checkEvery.inMilliseconds) return null;
    await prefs.setInt(checkedKey, now);
    return check();
  }

  /// Brings [update] down into [into] (the user's Downloads by default) and
  /// checks its SHA-256 against the feed's before handing it over. A file
  /// that does not match is deleted, and the error names it; null is
  /// [cancelled] having completed first, which leaves nothing behind either.
  ///
  /// Nothing is run: what comes back is a file, for [restartInto] or for the
  /// user to open.
  Future<File?> download(
    Update update, {
    Directory? into,
    void Function(int done, int total)? onProgress,
    Future<void>? cancelled,
  }) async {
    if (host.isEmpty) {
      throw const UpdateException('This build takes no updates.');
    }
    final folder = into ?? downloads ?? downloadsFolder();
    final separator = Platform.pathSeparator;
    final part = File('${folder.path}$separator${update.name}.part');
    var stop = false;
    unawaited(cancelled?.then((_) => stop = true));

    final IOSink sink;
    try {
      folder.createSync(recursive: true);
      sink = part.openWrite();
    } on FileSystemException catch (error) {
      throw UpdateException(
        'Could not write to ${folder.path}: '
        '${error.osError?.message ?? error.message}',
      );
    }
    var done = 0;
    try {
      // ponytail: a cancel takes effect on the next chunk, which over a real
      // link is milliseconds. A subscription of its own would stop it sooner.
      await for (final chunk in await _fetch(update.url(host))) {
        if (stop) break;
        done += chunk.length;
        // A file bigger than the feed says is not the file the feed says.
        if (done > update.size) {
          throw UpdateException(
            '${update.name} is bigger than the release says it is, so it was '
            'not kept.',
          );
        }
        sink.add(chunk);
        onProgress?.call(done, update.size);
      }
      await sink.close();
    } catch (error) {
      try {
        await sink.close();
      } catch (_) {
        // Already broken; the file goes either way.
      }
      _remove(part);
      if (error is UpdateException) rethrow;
      throw UpdateException('Could not download ${update.name}: $error');
    }
    if (stop) {
      _remove(part);
      return null;
    }

    final digest = await sha256.bind(part.openRead()).first;
    if (digest.toString() != update.sha256.toLowerCase()) {
      _remove(part);
      throw UpdateException(
        '${update.name} is not the file the release describes — its SHA-256 '
        'is $digest, not ${update.sha256.toLowerCase()}. It was deleted.',
      );
    }

    final file = File('${folder.path}$separator${update.name}');
    _remove(file);
    return part.renameSync(file.path);
  }

  static void _remove(File file) {
    try {
      if (file.existsSync()) file.deleteSync();
    } on FileSystemException {
      // Nothing more to do about a file that will not go.
    }
  }

  /// The feed, as text; a body far too big to be one is refused part-read.
  ///
  /// Everything that can go wrong on the way comes out as an
  /// [UpdateException], so what is shown is a line rather than a raw error,
  /// and so no caller is left waiting on something it did not expect.
  Future<String> _read(Uri url) async {
    final bytes = <int>[];
    try {
      await for (final chunk in await _fetch(url)) {
        bytes.addAll(chunk);
        if (bytes.length > 256 * 1024) {
          throw const UpdateException('The update feed is too big to be one.');
        }
      }
    } on UpdateException {
      rethrow;
    } catch (error) {
      throw UpdateException('Could not read the update feed: $error');
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  /// One GET, with no token: the feed is a public release's asset, and the
  /// build is a file under the baked host. Redirects are followed, which is
  /// how `releases/latest/download/…` reaches the asset.
  ///
  /// Everything it can throw — a refused connection, a name that does not
  /// resolve, a certificate it will not take, a URL that is no URL — comes
  /// out as an [UpdateException], so a caller has one kind of error to catch
  /// and what is shown is a line rather than a raw error. The stream it
  /// gives back can still fail later; [_read] and [download] wrap that.
  static Future<Stream<List<int>>> _get(Uri url) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..userAgent = 'Jeansh';
    try {
      final response = await (await client.getUrl(url)).close();
      if (response.statusCode != 200) {
        client.close(force: true);
        throw UpdateException('${url.host} answered ${response.statusCode}.');
      }
      // Not forced: the connection is kept until the body is read out.
      client.close();
      // Between chunks rather than for the whole download: a stalled link
      // fails rather than hanging.
      return response.timeout(const Duration(seconds: 60));
    } on UpdateException {
      client.close(force: true);
      rethrow;
    } on SocketException catch (error) {
      client.close(force: true);
      throw UpdateException('Could not reach ${url.host}: ${error.message}');
    } catch (error) {
      client.close(force: true);
      throw UpdateException('Could not reach ${url.host}: $error');
    }
  }
}

/// The feed, for [platform]: throws [UpdateException] naming what is wrong
/// with it rather than letting a half-read one through.
///
/// ```json
/// {
///   "version": "1.0.63", "build": 67,
///   "platforms": {
///     "linux": {
///       "path": "desktop/linux/Jeansh-1.0.63+67-linux-x64.tar.gz",
///       "size": 19922944,
///       "sha256": "8f43…"
///     }
///   }
/// }
/// ```
Update parseFeed(String body, String platform) {
  final Object? feed;
  try {
    feed = jsonDecode(body);
  } on FormatException {
    throw const UpdateException('The update feed is not readable.');
  }
  if (feed is! Map) {
    throw const UpdateException('The update feed is not readable.');
  }

  final version = feed['version'];
  final build = feed['build'];
  if (version is! String || version.isEmpty || build is! int) {
    throw const UpdateException('The update feed names no version.');
  }
  final platforms = feed['platforms'];
  final entry = platforms is Map ? platforms[platform] : null;
  if (entry is! Map) {
    throw UpdateException('Release $version has no $platform build.');
  }
  final path = entry['path'];
  final size = entry['size'];
  final digest = entry['sha256'];
  if (path is! String || size is! int || size <= 0 || digest is! String) {
    throw UpdateException(
      'Release $version describes its $platform build in a way this version '
      'cannot read.',
    );
  }
  // A desktop build is tens of megabytes. A feed asking for far more than any
  // of them could be is refused before it is offered, rather than filling the
  // disk on the way to a hash that was never going to match.
  if (size > maxUpdateSize) {
    throw UpdateException(
      "Release $version says its $platform build is ${formatBytes(size)}, "
      'which is too big to be one.',
    );
  }
  // The host is this build's own. A path that could leave it — an absolute
  // URL, a root path, a walk upwards — is the one thing a feed must not be
  // able to do, so it is refused rather than joined. A backslash goes with
  // them: it cannot leave the folder, but on Windows it would name a
  // subfolder that is not there and the write would simply fail.
  if (path.isEmpty ||
      path.startsWith('/') ||
      path.contains('..') ||
      path.contains('//') ||
      path.contains(':') ||
      path.contains(r'\')) {
    throw UpdateException(
      'Release $version points its $platform build somewhere this build will '
      'not download from.',
    );
  }
  if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(digest)) {
    throw UpdateException(
      'Release $version gives no SHA-256 for its $platform build.',
    );
  }
  return Update(
    version: version,
    build: build,
    path: path,
    size: size,
    sha256: digest,
  );
}

/// Whether [candidate] is a newer `X.Y.Z+N` than [current], compared part by
/// part as numbers rather than as text: 1.0.10 is newer than 1.0.9. The build
/// number settles a version name built again.
bool isNewer(String candidate, String current) {
  final a = _parts(candidate);
  final b = _parts(current);
  for (var i = 0; i < a.length && i < b.length; i++) {
    if (a[i] != b[i]) return a[i] > b[i];
  }
  return a.length > b.length;
}

/// The numbers in `X.Y.Z+N`, in order; anything that is not one ends it.
List<int> _parts(String version) {
  final parts = <int>[];
  for (final part in version.split(RegExp(r'[.+]'))) {
    final number = int.tryParse(part);
    if (number == null) break;
    parts.add(number);
  }
  return parts;
}

/// Where a download lands: the user's Downloads, or their home if there is no
/// such folder.
///
/// ponytail: the folder is not read from XDG's user-dirs or the Windows
/// shell, so a renamed or moved Downloads gets the home folder instead.
Directory downloadsFolder() {
  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '';
  if (home.isEmpty) return Directory.systemTemp;
  final downloads = Directory('$home${Platform.pathSeparator}Downloads');
  return downloads.existsSync() ? downloads : Directory(home);
}

/// The app's own, which Settings and the check at startup share.
final updater = Updater();
