import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/ui/ctrl_click.dart';
import 'package:sshbox/src/ui/pane_menu.dart';
import 'package:sshbox/src/ui/termul/tui_menu.dart';

/// What a selection's items do with text from the host, which is untrusted:
/// each hands a URL to openUrl (and its allowlist), a candidate to the
/// Ctrl+tap path or a path to the download, and none of them ever gets a
/// selection that is more than one word.
void main() {
  late List<Uri> urls;
  late List<String> opened, downloaded;

  Future<Map<String, TuiMenuItem<VoidCallback>>> menu(
    WidgetTester tester,
    String? selected,
  ) async {
    urls = [];
    opened = [];
    downloaded = [];
    late List<TuiMenuEntry<VoidCallback>> entries;
    await tester.pumpWidget(
      Builder(
        builder: (context) {
          entries = paneMenuEntries(
            context,
            Offset.zero,
            PaneMenu(
              selected: selected,
              link: null,
              tab: null,
              copy: null,
              paste: () {},
              copyLink: null,
              openUrl: urls.add,
              open: (LinkCandidate target) => opened.add(target.target),
              download: downloaded.add,
              selectAll: () {},
              clearBuffer: () {},
              reset: () {},
            ),
          );
          return const SizedBox();
        },
      ),
    );
    return {
      for (final entry in entries)
        if (entry is TuiMenuItem<VoidCallback>) entry.label: entry,
    };
  }

  testWidgets('a search is the selection as one query value, encoded', (
    tester,
  ) async {
    final items = await menu(tester, r'$(touch pwned); rm -rf ~ `id` &x=1#');
    items['Search the web for selection']!.value();
    expect(urls.single.scheme, 'https');
    expect(urls.single.host, 'www.google.com');
    expect(urls.single.queryParameters, {
      'q': r'$(touch pwned); rm -rf ~ `id` &x=1#',
    });
  });

  testWidgets('a selection of several words opens, mails and downloads '
      'nothing', (tester) async {
    for (final selected in [
      'me@example.com; rm -rf ~',
      '/etc/hosts; touch pwned',
      'https://a.example https://b.example',
    ]) {
      final items = await menu(tester, selected);
      expect(
        items['Send email to selected address']!.enabled,
        isFalse,
        reason: selected,
      );
      expect(items['Download with scp']!.enabled, isFalse, reason: selected);
      expect(items['Open selection']!.enabled, isFalse, reason: selected);
    }
  });

  testWidgets('a scheme that is not the web is never opened', (tester) async {
    for (final selected in [
      'javascript:alert(1)',
      'intent://x#Intent;scheme=sshbox;end',
      'sshbox://host/local',
      'file:///etc/passwd',
    ]) {
      final items = await menu(tester, selected);
      final open = items['Open selection']!;
      if (open.enabled) open.value();
      expect(urls, isEmpty, reason: selected);
      expect(
        items['Send email to selected address']!.enabled,
        isFalse,
        reason: selected,
      );
    }
  });

  testWidgets('an address is mailed as itself, and a path is downloaded as '
      'itself', (tester) async {
    var items = await menu(tester, 'me+jeansh@example.co.id');
    items['Send email to selected address']!.value();
    expect(urls, [Uri.parse('mailto:me+jeansh@example.co.id')]);

    items = await menu(tester, '~/logs/app.log');
    items['Download ~/logs/app.log']!.value();
    expect(downloaded, ['~/logs/app.log']);

    items = await menu(tester, 'https://dart.dev');
    items['Open selection']!.value();
    expect(opened, ['https://dart.dev']);
  });

  testWidgets('with nothing selected, none of them is on', (tester) async {
    final items = await menu(tester, '  ');
    for (final label in [
      'Search the web for selection',
      'Send email to selected address',
      'Download with scp',
      'Open selection',
    ]) {
      expect(items[label]!.enabled, isFalse, reason: label);
    }
  });
}
