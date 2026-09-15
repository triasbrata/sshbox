import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
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
class SftpFileBrowser implements FileBrowser, FileSearchCapable, SudoCapable {
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

  @override
  Future<RemoteEntryKind?> stat(String path) => _guard(
        'look at $path',
        () async {
          final attrs = await _statOrNull(await _channel(), path);
          if (attrs == null) return null;
          return attrs.isDirectory
              ? RemoteEntryKind.directory
              : attrs.isFile
                  ? RemoteEntryKind.file
                  : RemoteEntryKind.other;
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
      modified: _stampOf(attrs).modified,
    );
  }

  static FileStamp _stampOf(SftpFileAttrs attrs) => (
        modified: attrs.modifyTime == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(attrs.modifyTime! * 1000),
        size: attrs.size,
      );

  /// null when there is nothing at [path]; any other failure still throws.
  static Future<SftpFileAttrs?> _statOrNull(
    SftpClient sftp,
    String path, {
    bool followLink = true,
  }) async {
    try {
      return await sftp.stat(path, followLink: followLink);
    } on SftpStatusError catch (error) {
      if (error.code == 2) return null;
      rethrow;
    }
  }

  static Future<void> _removeQuietly(SftpClient sftp, String path) async {
    try {
      await sftp.remove(path);
    } catch (_) {
      // Leftover temp files are hidden and removed by the next save.
    }
  }

  @override
  Future<RemoteText> readText(
    String path, {
    int maxBytes = FileBrowser.defaultReadLimit,
  }) =>
      _guard('open $path', () async {
        final sftp = await _channel();

        // Size first, so a mistaken tap on a database dump costs one stat
        // rather than pulling the whole thing down a phone connection.
        final attrs = await sftp.stat(path);
        _checkOpenable(attrs, maxBytes);

        final file = await sftp.open(path, mode: SftpFileOpenMode.read);
        try {
          final bytes = await file.readBytes();
          return (text: _decodeText(bytes), stamp: _stampOf(attrs));
        } finally {
          await file.close();
        }
      });

  static void _checkOpenable(SftpFileAttrs attrs, int maxBytes) {
    if (attrs.isDirectory) {
      throw const FileBrowserException(
        'That is a directory, not a file.',
        fault: FileBrowserFault.notText,
      );
    }
    final size = attrs.size ?? 0;
    if (size > maxBytes) {
      throw FileBrowserException(
        '${formatBytes(size)} is too large to open here. '
        'Use the terminal for a file this size.',
        fault: FileBrowserFault.tooLarge,
      );
    }
  }

  static String _decodeText(Uint8List bytes) {
    // A NUL byte is the same signal `grep -I` uses, and it is right far more
    // often than any charset guess would be.
    if (bytes.contains(0)) {
      throw const FileBrowserException(
        'This looks like a binary file.',
        fault: FileBrowserFault.notText,
      );
    }

    try {
      return utf8.decode(bytes);
    } on FormatException {
      // Decoding it loosely would show mojibake and then save that mojibake
      // back over the original, which is worse than refusing.
      throw const FileBrowserException(
        'This file is not UTF-8 text, so editing it here would corrupt it.',
        fault: FileBrowserFault.notText,
      );
    }
  }

  static void _checkUnchanged(
    String path,
    SftpFileAttrs? current,
    FileStamp? expected,
  ) {
    if (expected == null) return;
    if (current != null && _stampOf(current) == expected) return;
    throw FileBrowserException(
      '${RemotePath.basename(path)} changed on the host since it was opened.',
      fault: FileBrowserFault.changed,
    );
  }

  @override
  Future<FileStamp> writeText(
    String path,
    String content, {
    FileStamp? expected,
  }) =>
      _guard('save $path', () async {
        final sftp = await _channel();
        final bytes = Uint8List.fromList(utf8.encode(content));

        var target = path;
        var current = await _statOrNull(sftp, path, followLink: false);
        var replaceable = true;
        if (current != null && current.isSymbolicLink) {
          // Saving through a link rewrites what it points at. Renaming over
          // the link itself would swap it for a plain file.
          target = await sftp.absolute(path).catchError((Object _) => path);
          current = await _statOrNull(sftp, target);
          // A server that will not resolve it leaves the in-place write, which
          // the host follows through the link on its own.
          replaceable = target != path;
        }

        _checkUnchanged(path, current, expected);

        final replaced = current != null &&
            replaceable &&
            await _replace(sftp, target, bytes, current);
        if (!replaced) await _writeInPlace(sftp, target, bytes);
        return _stampOf(await sftp.stat(target));
      });

