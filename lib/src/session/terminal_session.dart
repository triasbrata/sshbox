import 'package:flutter/foundation.dart';

import '../data/secret_store.dart';
import '../files/file_browser.dart';
import '../models/host_profile.dart';

enum SessionStatus { connecting, connected, closed, failed }

/// Failures we can put in front of the user as a single readable line.
class SshSessionException implements Exception {
  const SshSessionException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// A live interactive shell, described without mentioning SSH anywhere.
///
/// This is the seam that keeps mosh reachable later. The terminal UI talks
/// only to this interface, so adding mosh means writing one more
/// [SessionTransport] and changing the line that picks it — no widget has to
/// learn which protocol carried the bytes.
abstract class TerminalSession {
  /// Decoded remote output, ready to hand straight to the terminal.
  Stream<String> get output;

  ValueListenable<SessionStatus> get status;

  /// Why we are in [SessionStatus.failed], in words a user can act on.
  String? get failure;

  /// Keystrokes heading to the remote end.
  void send(String data);

  void resize(int columns, int rows, int pixelWidth, int pixelHeight);

  Future<void> dispose();
}

/// Optional capability, probed for rather than assumed.
///
/// Not every transport can move files — mosh, the obvious future one, cannot.
/// Keeping this separate from [TerminalSession] means the UI has to ask, and
/// a transport that lacks it simply does not implement it.
abstract class FileUploadCapable {
  /// Uploads a local file into `/tmp` on the remote host and returns the
  /// absolute remote path, ready to be typed into the shell.
  Future<String> uploadToTmp({
    required String localPath,
    required String fileName,
    void Function(int sent, int total)? onProgress,
  });
}

/// Optional capability: reading and writing files on the remote host.
///
/// Kept apart from [FileUploadCapable] because they are different promises.
/// Uploading is one shot into `/tmp` and any transport that can move bytes can
/// do it; browsing is a filesystem the user navigates, and a transport either
/// exposes one or does not.
abstract class FileBrowseCapable {
  /// Opens a browser bound to this session.
  ///
  /// The caller owns the result and must [FileBrowser.close] it — one browser
  /// per page, closed when that page goes away.
  FileBrowser openFileBrowser();
}

/// A listener on the device that tunnels to a port on the remote host.
class LocalPortForward {
  LocalPortForward({required this.localPort, required this.close});

  /// Port on the device. Point a WebView or HTTP client at
  /// `http://127.0.0.1:<localPort>`.
  final int localPort;

  /// Tears the listener down and drops any sockets still open through it.
  final Future<void> Function() close;
}

/// Optional capability: tunnelling a remote port to the device.
///
/// This is what lets code-server stay bound to loopback on the server. Nothing
/// is exposed to the network; the only route in is a session that has already
/// authenticated.
abstract class PortForwardCapable {
  Future<LocalPortForward> forwardLocalPort({
    required String remoteHost,
    required int remotePort,
  });
}

abstract class SessionTransport {
  Future<TerminalSession> connect({
    required HostProfile host,
    required SecretStore secrets,
    required int columns,
    required int rows,
  });
}
