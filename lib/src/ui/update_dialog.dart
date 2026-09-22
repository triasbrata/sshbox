import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../files/file_browser.dart' show formatBytes;
import '../update/updater.dart';
import 'toast.dart';
import 'tui.dart';

/// What to show for [error]: the updater's own errors are a line written to
/// be read, and anything else is said as it is rather than swallowed.
String _said(Object error) => error is UpdateException
    ? error.message
    : 'The update check went wrong: $error';

/// Settings' Check for updates, on the desktop builds: the app's version,
/// and a tap that always asks the feed. A build with no update host baked in
/// says so and asks nothing — see [Updater.enabled].
class UpdateTile extends StatefulWidget {
  const UpdateTile({super.key, Updater? using}) : _updater = using;

  final Updater? _updater;

  @override
  State<UpdateTile> createState() => _UpdateTileState();
}

class _UpdateTileState extends State<UpdateTile> {
  late final Updater _updater = widget._updater ?? updater;
  bool _checking = false;

  Future<void> _check() async {
    setState(() => _checking = true);
    final Update? update;
    try {
      update = await _updater.check();
    } catch (error) {
      // Everything, not [UpdateException] alone: an error nobody expected
      // would otherwise leave the row spinning and disabled for good, with
      // no way out but leaving Settings.
      if (!mounted) return;
      setState(() => _checking = false);
      showToast(context, _said(error), type: ToastificationType.error);
      return;
    }
    if (!mounted) return;
    // Before the dialog, so the row is not still spinning behind it.
    setState(() => _checking = false);
    if (update == null) {
      showToast(
        context,
        'Jeansh is up to date',
        type: ToastificationType.success,
      );
      return;
    }
    await showUpdate(context, update, using: _updater);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = _updater.enabled;
    return ListTile(
      leading: const Icon(Icons.system_update_alt),
      title: const Text('Check for updates'),
      subtitle: Text(
        enabled
            ? 'This is Jeansh ${_updater.version}. Jeansh also looks once a '
                  'day when it starts.'
            : 'This build takes no updates — it was built without an update '
                  'host, so there is nothing to check against.',
      ),
      enabled: enabled && !_checking,
      trailing: _checking
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : null,
      onTap: enabled && !_checking ? _check : null,
    );
  }
}

/// What a newer release is, and a Download that brings it down and checks it,
/// then offers Restart to update, which puts it in place of this copy and
/// starts it. Where this copy cannot replace itself, the file is handed over
/// in the Downloads instead, saying why.
Future<void> showUpdate(
  BuildContext context,
  Update update, {
  Updater? using,
}) => showDialog<void>(
  context: context,
  builder: (_) => _UpdateDialog(update, using ?? updater),
);

class _UpdateDialog extends StatefulWidget {
  const _UpdateDialog(this.update, this.updater);

  final Update update;
  final Updater updater;

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  /// Null before Download is pressed; the fraction while it comes down.
  double? _progress;
  bool _downloading = false;
  Completer<void>? _cancel;

  /// Where it landed, once it is in and its SHA-256 matches.
  File? _file;

  /// Why this copy cannot put the update in its own place, or null if it can;
  /// asked once, as the dialog opens.
  late final String? _refusal = widget.updater.installRefusal;

  /// The file handed over in the Downloads rather than installed: this copy
  /// cannot replace itself, or putting it in place failed before anything
  /// was changed.
  bool _handOver = false;

  /// Restart to update pressed, and the update being put in place.
  bool _installing = false;

  static const _installs =
      'Jeansh then offers to put it in place of this copy and restart.';
  static const _handsOver =
      'It goes to your Downloads — Jeansh cannot install it here.';

  Future<void> _download() async {
    final cancel = Completer<void>();
    setState(() {
      _downloading = true;
      _progress = 0;
      _cancel = cancel;
    });
    try {
      final file = await widget.updater.download(
        widget.update,
        cancelled: cancel.future,
        onProgress: (done, total) {
          if (mounted) setState(() => _progress = done / total);
        },
      );
      if (!mounted) return;
      // Null is Cancel, which is the user's own doing and needs no telling.
      if (file == null) {
        Navigator.of(context).pop();
        return;
      }
      setState(() {
        _file = file;
        _handOver = _refusal != null;
      });
      final refusal = _refusal;
      if (refusal != null) {
        showToast(context, refusal, type: ToastificationType.warning);
      }
    } catch (error) {
      // As above: anything at all, or the dialog is stuck on its bar.
      if (!mounted) return;
      Navigator.of(context).pop();
      showToast(context, _said(error), type: ToastificationType.error);
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  /// Puts the update in place and quits, for the helper to start it; see
  /// [Updater.restartInto]. Anything that stops it first hands the file over
  /// instead, with this copy as it was.
  Future<void> _restart(File file) async {
    setState(() => _installing = true);
    try {
      await widget.updater.restartInto(widget.update, file);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _installing = false;
        _handOver = true;
      });
      showToast(
        context,
        '${_said(error)} It is in your Downloads instead.',
        type: ToastificationType.error,
      );
    }
  }

