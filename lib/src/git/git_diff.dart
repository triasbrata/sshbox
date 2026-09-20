import '../files/file_browser.dart';
import 'git_repo.dart' show GitException;

/// A diff open in a file tab of its own.
///
/// What `git diff` or `git show` printed is not a file on the host, so the tab
/// cannot read it over SFTP: it holds the command instead and runs it again
/// whenever the tab asks, which is what Reload from host does here.
class GitDiff {
  const GitDiff({
    required this.key,
    required this.title,
    required this.subtitle,
    required this.read,
  });

  /// Identifies the tab: the repository and what is being diffed. The same
  /// diff asked for twice goes back to the tab already open, while a file's
  /// staged and unstaged diffs are two of them.
  final String key;

  /// What the tab and the page's header say it is.
  final String title;

  /// The line under the title: where the file is, or what the commit did.
  final String subtitle;

  /// Runs the git command again and gives back what it printed.
  final Future<String> Function() read;

  /// What the file tab is told it is reading. The name ends in `.diff` so the
  /// editor colours added and removed lines with the highlighter it already
  /// has for that extension, and so nothing takes the text for Markdown.
  String get path => '$key.diff';
}

/// The one "file" a diff tab reads: [GitDiff.read] and nothing else.
///
/// It is a [FileBrowser] so the diff goes through the very same file tab a
/// real file does — the same loading, the same errors, the same Reload — with
/// no second viewer to keep working. Everything a diff has no answer for
/// throws rather than pretending: the tab is read-only, so none of it is
/// reachable from the page.
class GitDiffBrowser implements FileBrowser {
  const GitDiffBrowser(this.diff);

  final GitDiff diff;

  static const _notAFile = FileBrowserException(
    'This tab holds a diff, not a file on the host.',
  );

  /// Whatever git says, said the way the file tab expects to hear it: the tab
  /// shows a [FileBrowserException] as its error and anything else as an
  /// unhandled one, which would leave it spinning for ever.
  @override
  Future<RemoteText> readText(
    String path, {
    int maxBytes = FileBrowser.defaultReadLimit,
  }) async {
    try {
      return (text: await diff.read(), stamp: (modified: null, size: null));
    } on GitException catch (error) {
      throw FileBrowserException(error.message);
    } catch (error) {
      throw FileBrowserException('$error');
    }
  }

  @override
  Future<void> close() async {}

  @override
  Future<String> resolveHome() => throw _notAFile;

  @override
  Future<List<RemoteEntry>> list(String path) => throw _notAFile;

  @override
  Future<RemoteEntryKind?> stat(String path) => throw _notAFile;

  @override
  Future<FileStamp> writeText(
    String path,
    String text, {
    FileStamp? expected,
  }) => throw _notAFile;

  @override
  Future<void> rename(String from, String to) => throw _notAFile;

  @override
  Future<void> delete(String path, {bool recursive = false}) => throw _notAFile;

  @override
  Future<void> makeDirectory(String path) => throw _notAFile;

  @override
  Future<void> upload(
    String localPath,
    String path, {
    bool replace = false,
    void Function(int sent, int total)? onProgress,
    Future<void>? cancel,
  }) => throw _notAFile;

  @override
  Future<void> download(
    String path,
    String localPath, {
    int offset = 0,
    int? length,
    void Function(int received, int total)? onProgress,
    Future<void>? cancel,
  }) => throw _notAFile;
}
