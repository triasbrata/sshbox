import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sshbox/src/app.dart';
import 'package:sshbox/src/telemetry/telemetry.dart' show telemetryOn;
import 'package:sshbox/src/ui/onboarding_page.dart';
import 'package:sshbox/src/ui/toast.dart' show TuiToastCard;

/// The app's own gate, as `SshboxApp` has it: the slides until they are
/// done, then Home.
Widget _gate(OnboardingDone done) => MaterialApp(
  home: ValueListenableBuilder(
    valueListenable: done,
    builder: (context, finished, _) => finished
        ? const Scaffold(body: Text('Home'))
        : OnboardingPage(onDone: done.complete),
  ),
);

void main() {
  testWidgets('a fresh install sees the slides once: Skip lands on Home, and '
      'the next start goes straight there', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final done = OnboardingDone();
    await done.load();
    expect(done.value, isFalse);

    await tester.pumpWidget(_gate(done));
    expect(find.text('Home'), findsNothing);
    // Skip is named so, whatever it is drawn as.
    await tester.tap(find.bySemanticsLabel('Skip'));
    await tester.pumpAndSettle();
    expect(find.text('Home'), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(OnboardingDone.key), isTrue);

    // The next start.
    final again = OnboardingDone();
    await again.load();
    expect(again.value, isTrue);
    await tester.pumpWidget(_gate(again));
    expect(find.text('Home'), findsOneWidget);
    expect(find.bySemanticsLabel('Skip'), findsNothing);
  });

  testWidgets('the last slide\'s Enter home lands on Home, and is done for '
      'good', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final done = OnboardingDone();
    await done.load();
    await tester.pumpWidget(_gate(done));

    // Not settled: the later slides animate for as long as they show, as
    // termul's do.
    await tester.tap(find.bySemanticsLabel('Continue'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.bySemanticsLabel('Continue'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    // No Skip on the last slide: Enter home is the way on.
    expect(find.bySemanticsLabel('Skip'), findsNothing);
    await tester.tap(find.bySemanticsLabel('Enter home'));
    await tester.pumpAndSettle();
    expect(find.text('Home'), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(OnboardingDone.key), isTrue);
  });

  test(
    'an install that has run before never sees it, and is marked so',
    () async {
      SharedPreferences.setMockInitialValues({
        'sshbox.terminal.fontSize': 15.0,
      });
      final done = OnboardingDone();
      await done.load();
      expect(done.value, isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(OnboardingDone.key), isTrue);
    },
  );

  testWidgets('the first run\'s word about telemetry waits until the slides '
      'are done, rather than lying over them', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final messenger = tester.binding.defaultBinaryMessenger;
    for (final name in [
      'sshbox/share',
      'dexterous.com/flutter/local_notifications',
      'com.llfbandit.app_links/messages',
    ]) {
      messenger.setMockMethodCallHandler(MethodChannel(name), (_) async => null);
    }
    messenger.setMockStreamHandler(
      const EventChannel('com.llfbandit.app_links/events'),
      MockStreamHandler.inline(onListen: (_, _) {}),
    );
    telemetryOn.value = true;
    onboardingDone.value = false;
    addTearDown(() => onboardingDone.value = true);

    await tester.pumpWidget(SshboxApp());
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.bySemanticsLabel('Skip'), findsOneWidget);
    expect(find.textContaining('Jeansh reports crashes'), findsNothing);

    await tester.tap(find.bySemanticsLabel('Skip'));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final notice = find.textContaining('Jeansh reports crashes');
    expect(notice, findsOneWidget);
    // Low on Home, where it lands: clear of the header, the title and Add.
    final card = tester.getRect(
      find.ancestor(of: notice, matching: find.byType(TuiToastCard)),
    );
    for (final (what, finder) in [
      ('the header', find.bySemanticsLabel('Jeansh')),
      ('Settings', find.byTooltip('Settings')),
      ('the title', find.text('No hosts\nyet')),
      ('Add', find.bySemanticsLabel('Add')),
    ]) {
      expect(
        card.overlaps(tester.getRect(finder.first)),
        isFalse,
        reason: 'the notice lies over $what',
      );
    }
    // Let the toast go before the test ends.
    await tester.pump(const Duration(seconds: 10));
    await tester.pump(const Duration(seconds: 1));
  });
}
