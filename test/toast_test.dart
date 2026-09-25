import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/ui/toast.dart';
import 'package:sshbox/src/ui/tui.dart';

void main() {
  late BuildContext context;
  final navigator = GlobalKey<NavigatorState>();

  /// A screen in [mode] showing [under], wrapped the way the app wraps its
  /// own.
  Future<void> pumpApp(
    WidgetTester tester, {
    ThemeMode mode = ThemeMode.light,
    Widget under = const SizedBox(),
  }) => tester.pumpWidget(
    MaterialApp(
      navigatorKey: navigator,
      themeMode: mode,
      theme: ThemeData(brightness: Brightness.light),
      darkTheme: ThemeData(brightness: Brightness.dark),
      builder: (context, child) => ToastLayer(child: child!),
      home: Builder(
        builder: (built) {
          context = built;
          return under;
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

  /// The toast saying [message].
  Finder card(String message) => find.ancestor(
    of: find.text(message),
    matching: find.byType(TuiToastCard),
  );

  /// What the toast saying [message] is drawn on.
  Material surface(WidgetTester tester, String message) =>
      tester.widget<Material>(
        find
            .ancestor(of: find.text(message), matching: find.byType(Material))
            .first,
      );

  TuiToastType? typeOf(WidgetTester tester, String message) =>
      tester.widget<TuiToastCard>(card(message)).type;

  testWidgets('a toast sits at the top as info, and goes by itself after a '
      'second', (tester) async {
    await pumpApp(tester);
    showToast(context, 'hello');
    await slideIn(tester);

    expect(typeOf(tester, 'hello'), TuiToastType.info);
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
    showToast(context, 'second', type: TuiToastType.warning);
    showToast(context, 'second', type: TuiToastType.warning);
    await slideIn(tester);

    expect(find.text('first'), findsOneWidget);
    expect(find.text('second'), findsOneWidget);
    expect(typeOf(tester, 'second'), TuiToastType.warning);
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

  testWidgets('an error stays five seconds', (tester) async {
    await pumpApp(tester);
    showToast(context, 'broken', type: TuiToastType.error);
    await slideIn(tester);

    // Four seconds in, still up.
    await tester.pump(const Duration(milliseconds: 3400));
    expect(find.text('broken'), findsOneWidget);
    // At five it goes.
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump();
    expect(find.text('broken'), findsNothing);
  });

  testWidgets("the navigator's own context will do, for a message from no "
      'page', (tester) async {
    await pumpApp(tester);
    showToast(navigator.currentContext!, 'hello');
    await slideIn(tester);

    expect(typeOf(tester, 'hello'), TuiToastType.info);
    await tester.pumpAndSettle();
  });

  for (final (mode, light) in [
    (ThemeMode.light, true),
    (ThemeMode.dark, false),
  ]) {
    testWidgets("in a ${mode.name} theme a toast is ${mode.name} too: termul's "
        'panel and ink', (tester) async {
      await pumpApp(tester, mode: mode);
      showToast(context, 'hello');
      await slideIn(tester);

      final p = TermulThemeData.of(context).palette;
      final ground = surface(tester, 'hello').color!;
      expect(ground, p.panel);
      expect(ground.computeLuminance(), light ? greaterThan(.5) : lessThan(.5));
      expect(tester.widget<Text>(find.text('hello')).style?.color, p.text);
      await tester.pumpAndSettle();
    });
  }

  testWidgets("what a toast is about shows only as termul's glyph mark, in "
      'the same ink as its words', (tester) async {
    await pumpApp(tester);
    final ink = TermulThemeData.of(context).palette.text;

    for (final (type, glyph, message) in [
      (TuiToastType.info, 'i', 'Port 3000 closed'),
      (TuiToastType.success, '+', 'Saved a.txt'),
      (TuiToastType.warning, '!', 'claude is running'),
      (TuiToastType.error, 'x', 'Not found: /x'),
    ]) {
      showToast(context, message, type: type);
      await slideIn(tester);

      final drawn = find.descendant(
        of: card(message),
        matching: find.text(glyph),
      );
      expect(drawn, findsOneWidget, reason: '$type');
      expect(tester.widget<Text>(drawn).style?.color, ink, reason: '$type');
      // Nothing but the message is said in words: no "Info", no "Error".
      expect(
        find.descendant(
          of: card(message),
          matching: find.textContaining(
            RegExp('info|success|warning|error', caseSensitive: false),
          ),
        ),
        findsNothing,
        reason: '$type',
      );
      await tester.pumpAndSettle();
    }
  });

  testWidgets('an error has no red in it', (tester) async {
    await pumpApp(tester);
    const message = 'Upload failed: gone';
    showToast(
      context,
      message,
      type: TuiToastType.error,
      action: (label: 'Retry', onPressed: () {}),
    );
    await slideIn(tester);

    Iterable<W> all<W extends Widget>() => tester.widgetList<W>(
      find.descendant(of: card(message), matching: find.byType(W)),
    );
    final colors = [
      for (final material in all<Material>()) material.color,
      for (final icon in all<Icon>()) icon.color,
      for (final text in all<RichText>()) text.text.style?.color,
      for (final box in all<ColoredBox>()) box.color,
    ].nonNulls.toList();

    expect(colors, isNotEmpty);
    // Red: well more of it than of green or blue, the way the package's own
    // error toast is.
    expect(colors.where((c) => c.r - math.max(c.g, c.b) > .2), isEmpty);
    await tester.pumpAndSettle();
  });

  testWidgets("a toast is termul's four fifths of the window wide, where a "
      'long one wraps', (tester) async {
    await pumpApp(tester);
    const short = 'Saved';
    final long = 'Upload failed:${' the host closed the connection' * 8}';
    showToast(context, short);
    showToast(context, long, type: TuiToastType.error);
    await slideIn(tester);

    final most = MediaQuery.sizeOf(context).width * .8;
    double width(String message) => tester
        .getSize(
          find
              .ancestor(of: find.text(message), matching: find.byType(Material))
              .first,
        )
        .width;
    expect(width(long), moreOrLessEquals(most, epsilon: .5));
    expect(width(short), moreOrLessEquals(most, epsilon: .5));
    // Wrapped rather than cut: lines of it, and all of them there.
    expect(
      tester.getSize(find.text(long)).height,
      greaterThan(tester.getSize(find.text(short)).height * 3),
    );
    expect(
      tester.renderObject<RenderParagraph>(find.text(long)).didExceedMaxLines,
      isFalse,
    );
    await tester.pumpAndSettle();
  });

  testWidgets('a touch beside a toast, or between two, goes through to what '
      'is under them; one on a toast does not', (tester) async {
    var tabTaps = 0;
    final through = <Offset>[];
    await pumpApp(
      tester,
      under: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (details) => through.add(details.globalPosition),
            ),
          ),
          // A tab, say: beside the column the toasts stack in.
          Positioned(
            left: 8,
            top: 16,
            width: 64,
            height: 48,
            child: TextButton(
              onPressed: () => tabTaps++,
              child: const Text('Tab'),
            ),
          ),
        ],
      ),
    );
    showToast(context, 'Copied');
    showToast(context, 'Saved notes.txt');
    await slideIn(tester);

    Rect drawnOn(String message) => tester.getRect(
      find
          .ancestor(of: find.text(message), matching: find.byType(Material))
          .first,
    );
    final [upper, lower] = [drawnOn('Copied'), drawnOn('Saved notes.txt')]
      ..sort((a, b) => a.top.compareTo(b.top));
    final tab = tester.getCenter(find.text('Tab'));
    final between = Offset(upper.center.dx, (upper.bottom + lower.top) / 2);
    // On neither card.
    for (final point in [tab, between]) {
      expect(upper.contains(point) || lower.contains(point), isFalse);
    }

    await tester.tap(find.text('Tab'));
    expect(tabTaps, 1);
    await tester.tapAt(between);
    expect(through, [between]);

    // On a toast, the toast has it.
    await tester.tapAt(upper.center);
    expect(through, [between]);
    expect(tabTaps, 1);
    await tester.pumpAndSettle();
  });

  testWidgets("a toast's own button still takes a tap, and a swipe still "
      'sends it away', (tester) async {
    await pumpApp(tester);
    var retried = false;
    showToast(
      context,
      'Upload failed: gone',
      type: TuiToastType.error,
      action: (label: 'Retry', onPressed: () => retried = true),
    );
    await slideIn(tester);

    await tester.tap(find.text('RETRY'));
    // termul fires it once the toast has gone, a frame on.
    await tester.pump();
    expect(retried, isTrue);
    // Long before its five seconds were up.
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.text('Upload failed: gone'), findsNothing);

    // Up for a minute, so only the swipe can have sent it.
    showToast(context, 'Saved notes.txt', duration: const Duration(minutes: 1));
    await slideIn(tester);
    await tester.fling(card('Saved notes.txt'), const Offset(600, 0), 2000);
    // Its slide off and its fold away: a second or so, not its minute.
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(TuiToastCard), findsNothing);
  });
}
