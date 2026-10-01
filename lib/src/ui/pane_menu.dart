import 'package:flutter/widgets.dart';

import 'ctrl_click.dart';
import 'right_click.dart';
import 'tui.dart';

/// What a terminal pane's right-click menu acts on: the click, the
/// selection, and what the pane and its tab can do. Each null where it
/// cannot, its row then shown greyed out, as iTerm2 shows its own.
class PaneMenu {
  const PaneMenu({
    required this.selected,
    required this.link,
    required this.tab,
    required this.copy,
    required this.paste,
    required this.copyLink,
    required this.openUrl,
    required this.open,
    required this.download,
    required this.selectAll,
    required this.clearBuffer,
    required this.reset,
  });

  /// The selection's text, or null with nothing selected.
  final String? selected;

  /// The OSC 8 hyperlink clicked or selected.
  final String? link;
  final TabActions? tab;
  final VoidCallback? copy;
  final VoidCallback paste;
  final VoidCallback? copyLink;
  final void Function(Uri url) openUrl;

  /// What a Ctrl+tap on [link] does; null where the pane can open nothing.
  final void Function(LinkCandidate link)? open;

  /// Brings a file on the host down, as the files drawer's Download does;
  /// null where the session has no files to reach.
  final void Function(String path)? download;
  final VoidCallback selectAll;
  final VoidCallback clearBuffer;
  final VoidCallback reset;
}

final _email = RegExp(r'^[\w.+-]+@[\w-]+(\.[\w-]+)+$');

/// A file on the host by its path: absolute, from home, or from here.
final _path = RegExp(r'^(/|~/|\./|\.\./)[^\s]*[^/\s]$');

/// iTerm2's pane menu, as far as Jeansh has each of its items, in its order.
///
/// Not here, Jeansh having nothing like them: New Window, Add Trigger, Send
/// Selection, Snippets, Annotations, Broadcast Input, Lock Pane, Bury and
/// AutoFill. New Tab and Terminal State are submenus in iTerm2; termul has
/// none, so New tab… opens a second menu where the first was, and Reset
/// terminal stands alone.
List<TuiMenuEntry<VoidCallback>> paneMenuEntries(
  BuildContext context,
  Offset at,
  PaneMenu menu,
) {
  final tab = menu.tab;
  final selected = menu.selected?.trim();
  final words = selected == null || selected.isEmpty ? null : selected;
  final single = words != null && !words.contains(RegExp(r'\s'));
  final email = single && _email.hasMatch(words) ? words : null;
  final path = single && _path.hasMatch(words) ? words : null;
  final found = single ? findLinks(words) : const <LinkCandidate>[];
  final target = found.length == 1 ? found.single : null;

  TuiMenuItem<VoidCallback> item(String label, VoidCallback? onTap) =>
      menuAction(label, onTap ?? () {}, enabled: onTap != null);

  final newTab = tab?.newTab;
  final open = menu.open;
  final download = menu.download;
  return [
    item(
      'New tab…',
      newTab == null
          ? null
          : () async {
              final targets = await newTab();
              if (!context.mounted || targets.isEmpty) return;
              await showActionsAt(context, at, [
                for (final (label, onTap) in targets) menuAction(label, onTap),
              ]);
            },
    ),
    const TuiMenuDivider(),
    item(
      'Search the web for selection',
      words == null
          ? null
          : () => menu.openUrl(
              Uri.https('www.google.com', '/search', {'q': words}),
            ),
    ),
    item(
      'Send email to selected address',
      email == null
          ? null
          : () => menu.openUrl(Uri(scheme: 'mailto', path: email)),
    ),
    item(
      path == null ? 'Download with scp' : 'Download $path',
      path == null || download == null ? null : () => download(path),
    ),
    item(
      'Open selection',
      target == null || open == null ? null : () => open(target),
    ),
    // #131's Show as diagram goes here, with the selection's other items.
    const TuiMenuDivider(),
    item('Split pane vertically', tab?.splitSideBySide),
    item('Split pane horizontally', tab?.splitStacked),
    item('Move into a group…', tab?.groupWith),
    item('Take out of group', tab?.takeOutOfGroup),
    item('Swap with the next pane', tab?.swap),
    const TuiMenuDivider(),
    item('Copy', menu.copy),
    item('Paste', menu.paste),
    if (menu.copyLink != null) item('Copy link address', menu.copyLink),
    item('Select all', menu.selectAll),
    item('Clear buffer', menu.clearBuffer),
    const TuiMenuDivider(),
    item('Edit session…', tab?.editSession),
    if (tab != null)
      menuAction('Close', tab.close, destructive: true)
    else
      item('Close', null),
    item('Restart', tab?.restart),
    const TuiMenuDivider(),
    item('Duplicate session', tab?.duplicate),
    item('Detach', tab?.detach),
    item('Attach to a session…', tab?.attach),
    item('Pane record', tab?.record),
    const TuiMenuDivider(),
    item('Reset terminal', menu.reset),
  ];
}
