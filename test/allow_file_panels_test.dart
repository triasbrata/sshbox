import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/ui/file_download.dart';

import 'fake_file_picker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Issue #136: unsandboxed, the Mac's save panel was refused with
  // ENTITLEMENT_REQUIRED_WRITE until file_picker was told to skip its check.
  test('turns off file_picker\'s entitlement check on macOS', () async {
    final picker = useFakePicker();
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await allowFilePanels();
    expect(picker.skippedEntitlementChecks, 1);
  });

  test('leaves every other platform alone', () async {
    final picker = useFakePicker();
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    for (final platform in TargetPlatform.values) {
      if (platform == TargetPlatform.macOS) continue;
      debugDefaultTargetPlatformOverride = platform;
      await allowFilePanels();
    }
    expect(picker.skippedEntitlementChecks, 0);
  });
}
