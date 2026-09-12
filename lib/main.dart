import 'package:flutter/material.dart';

import 'src/app.dart';
import 'src/session/session_log.dart';
import 'src/ui/settings_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Before the first frame, so a shell opens in the chosen font and the app in
  // its chosen colours, rather than changing a moment later when they arrive.
  await terminalSettings.load();
  await appTheme.load();
  // Before any session can connect, so its entry joins the saved log rather
  // than being wiped by it.
  await sessionLog.load();
  runApp(const SshboxApp());
}
