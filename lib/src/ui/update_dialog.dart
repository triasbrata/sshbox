import 'dart:async';

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
    final update = await askForUpdate(context, _updater);
    if (!mounted) return;
    // Before the dialog, so the row is not still spinning behind it.
    setState(() => _checking = false);
    if (update != null) await showUpdate(context, update, using: _updater);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = _updater.enabled;
    // termul's action rows, as Settings' others: a button, its small print
    // under it.
    Widget note(String text) => Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 16),
      child: TuiText(text, tone: TuiTextTone.muted, size: 10),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListenableBuilder(
          listenable: Listenable.merge([updateAvailable, updateDownload]),
          builder: (context, _) {
            final download = updateDownload.value;
            final update = updateAvailable.value;
            final shown = download != null && !download.gone ? download : null;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (shown != null) _DownloadRow(shown),
                // Its download, once there is one, says all the offer would.
                if (update != null && update.label != shown?.update.label) ...[
                  TuiButton(
                    label: 'Jeansh ${update.version} is available',
                    prefix: '↑',
                    onPressed: () =>
                        showUpdate(context, update, using: _updater),
                  ),
                  note('Tap to see it and update.'),
                ],
              ],
            );
          },
        ),
        Row(
          children: [
            TuiButton(
              label: 'Check for updates',
              prefix: '↻',
              variant: TuiButtonVariant.ghost,
              onPressed: enabled && !_checking ? _check : null,
            ),
            if (_checking) ...[
              const SizedBox(width: 12),
              const SizedBox(width: 16, height: 16, child: TuiSpinner()),
            ],
          ],
        ),
        note(
          enabled
              ? 'This is Jeansh ${_updater.version}. Jeansh also looks once '
                    'a day while it runs.'
              : _noUpdates,
        ),
      ],
    );
  }
}

const _noUpdates =
    'This build takes no updates — it was built without an update host, so '
    'there is nothing to check against.';

/// A check under way, which a second ask joins rather than starting another.
Future<Update?>? _asking;

/// Asks the feed and always answers: the newer release, or null having said
/// why there is none — up to date, a feed out of reach, or a build that takes
/// no updates. Settings' Check for updates and the menu's both come here.
Future<Update?> askForUpdate(BuildContext context, [Updater? using]) =>
    _asking ??= _ask(
      context,
      using ?? updater,
    ).whenComplete(() => _asking = null);

Future<Update?> _ask(BuildContext context, Updater updater) async {
  if (!updater.enabled) {
    showToast(context, 'This build takes no updates', type: TuiToastType.info);
    return null;
  }
  final Update? update;
  try {
    update = await updater.check();
  } catch (error) {
    // Everything, not [UpdateException] alone: an error nobody expected
    // would otherwise leave the row spinning and disabled for good.
    if (context.mounted) {
      showToast(context, _said(error), type: TuiToastType.error);
    }
    return null;
  }
  if (update == null && context.mounted) {
    showToast(context, 'Jeansh is up to date', type: TuiToastType.success);
  }
  return update;
}

/// The menu's Check for updates: [askForUpdate], and the dialog when there
/// is something newer.
Future<void> checkForUpdates(BuildContext context, [Updater? using]) async {
  final update = await askForUpdate(context, using);
  if (update != null && context.mounted) {
    await showUpdate(context, update, using: using);
  }
}

/// Home's marker while [updateAvailable] holds a newer release: a tap opens
/// its dialog. Nothing at all otherwise.
class UpdateChip extends StatelessWidget {
  const UpdateChip({super.key});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<Update?>(
    valueListenable: updateAvailable,
    builder: (context, update, _) => update == null
        ? const SizedBox.shrink()
        : Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: TuiButton(
              label: 'Update ${update.version}',
              prefix: '↑',
              onPressed: () => showUpdate(context, update),
            ),
          ),
  );
}

