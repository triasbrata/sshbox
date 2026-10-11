import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart' show visibleForTesting;

/// The `jeansh` command: `jeansh <file>...` opens each file in a file tab of
/// the terminal it is typed in, as `code <file>` does in VS Code's. A POSIX
/// sh script that needs only `base64` and `tr`, which Linux and macOS have.
///
/// It writes an OSC to the terminal itself, so one way works over SSH, in a
/// tmux pane, in a desktop Local shell and in WSL: see `OpenRequests`. The
/// second line is the marker the app looks for before it replaces its own
/// copy: a file without it is somebody else's and is left alone.
const openCommandMarker = '# jeansh-open: installed by Jeansh';

/// Where, under the home folder, the secret the command signs with is kept:
/// a file of its own that Jeansh rewrites on every connect. Never the
/// environment, which a shell hands on to an `ssh` started from it.
const openSecretDir = '.config/jeansh';
const openSecretFile = 'open-secret';

/// The most files one `jeansh` sends, and the longest path, in bytes. What
/// the app takes: see `OpenRequests.burst` and `OpenRequests.maxPath`.
const openMostFiles = 5;
const openLongestPath = 4096;

const openCommandScript = r'''#!/bin/sh
# jeansh-open: installed by Jeansh
# Usage: jeansh <file>...   Opens each file in Jeansh's file tab.
if [ $# -eq 0 ]; then
  echo "usage: jeansh <file>..." >&2
  exit 2
fi
# The secret is in a file Jeansh rewrites on every connect, not in the
# environment. A link, or a file that is not ours, is not read.
f="$HOME/.config/jeansh/open-secret"
s=
if [ -f "$f" ] && [ ! -L "$f" ] && [ -O "$f" ]; then
  IFS= read -r s <"$f"
fi
if [ -z "$s" ]; then
  echo "jeansh: not running in a Jeansh terminal" >&2
  exit 1
fi
# JEANSH_TTY is only for tests, which have no terminal to write to.
tty=${JEANSH_TTY:-/dev/tty}
rc=0
sent=0
bad=0
for a in "$@"; do
  # At most 5 at a time: the app refuses more, so say so here.
  if [ "$sent" -ge 5 ]; then
    echo "jeansh: $a: not opened, at most 5 files at a time" >&2
    rc=1
    bad=$((bad + 1))
    continue
  fi
  case $a in /*) p=$a ;; *) p=$PWD/$a ;; esac
  if [ ! -e "$p" ]; then
    echo "jeansh: $a: no such file" >&2
    rc=1
    bad=$((bad + 1))
    continue
  fi
  if [ -d "$p" ]; then
    echo "jeansh: $a: is a folder, only files open" >&2
    rc=1
    bad=$((bad + 1))
    continue
  fi
  if [ ! -f "$p" ]; then
    echo "jeansh: $a: is not a regular file" >&2
    rc=1
    bad=$((bad + 1))
    continue
  fi
  d=$(cd "$(dirname "$p")" 2>/dev/null && pwd -P) || {
    echo "jeansh: $a: cannot resolve" >&2
    rc=1
    bad=$((bad + 1))
    continue
  }
  p=$d/$(basename "$p")
  case $p in
    *[[:cntrl:]]*)
      echo "jeansh: $a: name holds a control character" >&2
      rc=1
      bad=$((bad + 1))
      continue
      ;;
  esac
  if command -v iconv >/dev/null 2>&1 &&
    ! printf %s "$p" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1; then
    echo "jeansh: $a: not opened, the name is not valid UTF-8" >&2
    rc=1
    bad=$((bad + 1))
    continue
  fi
  b=$(printf %s "$p" | base64 | tr -d '\n')
  # The time and a nonce, so that this exact output, replayed from a record
  # or a log, is refused.
  t=$(date +%s)
  n=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
  if printf '\033]7733;open;%s;%s;%s;%s\007' "$s" "$t" "$n" "$b" >>"$tty"; then
    sent=$((sent + 1))
  else
    rc=1
    bad=$((bad + 1))
  fi
done
if [ "$bad" -gt 0 ]; then
  echo "jeansh: $bad of $# not opened" >&2
fi
exit $rc
''';

