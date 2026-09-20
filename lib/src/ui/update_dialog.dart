import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../files/file_browser.dart' show formatBytes;
import '../update/updater.dart';
import 'toast.dart';

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
    } on UpdateException catch (error) {
      if (!mounted) return;
      setState(() => _checking = false);
      showToast(context, error.message, type: ToastificationType.error);
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

/// What a newer release is, and a Download that brings it down, checks it and
/// says where it went. Nothing is installed or run: the file is handed over.
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
      setState(() => _file = file);
    } on UpdateException catch (error) {
      if (!mounted) return;
      Navigator.of(context).pop();
      showToast(context, error.message, type: ToastificationType.error);
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  /// What to do with the file, which differs per platform because each ships
  /// differently. Jeansh does not replace itself yet.
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
    if (file != null) {
      return AlertDialog(
        title: Text('Jeansh ${update.version} is in your Downloads'),
        content: Text('${file.path}\n\n$_howToInstall'),
        actions: [
          TextButton(
            onPressed: () => unawaited(
              launchUrl(Uri.file(file.parent.path)),
            ),
            child: const Text('Open folder'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Done'),
          ),
        ],
      );
    }

    if (_downloading) {
      final progress = _progress ?? 0;
      return AlertDialog(
        title: Text('Downloading Jeansh ${update.version}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${(progress * 100).floor()}% of ${formatBytes(update.size)}',
            ),
            const SizedBox(height: 12),
            LinearProgressIndicator(value: progress),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => _cancel?.complete(),
            child: const Text('Cancel'),
          ),
        ],
      );
    }

    return AlertDialog(
      title: Text('Jeansh ${update.version} is out'),
      content: Text(
        'You have ${widget.updater.version}. The download is '
        '${formatBytes(update.size)}, and it is checked against the '
        "release's SHA-256 before Jeansh keeps it.\n\n"
        'It goes to your Downloads — Jeansh does not install it for you.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Not now'),
        ),
        FilledButton(
          onPressed: _download,
          child: const Text('Download'),
        ),
      ],
    );
  }
}
