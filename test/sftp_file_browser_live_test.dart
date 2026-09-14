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
/// Opt-in, because it logs into a real host with a real private key, which no
/// test run should do unasked: it is skipped unless SSHBOX_LIVE_KEY names an
/// unencrypted key for the host. There is no default key, and nothing under
/// ~/.ssh is ever read on its own. The host is 127.0.0.1:22 as $USER unless
/// SSHBOX_LIVE_HOST, SSHBOX_LIVE_PORT and SSHBOX_LIVE_USER say otherwise:
///
///     SSHBOX_LIVE_KEY=/path/to/test_key flutter test test/sftp_file_browser_live_test.dart
///
/// It works in a folder of its own under the login's home, plus a file in
/// this machine's temp directory and one in the host's /tmp, and removes all
/// of them when it is done, failed or not.
String get _host => Platform.environment['SSHBOX_LIVE_HOST'] ?? '127.0.0.1';

int get _port =>
    int.tryParse(Platform.environment['SSHBOX_LIVE_PORT'] ?? '') ?? 22;

String get _user =>
    Platform.environment['SSHBOX_LIVE_USER'] ??
    Platform.environment['USER'] ??
    'root';

String? get _keyPath => Platform.environment['SSHBOX_LIVE_KEY'];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('reads, writes and rearranges files on a real host', () async {
    final pem = await File(_keyPath!).readAsString();
    // A passphrase is something this test has no business holding.
    expect(
      pem,
      isNot(contains('ENCRYPTED')),
      reason: 'SSHBOX_LIVE_KEY must name an unencrypted key',
    );

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

    final session = await Dartssh2Transport(
      confirmHostKey: (_) async => true,
    ).connect(
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
      final local = _host == '127.0.0.1' || _host == 'localhost';
      if (local) {
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

      // A file only root may touch: sudo has to get through both ways and
      // leave it root's own. Needs this machine to be the host, and a sudo
      // here that does not ask.
      if (local && (await Process.run('sudo', ['-n', 'true'])).exitCode == 0) {
        List<String> temps() => Directory('/tmp')
            .listSync()
            .map((entry) => entry.path)
            .where((path) => path.startsWith('/tmp/.sshbox-'))
            .toList();
        final tempsBefore = temps();

        final secret = RemotePath.join(root, 'rahasia.conf');
        await Process.run('sudo', [
          '-n',
          'sh',
          '-c',
          r'printf "a=1\n" > "$1" && chmod 600 "$1"',
          'sh',
          secret,
        ]);
        await expectLater(
          browser.readText(secret),
          throwsA(
            isA<FileBrowserException>().having(
              (error) => error.fault,
              'fault',
              FileBrowserFault.permissionDenied,
            ),
          ),
        );

        expect(browser, isA<SudoCapable>());
        final sudo = browser as SudoCapable;
        final before = await sudo.sudoReadText(secret);
        expect(before.text, 'a=1\n');

        // A different length, so the stale stamp below is told apart even
        // when both saves land inside the same second.
        await sudo.sudoWriteText(secret, 'a=22\n', expected: before.stamp);
        expect((await sudo.sudoReadText(secret)).text, 'a=22\n');
        final owner = await Process.run(
          'sudo',
          ['-n', 'stat', '-c', '%U %a', secret],
        );
        expect((owner.stdout as String).trim(), 'root 600');

        await expectLater(
          sudo.sudoWriteText(secret, 'a=3\n', expected: before.stamp),
          throwsA(
            isA<FileBrowserException>().having(
              (error) => error.fault,
              'fault',
              FileBrowserFault.changed,
            ),
          ),
        );
        expect(temps(), tempsBefore);
        await Process.run('sudo', ['-n', 'rm', '-f', secret]);
      }

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

      // Uploads: to a free name only, never through a link planted under it,
      // private, and a replace swapped in whole. The bytes come back as they
      // went, over the chunk size so the loop turns more than once.
      final phone = File('${Directory.systemTemp.path}/sshbox-live-phone-$pid')
        ..writeAsBytesSync(List.generate(300 * 1024, (i) => i % 251));
      final small = File('${phone.path}.kecil')..writeAsBytesSync([1, 2, 3]);
      String? tmp;
      // What the host holds, fetched back the way a download brings it.
      Future<List<int>> fetch(String remote) async {
        final copy = File('${phone.path}.balik');
        try {
          await browser.download(remote, copy.path);
          return copy.readAsBytesSync();
        } finally {
          if (copy.existsSync()) copy.deleteSync();
        }
      }

      try {
        final uploaded = RemotePath.join(root, 'unggah.bin');
        await browser.upload(phone.path, uploaded);
        expect(await fetch(uploaded), phone.readAsBytesSync());
        await expectLater(
          browser.upload(phone.path, uploaded),
          throwsA(isA<FileBrowserException>()),
        );

        await browser.upload(small.path, uploaded, replace: true);
        expect(await fetch(uploaded), [1, 2, 3]);

        // The key bar's upload to /tmp sends the same way.
        tmp = await (session as FileUploadCapable).uploadToTmp(
          localPath: phone.path,
          fileName: 'sshbox-live-tmp-$pid.bin',
        );
        expect(await fetch(tmp), phone.readAsBytesSync());

        if (local) {
          expect(File(uploaded).statSync().mode & 0x1ff, 0x180);
          // A link planted under the name is refused, and a replace swaps
          // the link for the file: what it points at is never written.
          final victim = File(RemotePath.join(root, 'korban.txt'))
            ..writeAsStringSync('asli');
          final trap = Link(RemotePath.join(root, 'jebakan.bin'))
            ..createSync(victim.path);
          await expectLater(
            browser.upload(phone.path, trap.path),
            throwsA(isA<FileBrowserException>()),
          );
          await browser.upload(phone.path, trap.path, replace: true);
          expect(FileSystemEntity.isLinkSync(trap.path), isFalse);
          expect(victim.readAsStringSync(), 'asli');
        }

        // No half-sent or swapped-out copy left beside them.
        expect(
          (await browser.list(root))
              .map((entry) => entry.name)
              .where((name) => name.contains('sshbox')),
          isEmpty,
        );
      } finally {
        phone.deleteSync();
        small.deleteSync();
        // Best effort, as for the folder below: a failed check above must not
        // leave the upload in the host's /tmp.
        if (tmp != null) await browser.delete(tmp).catchError((Object _) {});
      }

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
  },
      skip: _keyPath == null
          ? 'opt-in: set SSHBOX_LIVE_KEY to a key for a test host to run it'
          : false,
      timeout: const Timeout(Duration(seconds: 90)));
}
