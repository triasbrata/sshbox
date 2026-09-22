import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../telemetry/scrub.dart';
import '../telemetry/telemetry.dart';
import 'toast.dart';
import 'tui.dart';

/// Where a named report goes: the user's own browser, their own GitHub
/// account, their own finger on Submit. Jeansh holds no token for this and
/// could not open an issue as them if it wanted to.
const issuesUrl = 'https://github.com/triasbrata/sshbox/issues/new';

/// How long the whole `issues/new?title=…&body=…` URL may be.
///
/// GitHub itself takes a good deal more, but a URL travels through whatever
/// browser and whatever launcher the phone has, and 8192 is the number most
/// of them stop at. 6000 leaves room for all of that and is still several
/// screens of text; past it the body is cut and says it was cut, rather than
/// arriving silently short.
const maxIssueUrl = 6000;

/// Report a bug, from Settings or from the offer after something went wrong.
///
/// [about] is what the app already knows — the text of a fault it just
/// caught — and goes into the report under whatever the user writes.
///
/// Deliberately reachable with telemetry off: this is the user deciding to
/// send something, which is a different thing from Jeansh collecting it.
///
/// [using] is the relay, for a test that must not reach the network.
Future<void> showBugReport(
  BuildContext context, {
  String? about,
  Telemetry? using,
}) => showDialog<void>(
  context: context,
  builder: (_) => _BugReportDialog(about: about, using: using),
);

class _BugReportDialog extends StatefulWidget {
  const _BugReportDialog({this.about, this.using});

  final String? about;
  final Telemetry? using;

  @override
  State<_BugReportDialog> createState() => _BugReportDialogState();
}

class _BugReportDialogState extends State<_BugReportDialog> {
  late final Telemetry _relay = widget.using ?? telemetry;
  final _what = TextEditingController();

  /// The version, build, platform and OS line, once it has been read.
  String _facts = '';
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _what.addListener(() => setState(() {}));
    _load();
  }

  Future<void> _load() async {
    final facts = await _relay.facts();
    if (!mounted) return;
    setState(() {
      _facts =
          'Jeansh ${facts['version']}+${facts['build']} on '
          '${facts['platform']}, ${facts['os']}';
    });
  }

  @override
  void dispose() {
    _what.dispose();
    super.dispose();
  }

  /// Everything that would be sent, exactly as it would be sent — which is
  /// what the box below the field shows, so nothing goes anywhere the user
  /// has not read first.
  ///
  /// Scrubbed the same way a crash is: what the user typed goes through it
  /// too, since the quickest way to put a hostname in a bug report is to
  /// write one.
  String get _body {
    final what = scrub(_what.text.trim());
    final about = widget.about;
    final body = StringBuffer(what.isEmpty ? '(nothing written)' : what);
    if (about != null && about.isNotEmpty) {
      body.writeln();
      body.writeln();
      body.writeln('What Jeansh caught:');
      body.writeln();
      body.writeln('```');
      body.writeln(scrub(about));
      body.writeln('```');
    }
    body.writeln();
    body.write(_facts);
    return body.toString();
  }

  String get _title {
    final line = scrub(_what.text.trim()).split('\n').first.trim();
    if (line.isEmpty) return 'Bug report from Jeansh';
    return line.length > 80 ? '${line.substring(0, 77)}…' : line;
  }

  /// The named route: their browser, their account, their Submit.
  Future<void> _openGitHub() async {
    var body = _body;
    // The whole URL has to fit, and only the body can give: work out what
    // everything else costs and cut the body to what is left.
    final overhead = Uri.parse(issuesUrl)
        .replace(queryParameters: {'title': _title, 'body': ''})
        .toString()
        .length;
    final room = maxIssueUrl - overhead;
    // Percent-encoding is up to three bytes a character, so the cut is made
    // on the encoded length rather than the written one.
    if (Uri.encodeComponent(body).length > room) {
      const note = '\n\n(cut short to fit in a link — the rest was left out)';
      var cut = body.length;
      while (cut > 0 &&
          Uri.encodeComponent(body.substring(0, cut) + note).length > room) {
        cut -= 64;
      }
      body = '${body.substring(0, cut < 0 ? 0 : cut)}$note';
    }
    final url = Uri.parse(issuesUrl)
        .replace(queryParameters: {'title': _title, 'body': body});
    final opened = await launchUrl(url, mode: LaunchMode.externalApplication);
    if (!mounted) return;
    // Said before the dialog goes: a toast wants a context that is still in
    // the tree to find the overlay it draws in.
    if (!opened) {
      showToast(
        context,
        'Could not open a browser for GitHub',
        type: ToastificationType.error,
      );
    }
    Navigator.of(context).pop();
  }

  /// The anonymous route: the Worker opens the issue as a bot, and the report
  /// says so, so nobody tries to reply to a reporter who left no name.
  Future<void> _sendAnonymously() async {
    setState(() => _sending = true);
    final String where;
    try {
      where = await _relay.report(
        _title,
        '$_body\n\nSent anonymously through Jeansh. There is no way to reply '
        'to whoever sent it.',
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _sending = false);
      showToast(
        context,
        error is TelemetryException ? error.message : 'Could not send: $error',
        type: ToastificationType.error,
      );
      return;
    }
    if (!mounted) return;
    showToast(
      context,
      'Reported\n$where',
      type: ToastificationType.success,
      duration: const Duration(seconds: 5),
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    final ready = _what.text.trim().isNotEmpty && !_sending;
    return TuiDialog(
      title: 'Report a bug',
      maxWidth: 460,
      actions: [
        TuiButton(
          label: 'Cancel',
          variant: TuiButtonVariant.ghost,
          onPressed: _sending ? null : () => Navigator.of(context).pop(),
        ),
        TuiButton(
          label: 'Under my name',
          variant: TuiButtonVariant.ghost,
          onPressed: ready ? _openGitHub : null,
        ),
        TuiButton(
          label: _sending ? 'Sending…' : 'Anonymously',
          prefix: '▸',
          onPressed: ready ? _sendAnonymously : null,
        ),
      ],
      child: Flexible(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TuiField(
                label: 'What went wrong?',
                controller: _what,
                autofocus: true,
                minLines: 3,
                maxLines: 6,
                hint: 'What you did, and what happened instead',
              ),
              const SizedBox(height: 16),
              const TuiText(
                'This is everything that will be sent:',
                tone: TuiTextTone.muted,
                size: 11,
              ),
              const SizedBox(height: 6),
              Container(
                constraints: const BoxConstraints(maxHeight: 180),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: p.bg,
                  border: Border.all(color: p.border),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(
                    _body,
                    style: TextStyle(
                      fontFamily: TermulFonts.mono,
                      fontSize: 11,
                      color: p.text,
                      height: 1.4,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              const TuiText(
                'Hostnames, logins, paths and commands are taken out before '
                'this is shown. Read it over — nothing else goes.',
                tone: TuiTextTone.dim,
                size: 11,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
