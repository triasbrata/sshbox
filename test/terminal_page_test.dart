import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/data/secret_store.dart';
import 'package:sshbox/src/models/host_profile.dart';
import 'package:sshbox/src/session/session_manager.dart';
import 'package:sshbox/src/ui/key_bar.dart';
import 'package:sshbox/src/ui/terminal_page.dart';

/// Holds nothing, so a password host fails to connect before a socket is
/// ever opened: the page comes up and stays up without a network.
class _NoSecrets implements SecretStore {
  @override
  Future<String?> read(String key) async => null;

  @override
  Future<void> write(String key, String? value) async {}

  @override
  Future<void> purgeHost(String hostId) async {}
}

void main() {
  testWidgets('no header: its buttons ride in the key bar, and no menu', (
    tester,
  ) async {
    final session = LiveSession(
      host: const HostProfile(
        id: 'host-1',
        label: 'box',
        host: '10.0.2.2',
        username: 'me',
      ),
    );
    addTearDown(session.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: TerminalPage(
          session: session,
          secrets: _NoSecrets(),
          onOpenFile: (_) {},
          onSaveFileRoot: (_) async {},
        ),
      ),
    );
    // The page connects after its first frame, and this one fails at once.
    await tester.pump();
    expect(session.ended, isTrue);

    expect(find.byType(AppBar), findsNothing);
    expect(find.byIcon(Icons.more_vert), findsNothing);

    // Still there with no shell to talk to, the way the header's were; the
    // keys are not.
    final bar = find.byType(TerminalKeyBar);
    for (final tooltip in ['Browse files', 'Upload a file to /tmp']) {
      expect(
        find.descendant(of: bar, matching: find.byTooltip(tooltip)),
        findsOneWidget,
      );
    }
    expect(find.text('ESC'), findsNothing);
  });
}
