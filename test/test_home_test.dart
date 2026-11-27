import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/app.dart';
import 'package:sshbox/src/session/open_command.dart';

/// No test writes into the real home: test/flutter_test_config.dart gives
/// each test file one of its own, and what the app writes into `~` with
/// nothing naming a home goes there.
void main() {
  final real = Platform.environment['HOME'];

  test('every test file has a home of its own, not HOME', () {
    expect(homeOverride, isNotNull);
    expect(homeOverride, isNot(real));
    expect(Directory(homeOverride!).existsSync(), isTrue);
    expect(localHome(), homeOverride);
  });

  test('with no override, the home is HOME', () {
    final saved = homeOverride;
    addTearDown(() => homeOverride = saved);
    homeOverride = null;
    expect(localHome(), real);
  });

  test("a local shell's secret, with no home named, goes into the test's "
      'home and not the real one', () {
    final write = localOpenSecretWriter(desktop: true, windows: false);
    expect(write, isNotNull);
    write!('s3cret');
    final file = File('$homeOverride/$openSecretDir/$openSecretFile');
    expect(file.readAsStringSync(), 's3cret\n');
    if (real != null) {
      final theirs = File('$real/$openSecretDir/$openSecretFile');
      expect(
        theirs.existsSync() && theirs.readAsStringSync() == 's3cret\n',
        isFalse,
      );
    }
  });

  test("the jeansh command, with no home named, goes into the test's home "
      'and not the real one', () {
    expect(installOpenCommandInHome(), isNull);
    final file = File('$homeOverride/.local/bin/jeansh');
    expect(file.readAsStringSync(), contains(openCommandMarker));
    if (real != null) {
      final theirs = File('$real/.local/bin/jeansh');
      expect(
        theirs.existsSync() &&
            theirs.readAsStringSync().contains(openCommandMarker) &&
            theirs.statSync().modified.isAfter(
              file.statSync().modified.subtract(const Duration(seconds: 5)),
            ),
        isFalse,
      );
    }
  });
}
