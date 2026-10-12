import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/chat/claude_chat.dart';
import 'package:sshbox/src/chat/outbox.dart';

/// Every test starts with an empty chat outbox held in memory: the real one
/// is files in the app's folder, which a widget test with a faked clock
/// cannot wait on, and which no test should touch or leave things in. The
/// settling wait before a message is sent again is off unless a test asks
/// for one.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  setUp(() {
    OutboxStore.shared = OutboxStore.memory();
    ClaudeChat.settleDelay = Duration.zero;
  });
  await testMain();
}
