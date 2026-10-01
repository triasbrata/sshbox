import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'file_browser.dart';
import 'sftp_file_browser.dart';

/// A [FileBrowser] over this machine's own filesystem, for a Local shell or
/// a WSL distro's: what the files drawer reads where there is no SFTP,
/// through `dart:io`.
///
/// Paths stay POSIX, as the tree and every page above it spell them. [native]
/// turns one into this machine's own: itself on a Mac or Linux, and the
/// distro's share on Windows, `\\wsl.localhost\<distro>\…`, which Windows
/// serves for every running distro.
///
/// What needs a shell — search through `grep`, and sudo — goes through
/// [process], the `sh -c` the session runs its commands with, which on
/// Windows runs inside the distro and so sees the same POSIX paths.
class LocalFileBrowser implements FileBrowser, FileSearchCapable, SudoCapable {
  LocalFileBrowser({
    required this.process,
    String Function(String path)? native,
    this.home,
    this.windows = false,
  }) : _native = native ?? _same;

  final Future<Process> Function(String command) process;
  final String Function(String path) _native;
  final Future<String> Function()? home;

  /// Whether [native] paths are Windows' own, where there is no `chmod` and
  /// a distro's share keeps its own permissions.
  final bool windows;

  static String _same(String path) => path;

  /// [path] in a WSL distro, [distro], as Windows reaches it.
  static String wslPath(String distro, String path) =>
      '\\\\wsl.localhost\\$distro${path.replaceAll('/', '\\')}';

  @override
  Future<String> resolveHome() =>
      _guard('resolve the home directory', () async {
        final found =
            await (home?.call() ??
                Future.value(Platform.environment['HOME'] ?? '/'));
        return found.isEmpty ? '/' : found;
      });

  @override
  Future<List<RemoteEntry>> list(String path) => _guard('list $path', () async {
    final entries = <RemoteEntry>[];
    await for (final entity in Directory(
      _native(path),
    ).list(followLinks: false)) {
      final child = RemotePath.join(
        path,
        entity.path.split(windows ? RegExp(r'[\\/]') : '/').last,
      );
      // stat follows a link, so a link's size and time are its target's,
      // and a broken one has neither.
      final stat = await entity.stat();
      final missing = stat.type == FileSystemEntityType.notFound;
      final kind = switch (entity) {
        Link() => RemoteEntryKind.symlink,
        Directory() => RemoteEntryKind.directory,
        File() when stat.type == FileSystemEntityType.file =>
          RemoteEntryKind.file,
        _ => RemoteEntryKind.other,
      };
      entries.add(
        RemoteEntry(
          name: RemotePath.basename(child),
          path: child,
          kind: kind,
          size: kind == RemoteEntryKind.directory || missing ? null : stat.size,
          modified: missing ? null : stat.modified,
          targetIsDirectory: kind == RemoteEntryKind.symlink && !missing
              ? stat.type == FileSystemEntityType.directory
              : null,
        ),
      );
    }
    SftpFileBrowser.sortEntries(entries);
    return entries;
  });

  @override
  Future<RemoteEntryKind?> stat(String path) =>
      _guard('look at $path', () async {
        return switch (await FileSystemEntity.type(_native(path))) {
          FileSystemEntityType.notFound => null,
          FileSystemEntityType.directory => RemoteEntryKind.directory,
          FileSystemEntityType.file => RemoteEntryKind.file,
          _ => RemoteEntryKind.other,
        };
      });

  /// null when nothing is at [path].
  Future<FileStat?> _statOrNull(String path) async {
    final stat = await FileStat.stat(_native(path));
    return stat.type == FileSystemEntityType.notFound ? null : stat;
  }

  static FileStamp _stampOf(FileStat stat) =>
      (modified: stat.modified, size: stat.size);

  static void _checkOpenable(FileStat stat, int maxBytes) {
    if (stat.type == FileSystemEntityType.directory) {
      throw const FileBrowserException(
        'That is a directory, not a file.',
        fault: FileBrowserFault.notText,
      );
    }
    if (stat.size > maxBytes) {
      throw FileBrowserException(
        '${formatBytes(stat.size)} is too large to open here. '
        'Use the terminal for a file this size.',
        fault: FileBrowserFault.tooLarge,
      );
    }
  }

