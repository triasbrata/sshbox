import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:xterm2/xterm.dart';

import '../session/session_manager.dart' show SharedFile;

/// MainActivity's clipboard, which hands an image over as a file of ours
/// rather than as pixels over the channel.
const _android = MethodChannel('sshbox/share');

/// The biggest image a paste will send to the host.
///
/// ponytail: 20 MB, the file tab's own ceiling for a picture. Every
/// screenshot is a small fraction of it and a camera photo fits; a video
/// pasted by accident does not, and is refused before a byte of it is copied.
/// Raise it when somebody has a real image bigger than this.
const pasteImageLimit = 20 * 1024 * 1024;

/// A paste into a terminal, whichever way it was asked for.
///
/// A terminal is a byte stream and an image on the Android clipboard is a
/// `content://` URI, so there is nothing to send down the wire for it — and
/// a program running on the host cannot see the tablet's clipboard either.
/// The only thing it can be handed is a path to a file already on the host,
/// so the image goes up through [upload] — the paperclip's own path, which
/// puts it in `/tmp` and types the remote path at the prompt. Anything else
/// is text, pasted exactly as it always was, bracketed when the shell asked
/// for that.
///
/// A paste that finds nothing it can use says so rather than doing nothing:
/// silence is what made a paste from Chrome, whose picture could not be read,
/// look like a feature that was simply broken.
///
/// Throws a [PlatformException] whose message says why when an image is
/// there but cannot be taken: too big, or the app that holds it refusing.
Future<void> pasteIntoTerminal(
  Terminal terminal, {
  required Future<void> Function(SharedFile image) upload,
  void Function(String message)? onNothing,
}) async {
  final image = await clipboardImage();
  if (image != null) {
    await upload(image);
    return;
  }
  final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
  if (text != null && text.isNotEmpty) {
    terminal.paste(text);
    return;
  }
  onNothing?.call('Nothing on the clipboard a terminal can paste');
}

/// The image on the clipboard, copied into a file of the app's own, or null
/// when the clipboard holds none.
///
/// Android only: `Clipboard.getData` reads text and nothing else, and there
/// is nothing behind this channel anywhere else. MainActivity takes the copy
/// because SFTP cannot read a `content://` URI, and only the path crosses the
/// channel — the same shape a share arrives in, and for the same reason: a
/// picture sent over as bytes is what freezes the app.
Future<SharedFile?> clipboardImage() async {
  if (defaultTargetPlatform != TargetPlatform.android) return null;
  final file = await _android.invokeMapMethod<String, String>(
    'clipboardImage',
    pasteImageLimit,
  );
  if (file == null) return null;
  return (path: file['path']!, name: file['name']!);
}

/// An image the soft keyboard committed, written into a file of the app's own
/// so the upload can stream it like any other.
///
/// Gboard's clipboard strip inserts a picture this way rather than through
/// the clipboard — `InputConnection.commitContent`, which it offers only to a
/// field that said it takes images — and Flutter has already read the bytes
/// by the time they reach us. Null when what arrived is not an image.
///
/// One at a time: the directory is cleared first, the way the clipboard's own
/// copy is, so a paste never leaves a pile of pictures behind.
///
/// Throws a [PlatformException], as the clipboard's half does, when it is too
/// big — which here only saves the upload, the bytes having crossed already.
Future<SharedFile?> insertedImage(KeyboardInsertedContent content) async {
  final data = content.data;
  if (data == null || !content.mimeType.startsWith('image/')) return null;
  if (data.length > pasteImageLimit) {
    throw PlatformException(
      code: 'too_big',
      message: 'That image is bigger than ${pasteImageLimit ~/ (1024 * 1024)} '
          'MB — send it from the files drawer instead.',
    );
  }
  return writePastedImage(data, content.mimeType);
}

/// Where [insertedImage] puts its bytes, and what it calls them. Separate so
/// a test can drive it without a platform behind it.
@visibleForTesting
Future<SharedFile> writePastedImage(Uint8List data, String mimeType) async {
  final dir = Directory('${Directory.systemTemp.path}/pasted');
  if (dir.existsSync()) dir.deleteSync(recursive: true);
  dir.createSync(recursive: true);
  // The extension is what makes the file readable as a picture once it is on
  // the host, so it comes from what the keyboard said it is rather than from
  // a URI that may carry none.
  final kind = mimeType.substring('image/'.length).split(';').first;
  final name = 'pasted.${kind == 'jpeg' ? 'jpg' : kind}';
  final file = File('${dir.path}/$name');
  await file.writeAsBytes(data);
  return (path: file.path, name: name);
}