/// What a newer release is, and a Download that brings it down and checks it,
/// then offers Restart to update, which puts it in place of this copy and
/// starts it. Where this copy cannot replace itself, the file is handed over
/// in the Downloads instead, saying why.
Future<void> showUpdate(
  BuildContext context,
  Update update, {
  Updater? using,
}) async {
  // One at a time: two checks finishing together, or a menu click while the
  // dialog is up, must not stack a second.
  if (_showingOn?.mounted ?? false) return;
  final navigator = _showingOn = Navigator.of(context);
  try {
    await showDialog<void>(
      context: context,
      builder: (_) => _UpdateDialog(update, using ?? updater),
    );
  } finally {
    if (_showingOn == navigator) _showingOn = null;
  }
}

/// The navigator the update dialog is up in, while it is; a navigator gone
/// with it still up takes its dialog along.
NavigatorState? _showingOn;

class _UpdateDialog extends StatefulWidget {
  const _UpdateDialog(this.update, this.updater);

  final Update update;
  final Updater updater;

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

/// The dialog is a window onto [updateDownload], which it does not own:
/// closing it any way but Cancel leaves the download running, and opening it
/// again shows the same one.
class _UpdateDialogState extends State<_UpdateDialog> {
  UpdateDownload? _last = updateDownload.value;

  static const _installs =
      'Jeansh then offers to put it in place of this copy and restart.';
  static const _handsOver =
      'It goes to your Downloads — Jeansh cannot install it here.';

  @override
  void initState() {
    super.initState();
    updateDownload.addListener(_changed);
  }

  @override
  void dispose() {
    updateDownload.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    final now = updateDownload.value;
    // A download gone with nothing kept is Cancel, which closes the dialog.
    final cancelled = _last?.phase == DownloadPhase.downloading && now == null;
    _last = now;
    if (!mounted) return;
    if (cancelled) {
      Navigator.of(context).pop();
    } else {
      setState(() {});
    }
  }

  Future<void> _restart() async {
    try {
      await restartToUpdate();
    } catch (error) {
      if (!mounted) return;
      showToast(
        context,
        '${_said(error)} It is in your Downloads instead.',
        type: TuiToastType.error,
      );
    }
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
    final state = updateDownload.value;
    // The running download whatever was asked about, or this update's own
    // finished one; anything else is an offer.
    final shown =
        state != null &&
            !state.gone &&
            (state.running || state.update.label == widget.update.label)
        ? state
        : null;
    final update = shown?.update ?? widget.update;
    Widget close(String label, {bool ghost = true}) => TuiButton(
      label: label,
      variant: ghost ? TuiButtonVariant.ghost : TuiButtonVariant.primary,
      onPressed: () => Navigator.of(context).pop(),
    );

    switch (shown?.phase) {
      case DownloadPhase.installing:
        return TuiDialog(
          title: 'update',
          maxWidth: 420,
          message: 'Installing Jeansh ${update.version}',
          child: const Row(
            children: [
              SizedBox(width: 20, height: 20, child: TuiSpinner()),
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
      case DownloadPhase.ready when shown!.handOver == null:
        return TuiDialog(
          title: 'update',
          maxWidth: 420,
          message: 'Jeansh ${update.version} is ready',
          detail:
              'It was checked against the release. Restart to update closes '
              'this Jeansh — open sessions end, and a tmux session goes on '
              'running on its host — and starts ${update.version} in its '
              'place.',
          actions: [
            close('Later'),
            TuiButton(
              label: 'Restart to update',
              prefix: '↻',
              onPressed: () => unawaited(_restart()),
            ),
          ],
        );
      case DownloadPhase.ready:
        final file = shown!.file!;
        return TuiDialog(
          title: 'update',
          maxWidth: 420,
          message: 'Jeansh ${update.version} is in your Downloads',
          detail: '${shown.handOver}\n\n${file.path}\n\n$_howToInstall',
          actions: [
            TuiButton(
              label: 'Open folder',
              variant: TuiButtonVariant.ghost,
              onPressed: () => unawaited(launchUrl(Uri.file(file.parent.path))),
            ),
            close('Done', ghost: false),
          ],
        );
      case DownloadPhase.failed:
        return TuiDialog(
          title: 'update',
          maxWidth: 420,
          message: 'Jeansh ${update.version} did not download',
          detail: shown!.error,
          actions: [
            close('Not now'),
            TuiButton(
              label: 'Try again',
              prefix: '↻',
              onPressed: retryDownload,
            ),
          ],
        );
      case DownloadPhase.downloading:
        return TuiDialog(
          title: 'update',
          maxWidth: 420,
          message: 'Downloading Jeansh ${update.version}',
          actions: [
            close('Hide'),
            // Cancel stays up until the next chunk arrives, so it can be
            // tapped again in that window; cancelDownload takes that.
            TuiButton(
              label: 'Cancel',
              variant: TuiButtonVariant.ghost,
              onPressed: cancelDownload,
            ),
          ],
          child: DownloadProgress(shown!),
        );
      case null:
        return TuiDialog(
          title: 'update',
          maxWidth: 420,
          message: 'Jeansh ${update.version} is out',
          detail:
              'You have ${widget.updater.version}. The download is '
              '${formatBytes(update.size)}, and it is checked against the '
              "release's SHA-256 before Jeansh keeps it.\n\n"
              '${widget.updater.installRefusal == null ? _installs : _handsOver}',
          actions: [
            close('Not now'),
            TuiButton(
              label: 'Download',
              prefix: '↓',
              onPressed: () => startDownload(update, widget.updater),
            ),
          ],
        );
    }
  }
}

/// A download's bar, with how much of it is in and how fast: the dialog's
/// and Settings'.
class DownloadProgress extends StatelessWidget {
  const DownloadProgress(this.download, {super.key});

  final UpdateDownload download;

  @override
  Widget build(BuildContext context) {
    final d = download;
    final speed = d.bytesPerSecond > 0
        ? ' · ${formatBytes(d.bytesPerSecond.round())}/s'
        : '';
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TuiText(
          d.checking
              ? 'Checking it against the release…'
              : '${formatBytes(d.done)} of ${formatBytes(d.total)}$speed',
          tone: TuiTextTone.muted,
          size: 11,
        ),
        const SizedBox(height: 12),
        TuiProgressBar(value: d.total > 0 ? d.done / d.total : 0),
      ],
    );
  }
}

/// Settings' view of [updateDownload]: the bar and Cancel while it comes
/// down, Restart to update once it is checked, why and Try again if it
/// failed.
class _DownloadRow extends StatelessWidget {
  const _DownloadRow(this.download);

