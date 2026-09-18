import 'dart:async';

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
  /// absolute remote path, ready to be typed into the shell. [cancel]
  /// completing stops it part way, and what was sent goes.
  Future<String> uploadToTmp({
    required String localPath,
    required String fileName,
    void Function(int sent, int total)? onProgress,
    Future<void>? cancel,
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

/// Optional capability: running a command on the host beside the shell,
/// without typing it into the shell.
///
/// What putting ports on the tailnet needs — see `TailnetForwarder`. A
/// transport that carries only a terminal, as mosh does, cannot offer it.
abstract class CommandCapable {
  /// Starts [command] when listened to and hands back its output a line at a
  /// time; the stream ends when the command does. Cancelling the subscription
  /// closes its channel.
  ///
  /// [pty] gives it a terminal, which is what makes that hang up a command
  /// that never writes, under OpenSSH: without one the host only closes its
  /// pipes, and a process that is not writing never notices. Tailscale SSH
  /// hangs up neither until the connection goes, so such a command has to be
  /// ended some other way.
  Stream<String> run(String command, {bool pty = false});
}

/// A command started by [ChannelCapable.open]: its output as the bytes it
/// wrote, its stdin, and a way to end it.
typedef CommandChannel = ({
  Stream<Uint8List> output,
  void Function(Uint8List data) write,
  void Function() close,
});

/// Optional capability: a command on the host that is talked to as well as
/// listened to, in raw bytes both ways.
///
/// What tmux's control mode needs — see `TmuxSession`. Apart from
/// [CommandCapable], whose line-at-a-time decoded output would mangle a
/// protocol that frames its own lines and carries UTF-8 split across them.
abstract class ChannelCapable {
  /// No pty: nothing on the way should turn `\n` into `\r\n` or read a
  /// control byte as a signal. [CommandChannel.close] ends the command.
  Future<CommandChannel> open(String command);
}

/// Optional capability: a command on the host with a terminal of its own,
/// talked to and listened to in raw bytes, both ways.
///
/// For a program that will not run without one, as `claude attach` will not.
/// Apart from [ChannelCapable], whose promise is the opposite — no pty, so
/// nothing on the way turns `\n` into `\r\n` or reads a byte as a signal —
/// and which the terminal, tmux and the chat's own Claude rely on.
abstract class TerminalChannelCapable {
  /// A pty of [columns] by [rows]. [CommandChannel.close] hangs it up, which
  /// ends what it was running.
  Future<CommandChannel> openTerminal(
    String command, {
    int columns = 120,
    int rows = 40,
  });
}

/// A TCP connection through the host — one [ForwardCapable.forward] made
/// from it, or one made to a port it listens on for us: the bytes the far
/// end sends, and a sink for ours whose close says we are done.
typedef Tunnel = ({Stream<Uint8List> output, StreamSink<List<int>> input});

/// A port the host listens on for us — see [ForwardCapable.listen]: the port
/// it listens on, the one it picked when asked for port 0, each connection
/// made to it, and a way to stop listening.
typedef RemotePort = ({
  int port,
  Stream<Tunnel> connections,
  void Function() close,
});

/// Optional capability: TCP connections through the host, as `ssh -L` and
/// `ssh -R` make them — what `LocalForwarder` pipes a port on the tablet
/// into, and `RemoteForwarder` pipes a port on the host out of.
abstract class ForwardCapable {
  /// Connects to [host]:[port] as the host reaches it. Throws, with the
  /// host's reason, when it cannot.
  Future<Tunnel> forward(String host, int port);

  /// Asks the host to listen on [host]:[port], and hand over each
  /// connection made there. Throws, with a reason, when it will not.
  Future<RemotePort> listen(String host, int port);
}

abstract class SessionTransport {
  /// [shell] false connects without starting one, for a session whose
  /// terminals come from somewhere else — tmux's panes, over
  /// [ChannelCapable.open]. The session then stays up for as long as the
  /// connection does, and its own output, input and size go nowhere.
  ///
  /// [environment] goes with the shell, and with each command
  /// [ChannelCapable.open] starts, for the programs there to read. A host
  /// may refuse it, which costs the variables, never the connection.
  ///
  /// [beforeShell] is called once the host has let us in, before the shell
  /// or any command starts, with the connection to listen on, and what it
  /// returns joins [environment]. It answers for its own failures: it hands
  /// back nothing rather than throw.
  Future<TerminalSession> connect({
    required HostProfile host,
    required SecretStore secrets,
    required int columns,
    required int rows,
    bool shell = true,
    Map<String, String> environment = const {},
    Future<Map<String, String>> Function(ForwardCapable host)? beforeShell,
  });
}