  /// Writes [bytes] beside [target] and renames them over it, so a connection
  /// that drops mid-save leaves the old file whole rather than half-written.
  ///
  /// Returns false, with [target] untouched, whenever the swap would not come
  /// out the same as writing in place: a directory we cannot add to, a file
  /// we do not own (the rename would hand it to us), or a server without
  /// `posix-rename`, whose plain rename refuses to replace a file.
  ///
  /// ponytail: a rename splits hard links, and SFTP v3 attributes carry no
  /// link count to spot them by. A daemon can check st_nlink first.
  Future<bool> _replace(
    SftpClient sftp,
    String target,
    Uint8List bytes,
    SftpFileAttrs current,
  ) async {
    final temp = RemotePath.join(
      RemotePath.parent(target),
      '.${RemotePath.basename(target)}.sshbox-save',
    );

    // Exclusive: where others can write to the directory, a link planted
    // under this name would aim the write at a file of their choosing. A
    // copy left by a save that died goes first; a name still taken after
    // that, by someone else's file, means writing in place instead.
    await _removeQuietly(sftp, temp);
    final SftpFile file;
    try {
      file = await sftp.open(
        temp,
        mode: SftpFileOpenMode.create |
            SftpFileOpenMode.exclusive |
            SftpFileOpenMode.write,
      );
    } on SftpStatusError catch (error) {
      // 3: not ours to add to. 4: SFTP v3's word for the name being taken.
      if (error.code == 3 || error.code == 4) return false;
      rethrow;
    }

    try {
      final made = await file.stat();
      if (made.userID != current.userID || made.groupID != current.groupID) {
        await file.close();
        await _removeQuietly(sftp, temp);
        return false;
      }
      // Before the bytes go in, so a private file is never readable as temp.
      await file.setStat(SftpFileAttrs(mode: current.mode));
      await file.writeBytes(bytes);
      await file.close();
    } catch (_) {
      // Not falling back here: an in-place write truncates first, and the
      // same failure (a full disk, say) would then take the original too.
      if (!file.isClosed) await file.close().catchError((Object _) {});
      await _removeQuietly(sftp, temp);
      rethrow;
    }

    try {
      await sftp.rename(temp, target);
    } on SftpStatusError {
      await _removeQuietly(sftp, temp);
      return false;
    }
    return true;
  }

  static Future<void> _writeInPlace(
    SftpClient sftp,
    String path,
    Uint8List bytes,
  ) async {
    final file = await sftp.open(
      path,
      mode: SftpFileOpenMode.create |
          SftpFileOpenMode.write |
          SftpFileOpenMode.truncate,
    );
    try {
      await file.writeBytes(bytes);
    } finally {
      await file.close();
    }
  }

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
  Future<void> upload(
    String localPath,
    String path, {
    bool replace = false,
    void Function(int sent, int total)? onProgress,
    Future<void>? cancel,
  }) =>
      _guard(
        'upload ${RemotePath.basename(path)} to ${RemotePath.parent(path)}',
        () async {
          final sftp = await _channel();
          // Straight to the name when it is free: exclusive, so a name taken
          // since it was looked at, by a file or by a link planted there,
          // fails the upload rather than being written over or through. A
          // replace goes in beside it and is renamed over it, which swaps a
          // link for the file rather than following it, and leaves the old
          // file whole until the new one is.
          final target = replace
              ? RemotePath.join(
                  RemotePath.parent(path),
                  '.${RemotePath.basename(path)}.${randomName()}'
                  '.sshbox-upload',
                )
              : path;
          final file = await sftp.open(
            target,
            mode: SftpFileOpenMode.create |
                SftpFileOpenMode.exclusive |
                SftpFileOpenMode.write,
          );
          try {
            await sendFile(
              file,
              localPath,
              onProgress: onProgress,
              cancel: cancel,
            );
            if (replace) {
              try {
                await sftp.rename(target, path);
              } on SftpStatusError {
                // No posix-rename on this server, and a plain rename will not
                // land on a name that is taken: the old file goes first.
                await sftp.remove(path);
                await sftp.rename(target, path);
              }
            }
          } catch (_) {
            // Ours, made just now: half a file is no use to anyone.
            await _removeQuietly(sftp, target);
            rethrow;
          }
        },
      );

