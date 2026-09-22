/// Everything that leaves the device — a crash report, a bug report — comes
/// through here first.
///
/// Jeansh is an SSH client, so the text it would otherwise send is unusually
/// dangerous. One exception message can carry the name of a machine on
/// somebody's tailnet, the login it uses, an absolute path on that machine,
/// the command that was running, a database URI with its password in it, or
/// the very bytes of a private key. None of that is ours to send anywhere,
/// and no amount of "it was only in a stack trace" makes it ours.
///
/// So the rule here is the blunt one: anything that *looks like* it could be
/// one of those things is replaced, whether or not it really is. A crash
/// report that reads `Could not reach <host>: <redacted>` is still worth
/// having — the type and the stack trace are what say where the bug is — and
/// it cannot leak. Losing a version number or a file name to the same rule is
/// a price worth paying, and a few of the rules below do exactly that.
///
/// Deliberately pure Dart, with nothing of Sentry in it: the same function
/// scrubs the bug report the user reads before sending it, and its tests need
/// no SDK and no network.
library;

/// The rules, in the order they run. Order matters: a URI is replaced whole
/// before the path rule can eat half of it, and a `user@host` before the
/// hostname rule can take the host and leave the login behind.
final List<(RegExp, String)> _rules = [
  // A private key pasted into a message or read back in an error. First,
  // because everything else would carve it up into unrecognisable pieces.
  (
    RegExp(r'-----BEGIN[^-]*-----[\s\S]*?-----END[^-]*-----', multiLine: true),
    '<key>',
  ),
  // Anything with a scheme: postgresql://user:pass@host/db, mongodb+srv://,
  // redis://, ssh://, and file:///home/… out of a debug stack trace. The
  // password is the point, but the host and the database name go too. It runs
  // to the next space, so a quote or a bracket around the URI goes with it —
  // over-redaction, which is the direction this file errs in.
  (RegExp(r'[a-zA-Z][a-zA-Z0-9+.\-]*://\S*'), '<uri>'),
  // A login and where it logs in: `trias@my-box`, and an email address, which
  // has the same shape and is no more ours to send.
  (RegExp(r'[\w.\-+]+@[\w.\-]+'), '<account>'),
  // A Windows path, C:\Users\… — the user's own name is usually in it.
  (RegExp(r'[A-Za-z]:\\\S*'), '<path>'),
  // A POSIX path, and `~/…`.
  //
  // The leading `/` must not follow a letter, a digit or a `+`, which is what
  // keeps this rule out of the middle of a base64 blob: a host fingerprint
  // reads `SHA256:47DEQpj8HBSa+/TImW…`, and without the lookbehind this rule
  // took everything from that inner `/` onward and left half a hash sitting in
  // the report. Blocked here, the run falls through to the key rule below and
  // goes whole. `=` is deliberately *not* in the lookbehind, or `HOME=/home/…`
  // would stop being a path and be short enough to survive the key rule too.
  //
  // It also means `and/or` in prose is left alone now, which it was not
  // before, since that `/` follows a letter.
  (RegExp(r'(?<![A-Za-z0-9+])~?/[\w.\-+]+(?:/[\w.\-+]*)*'), '<path>'),
  // An IPv6 literal, before IPv4 so that an embedded ::ffff:1.2.3.4 goes
  // whole rather than in halves.
  (RegExp(r'\b(?:[0-9a-fA-F]{0,4}:){2,}[0-9a-fA-F.]*'), '<ip>'),
  (RegExp(r'\b\d{1,3}(?:\.\d{1,3}){3}\b'), '<ip>'),
  // A long run of key characters: a token, a base64 key body, a fingerprint,
  // a session id. Shorter than 40 is left alone, or every Dart identifier
  // would go.
  (RegExp(r'[A-Za-z0-9+/=_\-]{40,}'), '<redacted>'),
];

/// A dotted name — `my-box.tail1a2b.ts.net`, and also `settings_page.dart` and
/// `1.0.62`. The first is a hostname and must go; the second and third are
/// collateral, except that a version number is worth keeping, so [scrub]
/// leaves a name whose every part is a number alone.
final _dotted = RegExp(r'\b[a-z0-9_\-]+(?:\.[a-z0-9_\-]+)+\b');
final _numbersOnly = RegExp(r'^[0-9.]+$');

/// [text] with everything above taken out of it.
String scrub(String text) {
  var out = text;
  for (final (pattern, replacement) in _rules) {
    out = out.replaceAll(pattern, replacement);
  }
  return out.replaceAllMapped(
    _dotted,
    (match) => _numbersOnly.hasMatch(match[0]!) ? match[0]! : '<host>',
  );
}

/// A bare Dart file name, `port_forwarding_page.dart`: no directory, so no
/// path, and no hostname either, `.dart` being no top-level domain.
final _dartFile = RegExp(r'^[\w.\-]+\.dart$');

