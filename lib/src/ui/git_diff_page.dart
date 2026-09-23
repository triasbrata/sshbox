import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:re_highlight/re_highlight.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../files/file_browser.dart' show RemotePath;
import '../git/git_diff.dart';
import '../git/git_repo.dart' show GitException;
import 'code_languages.dart';
import 'file_editor_page.dart'
    show copyAndSay, copyLimit, editorFontSizeKey, tooLargeToCopy;
import 'settings_page.dart' show terminalSettings;
import 'toast.dart';
import 'tui.dart';

/// A diff drawn the way GitHub draws one, in a tab of its own: each file under
/// a header of its own, the old version beside the new with a line number on
/// each side, removed lines on red and added ones on green, an empty filler
/// where one side has lines the other has not, the code coloured by its
/// language, and the unchanged lines around each hunk a tap away.
///
/// It replaced the file tab showing git's text, which the user turned down
/// for looking nothing like this ("yang di expektasikan user adalah seperti
/// ini", with a screenshot of GitHub's split view). It keeps what of the file
/// tab still means something here — Find, copying the diff, Reload from host,
/// the text size — and leaves out Go to line, a diff having two sets of
/// numbers and Find covering it.
class GitDiffPage extends StatefulWidget {
  const GitDiffPage({super.key, required this.diff, this.onClose});

  final GitDiff diff;
  final VoidCallback? onClose;

  @override
  State<GitDiffPage> createState() => _GitDiffPageState();
}

/// ponytail: 900 dp of page. Below it each column of a split view has room
/// for about fifty characters, where nearly every line of code wraps, so a
/// phone, a tablet in portrait and a narrow pane of a tab group start
/// unified, and a tablet in landscape starts split. Either can be switched,
/// and the switch is remembered for that width alone: see [_prefsSplit].
const _splitWidth = 900.0;

/// Whether a wide page, or a narrow one, is split: a choice remembered for
/// each, so turning a tablet round lands on what was picked for that way up
/// rather than dragging one choice across both.
String _prefsSplit(bool wide) => 'gitDiff.split.${wide ? 'wide' : 'narrow'}';

/// How many unchanged lines one tap on an arrow shows, as GitHub does.
const _stepLines = 20;

/// ponytail: past these, the code is shown in the plain colour rather than
/// coloured by its language, which would hold the frame while it parsed.
const _highlightLimit = 256 * 1024;

typedef _Piece = (String, TextStyle?);

/// What one file of the diff shows beyond what git printed.
class _FileView {
  bool collapsed = false;

  /// The old side's lines, once read, which the lines between and around the
  /// hunks come from: they are the same on both sides.
  List<String>? old;
  bool reading = false;

  /// Lines shown of each gap: gap i is the one before hunk i, and the one
  /// after the last hunk is gap `hunks.length`. [top] are shown under the
  /// hunk above the gap, [bottom] over the hunk below it.
  final top = <int, int>{};
  final bottom = <int, int>{};

  /// The lines made for the gaps, by old line number, made once so a line
  /// stays one object and keeps its colours and its find matches.
  final lines = <int, DiffLine>{};
}

/// One gap between hunks: its old lines [start] to [end], [end] null while
/// the file's length is not known, and [delta] to turn an old number into
/// the new one.
typedef _Gap = ({int start, int? end, int delta, int top, int bottom});

sealed class _Item {
  const _Item();
}

class _PreambleItem extends _Item {
  const _PreambleItem(this.text);
  final String text;
}

class _FileItem extends _Item {
  const _FileItem(this.file);
  final int file;
}

class _NoticeItem extends _Item {
  const _NoticeItem(this.text, {this.raw = false});
  final String text;
  final bool raw;
}

/// A hunk's `@@` header, or the row under the last hunk, with the arrows
/// that show more of the gap before it.
class _HunkItem extends _Item {
  const _HunkItem(this.file, this.gap);
  final int file;
  final int gap;
}

class _RowItem extends _Item {
  const _RowItem(this.left, this.right);
  final DiffLine? left;
  final DiffLine? right;
}

class _LineItem extends _Item {
  const _LineItem(this.line);
  final DiffLine line;
}

class _GitDiffPageState extends State<GitDiffPage> {
  final _scroll = ScrollController();

  String? _raw;
  ParsedDiff? _parsed;
  List<_FileView> _views = const [];
  String? _error;
  bool _loading = true;

  /// Split or unified, for a wide page and a narrow one, until the user
  /// says otherwise: see [_prefsSplit].
  final _split = <bool, bool>{true: true, false: false};
  double _fontSize = 13;

  /// Each line's code in its language's colours, made once per brightness.
  final _pieces = <DiffLine, List<_Piece>>{};
  final _coloured = <DiffFile>{};
  final _paintedOld = <_FileView, List<List<_Piece>>?>{};
  Brightness? _piecesFor;