  /// Stops the download, and does nothing if it is already stopping.
  void _cancelNow() {
    final cancel = _cancel;
    if (cancel != null && !cancel.isCompleted) cancel.complete();
  }

  /// What to do with the file, which differs per platform because each ships
  /// differently: for when Jeansh cannot put it in place itself.
  String get _howToInstall => switch (defaultTargetPlatform) {
    TargetPlatform.windows =>
      'Unzip it, and run Jeansh.exe from the folder it makes. Close this '
          'Jeansh first — Windows will not replace a running program.',
    TargetPlatform.macOS =>
      'Unzip it and drag Jeansh.app into Applications, over the old one. '
          'Quit this Jeansh first.',
    _ =>
      'Unpack it and run jeansh from the folder it makes, in place of the '
          'folder you run now.',
  };

  @override
  Widget build(BuildContext context) {
    final update = widget.update;
    final file = _file;
    if (_installing) {
      // TODO(termul): a spinner (gap 5).
      return TuiDialog(
        title: 'update',
        maxWidth: 420,
        message: 'Installing Jeansh ${update.version}',
        child: const Row(
          children: [
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 16),
            Expanded(
              child: TuiText(
                'Jeansh restarts when it is in place.',
                tone: TuiTextTone.muted,
                size: 11,
              ),
            ),
          ],
        ),
      );
    }
    if (file != null && !_handOver) {
      return TuiDialog(
        title: 'update',
        maxWidth: 420,
        message: 'Jeansh ${update.version} is ready',
        detail:
            'It was checked against the release. Restart to update closes '
            'this Jeansh — open sessions end, and a tmux session goes on '
            'running on its host — and starts ${update.version} in its place.',
        actions: [
          TuiButton(
            label: 'Later',
            variant: TuiButtonVariant.ghost,
            onPressed: () => Navigator.of(context).pop(),
          ),
          TuiButton(
            label: 'Restart to update',
            prefix: '↻',
            onPressed: () => unawaited(_restart(file)),
          ),
        ],
      );
    }
    if (file != null) {
      return TuiDialog(
        title: 'update',
        maxWidth: 420,
        message: 'Jeansh ${update.version} is in your Downloads',
        detail: '${file.path}\n\n$_howToInstall',
        actions: [
          TuiButton(
            label: 'Open folder',
            variant: TuiButtonVariant.ghost,
            onPressed: () => unawaited(launchUrl(Uri.file(file.parent.path))),
          ),
          TuiButton(
            label: 'Done',
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      );
    }

    if (_downloading) {
      final progress = _progress ?? 0;
      return TuiDialog(
        title: 'update',
        maxWidth: 420,
        message: 'Downloading Jeansh ${update.version}',
        actions: [
          TuiButton(
            label: 'Cancel',
            variant: TuiButtonVariant.ghost,
            // Cancel stays up until the next chunk arrives, so it can be
            // tapped again in that window; a Completer completed twice
            // throws.
            onPressed: () => _cancelNow(),
          ),
        ],
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TuiText(
              '${(progress * 100).floor()}% of ${formatBytes(update.size)}',
              tone: TuiTextTone.muted,
              size: 11,
            ),
            const SizedBox(height: 12),
            // TODO(termul): a progress bar (gap 5).
            LinearProgressIndicator(value: progress),
          ],
        ),
      );
    }

    return TuiDialog(
      title: 'update',
      maxWidth: 420,
      message: 'Jeansh ${update.version} is out',
      detail:
          'You have ${widget.updater.version}. The download is '
          '${formatBytes(update.size)}, and it is checked against the '
          "release's SHA-256 before Jeansh keeps it.\n\n"
          '${_refusal == null ? _installs : _handsOver}',
      actions: [
        TuiButton(
          label: 'Not now',
          variant: TuiButtonVariant.ghost,
          onPressed: () => Navigator.of(context).pop(),
        ),
        TuiButton(label: 'Download', prefix: '↓', onPressed: _download),
      ],
    );
  }
}
