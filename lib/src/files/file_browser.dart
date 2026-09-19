/// The shape of a remote filesystem, described without naming a protocol.
///
/// This is the seam that keeps a future daemon reachable. Today the only
/// implementation talks SFTP over the session that is already open; later one
/// can talk HTTP or WebSocket to something listening on the host, reached
/// through the same port forward code-server uses. The pages in `ui/` are
/// written against this file and nothing else, so swapping the transport means
/// writing one more [FileBrowser] and changing the line that picks it.
///
/// The methods here follow what the UI needs, deliberately, rather than what
/// SFTP happens to offer. Modelling them on SFTP would force a daemon into a
/// chatty round-trip-per-entry shape and throw away the one advantage it has.
library;

/// What kind of thing a listing row is.
///
/// An enum rather than a pair of booleans, because a symlink is not a third
/// boolean: it is a kind of its own whose target may be either, and a file
/// browser has to be able to show that difference.
enum RemoteEntryKind { directory, file, symlink, other }

/// One row in a directory listing.
class RemoteEntry {
  const RemoteEntry({
    required this.name,
    required this.path,
    required this.kind,
    this.size,
    this.modified,
    this.targetIsDirectory,
  });

  final String name;

  /// Absolute, so a row can be acted on without the widget holding it having
  /// to remember which directory the listing came from.
  final String path;

  final RemoteEntryKind kind;

  /// Null for entries the server did not report a size for — directories
  /// mostly, where the number would be meaningless anyway.
  final int? size;

  final DateTime? modified;

  /// For [RemoteEntryKind.symlink] only: whether following the link lands on a
  /// directory. Null when the link is broken, or when it was not followed.
  final bool? targetIsDirectory;

  /// Whether tapping this row should descend into it.
  bool get isTraversable =>
      kind == RemoteEntryKind.directory ||
      (kind == RemoteEntryKind.symlink && targetIsDirectory == true);

  bool get isHidden => name.startsWith('.');
}

/// One match from a content search.
class SearchHit {
  const SearchHit({
    required this.path,
    required this.line,
    required this.preview,
  });

  final String path;

  /// 1-based, matching what every tool that prints line numbers does.
  final int line;

  /// The matching line, as the remote end rendered it.
  final String preview;
}

/// Enough of a file's state to notice that somebody else saved it since.
///
/// ponytail: SFTP v3 reports mtime in whole seconds, so a second save of the
/// same size inside the same second looks unchanged. A daemon can send a hash.
typedef FileStamp = ({DateTime? modified, int? size});

/// A file's text together with the stamp it had when it was read.
typedef RemoteText = ({String text, FileStamp stamp});

/// The kinds of failure a caller might genuinely act on differently.
///
/// Everything else collapses into [unknown] with a readable message — the
/// point is not to enumerate errno, it is to stop the UI having to parse
/// somebody's error prose.
enum FileBrowserFault {
  notFound,
  permissionDenied,
  notEmpty,
  tooLarge,
  notText,

  /// The file on the host is no longer the one the caller read, so writing
  /// over it would quietly throw away someone else's save.
  changed,
  disconnected,
  unsupported,

  /// Stopped part way because Cancel was tapped, which says all there is to
  /// say about it.
  cancelled,
  unknown,
}

/// The single error type every [FileBrowser] throws.
///
/// SFTP status codes and a daemon's HTTP responses look nothing alike. Letting
/// either leak would make the UI fluent in two error languages and make
/// swapping the transport expensive — the same reasoning that put
/// `SshSessionException` in front of dartssh2's errors.
class FileBrowserException implements Exception {
  const FileBrowserException(
    this.message, {
    this.fault = FileBrowserFault.unknown,
  });

  /// One line, already fit to put in front of a user.
  final String message;

  final FileBrowserFault fault;

  /// What a transfer throws once its cancel has stopped it.
  static const cancelled = FileBrowserException(
    'Cancelled.',
    fault: FileBrowserFault.cancelled,
  );