  bool _finding = false;
  final _query = TextEditingController();
  final _queryFocus = FocusNode();

  /// Where each match starts in its line, and every match in list order.
  final _found = <DiffLine, List<int>>{};
  var _matches = <({int item, DiffLine line, int start})>[];
  ({DiffLine line, int start})? _current;

  /// The rows the list has built, and the one a jump is going to: see
  /// [_reveal].
  List<_Item> _items = const [];
  final _alive = <int>{};
  final _targetKey = GlobalKey();
  int? _target;

  @override
  void initState() {
    super.initState();
    unawaited(_restoreLook());
    unawaited(_load());
  }

  @override
  void dispose() {
    _scroll.dispose();
    _query.dispose();
    _queryFocus.dispose();
    super.dispose();
  }

  Future<void> _restoreLook() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _fontSize = prefs.getDouble(editorFontSizeKey) ?? _fontSize;
      for (final wide in [true, false]) {
        _split[wide] = prefs.getBool(_prefsSplit(wide)) ?? _split[wide]!;
      }
    });
  }

  Future<void> _setSplit(bool wide, bool split) async {
    setState(() => _split[wide] = split);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsSplit(wide), split);
  }

  Future<void> _setFontSize(double size) async {
    setState(() => _fontSize = size.clamp(9, 24).toDouble());
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(editorFontSizeKey, _fontSize);
  }

  /// Runs git again. What was on screen stays there until the answer comes,
  /// so the list keeps its place, and a diff that came back shorter settles
  /// at its end.
  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final text = await widget.diff.read();
      if (!mounted) return;
      final parsed = parseDiff(text);
      setState(() {
        _raw = text;
        _parsed = parsed;
        _views = [for (final _ in parsed.files) _FileView()];
        _pieces.clear();
        _coloured.clear();
        _paintedOld.clear();
      });
    } on GitException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (error) {
      // Anything else too: a tab left spinning for ever says nothing.
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ---------------------------------------------------------------- gaps

  _Gap _gap(DiffFile file, _FileView view, int g) {
    final hunks = file.hunks;
    final int start;
    final int? end;
    final int delta;
    if (g < hunks.length) {
      start = g == 0 ? 1 : hunks[g - 1].oldEnd;
      end = hunks[g].oldFrom;
      delta = hunks[g].newFrom - hunks[g].oldFrom;
    } else {
      final last = hunks.last;
      start = last.oldEnd;
      delta = last.newEnd - last.oldEnd;
      // A last old line with no newline is the end of the file.
      final ends = last.lines
          .lastWhere(
            (line) => line.oldNo != null,
            orElse: () => DiffLine(DiffLineKind.context, ''),
          )
          .noNewline;
      final old = view.old;
      end = ends
          ? start
          : old == null
          ? null
          : math.max(start, old.length + 1);
    }
    return (
      start: start,
      end: end,
      delta: delta,
      top: view.top[g] ?? 0,
      bottom: view.bottom[g] ?? 0,
    );
  }

  /// Lines of the gap still hidden, or null while the file's end is unknown.
  int? _hidden(_Gap gap) =>
      gap.end == null ? null : gap.end! - gap.start - gap.top - gap.bottom;

  List<DiffLine> _gapLines(_FileView view, _Gap gap, int from, int to) {
    final old = view.old;
    if (old == null) return const [];
    return [
      for (var n = from; n < to; n++)
        view.lines.putIfAbsent(
          n,
          // Past the text read, a line can only be blank: the runner trims
          // the blank lines off the end of what it reads.
          () => DiffLine(
            DiffLineKind.context,
            n - 1 < old.length ? old[n - 1] : '',
            oldNo: n,
            newNo: n + gap.delta,
          ),
        ),
    ];
  }

  /// Shows more of gap [g] of file [f]: [top] lines under the hunk above it,
  /// [bottom] over the hunk below, or the whole of it. Reads the old side
  /// first, once per file.
  Future<void> _expand(
    int f,
    int g, {
    int top = 0,
    int bottom = 0,
    bool all = false,
  }) async {
    final view = _views[f];
    final file = _parsed!.files[f];
    if (view.old == null) {
      final read = widget.diff.blob;
      final id = file.oldBlob;
      if (read == null || id == null || view.reading) return;
      setState(() => view.reading = true);
      try {
        final text = await read(id);
        view.old = text.isEmpty ? const [] : text.split('\n');
      } on GitException catch (error) {
        if (mounted) {
          showToast(context, error.message, type: TuiToastType.error);
        }
      } catch (error) {
        if (mounted) {
          showToast(context, '$error', type: TuiToastType.error);
        }
      } finally {
        view.reading = false;
        if (mounted) setState(() {});
      }
      // A Reload while it was read leaves this view behind.
      if (!mounted || view.old == null || !_views.contains(view)) return;
    }
    setState(() {
      final gaps = all ? [for (var n = 0; n <= file.hunks.length; n++) n] : [g];
      for (final gap in gaps) {
        final at = _gap(file, view, gap);
        final hidden = _hidden(at) ?? 0;
        if (all || top + bottom >= hidden) {
          // Above the first hunk, what is shown sits under its header,
          // which says where the file's changes start; anywhere else the
          // gap closes and the hunks run on as one.
          final size = at.end! - at.start;
          view.top[gap] = gap == 0 ? 0 : size;
          view.bottom[gap] = gap == 0 ? size : 0;
        } else {
          view.top[gap] = at.top + top;
          view.bottom[gap] = at.bottom + bottom;
        }
      }
    });
  }

  // --------------------------------------------------------------- items

  /// The diff as rows of a list, so only what is on screen is ever built.
  List<_Item> _itemsOf(ParsedDiff parsed, {required bool split}) {
    final items = <_Item>[
      if (parsed.preamble.isNotEmpty) _PreambleItem(parsed.preamble),
    ];
    void lines(List<DiffLine> lines) {
      if (split) {
        for (final row in splitRows(lines)) {
          items.add(_RowItem(row.left, row.right));
        }
      } else {
        items.addAll(lines.map(_LineItem.new));
      }
    }

    final more = widget.diff.blob != null;
    for (var f = 0; f < parsed.files.length; f++) {
      final file = parsed.files[f];
      final view = _views[f];
      items.add(_FileItem(f));
      if (view.collapsed) continue;
      if (file.combined) {
        items.add(_NoticeItem(file.raw, raw: true));
        continue;
      }
      if (file.binary) {
        items.add(const _NoticeItem('Binary file, not shown.'));
        continue;
      }
      if (file.hunks.isEmpty) {
        items.add(_NoticeItem(_nothingShown(file)));
        continue;
      }
      final expandable = more && file.expandable;
      for (var g = 0; g <= file.hunks.length; g++) {
        final gap = _gap(file, view, g);
        final hidden = _hidden(gap);
        lines(_gapLines(view, gap, gap.start, gap.start + gap.top));
        final last = g == file.hunks.length;
        if (last
            ? expandable && hidden != 0
            : g == 0 || !expandable || hidden != 0) {
          items.add(_HunkItem(f, g));
        }
        if (gap.end case final end?) {
          lines(_gapLines(view, gap, end - gap.bottom, end));
        }
        if (!last) lines(file.hunks[g].lines);
      }
    }
    return items;
  }

  static String _nothingShown(DiffFile file) {
    if (file.renamed) return 'File renamed without changes.';
    if (file.copied) return 'File copied without changes.';
    if (file.oldMode != null && file.newMode != null) {
      return 'File mode changed from ${file.oldMode} to ${file.newMode}.';
    }
    if (file.isNew) return 'Empty file added.';
    if (file.isDeleted) return 'Empty file deleted.';
    return 'No changes to show.';
  }

  // -------------------------------------------------------------- colour

  /// Colours a file's code by its language: each hunk's old side and its new
  /// side as a piece of code of their own, so a comment or a string that
  /// runs over several lines is coloured as one.
  void _colour(DiffFile file, Map<String, TextStyle> colours) {
    if (!_coloured.add(file)) return;
    final mode = codeModeFor(file.path);
    if (mode == null || file.raw.length > _highlightLimit) return;
    for (final hunk in file.hunks) {
      final old = [
        for (final line in hunk.lines)
          if (line.kind != DiffLineKind.added) line,
      ];
      final now = [
        for (final line in hunk.lines)
          if (line.kind != DiffLineKind.removed) line,
      ];
      _paint(mode, colours, old);
      _paint(mode, colours, now);
    }
  }

  void _paint(Mode mode, Map<String, TextStyle> colours, List<DiffLine> lines) {
    final painted = _highlight(
      mode,
      colours,
      lines.map((line) => line.text).join('\n'),
    );
    if (painted == null) return;
    for (var n = 0; n < lines.length && n < painted.length; n++) {
      _pieces[lines[n]] = painted[n];
    }
  }

  /// The old side of a file read for its gaps, coloured whole once, and each
  /// line of it shown so far given its colours.
  void _colourGaps(
    DiffFile file,
    _FileView view,
    Map<String, TextStyle> colours,
  ) {
    final old = view.old;
    if (old == null || view.lines.isEmpty) return;
    final unpainted = [
      for (final line in view.lines.values)
        if (!_pieces.containsKey(line)) line,
    ];
    if (unpainted.isEmpty) return;
    final painted = _paintedOld.putIfAbsent(view, () {
      final mode = codeModeFor(file.path);
      final text = old.join('\n');
      return mode == null || text.length > _highlightLimit
          ? null
          : _highlight(mode, colours, text);
    });
    for (final line in unpainted) {
      final n = line.oldNo! - 1;
      _pieces[line] = painted != null && n < painted.length
          ? painted[n]
          : [(line.text, null)];
    }
  }

  static final _highlighters = <Mode, Highlight>{};

  static List<List<_Piece>>? _highlight(
    Mode mode,
    Map<String, TextStyle> colours,
    String code,
  ) {
    try {
      final highlight = _highlighters.putIfAbsent(
        mode,
        () => Highlight()..registerLanguage('code', mode),
      );
      final renderer = _LineRenderer(colours);
      highlight.highlight(code: code, language: 'code').render(renderer);
      return renderer.lines;
    } catch (_) {
      // Plain beats nothing: a language that trips on a line still shows it.
      return null;
    }
  }

  // ---------------------------------------------------------------- find

  void _openFind() {
    setState(() => _finding = true);
    _queryFocus.requestFocus();
    _query.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _query.text.length,
    );
  }

  void _closeFind() {
    setState(() {
      _finding = false;
      _current = null;
    });
  }

  /// Every match of the query in the rows now in the list, in order. Run on
  /// every build, so a gap shown or a file folded is searched as it now is.
  void _search() {
    _found.clear();
    final matches = <({int item, DiffLine line, int start})>[];
    final needle = _query.text.toLowerCase();
    if (_finding && needle.isNotEmpty) {
      for (var i = 0; i < _items.length; i++) {
        final item = _items[i];
        final lines = switch (item) {
          _RowItem(:final left, :final right) => [
            ?left,
            if (!identical(left, right)) ?right,
          ],
          _LineItem(:final line) => [line],
          _ => const <DiffLine>[],
        };
        for (final line in lines) {
          final hay = line.text.toLowerCase();
          for (
            var at = hay.indexOf(needle);
            at != -1;
            at = hay.indexOf(needle, at + needle.length)
          ) {
            (_found[line] ??= []).add(at);
            matches.add((item: i, line: line, start: at));
          }
        }
      }
    }
    _matches = matches;
  }

  int get _currentIndex => _matches.indexWhere(
    (match) =>
        identical(match.line, _current?.line) && match.start == _current?.start,
  );

  void _step(int by) {
    if (_matches.isEmpty) return;
    final at = _currentIndex;
    final next = at == -1
        ? (by > 0 ? 0 : _matches.length - 1)
        : (at + by) % _matches.length;
    final match = _matches[next];
    setState(() => _current = (line: match.line, start: match.start));
    _reveal(match.item);
  }

  /// Scrolls row [index] into view. The rows wrap to whatever height their
  /// text needs, so where one sits is not known until it is built: this
  /// jumps by how tall the rows built so far are, and repeats until the one
  /// wanted is among them.
  void _reveal(int index, [int tries = 0]) {
    setState(() => _target = index);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _target != index) return;
      final built = _targetKey.currentContext;
      if (built != null) {
        unawaited(
          Scrollable.ensureVisible(
            built,
            alignment: 0.3,
            duration: const Duration(milliseconds: 150),
          ),
        );
        return;
      }
      if (tries >= 12 || !_scroll.hasClients || _alive.isEmpty) return;
      final first = _alive.reduce(math.min);
      final last = _alive.reduce(math.max);
      final position = _scroll.position;
      // The rows built fill the screen and the cache on either side of it.
      final each =
          (position.viewportDimension + 500) / math.max(1, last - first + 1);
      final offset = index < first
          ? position.pixels - (first - index) * each
          : position.pixels + (index - last) * each;
      _scroll.jumpTo(
        offset.clamp(position.minScrollExtent, position.maxScrollExtent),
      );
      _reveal(index, tries + 1);
    });
  }

  // --------------------------------------------------------------- build

  Future<void> _copyAll() {
    final raw = _raw ?? '';
    if (raw.length > copyLimit) {
      showToast(
        context,
        tooLargeToCopy('This diff'),
        type: TuiToastType.warning,
      );
      return Future.value();
    }
    return copyAndSay(
      context,
      'the diff',
      () => Clipboard.setData(ClipboardData(text: raw)),
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final wide = constraints.maxWidth >= _splitWidth;
      final split = _split[wide]!;
      final ready = _parsed != null && _error == null;
      return Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: false,
          leading: IconButton(
            tooltip: 'Close diff',
            icon: const Icon(Icons.close),
            onPressed: widget.onClose,
          ),
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(widget.diff.title, overflow: TextOverflow.ellipsis),
              Text(
                widget.diff.subtitle,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
          bottom: _loading && _parsed != null
              ? const PreferredSize(
                  preferredSize: Size.fromHeight(3),
                  child: TuiProgressBar(),
                )
              : null,
          actions: [
            // Says what a tap gives, as the file tab's Preview and Source do.
            IconButton(
              tooltip: split ? 'Unified view' : 'Split view',
              onPressed: () => _setSplit(wide, !split),
              icon: Icon(
                split
                    ? Icons.view_agenda_outlined
                    : Icons.vertical_split_outlined,
              ),
            ),
            IconButton(
              tooltip: 'Find',
              onPressed: ready ? _openFind : null,
              icon: const Icon(Icons.search),
            ),
            IconButton(
              tooltip: 'Reload from host',
              onPressed: _loading ? null : _load,
              icon: const Icon(Icons.refresh),
            ),
            MenuButton<VoidCallback>(
              tooltip: 'More',
              onSelected: (action) => action(),
              entries: [
                if (ready) menuAction('Copy diff', _copyAll),
                if (ready && _views.isNotEmpty) ...[
                  menuAction(
                    _views.any((view) => !view.collapsed)
                        ? 'Collapse all files'
                        : 'Expand all files',
                    () => setState(() {
                      final fold = _views.any((view) => !view.collapsed);
                      for (final view in _views) {
                        view.collapsed = fold;
                      }
                    }),
                  ),
                ],
                const TuiMenuDivider(),
                menuAction('Larger text', () => _setFontSize(_fontSize + 1)),
                menuAction('Smaller text', () => _setFontSize(_fontSize - 1)),
              ],
            ),
          ],
        ),
        body: _body(context, split: split),
      );
    },
  );

  Widget _body(BuildContext context, {required bool split}) {
    final parsed = _parsed;
    if (parsed == null) {
      if (_error case final error?) return _Failure(error);
      return const Center(child: TuiSpinner());
    }
    if (_error case final error?) return _Failure(error);
    if (parsed.files.isEmpty && parsed.preamble.isEmpty) {
      return const Center(child: Text('No changes'));
    }

    final theme = Theme.of(context);
    if (_piecesFor != theme.brightness) {
      _piecesFor = theme.brightness;
      _pieces.clear();
      _coloured.clear();
      _paintedOld.clear();
    }
    final colours = codeColoursFor(theme.brightness);
    for (var f = 0; f < parsed.files.length; f++) {
      if (_views[f].collapsed) continue;
      _colour(parsed.files[f], colours);
      _colourGaps(parsed.files[f], _views[f], colours);
    }

    _items = _itemsOf(parsed, split: split);
    _search();

    return ValueListenableBuilder(
      valueListenable: terminalSettings,
      builder: (context, terminal, _) {
        final look = _Look.of(
          context,
          TextStyle(
            fontFamily: terminal.fontFamily,
            fontFamilyFallback: terminal.fontFamilyFallback,
            fontSize: _fontSize,
            height: 1.45,
            color: theme.colorScheme.onSurface,
          ),
          digits: _digits(parsed),
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_finding) _findBar(theme),
            Expanded(
              child: SelectionArea(
                child: ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.only(bottom: 24),
                  itemCount: _items.length,
                  itemBuilder: (context, i) => _Tracked(
                    index: i,
                    alive: _alive,
                    child: KeyedSubtree(
                      key: i == _target ? _targetKey : null,
                      child: _row(context, _items[i], look, split: split),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// Digits enough for the longest line number anywhere in the diff, so every
  /// row's numbers line up.
  int _digits(ParsedDiff parsed) {
    var most = 0;
    for (var f = 0; f < parsed.files.length; f++) {
      for (final hunk in parsed.files[f].hunks) {
        most = math.max(most, math.max(hunk.oldEnd, hunk.newEnd));
      }
      final old = _views[f].old;
      if (old != null && parsed.files[f].hunks.isNotEmpty) {
        final last = parsed.files[f].hunks.last;
        most = math.max(most, old.length + last.newEnd - last.oldEnd);
      }
    }
    return math.max(3, '$most'.length);
  }

  Widget _findBar(ThemeData theme) {
    final at = _currentIndex;
    final count = _query.text.isEmpty
        ? ''
        : _matches.isEmpty
        ? 'No results'
        : '${at == -1 ? '–' : at + 1}/${_matches.length}';
    return Material(
      color: theme.colorScheme.surfaceContainerHigh,
      child: SizedBox(
        height: 48,
        child: Row(
          children: [
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _query,
                focusNode: _queryFocus,
                autocorrect: false,
                enableSuggestions: false,
                style: TextStyle(fontFamily: TermulFonts.mono, fontSize: 14),
                decoration: const InputDecoration(
                  hintText: 'Find',
                  border: InputBorder.none,
                  isDense: true,
                ),
                // The first match is shown as the query is typed, the way a
                // browser's find does.
                onChanged: (_) {
                  setState(() => _current = null);
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted && _matches.isNotEmpty) _step(1);
                  });
                },
                onSubmitted: (_) {
                  _step(1);
                  _queryFocus.requestFocus();
                },
              ),
            ),
            Text(count, style: theme.textTheme.bodySmall),
            IconButton(
              tooltip: 'Previous match',
              onPressed: _matches.isEmpty ? null : () => _step(-1),
              icon: const Icon(Icons.keyboard_arrow_up),
            ),
            IconButton(
              tooltip: 'Next match',
              onPressed: _matches.isEmpty ? null : () => _step(1),
              icon: const Icon(Icons.keyboard_arrow_down),
            ),
            IconButton(
              tooltip: 'Close find',
              onPressed: _closeFind,
              icon: const Icon(Icons.close),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(
    BuildContext context,
    _Item item,
    _Look look, {
    required bool split,
  }) => switch (item) {
    _PreambleItem(:final text) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(text, style: look.code),
    ),
    _FileItem(:final file) => _fileHeader(context, file, look),
    _NoticeItem(:final text, :final raw) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Text(
        text,
        style: raw
            ? look.code
            : Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
      ),
    ),
    _HunkItem(:final file, :final gap) => _hunkHeader(
      file,
      gap,
      look,
      split: split,
    ),
    _RowItem(:final left, :final right) => IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: _side(left, look, old: true)),
          ColoredBox(color: look.divider, child: const SizedBox(width: 1)),
          Expanded(child: _side(right, look, old: false)),
        ],
      ),
    ),
    _LineItem(:final line) => IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _number(line, line.oldNo, look),
          _number(line, line.newNo, look),
          Expanded(child: _code(line, look)),
        ],
      ),
    ),
  };

  /// One side of a split row: the number, the sign and the code, or the
  /// filler that keeps what follows level with the other side.
  Widget _side(DiffLine? line, _Look look, {required bool old}) {
    if (line == null) {
      return ColoredBox(
        key: const ValueKey('diff-filler'),
        color: look.filler(old: old),
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _number(line, old ? line.oldNo : line.newNo, look),
        Expanded(child: _code(line, look)),
      ],
    );
  }

  Widget _number(DiffLine line, int? number, _Look look) => Container(
    width: look.gutter,
    color: look.gutterFor(line.kind),
    padding: const EdgeInsets.symmetric(horizontal: 8),
    alignment: Alignment.topRight,
    child: SelectionContainer.disabled(
      child: Text(
        number == null ? '' : '$number',
        style: line.kind == DiffLineKind.context
            ? look.number
            : look.number.copyWith(color: look.code.color),
      ),
    ),
  );

  Widget _code(DiffLine line, _Look look) {
    final pieces = _pieces[line] ?? [(line.text, null)];
    return Container(
      color: look.codeFor(line.kind),
      padding: const EdgeInsets.only(right: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: look.sign,
            child: SelectionContainer.disabled(
              child: Text(
                switch (line.kind) {
                  DiffLineKind.added => '+',
                  DiffLineKind.removed => '-',
                  DiffLineKind.context => '',
                },
                textAlign: TextAlign.center,
                style: look.code,
              ),
            ),
          ),
          Expanded(
            child: Text.rich(
              TextSpan(
                style: look.code,
                children: [
                  ..._spans(pieces, line, look),
                  if (line.noNewline)
                    WidgetSpan(
                      alignment: PlaceholderAlignment.middle,
                      child: TuiTooltip(
                        message: 'No newline at end of file',
                        child: Padding(
                          padding: const EdgeInsets.only(left: 6),
                          child: Icon(
                            Icons.do_not_disturb_on_outlined,
                            size: look.code.fontSize,
                            color: look.p.red,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The code's colours with the find matches painted over them.
  List<InlineSpan> _spans(List<_Piece> pieces, DiffLine line, _Look look) {
    final starts = _found[line];
    if (starts == null) {
      return [
        for (final (text, style) in pieces) TextSpan(text: text, style: style),
      ];
    }
    final length = _query.text.length;
    final current = identical(_current?.line, line) ? _current!.start : null;
    final spans = <InlineSpan>[];
    var at = 0;
    for (final (text, style) in pieces) {
      var from = 0;
      while (from < text.length) {
        final here = at + from;
        final hit = starts
            .where((start) => start <= here && here < start + length)
            .firstOrNull;
        final int until;
        TextStyle? paint = style;
        if (hit != null) {
          until = math.min(text.length, hit + length - at);
          paint = (style ?? const TextStyle()).copyWith(
            backgroundColor: hit == current ? look.current : look.match,
          );
        } else {
          final next = starts.where((start) => start > here).firstOrNull;
          until = next == null ? text.length : math.min(text.length, next - at);
        }
        spans.add(TextSpan(text: text.substring(from, until), style: paint));
        from = until;
      }
      at += text.length;
    }
    return spans;
  }

  Widget _hunkHeader(int f, int g, _Look look, {required bool split}) {
    final file = _parsed!.files[f];
    final view = _views[f];
    final gap = _gap(file, view, g);
    final hidden = _hidden(gap);
    final last = g == file.hunks.length;
    final expandable = widget.diff.blob != null && file.expandable;

    // termul's expand buttons: a glyph in the accent.
    Widget arrow(String glyph, String tip, VoidCallback onTap) => TuiTooltip(
      message: tip,
      child: InkWell(
        onTap: view.reading ? null : onTap,
        hoverColor: look.p.selection,
        child: SizedBox(
          height: 28,
          width: double.infinity,
          child: Center(
            child: Text(
              glyph,
              style: TextStyle(
                fontFamily: TermulFonts.mono,
                fontSize: 10,
                color: look.p.accent,
              ),
            ),
          ),
        ),
      ),
    );

    final arrows = <Widget>[
      if (!expandable || hidden == 0)
        const SizedBox.shrink()
      else if (hidden != null && hidden <= _stepLines)
        arrow(
          '⇕',
          'Show $hidden hidden line${hidden == 1 ? '' : 's'}',
          () => _expand(f, g, all: false, top: hidden),
        )
      else ...[
        if (g > 0)
          arrow(
            '▼',
            'Show $_stepLines more lines below',
            () => _expand(f, g, top: _stepLines),
          ),
        if (!last)
          arrow(
            '▲',
            'Show $_stepLines more lines above',
            () => _expand(f, g, bottom: _stepLines),
          ),
      ],
    ];

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            width: split ? look.gutter : look.gutter * 2,
            color: look.arrows,
            child: view.reading
                ? const Center(
                    child: SizedBox.square(dimension: 14, child: TuiSpinner()),
                  )
                : Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: arrows,
                  ),
          ),
          Expanded(
            child: Container(
              color: look.hunk,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              alignment: Alignment.centerLeft,
              constraints: const BoxConstraints(minHeight: 32),
              child: Text(
                last ? '' : file.hunks[g].header,
                style: TextStyle(
                  fontFamily: TermulFonts.mono,
                  fontSize: 11,
                  color: look.p.cyan,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _fileHeader(BuildContext context, int f, _Look look) {
    final file = _parsed!.files[f];
    final view = _views[f];
    final expandable = widget.diff.blob != null && file.expandable;
    final name = (file.renamed || file.copied) && file.oldPath != file.newPath
        ? '${file.oldPath} → ${file.newPath}'
        : file.path;
    void wholeFile() => _expand(f, 0, all: true);
    final p = look.p;
    TextStyle mono(double size, Color color, [FontWeight? weight]) => TextStyle(
      fontFamily: TermulFonts.mono,
      fontSize: size,
      color: color,
      fontWeight: weight,
    );
    // termul's file header: the fold, the change bar, the counts, the path,
    // and the file's own actions on the right.
    return Padding(
      padding: EdgeInsets.only(top: f == 0 ? 0 : 12),
      child: Material(
        color: p.surface,
        shape: Border.all(color: p.border),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 4, 6),
          child: Row(
            children: [
              TuiTooltip(
                message: view.collapsed ? 'Show this file' : 'Hide this file',
                child: Semantics(
                  button: true,
                  label: view.collapsed ? 'Show this file' : 'Hide this file',
                  child: InkWell(
                    onTap: () =>
                        setState(() => view.collapsed = !view.collapsed),
                    hoverColor: p.selection,
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Text(
                        view.collapsed ? '▸' : '▾',
                        style: mono(12, p.dim),
                      ),
                    ),
                  ),
                ),
              ),
              TuiChangeBar(added: file.added, removed: file.removed),
              const SizedBox(width: 8),
              SelectionContainer.disabled(
                child: Text('+${file.added}', style: mono(11, p.green)),
              ),
              const SizedBox(width: 4),
              SelectionContainer.disabled(
                child: Text('−${file.removed}', style: mono(11, p.red)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: mono(12, p.text, FontWeight.w500),
                ),
              ),
              if (expandable)
                TuiIconButton(
                  icon: '⇕',
                  tooltip: 'Show the whole file',
                  size: 32,
                  iconSize: 14,
                  onPressed: view.reading ? null : wholeFile,
                ),
              TuiIconButton(
                icon: '⎘',
                tooltip: 'Copy path',
                size: 32,
                iconSize: 14,
                onPressed: () => copyAndSay(
                  context,
                  'the path',
                  () => Clipboard.setData(ClipboardData(text: file.path)),
                ),
              ),
              MenuButton<VoidCallback>(
                tooltip: 'File actions',
                icon: '⋯',
                onSelected: (action) => action(),
                entries: [
                  menuAction('Copy this file\'s diff', () {
                    if (file.raw.length > copyLimit) {
                      showToast(
                        context,
                        tooLargeToCopy(file.path),
                        type: TuiToastType.warning,
                      );
                      return;
                    }
                    unawaited(
                      copyAndSay(
                        context,
                        'the diff of ${RemotePath.basename(file.path)}',
                        () => Clipboard.setData(ClipboardData(text: file.raw)),
                      ),
                    );
                  }),
                  if (expandable) menuAction('Show the whole file', wholeFile),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Sizes and colours every row shares, worked out once a build.
class _Look {
  _Look._({
    required this.code,
    required this.number,
    required this.gutter,
    required this.p,
    required this.sign,
    required this.divider,
    required this.hunk,
    required this.arrows,
    required this.match,
    required this.current,
  });

  factory _Look.of(
    BuildContext context,
    TextStyle code, {
    required int digits,
  }) {
    final p = TermulThemeData.of(context).palette;
    final painter = TextPainter(
      text: TextSpan(text: '0' * digits, style: code),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    final width = painter.width;
    final char = width / digits;
    painter.dispose();
    return _Look._(
      p: p,
      code: code,
      number: code.copyWith(color: p.dim),
      gutter: width + 16,
      sign: char * 2,
      divider: p.border,
      hunk: p.selection,
      arrows: p.selection,
      match: Colors.amber.withValues(alpha: 0.35),
      current: Colors.orange.withValues(alpha: 0.8),
    );
  }

  final TextStyle code;
  final TextStyle number;
  final double gutter;
  final double sign;
  final TermulPalette p;
  final Color divider;
  final Color hunk;
  final Color arrows;
  final Color match;
  final Color current;

  /// termul's tint for a line of [kind], under its number and its code
  /// alike, as termul's diff rows are washed.
  Color? codeFor(DiffLineKind kind) => switch (kind) {
    DiffLineKind.added => p.green.withValues(alpha: p.isLight ? 0.12 : 0.2),
    DiffLineKind.removed => p.red.withValues(alpha: p.isLight ? 0.12 : 0.22),
    DiffLineKind.context => null,
  };

  Color? gutterFor(DiffLineKind kind) => codeFor(kind);

  /// Where one side has no line, termul's tint for what the other side did,
  /// faded.
  Color filler({required bool old}) =>
      codeFor(old ? DiffLineKind.removed : DiffLineKind.added)!
          .withValues(alpha: (p.isLight ? 0.12 : 0.21) * 0.35);
}

class _Failure extends StatelessWidget {
  const _Failure(this.message);

  final String message;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline, color: Theme.of(context).colorScheme.error),
          const SizedBox(height: 12),
          SelectableText(message, textAlign: TextAlign.center),
        ],
      ),
    ),
  );
}

/// Keeps [alive] holding the index of every row the list has built, which is
/// how [_GitDiffPageState._reveal] knows where it has landed.
class _Tracked extends StatefulWidget {
  const _Tracked({
    required this.index,
    required this.alive,
    required this.child,
  });

  final int index;
  final Set<int> alive;
  final Widget child;

  @override
  State<_Tracked> createState() => _TrackedState();
}

class _TrackedState extends State<_Tracked> {
  @override
  void initState() {
    super.initState();
    widget.alive.add(widget.index);
  }

  @override
  void didUpdateWidget(_Tracked old) {
    super.didUpdateWidget(old);
    if (old.index != widget.index) {
      widget.alive
        ..remove(old.index)
        ..add(widget.index);
    }
  }

  @override
  void dispose() {
    widget.alive.remove(widget.index);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Turns re_highlight's tree into lines of coloured pieces, a line of the
/// code to a list: a diff draws each line in a row of its own, and a string
/// or a comment that spans lines has to be split where they are.
class _LineRenderer implements HighlightRenderer {
  _LineRenderer(this.colours);

  final Map<String, TextStyle> colours;
  final lines = <List<_Piece>>[[]];
  final _styles = <TextStyle?>[];

  @override
  void addText(String text) {
    final style = _styles.lastOrNull;
    final parts = text.split('\n');
    for (var n = 0; n < parts.length; n++) {
      if (n > 0) lines.add([]);
      if (parts[n].isNotEmpty) lines.last.add((parts[n], style));
    }
  }

  @override
  void openNode(DataNode node) {
    final scope = node.scope;
    // `title.function` falls back to `title`; the root's own style, with
    // its background, is never taken.
    final own = scope == null || scope == 'root'
        ? null
        : colours[scope] ?? colours[scope.split('.').first];
    final outer = _styles.lastOrNull;
    _styles.add(
      outer == null
          ? own
          : own == null
          ? outer
          : outer.merge(own),
    );
  }

  @override
  void closeNode(DataNode node) {
    if (_styles.isNotEmpty) _styles.removeLast();
  }
}
