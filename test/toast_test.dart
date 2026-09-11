import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/ui/toast.dart';

void main() {
  testWidgets('a second toast replaces the first, and goes by itself', (
    tester,
  ) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (built) {
            context = built;
            return const SizedBox();
          },
        ),
      ),
    );

    showToast(context, 'first');
    await tester.pumpAndSettle();
    expect(find.text('first'), findsOneWidget);

    showToast(context, 'second');
    await tester.pumpAndSettle();
    expect(find.text('first'), findsNothing);
    expect(find.text('second'), findsOneWidget);

    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.text('second'), findsNothing);
  });
}
