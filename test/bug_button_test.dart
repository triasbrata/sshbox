import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sshbox/src/data/secret_store.dart';
import 'package:sshbox/src/models/host_profile.dart';
import 'package:sshbox/src/session/session_manager.dart';
import 'package:sshbox/src/session/terminal_session.dart';
import 'package:sshbox/src/telemetry/app_log.dart';
import 'package:sshbox/src/telemetry/bug_feedback.dart';
import 'package:sshbox/src/telemetry/crash_reporting.dart';
import 'package:sshbox/src/telemetry/telemetry.dart';
import 'package:sshbox/src/ui/bug_report.dart';
import 'package:sshbox/src/ui/tabs_shell.dart';
import 'package:sshbox/src/ui/toast.dart';
import 'package:sshbox/src/ui/tui.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';
import 'package:xterm2/xterm.dart' show Terminal;

import 'tui_finders.dart';

class _Launcher extends UrlLauncherPlatform {
  final opened = <String>[];

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    opened.add(url);
    return true;
  }
}

class _Net {
  final sent = <(Uri, String)>[];

  Future<({int status, String body})> post(Uri url, String body) async {
    sent.add((url, body));
    return (status: 200, body: '{"url":"https://github.test/issues/7"}');
  }
}

class _Feedback implements BugFeedback {
  _Feedback({this.available = true});

  @override
  final bool available;
  final sent = <({SentryId id, String message, String log})>[];

  @override
  Future<bool> send({
    required SentryId id,
    required String message,
    required String log,
  }) async {
    sent.add((id: id, message: message, log: log));
    return true;
  }
}

class _Refused implements SessionTransport {
  @override
  Future<TerminalSession> connect({
    required HostProfile host,
    required SecretStore secrets,
    required int columns,
    required int rows,
    bool shell = true,
    Map<String, String> environment = const {},
    Future<Map<String, String>> Function(ForwardCapable host)? beforeShell,
  }) async => throw const SshSessionException('refused');
}

/// Keeps what Sentry would have sent.
class _Wire implements Transport {
  final envelopes = <SentryEnvelope>[];

  @override
  Future<SentryId?> send(SentryEnvelope envelope) async {
    envelopes.add(envelope);
    return envelope.header.eventId;
  }

  Iterable<SentryEnvelopeItem> items(String type) =>
      envelopes.expand((e) => e.items).where((i) => i.header.type == type);
}