  @override
  String toString() => message;
}

/// [bytes] as a person reads a size: `512 B`, `3.4 MB`, `120 GB`.
String formatBytes(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final rounded = unit == 0 || value >= 100
      ? value.toStringAsFixed(0)
      : value.toStringAsFixed(1);
  return '$rounded ${units[unit]}';
}

/// Reading, writing and rearranging files on the remote host.
///
/// Implementations are cheap to create and own a resource — call [close] when
/// the page holding one goes away.
abstract class FileBrowser {
  /// Where to open when the user has not said. Usually the login home.
  Future<String> resolveHome();

  /// Entries in [path], directories first and then case-insensitively by name.
  ///
  /// Ordering is fixed here rather than in the UI so every transport agrees on
  /// it, and hidden entries are included — filtering them is the pages' call,
  /// not the transport's.
  Future<List<RemoteEntry>> list(String path);

  /// What is at [path] with links followed — a directory, a file or something
  /// else — or null when nothing is. For a path met outside any listing, such
  /// as one tapped in the terminal.
  Future<RemoteEntryKind?> stat(String path);

  /// The whole file as text, and the stamp to hand back to [writeText].
  ///
  /// Throws [FileBrowserFault.tooLarge] rather than truncating, and
  /// [FileBrowserFault.notText] for anything that is not, so the editor never
  /// silently shows half a file or a screenful of mojibake.
  Future<RemoteText> readText(String path, {int maxBytes = defaultReadLimit});

  /// Replaces the contents of [path], creating it if it is not there, and
  /// returns the stamp of what is there now.
  ///
  /// With [expected], the write only goes ahead while the file still matches
  /// it; otherwise it throws [FileBrowserFault.changed] and writes nothing.
  Future<FileStamp> writeText(
    String path,
    String content, {
    FileStamp? expected,
  });

  Future<void> rename(String from, String to);

  /// Removes [path]. A non-empty directory needs [recursive], and without it
  /// raises [FileBrowserFault.notEmpty] rather than deleting anything.
  Future<void> delete(String path, {bool recursive = false});

  Future<void> makeDirectory(String path);

  /// Sends the phone's file at [localPath] to [path], telling [onProgress]
  /// how far it has got.
  ///
  /// It arrives private to the login, and never goes through a link found
  /// under the name. Without [replace] a name already taken fails the upload;
  /// with it, what is there is replaced, and stays whole until the new file
  /// is. [cancel] completing stops it part way with
  /// [FileBrowserException.cancelled], and what was sent goes.
  Future<void> upload(
    String localPath,
    String path, {
    bool replace = false,
    void Function(int sent, int total)? onProgress,
    Future<void>? cancel,
  });

  /// Brings the file at [path] down into the phone's file at [localPath],
  /// byte for byte, a chunk at a time, telling [onProgress] how far it has
  /// got. Nothing is held in memory, so only the phone's disk bounds it.
  /// [cancel] completing stops it part way with
  /// [FileBrowserException.cancelled].
  ///
  /// With [offset] and [length], only that stretch of it: how a pane's
  /// record is read from its end without the whole of it coming down.
  Future<void> download(
    String path,
    String localPath, {
    int offset = 0,
    int? length,
    void Function(int received, int total)? onProgress,
    Future<void>? cancel,
  });

  /// Releases whatever the implementation is holding open.
  Future<void> close();

  /// 1 MiB. Large enough for any config file or script somebody would edit on
  /// a phone, small enough that a mistaken tap on a database dump does not
  /// take the app down with it.
  static const int defaultReadLimit = 1024 * 1024;
}

/// Optional capability, probed for rather than assumed.
///
/// Separate from [FileBrowser] because the quality on offer differs sharply:
/// over SFTP this shells out to `grep` and arrives in one lump, while a daemon
/// can stream ranked results as it finds them. Both are honest implementations
/// of the same promise, which is exactly why the promise is stated separately.
abstract class FileSearchCapable {
  /// Lines under [root] containing [query], as a literal string rather than a
  /// pattern. The stream closes when the search is done; cancel the
  /// subscription to stop it early.
  Stream<SearchHit> search({required String root, required String query});
}

