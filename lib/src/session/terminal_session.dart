import 'package:flutter/foundation.dart';

import '../data/secret_store.dart';
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

/// One entry in a remote directory.
class RemoteEntry {
  const RemoteEntry({
    required this.name,
    required this.path,
    required this.isDirectory,
    this.size,
  });

  final String name;

  /// Absolute, so opening an entry never depends on where the browser happens
  /// to be standing.
  final String path;

  final bool isDirectory;
  final int? size;
}

/// Optional capability: reading the remote filesystem.
///
/// This is what the files drawer lists and what a file tab shows. Like
/// uploading, it rides the session that has already authenticated — there is
/// no second connection.
abstract class FileBrowseCapable {
  /// Where browsing starts: the directory the user lands in on login.
  Future<String> homeDirectory();

  Future<List<RemoteEntry>> listDirectory(String path);

  /// Reads at most [maxBytes]. A phone has no business pulling a
  /// multi-gigabyte log into memory, so the caller says how much it will hold
  /// and the rest stays on the server.
  Future<Uint8List> readFile(String path, {required int maxBytes});
}

abstract class SessionTransport {
  Future<TerminalSession> connect({
    required HostProfile host,
    required SecretStore secrets,
    required int columns,
    required int rows,
  });
}