void main() {
  late _Launcher launcher;
  late _Net net;
  late Telemetry relay;
  late _Feedback feedback;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: 'Jeansh',
      packageName: 'cloud.brata.terminal',
      version: '1.0.62',
      buildNumber: '66',
      buildSignature: '',
    );
    UrlLauncherPlatform.instance = launcher = _Launcher();
    net = _Net();
    relay = Telemetry(post: net.post, host: 'https://t.test');
    feedback = _Feedback();
    telemetryOn.value = true;
  });

  group('AppLog', () {
    test('keeps to its line bound', () {
      final log = AppLog(maxLines: 5);
      for (var i = 0; i < 12; i++) {
        log.add('line number $i');
      }
      expect(log.length, 5);
      expect(log.current, contains('line number 11'));
      expect(log.current, isNot(contains('line number 6')));
    });

    test('keeps to its byte bound', () {
      final log = AppLog(maxBytes: 600);
      for (var i = 0; i < 50; i++) {
        log.add('x' * 90 + ' $i');
      }
      expect(utf8.encode(log.current).length, lessThanOrEqualTo(600));
      expect(log.current, contains(' 49'));
    });

    test('stores a line redacted', () {
      final log = AppLog();
      log.add(
        'failed trias@my-box.ts.net 100.101.228.69 /home/trias/.ssh/id_ed25519 '
        'postgresql://u:hunter2@db.internal/app '
        'ghp_abcdefghijklmnopqrstuvwxyz0123456789ABCD',
      );
      final text = log.render();
      for (final leak in [
        'trias',
        'my-box',
        '100.101',
        '.ssh',
        'hunter2',
        'db.internal',
        'ghp_abc',
      ]) {
        expect(text, isNot(contains(leak)), reason: leak);
      }
    });

    test('keeps a run across a restart, and only the one before', () async {
      final dir = Directory.systemTemp.createTempSync('applog');
      addTearDown(() => dir.deleteSync(recursive: true));
      final first = AppLog();
      await first.load(dir: dir);
      first.add('first run marker');
      await first.flush();
      final second = AppLog();
      await second.load(dir: dir);
      second.add('second run marker');
      await second.flush();
      final third = AppLog();
      await third.load(dir: dir);
      final text = third.render();
      expect(text, contains('second run marker'));
      expect(text, isNot(contains('first run marker')));
      if (!Platform.isWindows) {
        for (final name in ['applog.current', 'applog.previous']) {
          final mode = File('${dir.path}/$name').statSync().mode & 0x1ff;
          expect(mode, 384, reason: '$name is 0600');
        }
      }
    });

    test('nothing typed or written to a terminal reaches it', () async {
      final before = appLog.render();
      final terminal = Terminal();
      terminal.write('ls ~/secret; password: hunter2\r\n');
      terminal.textInput('rm -rf /home/trias');
      TextEditingController(text: 'my chat message').dispose();
      expect(appLog.render(), before);
    });
  });

  group('the button', () {
    Future<void> pump(WidgetTester tester) async {
      final session = LiveSession(
        host: HostProfile(
          id: 'h',
          label: 'box',
          host: '10.0.2.2',
          username: 'me',
        ),
        transport: (confirmHostKey, onAuthBanner) => _Refused(),
      );
      addTearDown(session.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: ToastLayer(
            child: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: TabStrip(
                  tabs: [
                    (
                      session: session,
                      kind: TabKind.terminal,
                      path: null,
                      web: null,
                    ),
                  ],
                  activeIndex: 1,
                  onSelect: (_, {kind = TabKind.terminal, path, web}) {},
                  onClose: (_) {},
                  onReconnect: (_) {},
                  onDuplicate: (_) {},
                ),
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('the first tap only expands, the second opens the report', (
      tester,
    ) async {
      await pump(tester);
      // The icon alone: its label is not drawn, only named for a reader.
      expect(find.text('Report a bug'), findsNothing);
      await tester.tap(find.bySemanticsLabel('Report a bug'));
      await tester.pumpAndSettle();
      expect(find.text('Report a bug'), findsOne);
      expect(find.byType(TuiDialog), findsNothing);
      await tester.tap(find.text('Report a bug'));
      await tester.pumpAndSettle();
      expect(find.byType(TuiDialog), findsOne);
    });

    testWidgets('a tap elsewhere folds it back', (tester) async {
      await pump(tester);
      await tester.tap(find.bySemanticsLabel('Report a bug'));
      await tester.pumpAndSettle();
      expect(find.text('Report a bug'), findsOne);
      await tester.tapAt(const Offset(700, 400));
      await tester.pumpAndSettle();
      expect(find.text('Report a bug'), findsNothing);
      expect(find.byType(TuiDialog), findsNothing);
    });

    testWidgets('it folds back by itself, and sits after +', (tester) async {
      await pump(tester);
      await tester.tap(find.bySemanticsLabel('Report a bug'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(find.text('Report a bug'), findsNothing);
      final plus = tester.getTopLeft(find.bySemanticsLabel('New tab'));
      final bug = tester.getTopLeft(find.bySemanticsLabel('Report a bug'));
      expect(bug.dx, greaterThan(plus.dx));
    });
  });

  group('the report', () {
    Future<void> open(
      WidgetTester tester, {
      String write = 'the tab froze',
      _Feedback? using,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ToastLayer(
            child: Builder(
              builder: (context) => Scaffold(
                body: ElevatedButton(
                  onPressed: () => showBugReport(
                    context,
                    using: relay,
                    feedback: using ?? feedback,
                  ),
                  child: const Text('go'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), write);
      await tester.pumpAndSettle();
    }

    final eventLine = RegExp(r'Sentry event: ([0-9a-f]{32})');

    testWidgets('shows the event id it will be found by', (tester) async {
      await open(tester);
      expect(find.textContaining(eventLine), findsWidgets);
    });

    testWidgets('the public issue holds the id and no log text', (
      tester,
    ) async {
      appLog.add('connect: marker-line-for-test session 7 connected');
      await open(tester);
      await tester.tap(find.bySemanticsLabel('Under my name'));
      await tester.pumpAndSettle();
      final id = feedback.sent.single.id.toString();
      // The log went to Sentry, whole...
      expect(feedback.sent.single.log, contains('marker-line-for-test'));
      // ...and the issue carries only the id.
      final body = Uri.parse(launcher.opened.single).queryParameters['body']!;
      expect(body, contains('Sentry event: $id'));
      expect(body, isNot(contains('marker-line-for-test')));
      expect(body, isNot(contains('session 7')));
    });

    testWidgets('the anonymous issue holds the id and no log text', (
      tester,
    ) async {
      appLog.add('chat: marker-line-for-test restart');
      await open(tester);
      await tester.tap(find.bySemanticsLabel('Anonymously'));
      await tester.pumpAndSettle();
      final sent = jsonDecode(net.sent.single.$2) as Map<String, dynamic>;
      expect(sent['body'], contains('Sentry event: '));
      expect(sent['body'], isNot(contains('marker-line-for-test')));
      expect(feedback.sent.single.log, contains('marker-line-for-test'));
    });

    testWidgets('with telemetry off it asks, and the answer starts as no', (
      tester,
    ) async {
      telemetryOn.value = false;
      await open(tester);
      expect(find.textContaining('Telemetry is off'), findsOne);
      expect(find.textContaining(eventLine), findsNothing);
      await tester.tap(find.bySemanticsLabel('Under my name'));
      await tester.pumpAndSettle();
      expect(feedback.sent, isEmpty);
      expect(
        Uri.parse(launcher.opened.single).queryParameters['body'],
        isNot(contains('Sentry event')),
      );
    });

    testWidgets('with telemetry off, saying yes sends it for this report', (
      tester,
    ) async {
      telemetryOn.value = false;
      await open(tester);
      await tester.ensureVisible(
        findTuiSwitch('Send the app log with this report'),
      );
      await tester.pumpAndSettle();
      await tester.tap(findTuiSwitchTrack('Send the app log with this report'));
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('Under my name'));
      await tester.pumpAndSettle();
      expect(feedback.sent, hasLength(1));
      expect(telemetryOn.value, isFalse, reason: 'the switch is untouched');
    });

    testWidgets('a build with no DSN says so, and still reports', (
      tester,
    ) async {
      await open(tester, using: _Feedback(available: false));
      expect(find.textContaining("can't be attached in this build"), findsOne);
      await tester.tap(find.bySemanticsLabel('Under my name'));
      await tester.pumpAndSettle();
      expect(
        Uri.parse(launcher.opened.single).queryParameters['body'],
        isNot(contains('Sentry event')),
      );
    });

    testWidgets('Show what\'s attached shows the exact log', (tester) async {
      appLog.add('tab: marker-shown opened file tab');
      await open(tester);
      await tester.ensureVisible(find.text("Show what's attached"));
      await tester.pumpAndSettle();
      await tester.tap(find.text("Show what's attached"));
      await tester.pumpAndSettle();
      final shown = tester
          .widgetList<SelectableText>(find.byType(SelectableText))
          .map((t) => t.data ?? '')
          .join('\n');
      expect(shown, contains('marker-shown'));
    });
  });

  group('what Sentry is handed', () {
    late _Wire wire;

    setUp(() async {
      wire = _Wire();
      await Sentry.init((options) {
        options.dsn = 'https://key@o0.ingest.sentry.test/1';
        options.transport = wire;
        options.beforeSend = scrubEvent;
        options.maxBreadcrumbs = 0;
      });
    });

    tearDown(() async => Sentry.close());

    test('a report arrives as one feedback event with its log', () async {
      final id = SentryId.newId();
      final ok = await sendFeedbackEvent(
        id: id,
        message: 'froze on my-box.ts.net for trias@my-box.ts.net',
        log: 'connect: session 1 connected',
      );
      expect(ok, isTrue);
      expect(wire.items('feedback'), hasLength(1));
      final sent = wire.envelopes.single.header.eventId;
      expect(sent, id);
      final attachment = wire.items('attachment').single;
      expect(attachment.header.attachmentType, isNotNull);
      expect(
        utf8.decode(await attachment.dataFactory()),
        'connect: session 1 connected',
      );
      final event = utf8.decode(
        await wire.items('feedback').single.dataFactory(),
      );
      expect(event, isNot(contains('my-box')));
      expect(event, isNot(contains('trias')));
    });

    test('and it gets through with telemetry off, being asked for', () async {
      telemetryOn.value = false;
      final ok = await sendFeedbackEvent(
        id: SentryId.newId(),
        message: 'froze',
        log: 'x',
      );
      expect(ok, isTrue);
    });

    test('nothing else new gets through: not a stray feedback event', () async {
      await Sentry.captureFeedback(SentryFeedback(message: 'not ours'));
      expect(wire.envelopes, isEmpty);
    });

    test('and an ordinary error is still held by telemetry off', () async {
      telemetryOn.value = false;
      await Sentry.captureException(StateError('boom'));
      expect(wire.envelopes, isEmpty);
    });
  });
}