  @override
  Future<RemoteText> readText(
    String path, {
    int maxBytes = FileBrowser.defaultReadLimit,
  }) => _guard('open $path', () async {
    final stat = await _statOrNull(path);
    if (stat == null) throw _gone('open $path');
    _checkOpenable(stat, maxBytes);
    final bytes = await File(_native(path)).readAsBytes();
    return (text: SftpFileBrowser.decodeText(bytes), stamp: _stampOf(stat));
  });

  static void _checkUnchanged(String path, FileStat? now, FileStamp? expected) {
    if (expected == null) return;
    if (now != null && _stampOf(now) == expected) return;
    throw FileBrowserException(
      '${RemotePath.basename(path)} changed on disk since it was opened.',
      fault: FileBrowserFault.changed,
    );
  }

  /// In place, through a link to what it points at, keeping the file's owner
  /// and permissions.
  ///
  /// ponytail: not a write beside it and a rename over it, as SFTP's is —
  /// that guards against a dropped connection, which a local disk has none
  /// of, and keeping the mode across a rename wants a chmod Dart lacks. A
  /// crash mid-write can leave the file short.
  @override
  Future<FileStamp> writeText(
    String path,
    String content, {
    FileStamp? expected,
  }) => _guard('save $path', () async {
    _checkUnchanged(path, await _statOrNull(path), expected);
    await File(_native(path)).writeAsString(content, flush: true);
    return _stampOf((await _statOrNull(path))!);
  });

  @override
  Future<void> rename(String from, String to) =>
      _guard('rename ${RemotePath.basename(from)}', () async {
        final source = _native(from);
        // Link first: a link to a folder would otherwise be renamed as the
        // folder, which Dart refuses.
        final entity = await FileSystemEntity.isLink(source)
            ? Link(source)
            : await FileSystemEntity.isDirectory(source)
            ? Directory(source)
            : File(source) as FileSystemEntity;
        await entity.rename(_native(to));
      });

  @override
  Future<void> delete(String path, {bool recursive = false}) =>
      _guard('delete ${RemotePath.basename(path)}', () async {
        final target = _native(path);
        // Not following a link: deleting one removes the link, never what it
        // points at, and Dart's recursive delete follows none either.
        if (await FileSystemEntity.isLink(target)) {
          await Link(target).delete();
        } else if (await FileSystemEntity.isDirectory(target)) {
          await Directory(target).delete(recursive: recursive);
        } else {
          await File(target).delete();
        }
      });

  @override
  Future<void> makeDirectory(String path) =>
      _guard('create ${RemotePath.basename(path)}', () async {
        if (await FileSystemEntity.type(_native(path)) !=
            FileSystemEntityType.notFound) {
          throw FileBrowserException(
            'Could not create ${RemotePath.basename(path)}: '
            'something by that name is already there.',
          );
        }
        await Directory(_native(path)).create();
      });

  /// Made new and exclusively, so a name taken since it was looked at — by a
  /// file or a link planted there — fails rather than being written through;
  /// a replace goes in beside it and is renamed over it. Private (0600)
  /// before a byte goes in, as SFTP's are.
  @override
  Future<void> upload(
    String localPath,
    String path, {
    bool replace = false,
    void Function(int sent, int total)? onProgress,
    Future<void>? cancel,
  }) => _guard(
    'upload ${RemotePath.basename(path)} to ${RemotePath.parent(path)}',
    () async {
      final target = replace
          ? RemotePath.join(
              RemotePath.parent(path),
              '.${RemotePath.basename(path)}.${SftpFileBrowser.randomName()}'
              '.sshbox-upload',
            )
          : path;
      final file = File(_native(target));
      await file.create(exclusive: true);
      try {
        await _private(file);
        await _copy(
          File(localPath),
          file,
          onProgress: onProgress,
          cancel: cancel,
        );
        if (replace) await file.rename(_native(path));
      } catch (_) {
        await file.delete().catchError((Object _) => file);
        rethrow;
      }
    },
  );

