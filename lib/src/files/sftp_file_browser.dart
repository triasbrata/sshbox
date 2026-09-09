import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import 'file_browser.dart';

/// A [FileBrowser] carried by the SSH session that is already open.
///
/// No second connection, no daemon to install, nothing listening on the host —
/// which is what makes it the right first implementation even though a daemon
/// would be faster. It is also the reason the interface is shaped the way it
/// is: everything here costs a round trip, so the UI was written to ask for
/// whole directories rather than entry-by-entry detail.
class SftpFileBrowser implements FileBrowser, FileSearchCapable {
  SftpFileBrowser(this._client);

  final SSHClient _client;

  /// One SFTP channel for the life of the page. Opening one per call is a
  /// round trip apiece on a link where round trips are the whole cost.
  Future<SftpClient>? _sftp;
  bool _closed = false;

  Future<SftpClient> _channel() {
    if (_closed) {
      throw const FileBrowserException(
        'The file browser was closed.',
        fault: FileBrowserFault.disconnected,
      );
    }
    return _sftp ??= _client.sftp();
  }

  @override
  Future<String> resolveHome() => _guard(
        'resolve the home directory',
        () async => (await _channel()).absolute('.'),
      );

  @override
  Future<List<RemoteEntry>> list(String path) => _guard(
        'list $path',
        () async {
          final sftp = await _channel();
          final names = await sftp.listdir(path);

          final entries = <RemoteEntry>[];
          for (final name in names) {
            // Every server sends these; nobody wants to see them as rows,
            // and "up" is the breadcrumb bar's job rather than a list entry's.
            if (name.filename == '.' || name.filename == '..') continue;
            entries.add(_toEntry(path, name));
          }

          await _resolveLinkTargets(sftp, entries);
          _sort(entries);
          return entries;
        },
      );

  /// `listdir` reports on the link itself, so a symlink to a directory would
  /// otherwise be untappable. One extra stat per link only — following every
  /// entry would double the cost of every listing for no gain.
  Future<void> _resolveLinkTargets(
    SftpClient sftp,
    List<RemoteEntry> entries,
  ) async {
    final links = <int>[
      for (var i = 0; i < entries.length; i++)
        if (entries[i].kind == RemoteEntryKind.symlink) i,
    ];
    if (links.isEmpty) return;

    final resolved = await Future.wait([
      for (final index in links)
        sftp
            .stat(entries[index].path)
            .then<bool?>((attrs) => attrs.isDirectory)
            // A broken link is a normal thing to find, not a failed listing.
            .catchError((Object _) => null),
    ]);

    for (var i = 0; i < links.length; i++) {
      final index = links[i];
      entries[index] = RemoteEntry(
        name: entries[index].name,
        path: entries[index].path,
        kind: RemoteEntryKind.symlink,
        size: entries[index].size,
        modified: entries[index].modified,
        targetIsDirectory: resolved[i],
      );
    }
  }