/// [scrub], for a file name in a stack frame.
///
/// A frame from a release build names its file as `package:sshbox/src/…` or
/// `dart:async` in `absPath`, and sentry-dart puts the last part of it,
/// `x.dart`, in `fileName`. Neither carries anything of the user's, and they
/// are the whole of what makes a stack trace readable — so they are kept
/// exactly as they are. Without the bare-name case the hostname rule took
/// every `x.dart` for a host, and every frame and every issue read `<host>`.
/// Anything else is a real path off this machine (a debug build's
/// `file:///home/…`) and goes through [scrub] like any other text.
String? scrubFrame(String? name) {
  if (name == null) return null;
  if (name.startsWith('package:') ||
      name.startsWith('dart:') ||
      _dartFile.hasMatch(name)) {
    return name;
  }
  return scrub(name);
}

/// A plugin's constant, `invalid_icon` or `sign_in_failed`: the shape a
/// `PlatformException.code` takes when it names what went wrong.
final _constantCode = RegExp(r'^[A-Za-z][A-Za-z0-9_.\-]{0,63}$');

/// A `PlatformException`'s code, kept when it is a constant and dropped when
/// it could be data. Its message is dropped whole (see [droppedValues]), and
/// the code is then the one thing left that says which failure it was.
///
/// A dotted code such as `my-box.ts.net` fits the shape and is still a
/// hostname, so a code [scrub] would change is dropped too.
String? scrubCode(Object? code) =>
    code is String && _constantCode.hasMatch(code) && scrub(code) == code
    ? code
    : null;

/// [scrub], for a whole line of a printed stack trace.
///
/// A line reads `#1      open (package:sshbox/src/x.dart:4:3)`, so the file
/// name is not at the start and [scrubFrame] cannot see it — the path rule
/// would eat `/src/x.dart` and leave the trace unreadable. A line whose
/// location is a `package:` or a `dart:` URI carries nothing of the user's
/// and is kept whole; any other line has a real path in it and is scrubbed.
String scrubStackLine(String line) =>
    line.contains('(package:') || line.contains('(dart:') ? line : scrub(line);

/// Exception types whose message is host output or a user's own path by
/// construction, so there is nothing in it worth the risk of sending: the
/// value is dropped whole and only the type name goes.
///
/// Jeansh's own first — every one of these is built to be put in front of the
/// user, which is exactly why they hold the user's world — then dartssh2's,
/// which quote the server, then `dart:io`'s and the platform channel's, which
/// quote a path or a native message.
const droppedValues = {
  'SshSessionException',
  'FileBrowserException',
  'DbException',
  'GitException',
  'TmuxException',
  'UpdateException',
  'IsolateWireFailure',
  'SSHAuthFailError',
  'SSHAuthAbortError',
  'SSHChannelOpenError',
  'SSHChannelRequestError',
  'SSHDisconnectError',
  'SSHHandshakeError',
  'SSHHostkeyError',
  'SSHKeyDecodeError',
  'SSHKeyDecryptError',
  'SSHPacketError',
  'SSHSocketError',
  'SSHStateError',
  'SSHInternalError',
  'SSHHttpException',
  'SftpStatusError',
  'SftpAbortError',
  'SftpError',
  'SocketException',
  'FileSystemException',
  'PathNotFoundException',
  'PathAccessException',
  'PathExistsException',
  'ProcessException',
  'HandshakeException',
  'TlsException',
  'HttpException',
  'OSError',
  'PlatformException',
  'MissingPluginException',
};

/// Types that mean the user tried something and it did not work — a wrong
/// password, a host that will not answer, a file that is not there, git
/// saying there is nothing to commit. Every one of them is thrown on purpose
/// and shown on purpose, so an event about one is noise: it says nothing
/// about a fault in Jeansh and it burns the free tier saying it.
///
/// The ceiling, worth knowing: a real bug that happens to surface as one of
/// these — a path we built wrongly coming back as a PathNotFoundException —
/// is dropped with the rest. Nothing here is reported, so nothing here can be
/// noticed from a report; the user's own bug report is the way those arrive.
const ordinaryFailures = {
  'SshSessionException',
  'FileBrowserException',
  'DbException',
  'GitException',
  'TmuxException',
  'UpdateException',
  'SSHAuthFailError',
  'SSHAuthAbortError',
  'SSHChannelOpenError',
  'SSHHostkeyError',
  'SSHSocketError',
  'SftpStatusError',
  'SocketException',
  'HandshakeException',
  'PathNotFoundException',
  'PathAccessException',
};

/// What to send as an exception's message: nothing at all for the types above,
/// and a scrubbed line for everything else.
String? scrubValue(String? type, String? value) {
  if (value == null) return null;
  if (type != null && droppedValues.contains(type)) {
    return '(message dropped: it can carry a host, a path or a credential)';
  }
  return scrub(value);
}