  Future<void> _private(File file) async {
    if (windows) return;
    final result = await Process.run('chmod', ['600', file.path]);
    if (result.exitCode != 0) {
      throw FileBrowserException('Could not make ${file.path} private.');
    }
  }

  @override
  Future<void> download(
    String path,
    String localPath, {
    int offset = 0,
    int? length,
    void Function(int received, int total)? onProgress,
    Future<void>? cancel,
  }) => _guard(
    'download ${RemotePath.basename(path)}',
    () => _copy(
      File(_native(path)),
      File(localPath),
      offset: offset,
      length: length,
      onProgress: onProgress,
      cancel: cancel,
    ),
  );

  /// [from]'s bytes from [offset], [length] of them or to its end, streamed
  /// into [to] a chunk at a time.
  static Future<void> _copy(
    File from,
    File to, {
    int offset = 0,
    int? length,
    void Function(int done, int total)? onProgress,
    Future<void>? cancel,
  }) async {
    final total = length ?? await from.length() - offset;
    var stopped = false;
    unawaited(cancel?.then((_) => stopped = true));
    var done = 0;
    final sink = to.openWrite();
    try {
      await for (final chunk in from.openRead(
        offset,
        length == null ? null : offset + length,
      )) {
        if (stopped) throw FileBrowserException.cancelled;
        sink.add(chunk);
        onProgress?.call(done += chunk.length, total);
      }
    } finally {
      await sink.close();
    }
  }

  @override
  Stream<SearchHit> search({
    required String root,
    required String query,
  }) async* {
    if (query.isEmpty) return;
    final q = SftpFileBrowser.shellQuote;
    final Process process;
    try {
      process = await this.process(
        'grep -rnIF --exclude-dir=.git -e ${q(query)} -- ${q(root)} '
        '2>/dev/null',
      );
    } catch (error) {
      throw FileBrowserException(
        'Could not start a search: $error',
        fault: FileBrowserFault.unsupported,
      );
    }
    var hits = 0;
    try {
      final lines = const LineSplitter().bind(
        const Utf8Decoder(allowMalformed: true).bind(process.stdout),
      );
      await for (final line in lines) {
        final hit = SftpFileBrowser.parseGrepLine(line);
        if (hit == null) continue;
        yield hit;
        if (++hits >= SftpFileBrowser.searchHitLimit) return;
      }
      final code = await process.exitCode;
      // 1 is no match; 127 no grep.
      if (hits == 0 && code > 1) {
        throw FileBrowserException(
          code == 127
              ? 'This machine has no grep, so search is not available.'
              : 'Search failed (exit $code).',
          fault: code == 127
              ? FileBrowserFault.unsupported
              : FileBrowserFault.unknown,
        );
      }
    } finally {
      process.kill();
    }
  }

  @override
  Future<RemoteText> sudoReadText(
    String path, {
    String? password,
    int maxBytes = FileBrowser.defaultReadLimit,
  }) => _guard('open $path', () async {
    // The login may not look at it, which is what sudo is for: then there
    // is no size to check first, nor a stamp.
    FileStat? stat;
    try {
      stat = await _statOrNull(path);
      if (stat == null) throw _gone('open $path');
      _checkOpenable(stat, maxBytes);
    } on FileSystemException {
      stat = null;
    }
    final bytes = await _sudo(
      'head -c ${maxBytes + 1} -- ${SftpFileBrowser.shellQuote(path)}',
      password,
      'open $path',
    );
    if (bytes.length > maxBytes) {
      throw const FileBrowserException(
        'This file is too large to open here. '
        'Use the terminal for a file this size.',
        fault: FileBrowserFault.tooLarge,
      );
    }
    return (
      text: SftpFileBrowser.decodeText(bytes),
      stamp: stat == null ? _unknownStamp : _stampOf(stat),
    );
  });

  static const FileStamp _unknownStamp = (modified: null, size: null);

