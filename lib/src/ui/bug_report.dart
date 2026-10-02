import 'package:flutter/material.dart';
import 'package:sentry_flutter/sentry_flutter.dart' show SentryId;
import 'package:url_launcher/url_launcher.dart';

import '../telemetry/app_log.dart';
import '../telemetry/bug_feedback.dart';
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
/// [using] is the relay, and [feedback] is where the log goes, for a test that
/// must not reach the network.
///
/// The log, what the app did this run and the last, goes to Sentry alone,
/// because this repository is public. The issue, on either route, carries the
/// description, the version and the id of the Sentry event, and never a line
/// of the log.
Future<void> showBugReport(
  BuildContext context, {
  String? about,
  Telemetry? using,
  BugFeedback? feedback,
}) => showDialog<void>(
  context: context,
  builder: (_) =>
      _BugReportDialog(about: about, using: using, feedback: feedback),
);

class _BugReportDialog extends StatefulWidget {
  const _BugReportDialog({this.about, this.using, this.feedback});

  final String? about;
  final Telemetry? using;
  final BugFeedback? feedback;

  @override
  State<_BugReportDialog> createState() => _BugReportDialogState();
}

class _BugReportDialogState extends State<_BugReportDialog> {
  late final Telemetry _relay = widget.using ?? telemetry;
  late final BugFeedback _feedback = widget.feedback ?? sentryBugFeedback;
  final _what = TextEditingController();

  /// The id of the Sentry event this report becomes, made now so the dialog
  /// can show it; the event is sent when the report is, not before, so a
  /// dialog that is cancelled uploads nothing.
  final _eventId = SentryId.newId();

  /// Whether the log goes. On with telemetry on; with it off the user is
  /// asked, and the answer starts as no.
  late bool _attach = telemetryOn.value;
  bool _showLog = false;

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
  bool get _logGoes => _feedback.available && _attach;

  String get _body => _bodyFor(_logGoes);

  String _bodyFor(bool withEventId) {
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
    if (withEventId) body.write('\nSentry event: $_eventId');
    return body.toString();
  }

  String get _title {
    final line = scrub(_what.text.trim()).split('\n').first.trim();
    if (line.isEmpty) return 'Bug report from Jeansh';
    return line.length > 80 ? '${line.substring(0, 77)}…' : line;
  }

  /// The log, to Sentry, under the id the dialog shows. True when it arrived;
  /// said so when it did not, and the report goes on without the id.
  Future<bool> _deliver() async {
    if (!_logGoes) return false;
    final sent = await _feedback.send(
      id: _eventId,
      message: _body,
      log: appLog.render(),
    );
    if (!sent && mounted) {
      showToast(
        context,
        'The log could not be attached, so the report goes without it',
        type: TuiToastType.warning,
      );
    }
    return sent;
  }

  /// The named route: their browser, their account, their Submit.
  Future<void> _openGitHub() async {
    setState(() => _sending = true);
    final sent = await _deliver();
    var body = _bodyFor(sent);
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
        type: TuiToastType.error,
      );
    }
    Navigator.of(context).pop();
  }

  /// The anonymous route: the Worker opens the issue as a bot, and the report
  /// says so, so nobody tries to reply to a reporter who left no name.
  Future<void> _sendAnonymously() async {
    setState(() => _sending = true);
    final sent = await _deliver();
    final String where;
    try {
      where = await _relay.report(
        _title,
        '${_bodyFor(sent)}\n\nSent anonymously through Jeansh. There is no way to reply '
        'to whoever sent it.',
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _sending = false);
      showToast(
        context,
        error is TelemetryException ? error.message : 'Could not send: $error',
        type: TuiToastType.error,
      );
      return;
    }
    if (!mounted) return;
    showToast(
      context,
      'Reported\n$where',
      type: TuiToastType.success,
      duration: const Duration(seconds: 5),
    );
    Navigator.of(context).pop();
  }

  /// What the app did, for the developer: its own switch, the id it will be
  /// found by, and the exact text, which is also what is sent.
  List<Widget> _logSection(TermulPalette p) {
    if (!_feedback.available) {
      return const [
        TuiText(
          "The log can't be attached in this build, which has nowhere to send "
          'it. The report goes without it.',
          tone: TuiTextTone.dim,
          size: 11,
        ),
      ];
    }
    final log = appLog.render();
    return [
      TuiSwitch(
        value: _attach,
        onChanged: _sending ? null : (on) => setState(() => _attach = on),
        label: telemetryOn.value
            ? 'Attach the app log'
            : 'Send the app log with this report',
        hint: telemetryOn.value
            ? 'What the app did this run and the last, so the bug can be '
                  'found. It goes to Sentry, never to the public issue.'
            : 'Telemetry is off, so nothing is sent unless you say so here, '
                  'for this report only. It goes to Sentry, never to the '
                  'public issue.',
      ),
      if (_attach) ...[
        const SizedBox(height: 8),
        TuiText('Sentry event: $_eventId', size: 11),
        const SizedBox(height: 4),
        GestureDetector(
          onTap: () => setState(() => _showLog = !_showLog),
          child: TuiText(
            _showLog ? "Hide what's attached" : "Show what's attached",
            tone: TuiTextTone.muted,
            size: 11,
          ),
        ),
        if (_showLog) ...[
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
                log.isEmpty ? '(empty)' : log,
                style: TextStyle(
                  fontFamily: TermulFonts.mono,
                  fontSize: 10,
                  color: p.text,
                  height: 1.4,
                ),
              ),
            ),
          ),
        ],
      ],
    ];
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
            const SizedBox(height: 16),
            ..._logSection(p),
          ],
        ),
      ),
    );
  }
}
