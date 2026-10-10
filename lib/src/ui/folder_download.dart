import 'dart:async';
import 'dart:io';

import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';

import '../files/file_browser.dart';
import '../files/folder_archive.dart';
import '../files/folder_plan.dart';
import '../files/transfers.dart';
import 'file_download.dart';
import 'toast.dart';
import 'tui.dart';

/// Whether [browser] can compress a folder on its host: the menu offers
/// Download as zip only then.
bool canArchive(FileBrowser browser) => browser is FolderArchiveCapable;

/// Compresses [folder] on the host with a tool the host has, then brings the
/// archive down and saves it through the same dialog a file goes through.
///
/// With no tool on the host it says so, and offers [onPlain] (a plain
/// download of the tree) where the platform has one. Never silent: every way
/// this fails is a toast or the Transfers row.
Future<void> downloadFolderAsArchive(
  BuildContext context,
  FileBrowser browser,
  String folder, {
  required String host,
  required void Function(Transfer? transfer) onTransfer,
  VoidCallback? onPlain,
}) async {
  final app = Navigator.of(context, rootNavigator: true).context;
  final archiver = browser as FolderArchiveCapable;
  final base = RemotePath.basename(folder);
  final ArchiveTool? tool;
  try {
    tool = await archiver.findArchiveTool();
  } on FileBrowserException catch (error) {
    if (app.mounted) showToast(app, error.message, type: TuiToastType.error);
    return;
  }
  if (!app.mounted) return;
  if (tool == null) {
    await _noTool(app, host, onPlain);
    return;
  }
  String? made;
  await downloadFile(
    context,
    browser,
    folder,
    host: host,
    onTransfer: onTransfer,
    name: '$base${tool.extension}',
    prepare: (transfer) async {
      transfer.setPhase('Compressing with ${tool!.label}');
      final archive = await archiver.archiveFolder(
        folder,
        tool,
        cancel: transfer.cancelled,
      );
      made = archive.path;
      transfer.setPhase(null);
      return archive.path;
    },
    cleanup: () async {
      final path = made;
      if (path != null) await archiver.removeArchive(path);
    },
  );
}

Future<void> _noTool(BuildContext app, String host, VoidCallback? onPlain) =>
    showDialog<void>(
      context: app,
      builder: (context) => TuiDialog(
        title: 'download as zip',
        message: 'No zip tool on $host',
        detail:
            'Looked for zip, 7z, bsdtar and tar with gzip, and found '
            'none. Install one on the host to compress a folder there'
            '${onPlain == null ? '.' : ', or download the folder as it is.'}',
        actions: [
          TuiButton(
            label: onPlain == null ? 'OK' : 'Cancel',
            logName: 'Close',
            variant: TuiButtonVariant.ghost,
            onPressed: () => Navigator.of(context).pop(),
          ),
          if (onPlain != null)
            TuiButton(
              label: 'Plain download',
              logName: 'Plain download',
              onPressed: () {
                Navigator.of(context).pop();
                onPlain();
              },
            ),
        ],
      ),
    );