  /// Fills [remote], a file of ours just made by an exclusive open, from the
  /// phone's file at [localPath], then closes it. [cancel] completing stops
  /// it with [FileBrowserException.cancelled].
  ///
  /// Private (0600) before any byte goes in: whatever is left readable there,
  /// every login that can see the directory can read. The one way a file
  /// goes up: the key bar's upload to /tmp and the tree's both end here.
  ///
  /// Streamed, never the whole file in memory: the phone's file is read
  /// 64 KB at a time, each read an event-loop turn of its own, so what is
  /// sealed on the UI isolate between two frames is one read's worth. 16
  /// writes wait on the host at most, which keeps a link 30 ms away busy,
  /// where 256 KB handed over at a time and each waited out left it idle in
  /// between: see tool/transfer_bench.dart.
  static Future<void> sendFile(
    SftpFile remote,
    String localPath, {
    void Function(int sent, int total)? onProgress,
    Future<void>? cancel,
  }) async {
    try {
      await remote.setStat(
        SftpFileAttrs(mode: const SftpFileMode.value(0x180)),
      );
      final source = File(localPath);
      final total = await source.length();
      final writer = remote.write(
        source.openRead().cast<Uint8List>(),
        onProgress: (sent) => onProgress?.call(sent, total),
        // One SSH packet each, headers and all, in the 32 KB a host takes.
        chunkSize: 32 * 1024 - 64,
        maxPendingRequests: 16,
      );
      var stopped = false;
      unawaited(
        cancel?.then((_) {
          stopped = true;
          return writer.abort();
        }),
      );
      await writer.done;
      if (stopped) throw FileBrowserException.cancelled;
    } finally {
      await remote.close();
    }
  }

  @override
  Future<void> download(
    String path,
    String localPath, {
    void Function(int received, int total)? onProgress,
    Future<void>? cancel,
  }) =>
      _guard('download ${RemotePath.basename(path)}', () async {
        final sftp = await _channel();
        final size = (await sftp.stat(path)).size ?? 0;
        final file = await sftp.open(path);
        final local = File(localPath).openWrite();
        var stopped = false;
        unawaited(cancel?.then((_) => stopped = true));
        try {
          // Half a megabyte in flight keeps a link 30 ms away busy, where a
          // quarter of it halves the speed. Every reply is decrypted on the
          // UI isolate, dartssh2 being pure Dart, and the paced socket in
          // dartssh2_transport.dart hands it over a packet at a time, so the
          // frames keep coming however much of it lands at once.
          var received = 0;
          await for (final chunk in file.read(
            chunkSize: 32 * 1024,
            maxPendingRequests: 16,
          )) {
            if (stopped) throw FileBrowserException.cancelled;
            local.add(chunk);
            onProgress?.call(received += chunk.length, size);
            // Written out every 2 MB: a disk slower than the link holds no
            // more than that in memory.
            if (received % (2 * 1024 * 1024) < chunk.length) {
              await local.flush();
            }
          }
        } finally {
          await local.close();
          await file.close();
        }
      });

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

  /// Where the login may not even stat the file there is no stamp to compare,
  /// so saves skip the check rather than fail every time.
  static const FileStamp _unknownStamp = (modified: null, size: null);

  /// What stat says about [path]: null attrs when nothing is there, and
  /// `refused` when the login may not look — common for the files sudo is
  /// for, under directories only root can enter.
  static Future<({SftpFileAttrs? attrs, bool refused})> _lookAt(
    SftpClient sftp,
    String path,
  ) async {
    try {
      return (attrs: await sftp.stat(path), refused: false);
    } on SftpStatusError catch (error) {
      if (error.code == 2) return (attrs: null, refused: false);
      if (error.code == 3) return (attrs: null, refused: true);
      rethrow;
    }
  }

  @override
  Future<RemoteText> sudoReadText(
    String path, {
    String? password,
    int maxBytes = FileBrowser.defaultReadLimit,
  }) =>
      _guard('open $path', () async {
        final sftp = await _channel();
        final look = await _lookAt(sftp, path);
        final attrs = look.attrs;
        if (attrs == null && !look.refused) {
          throw FileBrowserException(
            'Could not open $path: it is no longer there.',
            fault: FileBrowserFault.notFound,
          );
        }
        if (attrs != null) _checkOpenable(attrs, maxBytes);

        // One byte past the limit is enough to know, where stat could not say.
        final bytes = await _sudo(
          'head -c ${maxBytes + 1} -- ${_shellQuote(path)}',
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
          text: _decodeText(bytes),
          stamp: attrs == null ? _unknownStamp : _stampOf(attrs),
        );
      });

