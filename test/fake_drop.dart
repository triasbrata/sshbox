import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm2/xterm.dart';

/// A drop of [paths] onto the terminal, as desktop_drop's native half
/// reports one over its channel: the drag coming in over the terminal, then
/// the drop.
///
/// With [land] false the drag only hovers, for the highlight.
Future<void> dropOnTerminal(
  WidgetTester tester,
  List<String> paths, {
  bool land = true,
}) async {
  final at = tester.getCenter(find.byType(TerminalView).first);
  Future<void> call(String method, Object? arguments) =>
      tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        'desktop_drop',
        const StandardMethodCodec().encodeMethodCall(
          MethodCall(method, arguments),
        ),
        (_) {},
      );
  await call('entered', [at.dx, at.dy]);
  await tester.pump();
  if (land) await call('performOperation', paths);
}
