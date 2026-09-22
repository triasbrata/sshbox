import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../session/session_manager.dart' show SharedFile;

/// How a program is started, so a test can stand one in: the real one is
/// [Process.start].
typedef StartProcess = Future<Process> Function(
  String executable,
  List<String> arguments, {
  Map<String, String>? environment,
});

Future<Process> _start(
  String executable,
  List<String> arguments, {
  Map<String, String>? environment,
}) => Process.start(executable, arguments, environment: environment);

/// The picture on a Linux or Windows clipboard, copied into a file of the
/// app's own — the shape Android's and the Mac's native halves hand back.
///
/// Neither desktop has a native half, and neither needs one: a program the
/// desktop already has reads the clipboard for us, which keeps the build free
/// of C++ nobody here can compile and lets every step be tested. On Windows
/// that is Windows PowerShell, always there, which is also how Claude Code
/// itself takes a picture off a Windows clipboard; its .NET clipboard reads
/// Chrome's PNG, a screenshot's bitmap and a file copied in Explorer alike,
/// and encodes the bitmap as PNG, which C++ would have needed WIC for. On
/// Linux it is `wl-paste` (wl-clipboard) under Wayland or `xclip` under X11,
/// the tools every Linux clipboard script uses, and which may not be
/// installed — then [missing] says what to install.
///
/// The price is a program started per paste: well under a second for the
/// Linux tools, and about half a second or more for PowerShell while .NET
/// loads.
class DesktopClipboard {
  /// [environment] and [start] stand in for [Platform.environment] and
  /// [Process.start], for tests.
  DesktopClipboard({Map<String, String>? environment, StartProcess? start})
    : _env = environment ?? Platform.environment,
      _startProcess = start ?? _start;

  final Map<String, String> _env;
  final StartProcess _startProcess;

  /// Why the last look found no picture when a picture may well have been
  /// there: the clipboard could not be asked at all. Null when it was asked.
  /// Said only when nothing else pastes either, so text still pastes without
  /// the tool.
  String? get missing => _missing;
  String? _missing;

  /// The picture on the clipboard, or null when it holds none, as a file of
  /// ours with the name to give it on the host.
  ///
  /// Throws a [PlatformException] saying what to do when a picture is there
  /// but cannot be taken: bigger than [limit], or not handed over.
  Future<SharedFile?> image(int limit, {required bool windows}) {
    _missing = null;
    return windows ? _windows(limit) : _linux(limit);
  }

  // Linux.

  Future<SharedFile?> _linux(int limit) async {
    final wlPaste = _env['WAYLAND_DISPLAY']?.isNotEmpty == true
        ? _onPath('wl-paste')
        : null;
    final xclip = wlPaste == null && _env['DISPLAY']?.isNotEmpty == true
        ? _onPath('xclip')
        : null;
    final List<String> listTypes;
    final List<String> Function(String type) read;
    final String tool;
    if (wlPaste != null) {
      tool = wlPaste;
      listTypes = const ['--list-types'];
      read = (type) => ['--no-newline', '--type', type];
    } else if (xclip != null) {
      tool = xclip;
      listTypes = const [
        '-selection',
        'clipboard',
        '-target',
        'TARGETS',
        '-out',
      ];
      read = (type) => ['-selection', 'clipboard', '-target', type, '-out'];
    } else {
      _missing = _linuxHint();
      return null;
    }

    // An empty clipboard is an error to both tools ("Nothing is copied"),
    // and means only that there is no picture.
    final types = LineSplitter.split(
      utf8.decode(await _output(tool, listTypes) ?? const []),
    ).map((type) => type.trim()).toSet();

    // A picture copied in a file manager arrives as a file URI, and is taken
    // as it is, name and all — Nautilus, Dolphin and Thunar all offer this
    // type beside their own.
    if (types.contains('text/uri-list')) {
      final list = await _output(tool, read('text/uri-list'));
      final file = _firstImage(
        LineSplitter.split(utf8.decode(list ?? const [], allowMalformed: true))
            .where((line) => line.startsWith('file://'))
            .map((line) {
              try {
                return Uri.parse(line.trim()).toFilePath();
              } on FormatException {
                return null;
              } on UnsupportedError {
                return null;
              }
            })
            .nonNulls,
      );
      if (file != null) return _copy(file, limit);
    }

    // Everything else arrives as bytes, and a program usually offers the
    // same picture under several types: PNG first, as on the Mac, being
    // lossless and small, then the formats Claude reads, then anything else
    // an image.
    final type =
        const [
          'image/png',
          'image/jpeg',
          'image/gif',
          'image/webp',
        ].where(types.contains).firstOrNull ??
        types.where((type) => type.startsWith('image/')).firstOrNull;
    if (type == null) return null;
    final name = pastedName(_extensionOf(type));
    final file = File('${_freshDirectory().path}/$name');
    final wrote = await _output(tool, read(type), into: file, limit: limit);
    // It said it had one: a type that then hands over nothing is an error,
    // never silence, which reads as a feature that does nothing.
    if (wrote == null || file.lengthSync() == 0) throw _unreadable();
    return (path: file.path, name: name);
  }

