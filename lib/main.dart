import 'package:flutter/material.dart';

import 'src/app.dart';
import 'src/session/port_forwards.dart';
import 'src/session/session_log.dart';
import 'src/telemetry/crash_reporting.dart';
import 'src/telemetry/telemetry.dart';
import 'src/ui/settings_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Before the first frame, so a shell opens in the chosen font with the
  // chosen keys and the app in its chosen colours, rather than changing a
  // moment later when they arrive.
  await terminalSettings.load();
  await keyBarSettings.load();
  await appTheme.load();
  await gitInDrawer.load();
  await localTmux.load();
  await showDotfiles.load();
  // Before any session can connect, so its entry joins the saved log rather
  // than being wiped by it.
  await sessionLog.load();
  // Before any host is saved: the first time, it takes the port forwards
  // hosts kept themselves, which a host's next save no longer writes.
  await portForwards.load();
  // Before the app runs, because whether Sentry is started at all depends on
  // it: turned off, `SentryFlutter.init` is never called and no crash handler
  // is ever installed. See `runWithCrashReporting`.
  await telemetryOn.load();
  await runWithCrashReporting(() => runApp(const SshboxApp()));
}
