import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// A drop is for one window: the platform names the view before each event,
/// and a target in another view does not hear it.
void main() {
  const channel = MethodChannel('desktop_drop');

  Future<void> tell(WidgetTester tester, String method, Object? arguments) =>
      tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(MethodCall(method, arguments)),
        (_) {},
      );

  Future<void> drop(WidgetTester tester, {required int view}) async {
    await tell(tester, 'view', view);
    await tell(tester, 'entered', [20.0, 20.0]);
    await tell(tester, 'view', view);
    await tell(tester, 'performOperation', ['/tmp/dropped.txt']);
    await tester.pump();
  }

  Future<List<String>> pump(WidgetTester tester) async {
    final dropped = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: DropTarget(
          onDragDone: (details) =>
              dropped.addAll(details.files.map((file) => file.path)),
          child: const SizedBox.expand(),
        ),
      ),
    );
    return dropped;
  }

  testWidgets('a drop on the first window reaches a target in it', (
    tester,
  ) async {
    final dropped = await pump(tester);
    await drop(tester, view: 0);
    expect(dropped, ['/tmp/dropped.txt']);
  });

  testWidgets('a drop on another window does not reach it', (tester) async {
    final dropped = await pump(tester);
    await drop(tester, view: 5);
    expect(dropped, isEmpty);
    expect(DesktopDrop.instance.eventView, 5);
    // The view each event is for is told again before it: the next drop, on
    // this window, arrives.
    await drop(tester, view: 0);
    expect(dropped, ['/tmp/dropped.txt']);
  });
}
