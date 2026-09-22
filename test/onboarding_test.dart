import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sshbox/src/ui/onboarding_page.dart';

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
}