/// Runs `chmod` with [arguments]; replaced by a test that needs it to fail.
@visibleForTesting
ProcessResult Function(List<String> arguments) runChmod = (arguments) =>
    Process.runSync('chmod', arguments);

/// Said when a file could not be put where `jeansh` needs it. [message] says
/// what, plainly, for the user; a [FileSystemException] so a caller that
/// only asks "did it fail" keeps working.
class OpenInstallException extends FileSystemException {
  const OpenInstallException(super.message, [super.path]);
}

class _ForeignFile extends OpenInstallException {
  const _ForeignFile(String path)
    : super("$path is not the app's own, so it was left alone.", path);
}

String _why(Object error) => error is FileSystemException
    ? (error.osError?.message.isNotEmpty ?? false)
          ? error.osError!.message
          : error.message
    : '$error';

/// Writes [openCommandScript] as `jeansh` in [dir] on this machine, 0755:
/// made new beside it and renamed into place, so a link planted at the name
/// is replaced rather than followed. A file there that is not Jeansh's own,
/// by [openCommandMarker], is left alone and throws. Any other failure throws
/// [OpenInstallException] saying what failed, and leaves no half-written
/// file behind.
void installOpenCommand(String dir) {
  final target = '$dir/jeansh';
  try {
    Directory(dir).createSync(recursive: true);
    final type = FileSystemEntity.typeSync(target, followLinks: false);
    if (type == FileSystemEntityType.file &&
        File(target).readAsStringSync().contains(openCommandMarker)) {
      if (File(target).readAsStringSync() == openCommandScript) return;
    } else if (type != FileSystemEntityType.notFound) {
      throw _ForeignFile(target);
    }
  } on OpenInstallException {
    rethrow;
  } on FileSystemException catch (error) {
    throw OpenInstallException(
      'Could not write $target: ${_why(error)}.',
      target,
    );
  }
  _writeNew(target, openCommandScript, '755');
}

/// Writes [content] to a file made new beside [target], mode [mode], and
/// renames it over [target]. Exclusive, so a name planted there is an error
/// and never written through; removed again if anything fails.
void _writeNew(String target, String content, String mode) {
  final suffix = Random.secure().nextInt(1 << 32).toRadixString(36);
  final temp = File('$target.$suffix.new');
  try {
    temp.createSync(exclusive: true);
    // Before the content goes in, so a secret is never readable by others.
    final chmod = runChmod([mode, temp.path]);
    if (chmod.exitCode != 0) {
      throw OpenInstallException(
        'Could not make $target executable: chmod failed'
        '${chmod.stderr.toString().trim().isEmpty ? '' : ' (${chmod.stderr.toString().trim()})'}.',
        target,
      );
    }
    temp.writeAsStringSync(content, flush: true);
    temp.renameSync(target);
  } on OpenInstallException {
    _remove(temp);
    rethrow;
  } on FileSystemException catch (error) {
    _remove(temp);
    throw OpenInstallException(
      'Could not write $target: ${_why(error)}.',
      target,
    );
  } on ProcessException catch (error) {
    _remove(temp);
    throw OpenInstallException(
      'Could not make $target executable: ${error.message}.',
      target,
    );
  }
}

void _remove(File file) {
  try {
    if (file.existsSync()) file.deleteSync();
  } on FileSystemException {
    // Nothing more can be done for a file that will not go.
  }
}

