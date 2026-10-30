import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/chat/claude_chat.dart';
import 'package:sshbox/src/chat/outbox.dart';
import 'package:sshbox/src/session/open_command.dart';

/// Every test starts with an empty chat outbox held in memory: the real one
/// is files in the app's folder, which a widget test with a faked clock
/// cannot wait on, and which no test should touch or leave things in. The
/// settling wait before a message is sent again is off unless a test asks
/// for one.
///
/// And every test file gets a home of its own, gone when the file is done:
/// what the app would write into this computer's `~` — a local shell's
/// secret in `~/.config/jeansh`, the `jeansh` command in `~/.local/bin` —
/// goes there and never into the real one.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  late Directory home;
  setUpAll(() {
    home = Directory.systemTemp.createTempSync('jeansh-test-home');
    homeOverride = home.path;
  });
  tearDownAll(() {
    homeOverride = null;
    home.deleteSync(recursive: true);
  });
  setUp(() {
    OutboxStore.shared = OutboxStore.memory();
    ClaudeChat.settleDelay = Duration.zero;
  });
  await testMain();
}