  String _linuxHint() {
    final wayland = _env['WAYLAND_DISPLAY']?.isNotEmpty == true;
    final x11 = _env['DISPLAY']?.isNotEmpty == true;
    final install = switch ((wayland, x11)) {
      (true, _) => 'wl-clipboard',
      (false, true) => 'xclip',
      _ => 'wl-clipboard (Wayland) or xclip (X11)',
    };
    return 'Nothing on the clipboard a terminal can paste as text. To paste '
        'a picture, install $install.';
  }

  /// [tool] by its full path, from `PATH`, or null when it is not installed.
  String? _onPath(String tool) {
    for (final dir in (_env['PATH'] ?? '').split(':')) {
      if (dir.isEmpty) continue;
      final path = '$dir/$tool';
      final stat = FileStat.statSync(path);
      // Any execute bit.
      if (stat.type == FileSystemEntityType.file && stat.mode & 0x49 != 0) {
        return path;
      }
    }
    return null;
  }

  /// What [tool] printed, or null when it failed. With [into] it goes into
  /// that file instead, stopping at [limit] — so a video on the clipboard is
  /// refused having read no more than the ceiling — and the answer is empty.
  Future<List<int>?> _output(
    String tool,
    List<String> arguments, {
    File? into,
    int limit = 64 * 1024,
  }) async {
    final Process process;
    try {
      process = await _startProcess(tool, arguments, environment: _env);
    } on ProcessException {
      return null;
    }
    unawaited(process.stdin.close());
    unawaited(process.stderr.drain<void>());
    final sink = into?.openWrite();
    final bytes = <int>[];
    var count = 0;
    var tooBig = false;
    try {
      // A clipboard owner that never answers would otherwise hold the paste
      // for ever.
      await for (final chunk in process.stdout.timeout(
        const Duration(seconds: 10),
      )) {
        count += chunk.length;
        if (count > limit) {
          tooBig = true;
          break;
        }
        sink == null ? bytes.addAll(chunk) : sink.add(chunk);
      }
    } on TimeoutException {
      process.kill();
      await sink?.close();
      throw _unreadable();
    } finally {
      if (tooBig) process.kill();
    }
    await sink?.close();
    if (tooBig) {
      // A list of types or of files that long is no clipboard we can use.
      if (into == null) return null;
      into.deleteSync();
      throw _tooBig(limit);
    }
    if (await process.exitCode != 0) return null;
    return bytes;
  }

  // Windows.

  /// What Windows PowerShell runs, as `-EncodedCommand` takes it, so no
  /// quote in it can be mangled on its way through a Windows command line.
  ///
  /// It says what it found on its first line — `file` with the paths after,
  /// one a line; `png` once the picture is written to `JEANSH_PASTE_OUT`;
  /// `too_big`, `unreadable` or `none` — and the paths come over as UTF-8,
  /// so a name in any language survives.
  ///
  /// Chrome and Edge put a real PNG on the clipboard beside the bitmap, with
  /// its transparency, so that is taken first and as it is; a screenshot is
  /// a bitmap alone, which .NET encodes as PNG.
  static const _script = r'''
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$c = [System.Windows.Forms.Clipboard]
if ($c::ContainsFileDropList()) {
  'file'
  foreach ($f in $c::GetFileDropList()) { $f }
  exit 0
}
$out = $env:JEANSH_PASTE_OUT
$data = $c::GetDataObject()
if ($data -ne $null -and $data.GetDataPresent('PNG')) {
  $png = $data.GetData('PNG')
  if ($png -is [System.IO.Stream]) {
    if ($png.Length -gt [long]$env:JEANSH_PASTE_LIMIT) { 'too_big'; exit 0 }
    $file = [System.IO.File]::Create($out)
    try { $png.CopyTo($file) } finally { $file.Close() }
    'png'
    exit 0
  }
}
if ($c::ContainsImage()) {
  $image = $c::GetImage()
  if ($image -eq $null) { 'unreadable'; exit 0 }
  $image.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
  'png'
  exit 0
}
'none'
''';

  static final _encoded = base64.encode([
    for (final unit in _script.codeUnits) ...[unit & 0xff, unit >> 8],
  ]);