  final UpdateDownload download;

  Future<void> _restart(BuildContext context) async {
    try {
      await restartToUpdate();
    } catch (error) {
      if (!context.mounted) return;
      showToast(
        context,
        '${_said(error)} It is in your Downloads instead.',
        type: TuiToastType.error,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = download;
    final version = d.update.version;
    Widget row(String text, List<Widget> actions) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TuiText(text),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: actions),
      ],
    );
    final Widget body = switch (d.phase) {
      DownloadPhase.downloading => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TuiText('Jeansh $version is downloading'),
          const SizedBox(height: 8),
          DownloadProgress(d),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: TuiButton(
              label: 'Cancel',
              variant: TuiButtonVariant.ghost,
              onPressed: cancelDownload,
            ),
          ),
        ],
      ),
      DownloadPhase.installing => const Row(
        children: [
          SizedBox(width: 16, height: 16, child: TuiSpinner()),
          SizedBox(width: 12),
          TuiText('Installing — Jeansh restarts when it is in place.'),
        ],
      ),
      DownloadPhase.ready when d.handOver == null => row(
        'Jeansh $version is downloaded and checked.',
        [
          TuiButton(
            label: 'Restart to update',
            prefix: '↻',
            onPressed: () => unawaited(_restart(context)),
          ),
        ],
      ),
      DownloadPhase.ready => row(
        'Jeansh $version was downloaded to ${d.file!.path}',
        [
          TuiButton(
            label: 'Open folder',
            variant: TuiButtonVariant.ghost,
            onPressed: () =>
                unawaited(launchUrl(Uri.file(d.file!.parent.path))),
          ),
        ],
      ),
      DownloadPhase.failed => row(
        'Jeansh $version did not download: ${d.error}',
        [TuiButton(label: 'Try again', prefix: '↻', onPressed: retryDownload)],
      ),
    };
    return Padding(padding: const EdgeInsets.only(bottom: 16), child: body);
  }
}