  @override
  Future<FileStamp> sudoWriteText(
    String path,
    String content, {
    String? password,
    FileStamp? expected,
  }) =>
      _guard('save $path', () async {
        final sftp = await _channel();
        final look = await _lookAt(sftp, path);
        if (!look.refused) _checkUnchanged(path, look.attrs, expected);

        // The bytes cross the network into a file of our own first, and only
        // then does root copy them over the original, on the host itself. A
        // dropped connection can cut the upload short, never the original.
        //
        // Not `sudo tee` fed on stdin: where sudo does not ask for a password
        // (NOPASSWD, or credentials it still remembers) the password line
        // would land in the file along with the rest.
        //
        // Exclusive, under a name nobody can guess: /tmp is shared, and a
        // link planted there under a known name would aim this write
        // somewhere else.
        final temp = '/tmp/.sshbox-${randomName()}';
        final file = await sftp.open(
          temp,
          mode: SftpFileOpenMode.create |
              SftpFileOpenMode.exclusive |
              SftpFileOpenMode.write,
        );
        try {
          try {
            // 0600, before the bytes go in: /tmp is readable by everyone.
            await file.setStat(
              SftpFileAttrs(mode: const SftpFileMode.value(0x180)),
            );
            await file.writeBytes(Uint8List.fromList(utf8.encode(content)));
          } finally {
            await file.close();
          }
          // cp into an existing file writes through it: owner, permissions
          // and inode stay the file's own, and a symlink stays a link.
          await _sudo(
            'cp -- ${_shellQuote(temp)} ${_shellQuote(path)}',
            password,
            'save $path',
          );
        } finally {
          await _removeQuietly(sftp, temp);
        }

        final attrs = (await _lookAt(sftp, path)).attrs;
        return attrs == null ? _unknownStamp : _stampOf(attrs);
      });

  static final _random = Random.secure();

  /// Sixteen characters nobody can guess, for a file of ours in a directory
  /// others can write to.
  static String randomName() =>
      List.generate(16, (_) => _random.nextInt(36).toRadixString(36)).join();

  /// Runs [command] as root on the session's own connection and returns what
  /// it printed.
  ///
  /// The password goes in on stdin, never onto the command line where `ps`
  /// would show it to every other login on the host. Stdin closes right
  /// behind it, so a wrong password fails at once instead of leaving sudo
  /// waiting for another try.
  Future<Uint8List> _sudo(
    String command,
    String? password,
    String action,
  ) async {
    // -n: with no password to give, fail rather than ask. LC_ALL=C: sudo's
    // refusals are read below, and a translated one would not be recognised.
    final sudo = password == null ? 'sudo -n' : "sudo -S -p ''";
    final SSHSession session;
    try {
      session = await _client.execute('env LC_ALL=C $sudo $command');
    } catch (error) {
      throw FileBrowserException(
        'Could not start sudo on the host: $error',
        fault: FileBrowserFault.disconnected,
      );
    }

    try {
      if (password != null) session.stdin.add(utf8.encode('$password\n'));
      unawaited(session.stdin.close());

      final out = BytesBuilder(copy: false);
      final err = BytesBuilder(copy: false);
      // A sudo waiting on something no phone can give it (a hardware key, a
      // second factor) would otherwise hold the editor's spinner forever.
      await Future.wait([
        session.stdout.forEach(out.add),
        session.stderr.forEach(err.add),
      ]).timeout(
        const Duration(minutes: 1),
        onTimeout: () => throw const FileBrowserException(
          'sudo on the host did not answer.',
          fault: FileBrowserFault.disconnected,
        ),
      );
      final code = await session.waitForExit(
        timeout: const Duration(seconds: 5),
      );
      if (code == 0) return out.takeBytes();
      throw _sudoFailure(
        code,
        utf8.decode(err.takeBytes(), allowMalformed: true),
        action,
      );
    } finally {
      session.channel.destroy();
    }
  }

  /// What went wrong under sudo, as faults the editor can act on. Every
  /// refusal by sudo itself is [FileBrowserFault.permissionDenied]: each is
  /// answered the same way, by asking for a password or saying why not.
  static FileBrowserException _sudoFailure(
    int? code,
    String stderr,
    String action,
  ) {
    final said = stderr.trim();
    if (code == 127) {
      return const FileBrowserException(
        'This host has no sudo.',
        fault: FileBrowserFault.unsupported,
      );
    }
    if (said.contains('password is required')) {
      return const FileBrowserException(
        'sudo needs your password.',
        fault: FileBrowserFault.permissionDenied,
      );
    }
    if (said.contains('incorrect password') ||
        said.contains('try again') ||
        said.contains('no password was provided')) {
      return const FileBrowserException(
        'sudo did not accept that password.',
        fault: FileBrowserFault.permissionDenied,
      );
    }
    if (said.contains('sudoers') || said.contains('may not run sudo')) {
      return const FileBrowserException(
        'This login is not allowed to use sudo here.',
        fault: FileBrowserFault.permissionDenied,
      );
    }
    if (said.contains('No such file')) {
      return FileBrowserException(
        'Could not $action: it is no longer there.',
        fault: FileBrowserFault.notFound,
      );
    }
    // What the command itself said last is the part worth reading.
    final last = said.split('\n').last.trim();
    return FileBrowserException(
      'Could not $action as root: ${last.isEmpty ? 'exit $code' : last}',
    );
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
      //
      // `destroy` rather than `close`, which in dartssh2 only sends EOF and
      // waits for the far end to finish — and grep reads no stdin, so it would
      // run the whole tree anyway, sending every hit to be thrown away.
      session.channel.destroy();
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
}