/// Optional capability: reading and saving a file as root, through sudo.
///
/// Separate from [FileBrowser] because SFTP alone cannot do it: it needs a
/// shell, and a sudo that will have this login. A daemon may never need it,
/// running as root already.
abstract class SudoCapable {
  /// [FileBrowser.readText], as root. A null [password] only gets past a sudo
  /// that does not ask for one; every refusal is
  /// [FileBrowserFault.permissionDenied].
  Future<RemoteText> sudoReadText(
    String path, {
    String? password,
    int maxBytes = FileBrowser.defaultReadLimit,
  });

  /// [FileBrowser.writeText], as root, keeping the file's owner and
  /// permissions. [password] as for [sudoReadText].
  Future<FileStamp> sudoWriteText(
    String path,
    String content, {
    String? password,
    FileStamp? expected,
  });
}

/// POSIX path arithmetic.
///
/// Remote paths are POSIX no matter what the phone's own filesystem looks
/// like, so this deliberately never touches `dart:io`'s separator.
abstract final class RemotePath {
  static String join(String parent, String name) {
    if (name.startsWith('/')) return name;
    if (parent.isEmpty || parent == '/') return '/$name';
    return '${parent.endsWith('/') ? parent.substring(0, parent.length - 1) : parent}/$name';
  }

  static String parent(String path) {
    final trimmed = _stripTrailingSlash(path);
    final cut = trimmed.lastIndexOf('/');
    if (cut <= 0) return '/';
    return trimmed.substring(0, cut);
  }

  /// [path] made absolute against [home]. Blank, `~` and `~/…` mean home, as
  /// they would to a shell — SFTP itself expands none of them — and a bare
  /// relative path is taken from home too.
  static String resolve(String path, String home) {
    final trimmed = path.trim();
    if (trimmed.startsWith('/')) return _stripTrailingSlash(trimmed);
    if (trimmed.isEmpty || trimmed == '~') return home;
    return _stripTrailingSlash(
      join(home, trimmed.startsWith('~/') ? trimmed.substring(2) : trimmed),
    );
  }

  /// An absolute [path] with its `.` and `..` walked and doubled slashes
  /// dropped, so one file is always spelled one way — the tab strip tells
  /// files apart by path. `..` at the root stays there, as it does on the host.
  static String normalize(String path) {
    final parts = <String>[];
    for (final part in path.split('/')) {
      if (part == '..') {
        if (parts.isNotEmpty) parts.removeLast();
      } else if (part.isNotEmpty && part != '.') {
        parts.add(part);
      }
    }
    return '/${parts.join('/')}';
  }

  /// Whether [path] is [ancestor] itself or somewhere beneath it.
  static bool isWithin(String path, String ancestor) =>
      path == ancestor ||
      path.startsWith(ancestor == '/' ? '/' : '$ancestor/');

  static String basename(String path) {
    final trimmed = _stripTrailingSlash(path);
    final cut = trimmed.lastIndexOf('/');
    if (cut < 0) return trimmed;
    final name = trimmed.substring(cut + 1);
    return name.isEmpty ? '/' : name;
  }

  /// The directories leading to [path], root first, each with its full path —
  /// what a breadcrumb bar is made of.
  static List<({String name, String path})> crumbs(String path) {
    final crumbs = <({String name, String path})>[
      (name: '/', path: '/'),
    ];
    var walked = '';
    for (final segment in _stripTrailingSlash(path).split('/')) {
      if (segment.isEmpty) continue;
      walked = '$walked/$segment';
      crumbs.add((name: segment, path: walked));
    }
    return crumbs;
  }

  static String _stripTrailingSlash(String path) {
    if (path.length > 1 && path.endsWith('/')) {
      return path.substring(0, path.length - 1);
    }
    return path;
  }
}