  static void _sort(List<RemoteEntry> entries) {
    entries.sort((a, b) {
      final aDir = a.kind == RemoteEntryKind.directory;
      final bDir = b.kind == RemoteEntryKind.directory;
      if (aDir != bDir) return aDir ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
  }

  static RemoteEntry _toEntry(String parent, SftpName name) {
    final attrs = name.attr;
    final kind = attrs.isDirectory
        ? RemoteEntryKind.directory
        : attrs.isSymbolicLink
            ? RemoteEntryKind.symlink
            : attrs.isFile
                ? RemoteEntryKind.file
                : RemoteEntryKind.other;

    return RemoteEntry(
      name: name.filename,
      path: RemotePath.join(parent, name.filename),
      kind: kind,
      size: kind == RemoteEntryKind.directory ? null : attrs.size,
      modified: attrs.modifyTime == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(attrs.modifyTime! * 1000),
    );
  }

  @override
  Future<String> readText(
    String path, {
    int maxBytes = FileBrowser.defaultReadLimit,
  }) =>
      _guard('open $path', () async {
        final sftp = await _channel();

        // Size first, so a mistaken tap on a database dump costs one stat
        // rather than pulling the whole thing down a phone connection.
        final attrs = await sftp.stat(path);
        if (attrs.isDirectory) {
          throw const FileBrowserException(
            'That is a directory, not a file.',
            fault: FileBrowserFault.notText,
          );
        }
        final size = attrs.size ?? 0;
        if (size > maxBytes) {
          throw FileBrowserException(
            '${_formatBytes(size)} is too large to open here. '
            'Use the terminal for a file this size.',
            fault: FileBrowserFault.tooLarge,
          );
        }

        final file = await sftp.open(path, mode: SftpFileOpenMode.read);
        try {
          final bytes = await file.readBytes();

          // A NUL byte is the same signal `grep -I` uses, and it is right far
          // more often than any charset guess would be.
          if (bytes.contains(0)) {
            throw const FileBrowserException(
              'This looks like a binary file.',
              fault: FileBrowserFault.notText,
            );
          }

          try {
            return utf8.decode(bytes);
          } on FormatException {
            // Decoding it loosely would show mojibake and then save that
            // mojibake back over the original, which is worse than refusing.
            throw const FileBrowserException(
              'This file is not UTF-8 text, so editing it here would corrupt it.',
              fault: FileBrowserFault.notText,
            );
          }
        } finally {
          await file.close();
        }
      });

  @override
  Future<void> writeText(String path, String content) =>
      _guard('save $path', () async {
        final sftp = await _channel();
        final file = await sftp.open(
          path,
          mode: SftpFileOpenMode.create |
              SftpFileOpenMode.write |
              SftpFileOpenMode.truncate,
        );
        try {
          await file.writeBytes(Uint8List.fromList(utf8.encode(content)));
        } finally {
          await file.close();
        }
      });

  @override
  Future<void> rename(String from, String to) => _guard(
        'rename ${RemotePath.basename(from)}',
        () async => (await _channel()).rename(from, to),
      );

  @override
  Future<void> makeDirectory(String path) => _guard(
        'create ${RemotePath.basename(path)}',
        () async => (await _channel()).mkdir(path),
      );

  @override
  Future<void> delete(String path, {bool recursive = false}) => _guard(
        'delete ${RemotePath.basename(path)}',
        () async {
          final sftp = await _channel();
          final attrs = await sftp.stat(path);
          if (!attrs.isDirectory) {
            await sftp.remove(path);
            return;
          }
          if (!recursive) {
            await sftp.rmdir(path);
            return;
          }
          await _deleteTree(sftp, path);
        },
      );

  /// Walks the tree in Dart rather than sending `rm -rf`.
  ///
  /// Keeping deletion inside SFTP means this class needs nothing but the file
  /// protocol — no shell, no quoting to get wrong, and the same behaviour on a
  /// host whose login shell is something exotic.
  Future<void> _deleteTree(SftpClient sftp, String path) async {
    final names = await sftp.listdir(path);
    for (final name in names) {
      if (name.filename == '.' || name.filename == '..') continue;
      final child = RemotePath.join(path, name.filename);
      // Not `stat`: following a link here would delete what it points at
      // rather than the link, which is never what "delete this folder" means.
      if (name.attr.isDirectory) {
        await _deleteTree(sftp, child);
      } else {
        await sftp.remove(child);
      }
    }
    await sftp.rmdir(path);
  }

  /// Content search by shelling out to `grep` on the session's own connection.
  ///
  /// Worth stating plainly: this is the weaker half of the promise. Results
  /// arrive as one process's output rather than as ranked, streaming hits, and
  /// a host without `grep` cannot do it at all. It is still a real
  /// implementation, and having two of different quality is what keeps
  /// [FileSearchCapable] honest as a capability rather than a formality.
  @override
  Stream<SearchHit> search({
    required String root,
    required String query,
  }) async* {
    if (query.isEmpty) return;

    // -F: the box in the UI is a search field, not a regex prompt, so a stray
    // `.` or `*` must not quietly change what was asked for.
    // -I: skip binaries. Their "matches" are noise a phone screen cannot use.
    final command = 'grep -rnIF --exclude-dir=.git '
        '-e ${_shellQuote(query)} -- ${_shellQuote(root)} 2>/dev/null';

    final SSHSession session;
    try {
      session = await _client.execute(command);
    } catch (error) {
      throw FileBrowserException(
        'Could not start a search on the host: $error',
        fault: FileBrowserFault.disconnected,
      );
    }

    var hits = 0;
    try {
      // `bind` rather than `transform`, matching the shell reader: one decoder
      // carries its state across chunks, so a rune split over two TCP reads
      // survives instead of turning into a replacement character.
      const decoder = Utf8Decoder(allowMalformed: true);
      final lines = const LineSplitter().bind(decoder.bind(session.stdout));

      await for (final line in lines) {
        final hit = _parseGrepLine(line);
        if (hit == null) continue;
        yield hit;
        // A phone cannot use more than this, and an unbounded search over a
        // home directory will happily produce tens of thousands.
        if (++hits >= _searchHitLimit) return;
      }

      final exitCode = await session.waitForExit(
        timeout: const Duration(seconds: 5),
      );
      // grep exits 1 for "no matches", which is a result and not a failure.
      // 127 is the shell saying grep is not there at all.
      if (hits == 0 && exitCode != null && exitCode > 1) {
        throw FileBrowserException(
          exitCode == 127
              ? 'This host has no grep, so search is not available over SFTP.'
              : 'Search failed on the host (exit $exitCode).',
          fault: exitCode == 127
              ? FileBrowserFault.unsupported
              : FileBrowserFault.unknown,
        );
      }
    } finally {
      // Reached on cancellation too, which is what stops a runaway grep when
      // the user closes the search page.
      //
      // Closing the channel rather than signalling: sshd hangs up the process
      // when the channel goes, whereas the SSH "signal" request is one OpenSSH
      // does not implement. Sending it also leaves a request waiting for a
      // reply that the closing channel then fails, and that failure arrives
      // with nothing to catch it.
      session.close();
    }
  }

  static const _searchHitLimit = 500;

  /// `path:line:text`, with the path allowed to contain colons of its own —
  /// the digits between the two colons are what actually anchors the split.
  static final _grepLine = RegExp(r'^(.*?):(\d+):(.*)$');

  static SearchHit? _parseGrepLine(String line) {
    final match = _grepLine.firstMatch(line);
    if (match == null) return null;
    final number = int.tryParse(match.group(2)!);
    if (number == null) return null;
    return SearchHit(
      path: match.group(1)!,
      line: number,
      // Long minified lines would otherwise drag the whole list wide.
      preview: match.group(3)!.trim(),
    );
  }

  /// Wraps [value] so the remote shell sees exactly these bytes.
  ///
  /// Single quotes suspend every expansion the shell does; the dance in the
  /// middle is how a single quote itself gets through. Without this a search
  /// for `$(rm -rf ~)` would be a command, not a search.
  static String _shellQuote(String value) =>
      "'${value.replaceAll("'", r"'\''")}'";

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final sftp = _sftp;
    _sftp = null;
    if (sftp == null) return;
    try {
      (await sftp).close();
    } catch (_) {
      // Closing a channel whose connection already went away is not a failure
      // worth surfacing — the page is on its way out either way.
    }
  }

  /// Turns whatever SFTP threw into the one error type the UI knows.
  ///
  /// [action] completes the sentence "Could not …", so the message says which
  /// operation failed even when the server's own text does not.
  Future<T> _guard<T>(String action, Future<T> Function() body) async {
    try {
      return await body();
    } on FileBrowserException {
      rethrow;
    } catch (error) {
      throw _describe(action, error);
    }
  }

  static FileBrowserException _describe(String action, Object error) {
    if (error is SftpStatusError) {
      switch (error.code) {
        case 2:
          return FileBrowserException(
            'Could not $action: it is no longer there.',
            fault: FileBrowserFault.notFound,
          );
        case 3:
          return FileBrowserException(
            'Could not $action: permission denied.',
            fault: FileBrowserFault.permissionDenied,
          );
        case 4:
          // The catch-all code, which servers also use for "directory not
          // empty" — the one case a user can actually do something about.
          return FileBrowserException(
            'Could not $action: ${error.message}',
            fault: FileBrowserFault.notEmpty,
          );
        case 6:
        case 7:
          return const FileBrowserException(
            'The connection to the host was lost.',
            fault: FileBrowserFault.disconnected,
          );
        case 8:
          return FileBrowserException(
            'Could not $action: the server does not support it.',
            fault: FileBrowserFault.unsupported,
          );
      }
      return FileBrowserException('Could not $action: ${error.message}');
    }
    if (error is SftpError) {
      return FileBrowserException('Could not $action: ${error.message}');
    }
    if (error is SSHChannelOpenError || error is SSHStateError) {
      return const FileBrowserException(
        'The connection to the host was lost.',
        fault: FileBrowserFault.disconnected,
      );
    }
    return FileBrowserException('Could not $action: $error');
  }

  static String _formatBytes(int bytes) {
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    final rounded = unit == 0 || value >= 100
        ? value.toStringAsFixed(0)
        : value.toStringAsFixed(1);
    return '$rounded ${units[unit]}';
  }
}
