import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';
import 'package:sshbox/src/files/file_browser.dart';
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
    SaveChord.reset();
  });

  /// MainActivity's call when it takes a Ctrl+S.
  Future<void> nativeSave() => TestDefaultBinaryMessengerBinding
      .instance
      .defaultBinaryMessenger
      .handlePlatformMessage(
        'sshbox/keys',
        const StandardMethodCodec().encodeMethodCall(const MethodCall('save')),
        (_) {},
      );

  group('SaveChord', () {
    test('tells Android only when whether any editor wants it changes, and '
        'saves with the newest claim', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final saved = <String>[];
      final a = Object(), b = Object();
      SaveChord.want(a, () => saved.add('a'));
      SaveChord.want(b, () => saved.add('b'));
      await nativeSave();
      expect(saved, ['b']);
      SaveChord.want(b, null);
      await nativeSave();
      expect(saved, ['b', 'a']);
      expect(told, [true]);
      SaveChord.want(a, null);
      SaveChord.want(a, null);
      expect(told, [true, false]);
      await nativeSave();
      expect(saved, ['b', 'a']);
    });

    test('tells nothing anywhere but Android', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      SaveChord.want(Object(), () {});
      expect(told, isEmpty);
    });

    test('an engine with no handler is no error', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async {
            throw PlatformException(code: 'nope');
          });
      SaveChord.want(Object(), () {});
      await pumpEventQueue();
    });
  });

  testWidgets('the editor page claims Ctrl+S while it holds the focus, saves '
      'on the native call only with something to save, and lets go when the '
      'focus leaves and when it closes', (tester) async {
    final away = FocusNode();
    addTearDown(away.dispose);
    final open = ValueNotifier(true);
    addTearDown(open.dispose);
    final browser = _CountingBrowser();
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
                        browser: browser,
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

    // Nothing edited: nothing to save.
    await nativeSave();
    await tester.pumpAndSettle();
    expect(browser.writes, 0);

    tester
            .widget<CodeEditor>(find.byType(CodeEditor, skipOffstage: false))
            .controller!
            .text =
        'edited\n';
    await tester.pumpAndSettle();
    await nativeSave();
    await tester.pumpAndSettle();
    expect(browser.writes, 1);
    expect(browser.contents['/home/me/notes.txt'], 'edited\n');

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

class _CountingBrowser extends FakeFileBrowser {
  int writes = 0;

  @override
  Future<FileStamp> writeText(
    String path,
    String content, {
    FileStamp? expected,
  }) {
    writes++;
    return super.writeText(path, content, expected: expected);
  }
}
