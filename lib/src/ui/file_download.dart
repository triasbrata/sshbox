import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart' show FilePicker;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../files/file_browser.dart';
import '../files/transfers.dart';
import 'toast.dart';

/// MainActivity's save dialog, which takes a download as a file of ours
/// rather than as bytes over the channel, and opens what it saved.
const _android = MethodChannel('sshbox/share');

/// Whether a save dialog is up: MainActivity shows one at a time, so a
/// download whose bytes are in while another's is up waits for it.
///
/// ponytail: polled rather than queued, and so in no particular order. One
/// dialog is up at a time, and only for as long as it takes to pick a folder.
bool _saving = false;

/// Brings [path] down from [browser], byte for byte as [host] has it, and
/// hands it to the system's save dialog under its own name, as a transfer
/// the Transfers tab lists. The files drawer and a file tab both download
/// through here.
///
/// It lands in a file of the app's own first, a chunk at a time, and only
/// that file's path crosses to Android, which copies it into the document
/// picked there off the main thread. So nothing is held in memory, and no
/// size is refused but what the phone has room for twice over. The copy goes
/// again whatever happens, Cancel included.
///
/// [onTransfer] is handed the transfer while its bytes come down, and null
/// once they are in and the dialog takes over. [denied] stands in for the
/// host's words when the login may not read the file.
///
/// The news at the end goes through the app's navigator rather than
/// [context]'s page: the drawer or the tab may have been shut by then, and
/// the answer should not go with it. Cancel, or the dialog dismissed, says
/// nothing: the Transfers tab shows it.
Future<void> downloadFile(
  BuildContext context,
  FileBrowser browser,
  String path, {
  required String host,
  required void Function(Transfer? transfer) onTransfer,
  String? denied,
}) async {
  final app = Navigator.of(context, rootNavigator: true).context;
  void say(String message, ToastificationType type) {
    if (app.mounted) showToast(app, message, type: type);
  }

  final name = RemotePath.basename(path);
  try {
    await transfers.run(
      name: name,
      host: host,
      direction: TransferDirection.download,
      work: (transfer) async {
        // On Android, Flutter points systemTemp at the app's own code cache.
        final temp = Directory.systemTemp.createTempSync('download');
        final copy = '${temp.path}/file';
        try {
          onTransfer(transfer);
          await browser.download(
            path,
            copy,
            onProgress: transfer.report,
            cancel: transfer.cancelled,
          );
          onTransfer(null);
          // Not saved is the dialog dismissed, as good as Cancel.
          transfer.saved =
              await _saveAs(copy, name) ?? (throw FileBrowserException.cancelled);
        } finally {
          onTransfer(null);
          temp.deleteSync(recursive: true);
        }
      },
    );
    say('Saved $name', ToastificationType.success);
  } on FileBrowserException catch (error) {
    if (error.fault == FileBrowserFault.cancelled) return;
    final refused = error.fault == FileBrowserFault.permissionDenied;
    say(
      refused ? (denied ?? error.message) : error.message,
      ToastificationType.error,
    );
  } on PlatformException catch (error) {
    say(
      'Could not save $name: ${error.message ?? error.code}',
      ToastificationType.error,
    );
  }
}

/// Hands the app's [copy] to the save dialog as [name], in its turn: what it
/// was saved as, which [openDownload] opens, or null when the dialog was
/// dismissed.
Future<String?> _saveAs(String copy, String name) async {
  while (_saving) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  _saving = true;
  try {
    if (defaultTargetPlatform == TargetPlatform.android) {
      return await _android.invokeMethod<String>('saveAs', {
        'path': copy,
        'name': name,
      });
    }
    // ponytail: elsewhere file_picker still takes the whole file as bytes.
    // A native save like Android's lifts that.
    final saved = await FilePicker.saveFile(
      fileName: name,
      bytes: await File(copy).readAsBytes(),
    );
    return saved?.toString();
  } finally {
    _saving = false;
  }
}

/// Puts the image in the app's own file at [path] on the clipboard under
/// [name], so another app can paste it.
///
/// Android only: Flutter has no clipboard for pixels, and there is nothing
/// behind this channel anywhere else. MainActivity takes a copy of its own
/// that lasts as long as the clip does, so [path] may go whenever its owner
/// likes. Throws [PlatformException] when the phone refuses.
Future<void> copyImageToClipboard(String path, String name) =>
    _android.invokeMethod<void>('copyImage', {'path': path, 'name': name});

/// Opens a finished download, [saved] as [name], in whatever app the phone
/// has for its kind. False when none will.
Future<bool> openDownload(String saved, String name) async {
  try {
    return await _android.invokeMethod<bool>('open', {
          'uri': saved,
          'name': name,
        }) ??
        false;
  } on PlatformException {
    return false;
  } on MissingPluginException {
    return false;
  }
}

/// What is on its way up or down, and how far along it is, over the page
/// that started it. It follows [transfers] on its own, a few times a second,
/// and the page is built again only as the transfer starts and ends.
class TransferBar extends StatelessWidget {
  const TransferBar(this.transfer, {super.key, this.label});

  final Transfer transfer;

  /// What it says, where the page has more to say than the file's name.
  final String? label;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: transfers,
    builder: (context, _) {
      final fraction = transfer.fraction;
      final text =
          label ??
          '${transfer.direction == TransferDirection.download ? 'Downloading' : 'Uploading'} '
              '${transfer.name}';
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              fraction == null
                  ? text
                  : '$text  ${(fraction * 100).floor()}%',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 4),
            LinearProgressIndicator(value: fraction),
          ],
        ),
      );
    },
  );
}
