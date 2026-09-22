import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive.dart';

// Plain dart:io and the archive package, nothing of Flutter's: so the same
// file runs under a bare Dart VM, which is how its Windows half is tried on
// Windows itself.

/// Anything the updater has to say for itself, in a line fit to show.
class UpdateException implements Exception {
  const UpdateException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// What an update beside the install is called while it is unpacked: a folder
/// made new each time, which is also how what an update left behind is found
/// again at the next start (see [Install.cleanUp]).
const stagePrefix = '.jeansh-update-';

/// Where this copy of Jeansh is installed: the folder a desktop build unpacks
/// to on Linux and Windows, and the .app on macOS. An update replaces it
/// whole, under the same name, so a launcher or a shortcut pointing at it
/// keeps working.
class Install {
  Install(this.platform, this.root);

  /// `linux`, `windows` or `macos`, as the feed names them.
  final String platform;
  final Directory root;

  /// Where [executable] — `Platform.resolvedExecutable` — says this copy is
  /// installed, or null when it is not laid out the way a release unpacks,
  /// in which case nothing should replace it.
  static Install? of(String executable, String platform) {
    final program = File(executable);
    final name = _name(executable);
    switch (platform) {
      case 'linux' when name == 'jeansh':
        return Install(platform, program.parent);
      case 'windows' when name.toLowerCase() == 'jeansh.exe':
        return Install(platform, program.parent);
      case 'macos':
        final contents = program.parent.parent;
        final app = contents.parent;
        if (_name(program.parent.path) == 'MacOS' &&
            _name(contents.path) == 'Contents' &&
            app.path.endsWith('.app')) {
          return Install(platform, app);
        }
    }
    return null;
  }

  /// The program inside a build's own folder.
  String get program => switch (platform) {
    'windows' => 'Jeansh.exe',
    'macos' => 'Contents/MacOS/Jeansh',
    _ => 'jeansh',
  };

  static String get _sep => Platform.pathSeparator;

  /// Why this copy cannot replace itself, or null if it can. The update is
  /// unpacked beside it, so the folder it sits in has to take a new folder:
  /// one installed by root under /opt, in Program Files or in another user's
  /// /Applications does not.
  String? get refusal {
    try {
      root.parent.createTempSync(stagePrefix).deleteSync();
      return null;
    } on FileSystemException {
      return _unwritable;
    }
  }

  String get _unwritable =>
      'Jeansh cannot write to ${root.parent.path}, where it is installed, '
      'so it cannot replace itself.';

  /// Unpacks [archive] — which the updater has already held to the feed's
  /// SHA-256 — into a folder of its own beside [root], and checks what came
  /// out. Gives back the new build's own folder. Nothing of this copy is
  /// touched: that is [handOff]'s helper, once this copy has quit.
  ///
  /// Throws [UpdateException], with everything it made removed.
  Future<Directory> stage(File archive) async {
    final Directory stage;
    try {
      stage = root.parent.createTempSync(stagePrefix);
    } on FileSystemException {
      throw UpdateException(_unwritable);
    }
    try {
      final path = archive.path;
      final kind = platform;
      // Off this isolate: a tarball is read whole and gunzipped to be
      // checked, which would hold the frames for the better part of a second.
      final top = await Isolate.run(() => checkArchive(path, kind));
      final into = Directory('${stage.path}${_sep}new')..createSync();
      final (tool, args) = switch (platform) {
        // Each tool by its full path where one is fixed. On Windows it
        // matters: a bare name is looked for in this program's own folder
        // before System32.
        'windows' => (
          '${Platform.environment['SystemRoot'] ?? r'C:\Windows'}'
              r'\System32\tar.exe',
          ['-xf', path, '-C', into.path],
        ),
        // ditto rather than unzip: it puts back the framework links and the
        // extended attributes the app's signature covers.
        'macos' => ('/usr/bin/ditto', ['-x', '-k', path, into.path]),
        _ => ('tar', ['-xzf', path, '-C', into.path]),
      };
      final ProcessResult result;
      try {
        result = await Process.run(tool, args);
      } on ProcessException catch (error) {
        throw UpdateException('Could not unpack the update: ${error.message}');
      }
      if (result.exitCode != 0) {
        final said = '${result.stderr}'.trim().split('\n').last;
        throw UpdateException('Could not unpack the update: $said');
      }
      return checkUnpacked(into, top, platform, program);
    } catch (error) {
      _delete(stage);
      if (error is UpdateException) rethrow;
      throw UpdateException('Could not unpack the update: $error');
    }
  }

