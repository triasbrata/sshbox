import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sshbox/src/data/secret_store.dart';
import 'package:sshbox/src/files/file_browser.dart';
import 'package:sshbox/src/models/host_profile.dart';
import 'package:sshbox/src/session/dartssh2_transport.dart';
import 'package:sshbox/src/session/terminal_session.dart';

/// Moves real bytes to a real sshd and reads them back.
///
/// This is the one thing that had never actually been proven: that a file
/// written through the adapter arrives intact, byte for byte, multi-byte
/// characters and all. Every page in the browser rests on that, so it is worth
/// a test that needs a server to run.
///
/// Skips itself unless there is an sshd on the configured host and an
/// unencrypted key that can log into it, so it stays harmless on a machine or
/// CI runner without either. Override the defaults with SSHBOX_LIVE_HOST,
/// SSHBOX_LIVE_PORT, SSHBOX_LIVE_USER and SSHBOX_LIVE_KEY.
String get _host => Platform.environment['SSHBOX_LIVE_HOST'] ?? '127.0.0.1';

int get _port =>
    int.tryParse(Platform.environment['SSHBOX_LIVE_PORT'] ?? '') ?? 22;

String get _user =>
    Platform.environment['SSHBOX_LIVE_USER'] ??
    Platform.environment['USER'] ??
    'root';

String get _keyPath =>
    Platform.environment['SSHBOX_LIVE_KEY'] ??
    '${Platform.environment['HOME']}/.ssh/id_rsa';

Future<String?> _readUsableKey() async {
  final file = File(_keyPath);
  if (!file.existsSync()) return null;
  final pem = await file.readAsString();
  // An encrypted key would need a passphrase this test has no business
  // holding, so treat it the same as no key at all.
  if (pem.contains('ENCRYPTED')) return null;
  return pem;
}

Future<bool> _sshdReachable() async {
  try {
    final socket = await Socket.connect(
      _host,
      _port,
      timeout: const Duration(seconds: 2),
    );
    socket.destroy();
    return true;
  } on Exception {
    return false;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('reads, writes and rearranges files on a real host', () async {
    if (!await _sshdReachable()) {
      printOnFailure('skipped: nothing listening on $_host:$_port');
      return;
    }
    final pem = await _readUsableKey();
    if (pem == null) {
      printOnFailure('skipped: no usable private key at $_keyPath');
      return;
    }

    SharedPreferences.setMockInitialValues({});

    const hostId = 'sftp-live-test';
    final host = HostProfile(
      id: hostId,
      label: 'live sshd',
      host: _host,
      port: _port,
      username: _user,
      authMethod: SshAuthMethod.privateKey,
    );

    final secrets = InMemorySecretStore();
    await secrets.write(SecretKeys.privateKey(hostId), pem);

    final session = await Dartssh2Transport().connect(
      host: host,
      secrets: secrets,
      columns: 80,
      rows: 24,
    );

    // The capability probe is the contract the UI relies on, so exercise that
    // rather than reaching for the implementation directly.
    expect(session, isA<FileBrowseCapable>());
    final browser = (session as FileBrowseCapable).openFileBrowser();

    // Somewhere of our own, removed at the end, so a failing run cannot
    // scribble on anything the developer cares about.
    final home = await browser.resolveHome();
    final root = RemotePath.join(home, '.sshbox-live-test-$pid');

    try {
      expect(home, startsWith('/'));

      await browser.makeDirectory(root);

      // Deliberately not ASCII. A transport that chunks bytes without keeping
      // decoder state corrupts exactly this, and only this.
      const content = 'halo dunia — ✓\nbaris kedua\nselesai\n';
      final file = RemotePath.join(root, 'catatan.txt');
      await browser.writeText(file, content);

      final listing = await browser.list(root);
      expect(listing, hasLength(1));
      expect(listing.single.name, 'catatan.txt');
      expect(listing.single.kind, RemoteEntryKind.file);
      expect(listing.single.path, file);
      // The server's own count of what arrived, not ours.
      expect(listing.single.size, utf8.encode(content).length);

      // The claim the whole browser rests on: what comes back is what went out.
      final read = await browser.readText(file);
      expect(read.text, content);

      // A save that finds someone else's version on the host must not write.
      await browser.writeText(file, '${content}theirs\n');
      await expectLater(
        browser.writeText(file, 'mine\n', expected: read.stamp),
        throwsA(
          isA<FileBrowserException>().having(
            (error) => error.fault,
            'fault',
            FileBrowserFault.changed,
          ),
        ),
      );
      expect((await browser.readText(file)).text, '${content}theirs\n');

      // A save is a swap, and the swap must keep what the old file was:
      // its permissions, and a link staying a link. Only checkable when the
      // host's filesystem is this machine's.
      if (_host == '127.0.0.1' || _host == 'localhost') {
        final local = File(file);
        await Process.run('chmod', ['600', file]);
        final link = Link(RemotePath.join(root, 'tautan.txt'))
          ..createSync(file);

        final stamp = await browser.writeText(link.path, content);
        expect(link.existsSync(), isTrue);
        expect(FileSystemEntity.isLinkSync(link.path), isTrue);
        expect(local.readAsStringSync(), content);
        expect(local.statSync().mode & 0x1ff, 0x180);
        expect(stamp.size, utf8.encode(content).length);
        link.deleteSync();
      } else {
        await browser.writeText(file, content);
      }

      // No temp file left beside it once the swap is done.
      expect(
        (await browser.list(root)).map((entry) => entry.name),
        ['catatan.txt'],
      );

      final renamed = RemotePath.join(root, 'catatan-lama.txt');
      await browser.rename(file, renamed);
      final afterRename = await browser.list(root);
      expect(afterRename.single.name, 'catatan-lama.txt');

      // Search is optional, so ask before assuming — the same probe the UI
      // uses to decide whether to offer the button at all.
      expect(browser, isA<FileSearchCapable>());
      final hits = await (browser as FileSearchCapable)
          .search(root: root, query: 'baris kedua')
          .toList();
      expect(hits, hasLength(1));
      expect(hits.single.path, renamed);
      expect(hits.single.line, 2);
      expect(hits.single.preview, 'baris kedua');

      // A NUL byte is what marks a file unopenable, and refusing is the point:
      // decoding it loosely would show mojibake and then save that back.
      final binary = RemotePath.join(root, 'biner.bin');
      await browser.writeText(binary, 'abc\u0000def');
      await expectLater(
        browser.readText(binary),
        throwsA(
          isA<FileBrowserException>().having(
            (error) => error.fault,
            'fault',
            FileBrowserFault.notText,
          ),
        ),
      );

      // Deleting a directory with things in it has to fail loudly rather than
      // quietly taking the contents with it.
      await expectLater(
        browser.delete(root),
        throwsA(isA<FileBrowserException>()),
      );

      await expectLater(
        browser.readText(RemotePath.join(root, 'tidak-ada.txt')),
        throwsA(
          isA<FileBrowserException>().having(
            (error) => error.fault,
            'fault',
            FileBrowserFault.notFound,
          ),
        ),
      );

      await browser.delete(root, recursive: true);
      final remaining = await browser.list(home);
      expect(
        remaining.where((entry) => entry.path == root),
        isEmpty,
        reason: 'the recursive delete should have removed the test directory',
      );
    } finally {
      // Best effort: a failed assertion above must not leave the directory
      // behind for the next run to trip over.
      try {
        await browser.delete(root, recursive: true);
      } catch (_) {}
      await browser.close();
      await session.dispose();
    }
  }, timeout: const Timeout(Duration(seconds: 90)));
}