  /// Into a file of our own in `/tmp` first, made exclusively and 0600 under
  /// a name nobody can guess, and then `cp` as root over the original, which
  /// keeps its owner, permissions and inode — as over SFTP.
  @override
  Future<FileStamp> sudoWriteText(
    String path,
    String content, {
    String? password,
    FileStamp? expected,
  }) => _guard('save $path', () async {
    Future<FileStat?> look() async {
      try {
        return await _statOrNull(path);
      } on FileSystemException {
        return null;
      }
    }

    if (expected != null && expected != _unknownStamp) {
      _checkUnchanged(path, await look(), expected);
    }
    final temp = '/tmp/.sshbox-${SftpFileBrowser.randomName()}';
    final file = File(_native(temp));
    await file.create(exclusive: true);
    try {
      await _private(file);
      await file.writeAsString(content, flush: true);
      await _sudo(
        'cp -- ${SftpFileBrowser.shellQuote(temp)} '
            '${SftpFileBrowser.shellQuote(path)}',
        password,
        'save $path',
      );
    } finally {
      await file.delete().catchError((Object _) => file);
    }
    final now = await look();
    return now == null ? _unknownStamp : _stampOf(now);
  });

  /// [command] as root, the password on stdin and never on the command line,
  /// stdin closed right behind it so a wrong one fails at once.
  Future<Uint8List> _sudo(
    String command,
    String? password,
    String action,
  ) async {
    final sudo = password == null ? 'sudo -n' : "sudo -S -p ''";
    final Process process;
    try {
      process = await this.process('env LC_ALL=C $sudo $command');
    } catch (error) {
      throw FileBrowserException(
        'Could not start sudo: $error',
        fault: FileBrowserFault.unsupported,
      );
    }
    if (password != null) process.stdin.add(utf8.encode('$password\n'));
    unawaited(process.stdin.close().catchError((Object _) {}));
    final out = BytesBuilder(copy: false);
    final err = BytesBuilder(copy: false);
    try {
      await Future.wait([
        process.stdout.forEach(out.add),
        process.stderr.forEach(err.add),
      ]).timeout(
        const Duration(minutes: 1),
        onTimeout: () => throw const FileBrowserException(
          'sudo did not answer.',
          fault: FileBrowserFault.disconnected,
        ),
      );
    } finally {
      process.kill();
    }
    final code = await process.exitCode;
    if (code == 0) return out.takeBytes();
    throw SftpFileBrowser.sudoFailure(
      code,
      utf8.decode(err.takeBytes(), allowMalformed: true),
      action,
    );
  }

  @override
  Future<void> close() async {}

  static FileBrowserException _gone(String action) => FileBrowserException(
    'Could not $action: it is no longer there.',
    fault: FileBrowserFault.notFound,
  );

  Future<T> _guard<T>(String action, Future<T> Function() body) async {
    try {
      return await body();
    } on FileBrowserException {
      rethrow;
    } on FileSystemException catch (error) {
      throw _describe(action, error);
    }
  }

  /// errno on a Mac or Linux, Windows' own codes on its side.
  FileBrowserException _describe(String action, FileSystemException error) {
    final code = error.osError?.errorCode;
    final (notFound, denied, notEmpty, exists) = windows
        ? ({2, 3}, {5}, {145}, {80, 183})
        : ({2}, {1, 13}, {39, 66}, {17});
    if (error is PathNotFoundException || notFound.contains(code)) {
      return _gone(action);
    }
    if (denied.contains(code)) {
      return FileBrowserException(
        'Could not $action: permission denied.',
        fault: FileBrowserFault.permissionDenied,
      );
    }
    if (notEmpty.contains(code)) {
      return FileBrowserException(
        'Could not $action: the folder is not empty.',
        fault: FileBrowserFault.notEmpty,
      );
    }
    if (exists.contains(code)) {
      return FileBrowserException(
        'Could not $action: something by that name is already there.',
      );
    }
    return FileBrowserException(
      'Could not $action: ${error.osError?.message ?? error.message}',
    );
  }
}
