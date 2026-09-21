import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sshbox/src/data/host_repository.dart';
import 'package:sshbox/src/data/secret_store.dart';
import 'package:sshbox/src/files/file_browser.dart';
import 'package:sshbox/src/models/host_profile.dart';
import 'package:sshbox/src/session/session_manager.dart';
import 'package:sshbox/src/session/terminal_session.dart';
import 'package:sshbox/src/ui/key_bar.dart';
import 'package:sshbox/src/ui/tabs_shell.dart';
import 'package:xterm2/xterm.dart';

import 'fake_file_browser.dart';

class _NoSecrets implements SecretStore {
  @override
  Future<String?> read(String key) async => null;

  @override
  Future<void> write(String key, String? value) async {}

  @override
  Future<void> purgeHost(String hostId) async {}
}

/// A shell that is up the moment it is asked for and keeps every window
/// change the host was sent.
class _Shell implements SessionTransport, TerminalSession, FileBrowseCapable {
  final resizes = <(int, int)>[];

  @override
  Future<TerminalSession> connect({
    required HostProfile host,
    required SecretStore secrets,
    required int columns,
    required int rows,
    bool shell = true,
    Map<String, String> environment = const {},
    Future<Map<String, String>> Function(ForwardCapable host)? beforeShell,
  }) async => this;

  @override
  final status = ValueNotifier(SessionStatus.connected);

  @override
  Stream<String> get output => const Stream.empty();

  @override
  String? get failure => null;

  @override
  void send(String data) {}

  @override
  void resize(int columns, int rows, int pixelWidth, int pixelHeight) =>
      resizes.add((columns, rows));

  @override
  Future<void> dispose() async {}

  @override
  FileBrowser openFileBrowser() => FakeFileBrowser();
}

void main() {
  testWidgets('the soft keyboard sliding in resizes each terminal once', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final manager = SessionManager();
    addTearDown(manager.closeAll);
    addTearDown(tester.view.resetViewInsets);
    // Three tabs, so two of them hidden in the IndexedStack, which lays them
    // out all the same.
    final shells = [_Shell(), _Shell(), _Shell()];
    for (final (index, shell) in shells.indexed) {
      manager.open(
        HostProfile(
          id: 'host-$index',
          label: 'box $index',
          host: '10.0.2.$index',
          username: 'me',
        ),
        transport: (_, _) => shell,
      );
    }
    for (final session in manager.sessions) {
      await session.connect(secrets: _NoSecrets());
    }
    await tester.pumpWidget(
      MaterialApp(
        home: TabsShell(
          repository: HostRepository(_NoSecrets()),
          secrets: _NoSecrets(),
          sessions: manager,
          onOpenHost: (_) async {},
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    final before = shells.first.resizes.last;
    for (final shell in shells) {
      shell.resizes.clear();
    }

    /// The keyboard's slide as Android reports it: a new inset every frame,
    /// easing out, from [from] to [to] physical pixels.
    Future<void> slide({required double from, required double to}) async {
      for (var frame = 1; frame <= 20; frame++) {
        final t = Curves.easeOutCubic.transform(frame / 20);
        tester.view.viewInsets = FakeViewPadding(
          bottom: from + (to - from) * t,
        );
        await tester.pump(const Duration(milliseconds: 16));

        // The prompt rides up on the key bar the whole way, rather than
        // sliding under the keyboard until the resize.
        expect(
          tester.getRect(find.byType(TerminalView).first).bottom,
          tester.getRect(find.byType(TerminalKeyBar).first).top,
        );
      }
    }

    await slide(from: 0, to: 900);
    // Nothing yet: every row lost along the way used to be a window change,
    // twelve of them here, for each of the three.
    for (final shell in shells) {
      expect(shell.resizes, isEmpty);
    }

    await tester.pump(const Duration(milliseconds: 200));
    for (final shell in shells) {
      expect(shell.resizes, hasLength(1));
      expect(shell.resizes.single.$1, before.$1);
      expect(shell.resizes.single.$2, lessThan(before.$2));
    }

    // And going away: one more, back where it was.
    await slide(from: 900, to: 0);
    await tester.pump(const Duration(milliseconds: 200));
    for (final shell in shells) {
      expect(shell.resizes, hasLength(2));
      expect(shell.resizes.last, before);
    }
  });
}