  /// Starts the helper that swaps [staged] in for this copy once this copy
  /// has quit, and then starts it — [posixHelper], or [windowsHelper] — and
  /// returns once the helper says it is running. This copy must then quit,
  /// which the helper waits for.
  ///
  /// Throws [UpdateException] if the helper never says so, with [staged]'s
  /// folder and the helper's removed, which also calls off a helper that
  /// starts late.
  Future<void> handOff(
    Directory staged, {
    int? processId,
    Duration wait = const Duration(seconds: 15),
  }) async {
    final stage = staged.parent.parent;
    Directory? dir;
    Process? helper;
    try {
      // A name nobody had, made new, and then closed to everyone else: Dart
      // makes it 0755, so it is 0700 before the script goes in. On Windows it
      // is under the user's own %TEMP%, which only they, SYSTEM and the
      // administrators can open.
      dir = Directory.systemTemp.createTempSync(stagePrefix);
      if (platform != 'windows' &&
          Process.runSync('chmod', ['700', dir.path]).exitCode != 0) {
        throw const UpdateException('Could not make a folder of its own.');
      }
      final List<String> command;
      if (platform == 'windows') {
        final script = File('${dir.path}${_sep}finish-update.ps1')
          ..writeAsStringSync(windowsHelper);
        final system = Platform.environment['SystemRoot'] ?? r'C:\Windows';
        command = [
          '$system\\System32\\WindowsPowerShell\\v1.0\\powershell.exe',
          '-NoProfile',
          '-NonInteractive',
          '-ExecutionPolicy',
          'Bypass',
          '-WindowStyle',
          'Hidden',
          '-File',
          script.path,
        ];
      } else {
        final script = File('${dir.path}${_sep}finish-update.sh')
          ..writeAsStringSync(posixHelper);
        command = ['/bin/sh', script.path];
      }
      // Every path as an argument of its own, and no shell between: each
      // reaches the script as the one string it is.
      command.addAll([
        '${processId ?? pid}',
        root.path,
        staged.path,
        stage.path,
        dir.path,
        if (platform != 'windows') platform,
      ]);
      helper = await Process.start(
        command.first,
        command.sublist(1),
        // Windows PowerShell does not start at all detached, its console
        // host having no console, and a child on Windows outlives its parent
        // anyway: so there it starts as any child does, its pipes drained.
        mode: platform == 'windows'
            ? ProcessStartMode.normal
            : ProcessStartMode.detached,
        // Not in the install, which Windows would then refuse to rename.
        workingDirectory: Directory.systemTemp.path,
      );
      if (platform == 'windows') {
        unawaited(helper.stdout.drain<void>());
        unawaited(helper.stderr.drain<void>());
      }
      final ready = File('${dir.path}${_sep}ready');
      final until = DateTime.now().add(wait);
      while (!ready.existsSync()) {
        if (DateTime.now().isAfter(until)) {
          throw const UpdateException(
            'The helper that puts the update in place did not start.',
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    } catch (error) {
      if (dir != null) _delete(dir);
      _delete(stage);
      helper?.kill();
      if (error is UpdateException) rethrow;
      throw UpdateException('Could not start the update: $error');
    }
  }

  /// Removes what an update left beside this copy: the old copy, once the
  /// new one — this — has started, and a new build that never went in. True
  /// for the second: an update that did not take.
  bool cleanUp() {
    var failed = false;
    try {
      for (final entity in root.parent.listSync(followLinks: false)) {
        if (entity is! Directory ||
            !_name(entity.path).startsWith(stagePrefix)) {
          continue;
        }
        final left = Directory('${entity.path}${_sep}new');
        if (left.existsSync() && left.listSync().isNotEmpty) failed = true;
        _delete(entity);
      }
    } on FileSystemException {
      // A folder that cannot be listed has nothing of ours in it to find.
    }
    return failed;
  }
}

/// The last part of [path], whichever separator it uses.
String _name(String path) => path.split(RegExp(r'[/\\]')).last;

/// Deletes [dir] and what is in it. Links inside are removed, never followed.
void _delete(Directory dir) {
  try {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  } on FileSystemException {
    // Nothing more to do about a folder that will not go.
  }
}

Never _refuse(String why) =>
    throw UpdateException('The update was not installed: $why.');

/// The parts of [name], an archive entry, or a refusal: a name that is
/// absolute, walks upwards, names a drive, or holds anything but printable
/// ASCII. Jeansh's builds hold nothing else, and ASCII leaves a case-blind
/// comparison as the only one two filesystems could disagree on.
List<String> _parts(String name) {
  final bad =
      name.isEmpty ||
      name.startsWith('/') ||
      name.contains(r'\') ||
      name.contains(':') ||
      name.codeUnits.any((unit) => unit < 0x20 || unit > 0x7e);
  final parts = name.split('/');
  if (parts.last.isEmpty) parts.removeLast();
  if (bad ||
      parts.isEmpty ||
      parts.any((part) => part.isEmpty || part == '.' || part == '..')) {
    _refuse('it holds an entry named "$name"');
  }
  return parts;
}

/// The one folder at the top of [path], a build's archive — a `.tar.gz`, or a
/// `.zip` — once every entry in it has been checked, since the tool that
/// unpacks it writes wherever an entry says. Refused, with
/// [UpdateException]: an entry outside that one folder, by name or by a
/// symbolic link, or written through one; a link on Windows, whose builds
/// have none; and anything but a file, a folder or a link.
String checkArchive(String path, String platform) {
  final entries = <({String name, bool folder, String? link})>[];
  if (path.endsWith('.tar.gz')) {
    final tar = TarDecoder()
      ..decodeBytes(
        gzip.decode(File(path).readAsBytesSync()),
        storeData: false,
      );
    for (final file in tar.files) {
      final type = file.typeFlag;
      // '0' and '' a file, '5' a folder, '2' a symbolic link. A hard link, a
      // device or a FIFO is nothing a build holds.
      if (!const {'0', '', '5', '2'}.contains(type)) {
        _refuse('"${file.filename}" is not a file, a folder or a link');
      }
      entries.add((
        name: file.filename,
        folder: type == '5',
        link: type == '2' ? (file.nameOfLinkedFile ?? '') : null,
      ));
    }
  } else if (path.endsWith('.zip')) {
    final input = InputFileStream(path);
    try {
      for (final file in ZipDecoder().decodeStream(input)) {
        // The Unix file type, where the archive was made on Unix; 0 where it
        // was not, as a Windows build's is.
        final type = file.mode & 0xf000;
        if (!const {0, 0x8000, 0x4000, 0xa000}.contains(type)) {
          _refuse('"${file.name}" is not a file, a folder or a link');
        }
        entries.add((
          name: file.name,
          folder: file.isDirectory,
          link: type == 0xa000 ? (file.symbolicLink ?? '') : null,
        ));
      }
    } finally {
      input.closeSync();
    }
  } else {
    _refuse('${_name(path)} is not an archive this version can read');
  }

  String? top;
  final links = <String>{};
  for (final entry in entries) {
    final parts = _parts(entry.name);
    top ??= parts.first;
    if (parts.first != top) _refuse('it holds more than one folder');
    if (parts.length == 1 && !entry.folder) {
      _refuse('"${entry.name}" is not a folder');
    }
    final link = entry.link;
    if (link == null) continue;
    if (platform == 'windows') _refuse('it holds a link, "${entry.name}"');
    // Where the link points, walked from its own folder: it must stay in the
    // build's folder, and never start from the root or a drive.
    final at = parts.sublist(0, parts.length - 1);
    var outside =
        link.isEmpty ||
        link.startsWith('/') ||
        link.contains(r'\') ||
        link.contains(':') ||
        link.codeUnits.any((unit) => unit < 0x20 || unit > 0x7e);
    for (final step in outside ? const <String>[] : link.split('/')) {
      if (step.isEmpty || step == '.') continue;
      if (step != '..') {
        at.add(step);
      } else if (at.length > 1) {
        at.removeLast();
      } else {
        outside = true;
        break;
      }
    }
    if (outside) _refuse('"${entry.name}" links out of it, to "$link"');
    links.add(parts.join('/').toLowerCase());
  }
  if (top == null) _refuse('it is empty');

  // Nothing is written through a link, whatever order the entries come in:
  // `a -> ..` followed by `a/a -> ..` puts the second link above the folder,
  // and `a/b` beneath a link is written wherever the link points. Compared
  // without case, since macOS and Windows compare names that way.
  for (final entry in entries) {
    final parts = _parts(entry.name);
    for (var i = 1; i < parts.length; i++) {
      if (links.contains(parts.take(i).join('/').toLowerCase())) {
        _refuse('"${entry.name}" is written through a link');
      }
    }
  }
  return top;
}

/// The new build's folder in [into], once what the tool unpacked there is
/// what [checkArchive] passed: that one folder alone, every link in it
/// resolving inside it — on the disk now, links through links included —
/// and [program] in it, a file, and on macOS and Linux one that runs.
Directory checkUnpacked(
  Directory into,
  String top,
  String platform,
  String program,
) {
  final found = into.listSync(followLinks: false);
  if (found.length != 1 ||
      found.single is! Directory ||
      _name(found.single.path) != top) {
    _refuse('it did not unpack to the one folder it names');
  }
  final folder = found.single as Directory;
  final real = folder.resolveSymbolicLinksSync();
  final sep = Platform.pathSeparator;
  for (final entity in folder.listSync(recursive: true, followLinks: false)) {
    if (entity is! Link) continue;
    if (platform == 'windows') _refuse('it holds a link, ${entity.path}');
    String? to;
    try {
      to = entity.resolveSymbolicLinksSync();
    } on FileSystemException {
      to = null;
    }
    if (to == null || (to != real && !to.startsWith('$real$sep'))) {
      _refuse('${entity.path} links out of it');
    }
  }
  final path = '${folder.path}$sep${program.replaceAll('/', sep)}';
  if (FileSystemEntity.typeSync(path, followLinks: false) !=
      FileSystemEntityType.file) {
    _refuse('it has no $program');
  }
  if (platform != 'windows' && File(path).statSync().mode & 0x49 == 0) {
    _refuse('its $program cannot be run');
  }
  return folder;
}

/// Finishes an update on macOS and Linux once the copy that downloaded it has
/// quit: see [Install.handOff]. Text that never changes, with no path in it:
/// every path comes in as an argument and is only ever expanded inside
/// double quotes, so none is read as code.
const posixHelper = r'''#!/bin/sh
# Finishes a Jeansh update once the copy that downloaded it has quit, from
# lib/src/update/install.dart. Every path is an argument, and each is only
# ever expanded inside double quotes:
#   $1  the process id of that copy, which must quit first
#   $2  the install it replaces: the folder, or the .app
#   $3  the new build, unpacked beside it
#   $4  the folder $3 was unpacked under, where the old install goes
#   $5  this script's own folder
#   $6  linux or macos: how to start the new build
case $1 in '' | *[!0-9]*) exit 1 ;; esac
pid=$1 install=$2 new=$3 stage=$4 dir=$5
: >"$dir/ready" || exit 1
tries=0
while kill -0 "$pid" 2>/dev/null; do
  # Quit but not yet reaped by whatever started it is quit.
  case $(ps -o stat= -p "$pid" 2>/dev/null) in Z*) break ;; esac
  tries=$((tries + 1))
  [ "$tries" -lt 600 ] || exit 1
  sleep 0.2
done
# Called off: Jeansh stopped waiting for this script and took its folder.
[ -e "$dir/ready" ] || exit 0
# The swap, last: the old install aside, the new one into its place, and the
# old one back if that fails. The old one goes at the next start.
if mv -f -- "$install" "$stage/old"; then
  mv -f -- "$new" "$install" || mv -f -- "$stage/old" "$install"
fi
rm -rf -- "$dir"
cd / || exit 1
case $6 in
  macos) exec /usr/bin/open "$install" ;;
  *) exec "$install/jeansh" </dev/null >/dev/null 2>&1 ;;
esac
''';

/// [posixHelper] for Windows, in PowerShell: every path is a parameter, and
/// is only ever handed to .NET as a string — never to cmd, never into a
/// command line, never to a cmdlet that reads wildcards — so no `%`, `^`,
/// `$( )` or backtick in one is read as anything. ASCII, since Windows
/// PowerShell reads a script with no BOM in the ANSI code page.
const windowsHelper = r'''# Finishes a Jeansh update once the copy that downloaded it has quit, from
# lib/src/update/install.dart. Every path is a parameter, and is only ever
# handed to .NET as a string.
param(
  [Parameter(Mandatory = $true)][int]$ProcessId,
  [Parameter(Mandatory = $true)][string]$Install,
  [Parameter(Mandatory = $true)][string]$New,
  [Parameter(Mandatory = $true)][string]$Stage,
  [Parameter(Mandatory = $true)][string]$Dir
)
$ErrorActionPreference = 'Stop'
$ready = [IO.Path]::Combine($Dir, 'ready')
[IO.File]::WriteAllText($ready, '')
$running = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
if ($running -and -not $running.WaitForExit(120000)) { exit 1 }
# Called off: Jeansh stopped waiting for this script and took its folder.
if (-not [IO.File]::Exists($ready)) { exit 0 }
# Windows can hold a folder for a moment after the program in it has quit,
# for an antivirus scan or the search indexer, so each move is retried.
function Move-Folder([string]$From, [string]$To) {
  for ($i = 0; $i -lt 100; $i++) {
    try { [IO.Directory]::Move($From, $To); return $true }
    catch { Start-Sleep -Milliseconds 200 }
  }
  return $false
}
# The swap, last: the old install aside, the new one into its place, and the
# old one back if that fails. The old one goes at the next start.
$old = [IO.Path]::Combine($Stage, 'old')
if (Move-Folder $Install $old) {
  if (-not (Move-Folder $New $Install)) { [void](Move-Folder $old $Install) }
}
try { [IO.Directory]::Delete($Dir, $true) } catch {}
$start = New-Object Diagnostics.ProcessStartInfo
$start.FileName = [IO.Path]::Combine($Install, 'Jeansh.exe')
$start.WorkingDirectory = $Install
# Through the shell, as a double-click starts it: nothing of this script's own
# pipes, which went with the copy that started it, is handed on.
$start.UseShellExecute = $true
[void][Diagnostics.Process]::Start($start)
''';
