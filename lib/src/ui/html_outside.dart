import 'dart:async';

import 'package:flutter/material.dart';

import '../files/file_browser.dart';
import '../files/html_site.dart';
import 'terminal_page.dart' show openUrl;
import 'toast.dart';
import 'tui.dart';

/// Shows an HTML file on the host in the machine's own browser, where the
/// system has no web view for a tab of ours: Linux and Windows.
///
/// The same site as a tab's, on 127.0.0.1 with the same confinement, so the
/// page loads the files beside it and nothing more. What a tab has that this
/// has not is Jeansh's say over where the page goes next: the browser is the
/// user's own, so the dialog says that it is outside, and the site is served
/// only while the dialog is up.
Future<void> openHtmlOutside(
  BuildContext context,
  FileBrowser browser,
  String path,
) async {
  final HtmlSite site;
  try {
    site = await HtmlSite.start(browser: browser, htmlPath: path);
  } catch (error) {
    if (context.mounted) {
      showToast(
        context,
        'Could not open $path: $error',
        type: TuiToastType.error,
      );
    }
    return;
  }
  if (!context.mounted) {
    await site.close();
    return;
  }
  unawaited(openUrl(context, site.url));
  final notice = ValueListenableBuilder(
    valueListenable: site.problems,
    builder: (context, problems, _) {
      if (problems.isEmpty) return const SizedBox.shrink();
      final shown = problems.entries
          .take(5)
          .map((e) => '${e.key.split('/').skip(2).join('/')} (${e.value})');
      return Padding(
        padding: const EdgeInsets.only(top: 10),
        child: TuiBox(
          expanded: false,
          child: Text(
            '${problems.length} not loaded: ${shown.join(', ')}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      );
    },
  );
  await showDialog<void>(
    context: context,
    builder: (context) => TuiDialog(
      title: 'opens outside Jeansh',
      message: '${RemotePath.basename(path)} is shown in your browser',
      detail:
          'This build has no browser tab on this system. Jeansh serves the '
          'file, and the files beside it, to this computer only, while this '
          'window is open. Done stops it.',
      maxWidth: 440,
      actions: [
        TuiButton(
          label: 'Open again',
          logName: 'Open again',
          variant: TuiButtonVariant.ghost,
          onPressed: () => unawaited(openUrl(context, site.url)),
        ),
        TuiButton(
          label: 'Done',
          logName: 'Done',
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
      child: notice,
    ),
  );
  await site.close();
}