/// Downloads [folder] as its tree: every regular file under it, one transfer
/// row with the bytes of all of them, into a folder picked on this computer.
/// Desktop only; Android has no folder to put it in.
///
/// Links and special files are skipped and said so, a file that fails does
/// not stop the rest and is listed at the end, and the tree goes into a part
/// folder that is renamed to its name only once it is in.
Future<void> downloadFolderPlain(
  BuildContext context,
  FileBrowser browser,
  String folder, {
  required String host,
  required void Function(Transfer? transfer) onTransfer,
}) async {
  final app = Navigator.of(context, rootNavigator: true).context;
  void say(String message, TuiToastType type) {
    if (app.mounted) showToast(app, message, type: type);
  }

  final base = RemotePath.basename(folder);
  if (base == '/' || base.isEmpty) {
    say('Open a folder inside the root to download it.', TuiToastType.warning);
    return;
  }
  final String? destination;
  try {
    destination = await FileSelectorPlatform.instance
        .getDirectoryPathWithOptions(
          const FileDialogOptions(confirmButtonText: 'Save here'),
        );
  } catch (error) {
    say('Could not open the folder picker: $error', TuiToastType.error);
    return;
  }
  if (destination == null) return;

  FolderPlan? plan;
  final failed = <String>[];
  var saved = 0;
  try {
    await transfers.run(
      name: base,
      host: host,
      direction: TransferDirection.download,
      work: (transfer) async {
        onTransfer(transfer);
        try {
          transfer.setPhase('Counting files');
          final found = plan = await planFolder(
            browser,
            folder,
            cancel: transfer.cancelled,
          );
          transfer.setPhase(null);
          if (found.large) {
            final go =
                app.mounted &&
                await showTuiConfirmDialog(
                  app,
                  title: 'large folder',
                  message:
                      '${found.files.length} files, '
                      '${formatBytes(found.totalBytes)}',
                  detail:
                      'That is a lot to bring down one file at a time. '
                      'Download as zip is faster where the host can '
                      'compress.',
                  confirmLabel: 'Download',
                  cancelLabel: 'Cancel',
                  confirmVariant: TuiButtonVariant.primary,
                );
            if (!go) throw FileBrowserException.cancelled;
          }
          if (!app.mounted) throw FileBrowserException.cancelled;
          saved = await _fetchTree(
            browser,
            found,
            destination!,
            base,
            transfer,
            failed,
            app,
          );
        } finally {
          onTransfer(null);
        }
      },
    );
  } on FileBrowserException catch (error) {
    if (error.fault == FileBrowserFault.cancelled) return;
    say(error.message, TuiToastType.error);
    return;
  } on FileSystemException catch (error) {
    say(
      'Could not save $base: ${error.osError?.message ?? error.message}',
      TuiToastType.error,
    );
    return;
  } catch (error) {
    say('Could not save $base: $error', TuiToastType.error);
    return;
  }
  final skipped = plan?.skipped ?? const <String>[];
  final unreadable = plan?.unreadable ?? const <String>[];
  if (failed.isEmpty && skipped.isEmpty && unreadable.isEmpty) {
    say('Saved $base', TuiToastType.success);
    return;
  }
  say(
    'Saved $saved files of $base: ${failed.length + unreadable.length} '
    'failed, ${skipped.length} skipped',
    TuiToastType.warning,
  );
  if (app.mounted) {
    await showDialog<void>(
      context: app,
      builder: (context) => TuiDialog(
        title: 'download folder',
        message: 'Saved $saved files; some were not',
        detail: _list(failed: [...failed, ...unreadable], skipped: skipped),
        actions: [
          TuiButton(
            label: 'OK',
            logName: 'Close',
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }
}

/// The failures and the skipped, a few of each, for a dialog.
@visibleForTesting
String folderReport({
  required List<String> failed,
  required List<String> skipped,
}) => _list(failed: failed, skipped: skipped);

String _list({required List<String> failed, required List<String> skipped}) {
  String some(List<String> items) =>
      items.take(15).join('\n') +
      (items.length > 15 ? '\n… and ${items.length - 15} more' : '');
  return [
    if (failed.isNotEmpty) 'Failed:\n${some(failed)}',
    if (skipped.isNotEmpty) 'Skipped, never followed:\n${some(skipped)}',
  ].join('\n\n');
}

/// Fetches [plan] into a part folder under [destination] and renames it to
/// [base]. Returns how many files are in.
Future<int> _fetchTree(
  FileBrowser browser,
  FolderPlan plan,
  String destination,
  String base,
  Transfer transfer,
  List<String> failed,
  BuildContext app,
) async {
  final sep = Platform.pathSeparator;
  final target = '$destination$sep$base';
  if (FileSystemEntity.typeSync(target, followLinks: false) !=
      FileSystemEntityType.notFound) {
    final replace =
        app.mounted &&
        await showTuiConfirmDialog(
          app,
          title: 'replace folder',
          message: 'Replace $base?',
          detail: '$target is there already.',
          confirmLabel: 'Replace',
          cancelLabel: 'Cancel',
        );
    if (!replace) throw FileBrowserException.cancelled;
  }
  final part = Directory(destination).createTempSync('.jeansh-part-');
  try {
    final root = '${part.path}$sep$base';
    Directory(root).createSync();
    for (final folder in plan.folders) {
      Directory('$root$sep${folder.replaceAll('/', sep)}')
          .createSync(recursive: true);
    }
    final total = plan.totalBytes;
    var before = 0;
    var saved = 0;
    for (final file in plan.files) {
      final local = '$root$sep${file.rel.replaceAll('/', sep)}';
      try {
        Directory(File(local).parent.path).createSync(recursive: true);
        await browser.download(
          file.remote,
          local,
          onProgress: (received, _) =>
              transfer.report(before + received, total),
          cancel: transfer.cancelled,
        );
        saved++;
      } on FileBrowserException catch (error) {
        if (error.fault == FileBrowserFault.cancelled) rethrow;
        failed.add('${file.rel}: ${error.message}');
      } on FileSystemException catch (error) {
        failed.add('${file.rel}: ${error.osError?.message ?? error.message}');
      }
      before += file.size;
      transfer.report(before, total);
    }
    if (plan.files.isNotEmpty && saved == 0) {
      throw FileBrowserException('No file came down. ${failed.first}');
    }
    if (Platform.isWindows) {
      // As a single download is: a file from a host is marked as from the
      // internet, so Windows warns before running one.
      for (final file in plan.files) {
        try {
          File('$root$sep${file.rel.replaceAll('/', sep)}:Zone.Identifier')
              .writeAsStringSync('[ZoneTransfer]\r\nZoneId=3\r\n');
        } on FileSystemException {
          // A drive with no streams.
        }
      }
    }
    final old = Directory(target);
    if (old.existsSync()) old.deleteSync(recursive: true);
    Directory(root).renameSync(target);
    transfer.saved = Uri.directory(target).toString();
    transfer.note = failed.isEmpty && plan.skipped.isEmpty
        ? '$saved files'
        : '$saved files, ${failed.length} failed, ${plan.skipped.length} skipped';
    return saved;
  } finally {
    try {
      part.deleteSync(recursive: true);
    } on FileSystemException {
      // Left behind rather than failing a save that went in.
    }
  }
}
