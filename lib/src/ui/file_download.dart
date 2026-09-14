import 'dart:io';

import 'package:file_picker/file_picker.dart' show FilePicker;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../files/file_browser.dart';
import 'toast.dart';

/// MainActivity's save dialog, which takes a download as a file of ours
/// rather than as bytes over the channel.
const _android = MethodChannel('sshbox/share');

/// Brings [path] down from [browser], byte for byte as the host has it, and
/// hands it to the system's save dialog under its own name. The files drawer
/// and a file tab both download through here.
///
/// It lands in a file of the app's own first, a chunk at a time, and only
/// that file's path crosses to Android, which copies it into the document
/// picked there off the main thread. So nothing is held in memory, and no
/// size is refused but what the phone has room for twice over. The copy goes
/// again whatever happens.
///
/// [onTransfer] is told how far along it is, and null once the bytes are in
/// and the dialog takes over. [denied] stands in for the host's words when
/// the login may not read the file.
///
/// The news at the end goes through the app's navigator rather than
/// [context]'s page: the drawer or the tab may have been shut by then, and
/// the answer should not go with it.
Future<void> downloadFile(
  BuildContext context,
  FileBrowser browser,
  String path, {
  required void Function(({String label, double? progress})? transfer)
      onTransfer,
  String? denied,
}) async {
  final app = Navigator.of(context, rootNavigator: true).context;
  void say(String message, ToastificationType type) {
    if (app.mounted) showToast(app, message, type: type);
  }

  final name = RemotePath.basename(path);
  final label = 'Downloading $name';
  onTransfer((label: label, progress: null));
  // On Android, Flutter points systemTemp at the app's own code cache.
  final temp = Directory.systemTemp.createTempSync('download');
  final copy = '${temp.path}/file';
  try {
    var shown = -1;
    await browser.download(
      path,
      copy,
      // A rebuild of the page per percent, rather than per packet.
      onProgress: (done, total) {
        final percent = total > 0 ? done * 100 ~/ total : -1;
        if (percent == shown) return;
        shown = percent;
        onTransfer((label: label, progress: percent / 100));
      },
    );
    onTransfer(null);
    final saved = defaultTargetPlatform == TargetPlatform.android
        ? await _android.invokeMethod<bool>(
              'saveAs',
              {'path': copy, 'name': name},
            ) ==
            true
        // ponytail: elsewhere file_picker still takes the whole file as
        // bytes. A native save like Android's lifts that.
        : await FilePicker.saveFile(
              fileName: name,
              bytes: await File(copy).readAsBytes(),
            ) !=
            null;
    // Not saved is the dialog dismissed, which says enough on its own.
    if (saved) say('Saved $name', ToastificationType.success);
  } on FileBrowserException catch (error) {
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
  } finally {
    onTransfer(null);
    temp.deleteSync(recursive: true);
  }
}

/// What is on its way up or down, and how far along it is.
class TransferBar extends StatelessWidget {
  const TransferBar(this.transfer, {super.key});

  final ({String label, double? progress}) transfer;

  @override
  Widget build(BuildContext context) {
    final progress = transfer.progress;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            progress == null
                ? transfer.label
                : '${transfer.label}  ${(progress * 100).floor()}%',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 4),
          LinearProgressIndicator(value: progress),
        ],
      ),
    );
  }
}
