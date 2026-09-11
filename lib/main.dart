import 'package:flutter/material.dart';

import 'src/app.dart';
import 'src/ui/settings_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Before the first frame, so a shell opens in the chosen font rather than
  // resizing a moment later when the choice arrives.
  await terminalSettings.load();
  runApp(const SshboxApp());
}
