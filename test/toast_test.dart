import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/ui/toast.dart';
import 'package:toastification/toastification.dart';

void main() {
  late BuildContext context;

  Future<void> pumpApp(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (built) {
          context = built;
          return const SizedBox();
        },
      ),
    ),
  );

  /// Lets the toasts just asked for slide all the way in: a frame for the
  /// package's overlay, one to start the slide, and the slide.
  Future<void> slideIn(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
  }

  ToastificationType? typeOf(WidgetTester tester, String message) => tester
      .widget<BuiltInToastBuilder>(
        find.ancestor(
          of: find.text(message),
          matching: find.byType(BuiltInToastBuilder),
        ),
      )
      .type;

  testWidgets('a toast sits at the top as info, and goes by itself after a '
      'second', (tester) async {
    await pumpApp(tester);
    showToast(context, 'hello');
    await slideIn(tester);

    expect(typeOf(tester, 'hello'), ToastificationType.info);
    expect(tester.getCenter(find.text('hello')).dy, lessThan(100));

    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('hello'), findsOneWidget);
    // At a second it goes, and slides away. Not settled: that would wait out
    // any countdown, however long.
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump();
    expect(find.text('hello'), findsNothing);
  });

  testWidgets('a second toast stacks, and the same one twice does not', (
    tester,
  ) async {
    await pumpApp(tester);
    showToast(context, 'first');
    showToast(context, 'second', type: ToastificationType.warning);
    showToast(context, 'second', type: ToastificationType.warning);
    await slideIn(tester);

    expect(find.text('first'), findsOneWidget);
    expect(find.text('second'), findsOneWidget);
    expect(typeOf(tester, 'second'), ToastificationType.warning);
    expect(
      tester
          .getRect(find.text('first'))
          .overlaps(tester.getRect(find.text('second'))),
      isFalse,
    );

    await tester.pumpAndSettle();
    expect(find.text('first'), findsNothing);
    expect(find.text('second'), findsNothing);
  });
}
