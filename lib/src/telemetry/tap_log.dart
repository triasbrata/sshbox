import 'package:flutter/widgets.dart';

import 'app_log.dart';

/// One line for a tap on one of the app's own controls: `tap Save (editor)`.
///
/// **[name] comes from code and nothing else**: a fixed label constant or a
/// `logName` the call site passes. A control whose label is built from a host,
/// a file or a session name passes a fixed name ("Close tab", "Open host") or
/// none, and then only its kind is written (`tap button (home)`), so a name
/// the user or a host chose can never reach the log through here.
void logTap(BuildContext context, String? name, String kind) {
  appLog.add('tap ${name ?? kind} (${tapWhere(context)})');
}

/// The part of the app the control sits in, by the page above it.
String tapWhere(BuildContext context) {
  var where = 'app';
  context.visitAncestorElements((e) {
    final found = switch (e.widget.runtimeType.toString()) {
      'TerminalPage' => 'terminal',
      'ChatPage' => 'chat',
      'FileEditorPage' => 'editor',
      'GitPage' => 'git',
      'DbBrowserPage' => 'database',
      'DbEditorPage' => 'database',
      'SettingsPage' => 'settings',
      'HostsPage' => 'home',
      'FileBrowserPage' => 'files',
      'PortForwardingPage' => 'ports',
      'HostEditPage' => 'host editor',
      _ => null,
    };
    if (found == null) return true;
    where = found;
    return false;
  });
  return where;
}
