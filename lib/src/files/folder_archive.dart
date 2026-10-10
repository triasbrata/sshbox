import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'file_browser.dart';

/// Which archiver the host has, in the order they are preferred.
enum ArchiveKind { zip, sevenZip, bsdtar, tarGz }

/// An archiver found on the host: what it is, and the path it was found at.
class ArchiveTool {
  const ArchiveTool(this.kind, this.binary);

  final ArchiveKind kind;

  /// Absolute path on the host, as `command -v` printed it.
  final String binary;

  /// `.zip`, or `.tar.gz` for the fallback, which is never called a zip.
  String get extension => kind == ArchiveKind.tarGz ? '.tar.gz' : '.zip';

  String get label => switch (kind) {
    ArchiveKind.zip => 'zip',
    ArchiveKind.sevenZip => '7z',
    ArchiveKind.bsdtar => 'bsdtar',
    ArchiveKind.tarGz => 'tar (.tar.gz)',
  };
}

/// What a script printed and how it ended.
typedef ScriptResult = ({int exitCode, String stdout, String stderr});

/// Runs [script] under `sh` on the host; completing [cancel] stops it, which
/// hangs the shell up so its own traps run.
typedef ScriptRunner = Future<ScriptResult> Function(
  String script, {
  Future<void>? cancel,
});

/// Optional capability: making an archive of a folder on the host itself and
/// handing back where it is, to be brought down with [FileBrowser.download].
abstract class FolderArchiveCapable {
  /// The first archiver the host has, or null when it has none. Also sweeps
  /// this login's own leftovers from an earlier run.
  Future<ArchiveTool?> findArchiveTool();

  /// Archives [folder] with [tool] into a private folder on the host and
  /// returns the archive's path and size. [cancel] stops it and removes
  /// everything it made.
  Future<({String path, int size})> archiveFolder(
    String folder,
    ArchiveTool tool, {
    Future<void>? cancel,
  });

  /// Removes what [archiveFolder] made, best effort.
  Future<void> removeArchive(String archivePath);
}

/// The scripts, and what is read back from them. One implementation over a
/// [ScriptRunner], shared by the SFTP and the local browsers.
class FolderArchiver implements FolderArchiveCapable {
  FolderArchiver(this._run);

  final ScriptRunner _run;

  static String _q(String value) => "'${value.replaceAll("'", r"'\''")}'";

  /// A non-login shell's PATH leaves out Homebrew and friends.
  static const _path =
      r'PATH="$PATH:/usr/local/bin:/opt/homebrew/bin:/opt/local/bin:'
      r'$HOME/.local/bin:$HOME/.nix-profile/bin:/snap/bin"; export PATH';

  /// Removes this login's own `jeansh-zip.*` folders older than an hour,
  /// where an app that died mid-way left them. Only a real folder (a link
  /// is a link to find, and is never matched), only directly under the temp
  /// folder, and only this user's.
  static const sweepScript =
      r'''find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name 'jeansh-zip.*' '''
      r'''-user "$(id -un)" -mmin +60 -exec rm -rf {} + 2>/dev/null''';

  /// Prints `kind=path` for each archiver there is. Runs nothing of theirs.
  static final probeScript =
      '$_path\n'
      '$sweepScript\n'
      'for t in zip 7zz 7z 7za bsdtar tar gzip; do\n'
      '  p=\$(command -v "\$t" 2>/dev/null) && [ -n "\$p" ] && '
      'printf "%s=%s\\n" "\$t" "\$p"\n'
      'done; true';

  /// The best tool in a probe's [output], or null. `tar` counts only with
  /// `gzip` beside it.
  static ArchiveTool? parseProbe(String output) {
    final found = <String, String>{};
    for (final line in const LineSplitter().convert(output)) {
      final at = line.indexOf('=');
      if (at <= 0) continue;
      final path = line.substring(at + 1);
      if (!path.startsWith('/')) continue;
      found[line.substring(0, at)] = path;
    }
    final zip = found['zip'];
    if (zip != null) return ArchiveTool(ArchiveKind.zip, zip);
    for (final name in const ['7zz', '7z', '7za']) {
      final seven = found[name];
      if (seven != null) return ArchiveTool(ArchiveKind.sevenZip, seven);
    }
    final bsdtar = found['bsdtar'];
    if (bsdtar != null) return ArchiveTool(ArchiveKind.bsdtar, bsdtar);
    final tar = found['tar'];
    if (tar != null && found.containsKey('gzip')) {
      return ArchiveTool(ArchiveKind.tarGz, tar);
    }
    return null;
  }

  /// The folder's parent and its own name, or null for `/`.
  static (String parent, String base)? split(String folder) {
    final trimmed = folder.length > 1 && folder.endsWith('/')
        ? folder.substring(0, folder.length - 1)
        : folder;
    final at = trimmed.lastIndexOf('/');
    if (at < 0 || trimmed.substring(at + 1).isEmpty) return null;
    final base = trimmed.substring(at + 1);
    if (base == '.' || base == '..') return null;
    return (at == 0 ? '/' : trimmed.substring(0, at), base);
  }

