import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sshbox/src/data/host_repository.dart';
import 'package:sshbox/src/data/secret_store.dart';
import 'package:sshbox/src/models/host_profile.dart';
import 'package:sshbox/src/notifications/notify_key.dart';
import 'package:sshbox/src/ui/host_edit_page.dart';
import 'package:toastification/toastification.dart';

import 'fake_relay.dart';

const _openSshKey = '-----BEGIN OPENSSH PRIVATE KEY-----\n'
    'b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAAB\n'
    '-----END OPENSSH PRIVATE KEY-----\n';

const _publicKey = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFake me@box\n';

/// A picker that hands over [next] without asking anyone.
class _FakePicker extends FilePickerPlatform {
  PlatformFile? next;

  /// How many times the plugin's cached copies were cleared.
  var cleared = 0;

  @override
  Future<PlatformFile?> pickFile({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async => next;

  @override
  Future<void> clearTemporaryFiles() async {
    cleared++;
  }
}

/// A picked file, read from memory.
final class _PickedFile extends PlatformFile {
  _PickedFile(this.name, String text) : _bytes = utf8.encode(text);

  @override
  final String name;
  final Uint8List _bytes;

  @override
  Uri get uri => Uri.file('/data/cache/file_picker/1/$name');

  @override
  get xFile => throw UnimplementedError();

  @override
  int? lengthSync() => _bytes.length;

  @override
  Future<int> length() async => _bytes.length;

  @override
  Future<Uint8List> readAsBytes() async => _bytes;

  @override
  Stream<Uint8List> readAsByteStream() => Stream.value(_bytes);
}

/// Opens the edit page of a host that signs in with a key, tall enough to
/// show all of it.
Future<void> _openKeyHost(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  await tester.binding.setSurfaceSize(const Size(800, 2000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final secrets = InMemorySecretStore();
  await tester.pumpWidget(
    ToastificationWrapper(
      child: MaterialApp(
        home: HostEditPage(
          repository: HostRepository(secrets),
          secrets: secrets,
          existing: const HostProfile(
            id: 'box',
            label: 'box',
            host: '10.0.0.5',
            username: 'me',
            authMethod: SshAuthMethod.privateKey,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

TextField _field(WidgetTester tester, String label) =>
    tester.widget<TextField>(find.widgetWithText(TextField, label));

void main() {
  testWidgets('picks a saved host to jump through, and saves it with the '
      'alternative address', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final secrets = InMemorySecretStore();
    final repository = HostRepository(secrets);
    const box = HostProfile(
      id: 'box',
      label: 'box',
      host: '10.0.0.5',
      username: 'me',
      jumpHostId: 'deleted-since',
    );
    await repository.upsert(
      const HostProfile(
        id: 'gw',
        label: 'office gw',
        host: 'gw.example',
        username: 'me',
      ),
    );
    await repository.upsert(box);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<HostProfile>(
                builder: (_) => HostEditPage(
                  repository: repository,
                  secrets: secrets,
                  existing: box,
                ),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // A jump host deleted since is no jump host, and the host itself is not
    // offered.
    await tester.tap(find.text('None, connect directly'));
    await tester.pumpAndSettle();
    expect(find.text('box'), findsOneWidget);
    await tester.tap(find.text('office gw').last);
    await tester.pumpAndSettle();

    // The LAN address of the same machine, for when the tailnet is down.
    await tester.enterText(
      find.widgetWithText(TextField, 'Alternative address'),
      ' 192.168.1.20 ',
    );

    await tester.tap(find.byTooltip('Save'));
    await tester.pumpAndSettle();
    final saved = (await repository.load()).firstWhere((h) => h.id == 'box');
    expect(saved.jumpHostId, 'gw');
    expect(saved.altHost, '192.168.1.20');
  });

  testWidgets('the passphrase is masked until its eye shows it, and the '
      'keyboard learns it neither way', (tester) async {
    await _openKeyHost(tester);

    void expectUnlearned() {
      final field = _field(tester, 'Key passphrase');
      expect(field.enableSuggestions, isFalse);
      expect(field.autocorrect, isFalse);
      expect(field.enableIMEPersonalizedLearning, isFalse);
    }

    expect(_field(tester, 'Key passphrase').obscureText, isTrue);
    expectUnlearned();

    await tester.tap(find.byTooltip('Show passphrase'));
    await tester.pump();
    expect(_field(tester, 'Key passphrase').obscureText, isFalse);
    expectUnlearned();

    await tester.tap(find.byTooltip('Hide passphrase'));
    await tester.pump();
    expect(_field(tester, 'Key passphrase').obscureText, isTrue);
  });

  testWidgets('a picked key file fills the key field; a public key does not, '
      'and the picker\'s copies are cleared either way', (tester) async {
    final picker = _FakePicker();
    final real = FilePickerPlatform.instance;
    FilePickerPlatform.instance = picker;
    addTearDown(() => FilePickerPlatform.instance = real);
    await _openKeyHost(tester);
    String key() =>
        _field(tester, 'Private key (OpenSSH or PEM)').controller!.text;

    picker.next = _PickedFile('id_ed25519', _openSshKey);
    await tester.tap(find.text('Choose file'));
    await tester.pumpAndSettle();
    expect(key(), _openSshKey);
    expect(picker.cleared, 1);

    picker.next = _PickedFile('id_ed25519.pub', _publicKey);
    await tester.tap(find.text('Choose file'));
    // A toast is on screen a couple of frames and its slide-in later.
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.textContaining('public half'), findsOneWidget);
    expect(key(), _openSshKey);
    expect(picker.cleared, 2);

    // The toast goes by itself.
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
  });

  testWidgets("a saved host's notification key is copied from its page; one "
      'with none yet says so, and a new host offers none', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.binding.setSurfaceSize(const Size(800, 2000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final copied = <Object?>[];
    final platform = tester.binding.defaultBinaryMessenger;
    platform.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied.add(call.arguments);
      return null;
    });
    addTearDown(
      () => platform.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    final secrets = InMemorySecretStore();
    final notifyKeys = NotifyKeys(secrets, relay: FakeRelay());
    await notifyKeys.useFcmToken('fcm-token');
    final key = await notifyKeys.forConnect('box');

    Future<void> open(String? hostId) async {
      await tester.pumpWidget(
        ToastificationWrapper(
          child: MaterialApp(
            home: HostEditPage(
              key: ValueKey(hostId),
              repository: HostRepository(secrets),
              secrets: secrets,
              notifyKeys: notifyKeys,
              existing: hostId == null
                  ? null
                  : HostProfile(
                      id: hostId,
                      label: hostId,
                      host: '10.0.0.5',
                      username: 'me',
                    ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    /// Copies, and waits for the toast that says how it went.
    Future<void> copy() async {
      await tester.tap(find.text('Copy notification key'));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
    }

    await open('box');
    expect(find.textContaining('LC_SSHBOX_KEY'), findsOneWidget);
    await copy();
    // The host's LC_SSHBOX_KEY value, never the FCM token.
    expect(copied, [
      {'text': key},
    ]);
    expect(find.text('Notification key copied'), findsOneWidget);
    await tester.pumpAndSettle();

    await open('never-connected');
    await copy();
    expect(copied, hasLength(1));
    expect(find.textContaining('No notification key yet'), findsOneWidget);
    await tester.pumpAndSettle();

    await open(null);
    expect(find.text('Copy notification key'), findsNothing);
  });

  test('a key file is read if it holds an OpenSSH or PEM private key, and '
      'refused in words that say why otherwise', () {
    for (final key in [
      _openSshKey,
      '-----BEGIN RSA PRIVATE KEY-----\nProc-Type: 4,ENCRYPTED\n'
          'DEK-Info: AES-128-CBC,00\n\nMIIE\n-----END RSA PRIVATE KEY-----\n',
      '-----BEGIN EC PRIVATE KEY-----\nMHcC\n-----END EC PRIVATE KEY-----\n',
      '-----BEGIN DSA PRIVATE KEY-----\nMIIB\n-----END DSA PRIVATE KEY-----\n',
      '-----BEGIN PRIVATE KEY-----\nMIIE\n-----END PRIVATE KEY-----\n',
      '-----BEGIN ENCRYPTED PRIVATE KEY-----\nMIIF\n'
          '-----END ENCRYPTED PRIVATE KEY-----\n',
    ]) {
      expect(privateKeyFromFile(utf8.encode(key)), key);
    }

    Matcher refused(String why) => throwsA(
      isA<FormatException>().having((e) => e.message, 'message', contains(why)),
    );
    String? read(String text) => privateKeyFromFile(utf8.encode(text));

    expect(() => read(_publicKey), refused('public half'));
    expect(
      () => read('-----BEGIN PUBLIC KEY-----\nMIIB\n-----END PUBLIC KEY-----\n'),
      refused('public half'),
    );
    expect(
      () => read('PuTTY-User-Key-File-3: ssh-ed25519\nEncryption: none\n'),
      refused('puttygen key.ppk -O private-openssh -o key'),
    );
    expect(() => read('hello world\n'), refused("isn't a private key"));
    // Cut short: a BEGIN with no END.
    expect(
      () => read('-----BEGIN OPENSSH PRIVATE KEY-----\nb3Bl\n'),
      refused("isn't a private key"),
    );
    expect(
      () => privateKeyFromFile([0xff, 0xfe, 0x00, 0x01]),
      refused("isn't text"),
    );
    expect(
      () => privateKeyFromFile(List.filled(maxKeyFileBytes + 1, 0x41)),
      refused('64 KB'),
    );
  });
}