  Future<SharedFile?> _windows(int limit) async {
    final name = pastedName('png');
    // A forward slash, which .NET takes as readily as Windows' own.
    final out = File('${_freshDirectory().path}/$name');
    final powershell =
        '${_env['SystemRoot'] ?? r'C:\Windows'}'
        r'\System32\WindowsPowerShell\v1.0\powershell.exe';
    final String said;
    try {
      final process = await _startProcess(
        powershell,
        [
          '-NoProfile',
          '-NonInteractive',
          '-STA',
          '-WindowStyle',
          'Hidden',
          '-EncodedCommand',
          _encoded,
        ],
        environment: {
          ..._env,
          'JEANSH_PASTE_OUT': out.path,
          'JEANSH_PASTE_LIMIT': '$limit',
        },
      );
      unawaited(process.stdin.close());
      unawaited(process.stderr.drain<void>());
      final printed = process.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .join()
          .timeout(const Duration(seconds: 15));
      said = await printed;
      if (await process.exitCode != 0) throw const ProcessException('', []);
    } on Object {
      // PowerShell missing or refused (a locked-down machine can forbid
      // Add-Type): the paste goes on as text, and says why only if that
      // finds nothing either.
      _missing =
          'Nothing on the clipboard a terminal can paste as text, and Windows '
          'PowerShell could not be asked for a picture.';
      return null;
    }
    final lines = LineSplitter.split(said.replaceAll('\uFEFF', ''))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
    switch (lines.firstOrNull) {
      case 'file':
        final file = _firstImage(lines.skip(1));
        // Files copied in Explorer, none of them a picture: nothing to send,
        // and the paste goes on to be text, as with nothing copied.
        return file == null ? null : _copy(file, limit);
      case 'png':
        // Written from a bitmap there is no knowing its size first, so it is
        // weighed once written.
        if (!out.existsSync() || out.lengthSync() == 0) throw _unreadable();
        if (out.lengthSync() > limit) {
          out.deleteSync();
          throw _tooBig(limit);
        }
        return (path: out.path, name: name);
      case 'too_big':
        throw _tooBig(limit);
      case 'unreadable':
        throw _unreadable();
      default:
        return null;
    }
  }

  // Both.

  /// The first of [paths] that is a picture this app can send, as a file.
  static String? _firstImage(Iterable<String> paths) => paths
      .where(
        (path) =>
            _imageName.hasMatch(path) &&
            FileSystemEntity.typeSync(path) == FileSystemEntityType.file,
      )
      .firstOrNull;

  static final _imageName = RegExp(
    r'\.(png|jpe?g|gif|webp|bmp|tiff?|heic|heif|avif)$',
    caseSensitive: false,
  );

  /// A picture already on disk: weighed before it is copied, so a huge one
  /// is refused without being read at all, and keeping the name it has.
  SharedFile _copy(String path, int limit) {
    final source = File(path);
    if (source.lengthSync() > limit) throw _tooBig(limit);
    final name = path.split('/').last.split(r'\').last;
    final copy = source.copySync('${_freshDirectory().path}/$name');
    return (path: copy.path, name: name);
  }

  /// One picture at a time, as Android and the Mac keep one: the directory
  /// the last paste made goes before each copy. Made new each time, by
  /// mkdtemp, so it is ours alone even in a `/tmp` every login shares.
  static Directory? _last;

  static Directory _freshDirectory() {
    try {
      _last?.deleteSync(recursive: true);
    } on FileSystemException {
      // Already gone, or held open by the upload of the last one.
    }
    return _last = Directory.systemTemp.createTempSync('jeansh-paste-');
  }

  static String _extensionOf(String type) {
    final kind = type.substring('image/'.length).split(';').first;
    return switch (kind) {
      'jpeg' => 'jpg',
      'svg+xml' => 'svg',
      _ => kind.replaceAll(RegExp(r'[^A-Za-z0-9]'), ''),
    };
  }

  static PlatformException _unreadable() => PlatformException(
    code: 'unreadable',
    message:
        'The picture on the clipboard could not be read. Try copying it '
        'again, or open it from the files drawer.',
  );

  static PlatformException _tooBig(int limit) => PlatformException(
    code: 'too_big',
    message:
        'That image is bigger than ${limit ~/ (1024 * 1024)} MB — send it '
        'from the files drawer instead.',
  );
}

/// What a picture with no name of its own is called once it is on the host,
/// where the user reads it and types it at a prompt — as Android and the Mac
/// name one.
@visibleForTesting
String pastedName(String extension, [DateTime? now]) {
  final t = now ?? DateTime.now();
  String two(int n) => n.toString().padLeft(2, '0');
  return 'pasted-${t.year}${two(t.month)}${two(t.day)}-'
      '${two(t.hour)}${two(t.minute)}${two(t.second)}.$extension';
}
