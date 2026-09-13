import 'package:file_picker/file_picker.dart' show FilePicker;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../files/file_browser.dart';
import 'toast.dart';

/// The most a download takes. The phone's save dialog wants the whole file
/// at once (file_picker's saveFile takes bytes, not a stream), so it is
/// held in memory here and again on Android's Java side, whose heap is
/// often capped at 256 MB.
///
/// ponytail: a cap, not a stream. A save that takes a stream into a SAF
/// document lifts it.
const _downloadLimit = 100 * 1024 * 1024;

/// Brings [path] down from [browser], byte for byte as the host has it, and
/// hands it to the system's save dialog under its own name. The files drawer
/// and a file tab both download through here.
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
  try {
    final bytes = await browser.readBytes(
      path,
      maxBytes: _downloadLimit,
      onProgress: (done, total) => onTransfer(
        (label: label, progress: total > 0 ? done / total : null),
      ),
    );
    onTransfer(null);
    final saved = await FilePicker.saveFile(fileName: name, bytes: bytes);
    // Null is the dialog dismissed, which says enough on its own.
    if (saved != null) say('Saved $name', ToastificationType.success);
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
