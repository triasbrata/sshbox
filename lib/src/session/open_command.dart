import 'dart:io';

/// The `jeansh` command: `jeansh <file>...` opens each file in a file tab of
/// the terminal it is typed in, as `code <file>` does in VS Code's. A POSIX
/// sh script that needs only `base64` and `tr`, which Linux and macOS have.
///
/// It writes an OSC to the terminal itself, so one way works over SSH, in a
/// tmux pane, in a desktop Local shell and in WSL: see `OpenRequests`. The
/// second line is the marker the app looks for before it replaces its own
/// copy: a file without it is somebody else's and is left alone.
const openCommandMarker = '# jeansh-open: installed by Jeansh';

const openCommandScript = r'''#!/bin/sh
# jeansh-open: installed by Jeansh
# Usage: jeansh <file>...   Opens each file in Jeansh's file tab.
if [ $# -eq 0 ]; then
  echo "usage: jeansh <file>..." >&2
  exit 2
fi
if [ -z "$LC_SSHBOX_OPEN_SECRET" ]; then
  echo "jeansh: not running in a Jeansh terminal" >&2
  exit 1
fi
# JEANSH_TTY is only for tests, which have no terminal to write to.
tty=${JEANSH_TTY:-/dev/tty}
rc=0
for a in "$@"; do
  case $a in /*) p=$a ;; *) p=$PWD/$a ;; esac
  if [ ! -e "$p" ]; then
    echo "jeansh: $a: no such file" >&2
    rc=1
    continue
  fi
  if [ -d "$p" ]; then
    echo "jeansh: $a: is a folder, only files open" >&2
    rc=1
    continue
  fi
  d=$(cd "$(dirname "$p")" 2>/dev/null && pwd -P) || {
    echo "jeansh: $a: cannot resolve" >&2
    rc=1
    continue
  }
  p=$d/$(basename "$p")
  case $p in
    *[[:cntrl:]]*)
      echo "jeansh: $a: name holds a control character" >&2
      rc=1
      continue
      ;;
  esac
  b=$(printf %s "$p" | base64 | tr -d '\n')
  printf '\033]7733;open;%s;%s\007' "$LC_SSHBOX_OPEN_SECRET" "$b" >>"$tty" ||
    rc=1
done
exit $rc
''';

/// Writes [openCommandScript] as `jeansh` in [dir] on this machine, 0755:
/// made new beside it and renamed into place, so a link planted at the name
/// is replaced rather than followed. A file there that is not Jeansh's own,
/// by [openCommandMarker], is left alone and throws.
void installOpenCommand(String dir) {
  Directory(dir).createSync(recursive: true);
  final target = '$dir/jeansh';
  final type = FileSystemEntity.typeSync(target, followLinks: false);
  if (type == FileSystemEntityType.file &&
      File(target).readAsStringSync().contains(openCommandMarker)) {
    if (File(target).readAsStringSync() == openCommandScript) return;
  } else if (type != FileSystemEntityType.notFound) {
    throw FileSystemException('not Jeansh\'s own', target);
  }
  final temp = File('$target.$pid.new');
  temp.writeAsStringSync(openCommandScript, flush: true);
  Process.runSync('chmod', ['755', temp.path]);
  temp.renameSync(target);
}

/// Puts `jeansh` in this computer's `~/.local/bin`, the folder a Debian or
/// Ubuntu login adds to PATH once it exists: what the Settings switch does.
/// True when it is there, false for a file or link that is not Jeansh's own,
/// a missing HOME or a folder that cannot be written.
bool installOpenCommandInHome([String? home]) {
  home ??= Platform.environment['HOME'];
  if (home == null || home.isEmpty) return false;
  try {
    installOpenCommand('$home/.local/bin');
    return true;
  } on FileSystemException {
    return false;
  }
}

/// What a host runs to put [openCommandScript] at `~/.local/bin/jeansh`, as
/// one `sh -c` line. Written beside it under a name of its own and renamed
/// into place, so a link planted at the name is replaced and never written
/// through; a link there, or a file without [openCommandMarker], is left
/// alone. Its last line says `installed`, `current` or `left alone`.
String openCommandInstallScript() {
  final script =
      r'''
d="$HOME/.local/bin"; t="$d/jeansh"
mkdir -p "$d" || exit 1
if [ -L "$t" ] || { [ -e "$t" ] && ! grep -q '^# jeansh-open: installed by Jeansh' "$t"; }; then
  echo "left alone"; exit 0
fi
n="$t.$$.new"; umask 022
cat > "$n" <<'JEANSH_OPEN_EOF'
''' +
      openCommandScript +
      r'''JEANSH_OPEN_EOF
if [ -e "$t" ] && cmp -s "$n" "$t"; then rm -f "$n"; echo current; exit 0; fi
chmod 755 "$n" && mv -f "$n" "$t" && echo installed
''';
  return "sh -c '${script.replaceAll("'", r"'\''")}'";
}