/// Puts [secret] in `~/.config/jeansh/open-secret` under [home], 0600 in a
/// 0700 folder, replacing what is there. Refuses, with [OpenInstallException],
/// if `.config/jeansh` is a link: the secret is not written through one.
void writeOpenSecret(String home, String secret) {
  final dir = '$home/$openSecretDir';
  try {
    if (FileSystemEntity.typeSync(dir, followLinks: false) ==
        FileSystemEntityType.link) {
      throw OpenInstallException(
        '~/$openSecretDir is a link, so the key for the jeansh command was '
        'not written there.',
        dir,
      );
    }
    Directory(dir).createSync(recursive: true);
    final chmod = runChmod(['700', dir]);
    if (chmod.exitCode != 0) {
      throw OpenInstallException(
        'Could not make ~/$openSecretDir private: chmod failed.',
        dir,
      );
    }
  } on OpenInstallException {
    rethrow;
  } on FileSystemException catch (error) {
    throw OpenInstallException(
      'Could not write the key for the jeansh command to ~/$openSecretDir: '
      '${_why(error)}.',
      dir,
    );
  } on ProcessException catch (error) {
    throw OpenInstallException(
      'Could not make ~/$openSecretDir private: ${error.message}.',
      dir,
    );
  }
  _writeNew('$dir/$openSecretFile', '$secret\n', '600');
}

/// Puts `jeansh` in this computer's `~/.local/bin`, the folder a Debian or
/// Ubuntu login adds to PATH once it exists: what the Settings switch does.
/// Null when it is there, else what to tell the user: a file or link that is
/// not Jeansh's own, a missing HOME or a folder that cannot be written.
String? installOpenCommandInHome([String? home]) {
  home ??= Platform.environment['HOME'];
  if (home == null || home.isEmpty) {
    return 'There is no home folder to put the jeansh command in.';
  }
  try {
    installOpenCommand('$home/.local/bin');
    return null;
  } on OpenInstallException catch (error) {
    return error.message;
  } on FileSystemException catch (error) {
    return 'Could not write ~/.local/bin/jeansh: ${_why(error)}.';
  }
}

/// What a host answers to [openCommandInstallScript], its last line.
const openInstalled = 'installed';
const openCurrent = 'current';
const openLeftAlone = 'left alone';
const openSecretLink = 'secret folder is a link';

/// What a host runs to put [openCommandScript] at `~/.local/bin/jeansh` and
/// [secret] in `~/.config/jeansh/open-secret`, as one `sh -c` line. Each is
/// written beside its place under a name of its own and renamed into it, so
/// a link planted at the name is replaced and never written through; a link
/// at `~/.config/jeansh` is refused. A link at `jeansh`, or a file without
/// [openCommandMarker], is left alone. Its last line says [openInstalled],
/// [openCurrent], [openLeftAlone] or [openSecretLink]; anything else, or an
/// exit code, is a failure.
String openCommandInstallScript(String secret) {
  assert(RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(secret));
  final script =
      r'''
d="$HOME/.local/bin"; t="$d/jeansh"; c="$HOME/.config/jeansh"
umask 077
if [ -L "$c" ]; then echo "secret folder is a link"; exit 0; fi
mkdir -p "$c" && chmod 700 "$c" || exit 1
w=$(mktemp "$c/open-secret.XXXXXX") || exit 1
printf '%s\n' '@SECRET@' > "$w" && chmod 600 "$w" && mv -f "$w" "$c/open-secret" || { rm -f "$w"; exit 1; }
mkdir -p "$d" || exit 1
if [ -L "$t" ] || { [ -e "$t" ] && { [ ! -f "$t" ] || ! grep -q '^# jeansh-open: installed by Jeansh' "$t"; }; }; then
  echo "left alone"; exit 0
fi
n=$(mktemp "$t.XXXXXX") || exit 1
cat > "$n" <<'JEANSH_OPEN_EOF' || { rm -f "$n"; exit 1; }
''' +
      openCommandScript +
      r'''JEANSH_OPEN_EOF
if [ -e "$t" ] && cmp -s "$n" "$t"; then rm -f "$n"; echo current; exit 0; fi
chmod 755 "$n" && mv -f "$n" "$t" && echo installed || { rm -f "$n"; exit 1; }
''';
  final filled = script.replaceFirst('@SECRET@', secret);
  return "sh -c '${filled.replaceAll("'", r"'\''")}'";
}
