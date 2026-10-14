import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';
import 'package:sshbox/src/ui/file_editor_page.dart';
import 'package:sshbox/src/ui/save_chord.dart';

import 'fake_file_browser.dart';

void main() {
  const channel = MethodChannel('sshbox/share');
  late List<Object?> told;

  setUp(() {
    SaveChord.reset();
    told = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'saveChord') told.add(call.arguments);
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('SaveChord', () {
    test('tells Android only when whether any editor wants it changes', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final a = Object(), b = Object();
      SaveChord.want(a, true);
      SaveChord.want(b, true);
      SaveChord.want(a, false);
      expect(told, [true]);
      SaveChord.want(b, false);
      SaveChord.want(b, false);
      expect(told, [true, false]);
    });

    test('tells nothing anywhere but Android', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      SaveChord.want(Object(), true);
      expect(told, isEmpty);
    });

    test('an engine with no handler is no error', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async {
            throw PlatformException(code: 'nope');
          });
      SaveChord.want(Object(), true);
      await pumpEventQueue();
    });
  });

  testWidgets('the editor page claims Ctrl+S while it holds the focus, and '
      'lets go when the focus leaves and when it closes', (tester) async {
    final away = FocusNode();
    addTearDown(away.dispose);
    final open = ValueNotifier(true);
    addTearDown(open.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Column(
          children: [
            Focus(focusNode: away, child: const SizedBox(height: 10)),
            Expanded(
              child: ValueListenableBuilder(
                valueListenable: open,
                builder: (_, on, _) => on
                    ? FileEditorPage(
                        browser: FakeFileBrowser(),
                        path: '/home/me/notes.txt',
                      )
                    : const SizedBox(),
              ),
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    // The page takes the focus as it opens.
    expect(told, [true]);

    away.requestFocus();
    await tester.pumpAndSettle();
    expect(told, [true, false]);

    await tester.tap(find.byType(CodeEditor));
    await tester.pumpAndSettle();
    expect(told, [true, false, true]);

    open.value = false;
    await tester.pumpAndSettle();
    expect(told, [true, false, true, false]);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