  /// The script that archives [folder]. The folder's name is only ever an
  /// argument, after `./` or `--`, and the archive's own name is fixed, so
  /// nothing a name holds is read as an option, a pattern or a command.
  static String archiveScript(String folder, ArchiveTool tool) {
    final (parent, base) = split(folder)!;
    final out = 'jeansh${tool.extension}';
    final name = _q('./$base');
    final bin = _q(tool.binary);
    final command = switch (tool.kind) {
      // -y keeps a link a link, rather than archiving what it points at.
      ArchiveKind.zip => '$bin -qry -nw "\$d/$out" $name',
      // -spd: no wildcards in names. -snl: links stay links.
      ArchiveKind.sevenZip =>
        '$bin a -tzip -bd -bso0 -bsp0 -spd -snl -- "\$d/$out" $name',
      ArchiveKind.bsdtar => '$bin --format zip -cf "\$d/$out" -- $name',
      ArchiveKind.tarGz => '$bin -czf "\$d/$out" -- $name',
    };
    return '$_path\n'
        'umask 077\n'
        r'd=$(mktemp -d "${TMPDIR:-/tmp}/jeansh-zip.XXXXXX") || '
        '{ echo "could not make a private folder for the archive" >&2; '
        'exit 70; }\n'
        'ok=0; pid=\n'
        r'''trap 'kill "$pid" 2>/dev/null; [ "$ok" = 1 ] || rm -rf "$d"' EXIT'''
        '\n'
        'trap "exit 129" HUP; trap "exit 130" INT; trap "exit 143" TERM\n'
        'cd -- ${_q(parent)} || exit 71\n'
        '$command &\n'
        'pid=\$!; wait "\$pid"; rc=\$?; [ "\$rc" -eq 0 ] || exit "\$rc"\n'
        'if [ ! -s "\$d/$out" ]; then echo "the archive came out empty" >&2; '
        'exit 72; fi\n'
        'ok=1\n'
        'printf "%s\\n%s\\n" "\$d/$out" "\$(wc -c < "\$d/$out" | tr -d " ")"';
  }

  static final _archivePath = RegExp(
    r'^/(?:[^/]+/)*jeansh-zip\.[A-Za-z0-9]+/jeansh\.(?:zip|tar\.gz)$',
  );

  /// Removes the archive's folder, and refuses any path that is not one.
  static String? removeScript(String archivePath) {
    if (!_archivePath.hasMatch(archivePath)) return null;
    final dir = archivePath.substring(0, archivePath.lastIndexOf('/'));
    return 'rm -rf -- ${_q(dir)}';
  }

  /// A line fit to show of what a failing tool said.
  static String oneLine(String text) {
    final lines = const LineSplitter()
        .convert(text.replaceAll(RegExp(r'[\x00-\x08\x0b-\x1f\x7f]'), ' '))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
    final tail = lines.length > 3 ? lines.sublist(lines.length - 3) : lines;
    final joined = tail.join(' · ');
    return joined.length > 300 ? '${joined.substring(0, 300)}…' : joined;
  }

  @override
  Future<ArchiveTool?> findArchiveTool() async {
    final ScriptResult result;
    try {
      result = await _run(probeScript);
    } catch (error) {
      throw FileBrowserException(
        'Could not look for a zip tool on the host: $error',
        fault: FileBrowserFault.disconnected,
      );
    }
    return parseProbe(result.stdout);
  }

  @override
  Future<({String path, int size})> archiveFolder(
    String folder,
    ArchiveTool tool, {
    Future<void>? cancel,
  }) async {
    if (split(folder) == null) {
      throw const FileBrowserException(
        'This folder cannot be archived as it is; open a folder inside it.',
      );
    }
    var stopped = false;
    unawaited(cancel?.then((_) => stopped = true));
    final ScriptResult result;
    try {
      result = await _run(archiveScript(folder, tool), cancel: cancel);
    } catch (error) {
      if (stopped) throw FileBrowserException.cancelled;
      if (error is FileBrowserException) rethrow;
      throw FileBrowserException(
        'Could not start ${tool.label} on the host: $error',
        fault: FileBrowserFault.disconnected,
      );
    }
    if (stopped) throw FileBrowserException.cancelled;
    if (result.exitCode != 0) {
      final said = oneLine(result.stderr);
      throw FileBrowserException(
        '${tool.label} failed on the host (exit ${result.exitCode})'
        '${said.isEmpty ? '' : ': $said'}',
        fault: result.exitCode == 126 || result.exitCode == 127
            ? FileBrowserFault.unsupported
            : FileBrowserFault.unknown,
      );
    }
    final lines = const LineSplitter().convert(result.stdout);
    final path = lines.length < 2 ? '' : lines[lines.length - 2];
    final size = lines.length < 2 ? 0 : int.tryParse(lines.last) ?? 0;
    if (!_archivePath.hasMatch(path) || size <= 0) {
      throw const FileBrowserException(
        'The host made no archive, though its tool said nothing was wrong.',
      );
    }
    return (path: path, size: size);
  }

  @override
  Future<void> removeArchive(String archivePath) async {
    final script = removeScript(archivePath);
    if (script == null) return;
    try {
      await _run(script);
    } catch (_) {
      // Best effort: the sweep at the next probe is the backstop.
    }
  }
}

/// A [ScriptRunner] over a started `sh -c` process.
ScriptRunner processRunner(Future<Process> Function(String command) start) =>
    (script, {cancel}) async {
      final process = await start(script);
      var stopped = false;
      unawaited(
        cancel?.then((_) {
          stopped = true;
          process.kill();
        }),
      );
      final out = process.stdout.transform(utf8.decoder).join();
      final err = process.stderr.transform(utf8.decoder).join();
      final code = await process.exitCode;
      final result = (
        exitCode: stopped ? 143 : code,
        stdout: await out,
        stderr: await err,
      );
      return result;
    };
