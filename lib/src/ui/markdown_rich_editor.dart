import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'key_bar.dart';
import 'markdown_live.dart';
import 'save_chord.dart';
import 'termul/termul_palette.dart';
import 'termul/termul_theme.dart';
import 'termul/tui_checkbox.dart';

export 'markdown_live.dart' show MdLink;

/// A Markdown file edited as one document, the way Obsidian's live preview
/// edits one: a single text field whose text is the file itself, byte for
/// byte, drawn so that `**`, `_`, `` ` ``, `#`, links, bullets and `>` hide
/// away from the caret and show where it is, and a table, a code fence, a
/// rule and a picture draw rendered until the caret goes into them.
///
/// Since the text is the source, nothing is ever written that was not typed:
/// opened and saved untouched, the file is as it was, and a typed letter is
/// that letter. The caret, the arrow keys, a selection, copy and paste all
/// run through the whole document as in any editor, because it is one field.
///
/// Every change goes out through [onChanged] as the whole new text, and
/// anything that changes [text] from outside — an undo, a reload, an edit in
/// Source — is read back in. That keeps one text, one save and one undo
/// history for both modes.
class MarkdownRichEditor extends StatefulWidget {
  const MarkdownRichEditor({
    super.key,
    required this.text,
    required this.onChanged,
    required this.blockBuilder,
    required this.onOpenLink,
    required this.onRefused,
    required this.askLink,
    this.onUndo,
    this.onRedo,
    this.at = 0,
    this.onScroll,
    this.controller,
    this.codeFont,
  });

  final String text;

  /// The document after an edit. [coalesce] is set while the user goes on
  /// typing, so one undo takes back the run, not a letter.
  final void Function(String text, {required bool coalesce}) onChanged;

  /// Draws a table, a code fence or a picture from its Markdown, while the
  /// caret is not in it.
  final Widget Function(BuildContext context, String markdown) blockBuilder;

  final void Function(MdLink link) onOpenLink;

  /// Says why something asked for was not done.
  final void Function(String message) onRefused;

  /// Asks for a link's address, [current] filled in; null when cancelled and
  /// empty to take the link off.
  final Future<String?> Function(String? current) askLink;

  final VoidCallback? onUndo;
  final VoidCallback? onRedo;

  /// Where it was last left, in pixels.
  final double at;
  final ValueChanged<double>? onScroll;

  /// For the accessory bar below the page on a phone.
  final MarkdownRichController? controller;

  /// Code's face: the terminal's, following Settings. The reading text is
  /// the platform's own sans serif.
  final TextStyle? codeFont;

  /// ponytail: the whole document is one paragraph, laid out again on every
  /// key, at a cost that grows with how much markup it has: about 100 ms a
  /// key for an 83 KB README in a debug build (see the PR). Past this a file
  /// opens in Source, which lays out only the lines on screen.
  static const limit = 160 * 1024;

  /// Whether the formatting goes in a bar floating over a selection, as on
  /// Medium, rather than in the bar over the keyboard.
  static bool get floatingBar => !_touchPlatform;

  static bool get _touchPlatform =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  @override
  State<MarkdownRichEditor> createState() => _MarkdownRichEditorState();
}

/// What the formatting bars read and do, for the caret or the selection.
class MarkdownRichController extends ChangeNotifier {
  _MarkdownRichEditorState? _state;

  /// The marks at the caret, or across the selection; null while the editor
  /// has no caret.
  MdFormat? get format => _state?._format();

  void toggleBold() => _state?._toggleInline('**', MdMark.bold);
  void toggleItalic() => _state?._toggleInline('_', MdMark.italic);
  void toggleCode() => _state?._toggleInline('`', MdMark.code);
  Future<void> editLink() async => _state?._editLink();
  void toggleHeading(int level) => _state?._toggleHeading(level);
  void toggleQuote() => _state?._toggleQuote();

  bool _scheduled = false;
  bool _disposed = false;

  /// Tells the bars, after the frame when the change came during a build: a
  /// read-back from an undo happens while the page builds.
  void _changed() {
    if (SchedulerBinding.instance.schedulerPhase !=
        SchedulerPhase.persistentCallbacks) {
      notifyListeners();
      return;
    }
    if (_scheduled) return;
    _scheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!_disposed) notifyListeners();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// What is on where the caret is, for lighting the bars.
@immutable
class MdFormat {
  const MdFormat({
    this.bold = false,
    this.italic = false,
    this.code = false,
    this.link = false,
    this.heading = 0,
    this.quote = false,
  });

  final bool bold;
  final bool italic;
  final bool code;
  final bool link;
  final int heading;
  final bool quote;
}

/// How the document is drawn: the reading face and what each mark does to
/// it. Built from the palette and the column's width on every build.
class MdLiveLook {
  MdLiveLook({
    required this.base,
    required this.code,
    required this.palette,
    required this.width,
  });

  final TextStyle base;
  final TextStyle code;
  final TermulPalette palette;
  final double width;

  late final double size = base.fontSize!;

  /// The style the whole text sits in, which is also the paragraph's own:
  /// at line height 1, since its 1.6 would add its leading round a line
  /// that holds a section drawn apart. Every run of text carries its own
  /// style, line height included.
  late final TextStyle root = base.copyWith(height: 1);

  late final hidden = TextStyle(
    fontSize: 0.01,
    height: 1,
    letterSpacing: 0,
    wordSpacing: 0,
    color: const Color(0x00000000),
    backgroundColor: const Color(0x00000000),
    decoration: TextDecoration.none,
  );

  static const _scale = [1.0, 1.75, 1.45, 1.25, 1.1, 1.0, 0.9];

  final _cache = <int, TextStyle>{};

  TextStyle of(int marks) => _cache.putIfAbsent(marks, () => _build(marks));

  TextStyle _build(int marks) {
    final p = palette;
    var s = base;
    if (marks & MdMark.gap != 0) {
      return s.copyWith(fontSize: size * 0.5, height: 1);
    }
    if (marks & (MdMark.codeBlock | MdMark.code) != 0) {
      s = s
          .merge(code)
          .copyWith(
            fontSize: size * 0.88,
            height: marks & MdMark.codeBlock != 0 ? 1.45 : null,
            backgroundColor: (p.text).withValues(alpha: 0.07),
          );
    }
    final level = MdMark.heading(marks);
    if (level > 0) {
      s = s.copyWith(
        fontSize: size * _scale[level],
        height: 1.3,
        fontWeight: level <= 2 ? FontWeight.w700 : FontWeight.w600,
        color: p.text,
      );
    }
    if (marks & MdMark.quote != 0) s = s.copyWith(color: p.muted);
    if (marks & MdMark.bold != 0) s = s.copyWith(fontWeight: FontWeight.w700);
    if (marks & MdMark.italic != 0) s = s.copyWith(fontStyle: FontStyle.italic);
    if (marks & MdMark.link != 0) s = s.copyWith(color: p.accent);
    final lines = <TextDecoration>[
      if (marks & (MdMark.strike | MdMark.done) != 0)
        TextDecoration.lineThrough,
    ];
    if (lines.isNotEmpty) {
      s = s.copyWith(decoration: TextDecoration.combine(lines));
    }
    if (marks & MdMark.done != 0) s = s.copyWith(color: p.dim);
    if (marks & MdMark.dim != 0) s = s.copyWith(color: p.dim);
    if (marks & MdMark.indent != 0) {
      // A space is narrow in a proportional face: nested items would barely
      // move. Wider, the same number of characters.
      s = s.copyWith(letterSpacing: size * 0.55);
    }
    return s;
  }
}

/// The document's own text, drawn live.
class _LiveController extends TextEditingController {
  _LiveController(String text) : super(text: text);

  MdLive? _live;

  /// The reading of the current text, made once per text: from the last
  /// one, reading again only the sections an edit touched.
  MdLive get live {
    final known = _live;
    if (known != null && identical(known.text, text)) return known;
    return _live = known == null
        ? MdLive.parse(text)
        : MdLive.update(known, text);
  }

  MdLiveLook? look;

  /// Builds the widget a swapped piece of source is drawn as.
  Widget Function(MdSwap swap, String source)? swapBuilder;

  /// Builds the widget a section with no caret in it is drawn as.
  Widget Function(MdRange section)? sectionBuilder;

  /// Told before each drawing of the text, which asks [sectionBuilder] for
  /// every section afresh.
  VoidCallback? beforeBuild;

  /// Sections drawn as text although no caret is in them yet: the one a
  /// finger or the mouse just went down on, so that what the tap or the
  /// drag goes on to hit is the text itself.
  Set<int> pinned = const {};

  /// Draws the text again with the same value, after [pinned] changed.
  void restyle() => notifyListeners();

  /// Whether the field has focus: without it nothing is revealed, so a page
  /// only being read is all rendered.
  bool focused = false;

  /// Where a caret or a selection's end is, which reveals what it touches.
  List<int> get _ends {
    final sel = selection;
    if (!focused || !sel.isValid) return const [];
    final ends = sel.isCollapsed ? [sel.baseOffset] : [sel.start, sel.end];
    // What an input method is composing keeps what it began beside shown:
    // a marker hiding as the caret moves on mid-word would move the word.
    final composing = value.composing;
    if (composing.isValid && !composing.isCollapsed) ends.add(composing.start);
    return ends;
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final look = this.look;
    final t = text;
    if (look == null) return TextSpan(text: t, style: style);
    beforeBuild?.call();
    return liveSpan(
      live,
      look,
      _ends,
      withComposing && value.isComposingRangeValid
          ? value.composing
          : TextRange.empty,
      swapBuilder,
      sectionBuilder: sectionBuilder,
      active: pinned,
    );
  }
}

/// What to draw for a character, besides drawing it as it is (0).
const _hide = 1;
const _widget = 2;
const _section = 3;

/// The text drawn, from [from] to [to]: [live] styled by [look], with what
/// [ends] does not touch hidden or swapped. Exactly as long as the text, a
/// widget standing for one character, so every offset means the same thing in
/// both.
///
/// With [sectionBuilder], each of [MdLive.sections] that no end touches and
/// that is not in [active] is one widget, its own text drawn there and laid
/// out once, and the rest of it one hidden run: what is shaped again on a key
/// is then the section being typed in and a few runs a section, not the whole
/// document.
@visibleForTesting
TextSpan liveSpan(
  MdLive live,
  MdLiveLook look,
  List<int> ends,
  TextRange composing,
  Widget Function(MdSwap swap, String source)? swapBuilder, {
  int from = 0,
  int? to,
  Widget Function(MdRange section)? sectionBuilder,
  Set<int> active = const {},
}) {
  final l = look;
  final t = live.text;
  final n = t.length;
  final end = to ?? n;
  final draw = Uint8List(n);
  bool revealed(MdRange r) {
    for (final e in ends) {
      if (r.touches(e)) return true;
    }
    return false;
  }

  bool outside(MdRange r) => r.end <= from || r.start >= end;

  for (final h in live.hides) {
    if (outside(h.range) || revealed(h.reveal)) continue;
    for (var i = h.range.start; i < h.range.end; i++) {
      draw[i] = _hide;
    }
  }
  final swapAt = <int, MdSwap>{};
  for (final s in live.swaps) {
    if (outside(s.range) || revealed(s.reveal) || swapBuilder == null) {
      continue;
    }
    if (s.range.end <= s.range.start) continue;
    draw[s.range.start] = _widget;
    swapAt[s.range.start] = s;
    for (var i = s.range.start + 1; i < s.range.end; i++) {
      draw[i] = _hide;
    }
    // A block drawn whole takes its line: the break after it hides too, or
    // the rows it stands for leave a line of their own below it.
    final block = switch (s.kind) {
      MdSwapKind.table ||
      MdSwapKind.fence ||
      MdSwapKind.frontMatter ||
      MdSwapKind.details => true,
      _ => false,
    };
    if (block && s.range.end + 1 < n && t.codeUnitAt(s.range.end) == 0x0A) {
      draw[s.range.end] = _hide;
    }
  }
  final sectionAt = <int, MdRange>{};
  if (sectionBuilder != null) {
    for (final s in live.sections) {
      if (s.end <= s.start || outside(s)) continue;
      if (revealed(s) || active.contains(s.start)) continue;
      draw[s.start] = _section;
      sectionAt[s.start] = s;
      for (var i = s.start + 1; i < s.end; i++) {
        draw[i] = _hide;
      }
    }
  }

  final children = <InlineSpan>[];
  bool inComposing(int k) =>
      composing.isValid && k >= composing.start && k < composing.end;
  var i = from;
  while (i < end) {
    if (draw[i] == _section) {
      children.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.top,
          child: sectionBuilder!(sectionAt[i]!),
        ),
      );
      i++;
      continue;
    }
    if (draw[i] == _widget) {
      final swap = swapAt[i]!;
      children.add(
        WidgetSpan(
          alignment: switch (swap.kind) {
            MdSwapKind.table ||
            MdSwapKind.fence ||
            MdSwapKind.image ||
            MdSwapKind.rule ||
            MdSwapKind.frontMatter ||
            MdSwapKind.details => PlaceholderAlignment.bottom,
            _ => PlaceholderAlignment.middle,
          },
          child: swapBuilder!(
            swap,
            t.substring(swap.range.start, swap.range.end),
          ),
        ),
      );
      i++;
      continue;
    }
    final d = draw[i];
    final m = live.marks[i];
    final c = inComposing(i);
    var j = i + 1;
    while (j < end &&
        draw[j] == d &&
        (d == _hide || live.marks[j] == m) &&
        inComposing(j) == c) {
      j++;
    }
    var style = d == _hide ? l.hidden : l.of(m);
    if (c) style = style.copyWith(decoration: TextDecoration.underline);
    children.add(TextSpan(text: t.substring(i, j), style: style));
    i = j;
  }
  return TextSpan(style: l.root, children: children);
}

class _MarkdownRichEditorState extends State<MarkdownRichEditor> {
  late final _LiveController _text = _LiveController(widget.text);
  final _focus = FocusNode(debugLabel: 'markdown rich text');
  final _fieldKey = GlobalKey();

  /// The text this editor last sent out or read in.
  late String _known = widget.text;

  late final ScrollController _scroll =
      ScrollController(initialScrollOffset: widget.at)..addListener(() {
        if (_scroll.hasClients) widget.onScroll?.call(_scroll.offset);
        _placeBar();
        _placeTaskNodes();
      });

  /// Whether the next change out continues a run of typing.
  bool _typing = false;
  DateTime _lastAt = DateTime(0);

  /// Where the floating bar sits, over the selection; null while hidden.
  final _bar = ValueNotifier<Offset?>(null);
  bool _pointerDown = false;

  @override
  void initState() {
    super.initState();
    widget.controller?._state = this;
    _text.addListener(_onText);
    SemanticsBinding.instance.addSemanticsEnabledListener(_placeTaskNodes);
    _focus.addListener(() {
      _text.focused = _focus.hasFocus;
      RichChords.want(this, _focus.hasFocus ? _onChord : null);
      // Revealed markup hides again, and the bars dim, as focus leaves.
      setState(() {});
      widget.controller?._changed();
      _placeBar();
    });
  }

  @override
  void didUpdateWidget(MarkdownRichEditor old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      if (old.controller?._state == this) old.controller!._state = null;
      widget.controller?._state = this;
    }
    if (widget.text != _known) _readBack(widget.text);
  }

  @override
  void dispose() {
    if (widget.controller?._state == this) widget.controller!._state = null;
    RichChords.want(this, null);
    _text.dispose();
    _focus.dispose();
    _scroll.dispose();
    _settle?.cancel();
    _bar.dispose();
    SemanticsBinding.instance.removeSemanticsEnabledListener(_placeTaskNodes);
    _taskNodes.dispose();
    super.dispose();
  }

  /// [text] changed from outside: an undo, a redo, a reload or Source. The
  /// caret goes where the change ended.
  void _readBack(String text) {
    final old = _text.text;
    var p = 0;
    while (p < old.length && p < text.length && old[p] == text[p]) {
      p++;
    }
    var s = 0;
    while (s < old.length - p &&
        s < text.length - p &&
        old[old.length - 1 - s] == text[text.length - 1 - s]) {
      s++;
    }
    _known = text;
    _typing = false;
    _text.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length - s),
    );
  }

  /// Every change to the field, typed or made by a bar, goes out from here.
  void _onText() {
    widget.controller?._changed();
    _placeBar();
    _placeTaskNodes();
    final text = _text.text;
    if (text == _known) return;
    _known = text;
    final now = DateTime.now();
    final coalesce =
        _typing && now.difference(_lastAt) < const Duration(milliseconds: 1500);
    _lastAt = now;
    widget.onChanged(text, coalesce: coalesce);
  }

  /// Sets the text from a command: one undo step of its own.
  void _apply(String text, TextSelection selection) {
    _typing = false;
    _text.value = TextEditingValue(text: text, selection: selection);
    _typing = false;
  }

  /// What typing turns into, as Obsidian does: Enter in a list goes on with
  /// the list, Enter on an empty item ends it, Backspace at an item's start
  /// takes its marker, and Enter after a fence's opening line closes it.
  TextEditingValue _onEdit(TextEditingValue old, TextEditingValue next) {
    final o = old.text;
    final n = next.text;
    if (o == n) return next;
    var p = 0;
    while (p < o.length && p < n.length && o[p] == n[p]) {
      p++;
    }
    if (next.selection.isCollapsed) {
      final grown = n.length - o.length;
      final cap = next.selection.baseOffset - (grown > 0 ? grown : 0);
      if (cap >= 0 && cap < p) p = cap;
    }
    var s = 0;
    while (s < o.length - p &&
        s < n.length - p &&
        o[o.length - 1 - s] == n[n.length - 1 - s]) {
      s++;
    }
    final a = p;
    final b = o.length - s;
    final ins = n.substring(p, n.length - s);
    // A run of typing is one undo step; a paste or a cut is its own.
    _typing = ins.length <= 1 && b - a <= 1;
    final composing = next.composing.isValid && !next.composing.isCollapsed;
    if (composing) return next;
    final converted = markdownShortcut(
      o,
      a,
      b,
      ins,
      shift: HardwareKeyboard.instance.isShiftPressed,
      live: identical(o, _text.text) ? _text.live : null,
    );
    if (converted == null) return next;
    _typing = false;
    return converted;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final keys = HardwareKeyboard.instance;
    final command =
        defaultTargetPlatform == TargetPlatform.macOS ||
            defaultTargetPlatform == TargetPlatform.iOS
        ? keys.isMetaPressed
        : keys.isControlPressed;
    if (!command || keys.isAltPressed) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.keyZ) {
      (keys.isShiftPressed ? widget.onRedo : widget.onUndo)?.call();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyY) {
      widget.onRedo?.call();
      return KeyEventResult.handled;
    }
    final run = <LogicalKeyboardKey, VoidCallback>{
      LogicalKeyboardKey.keyB: () => _toggleInline('**', MdMark.bold),
      LogicalKeyboardKey.keyI: () => _toggleInline('_', MdMark.italic),
      LogicalKeyboardKey.keyE: () => _toggleInline('`', MdMark.code),
      LogicalKeyboardKey.keyK: () => unawaited(_editLink()),
    }[key];
    if (run == null) return KeyEventResult.ignored;
    run();
    return KeyEventResult.handled;
  }

  /// A chord MainActivity took before Gboard could (see [RichChords]): the
  /// same as [_onKey] does with it when it reaches Flutter.
  void _onChord(String chord) {
    if (!_focus.hasFocus) return;
    switch (chord) {
      case 'bold':
        _toggleInline('**', MdMark.bold);
      case 'italic':
        _toggleInline('_', MdMark.italic);
      case 'code':
        _toggleInline('`', MdMark.code);
      case 'link':
        unawaited(_editLink());
      default:
        final parts = chord.split(':');
        if (parts.length < 2 || parts.first != 'select') return;
        final forward = parts[1] == 'right' || parts[1] == 'down';
        final word = parts.length > 2 && parts[2] == 'word';
        final Intent intent = switch (parts[1]) {
          'left' ||
          'right' when word => ExtendSelectionToNextWordBoundaryIntent(
            forward: forward,
            collapseSelection: false,
          ),
          'left' || 'right' => ExtendSelectionByCharacterIntent(
            forward: forward,
            collapseSelection: false,
          ),
          'up' || 'down' => ExtendSelectionVerticallyToAdjacentLineIntent(
            forward: forward,
            collapseSelection: false,
          ),
          _ => const DoNothingIntent(),
        };
        // The field's own action, so the selection moves as Shift and an
        // arrow move it on a desktop.
        final context = _focus.context;
        if (context != null) Actions.maybeInvoke(context, intent);
    }
  }

  MdFormat? _format() {
    if (!_focus.hasFocus) return null;
    final sel = _text.selection;
    if (!sel.isValid) return null;
    final live = _text.live;
    final marks = live.marks;
    int at(int k) => k >= 0 && k < marks.length ? marks[k] : 0;
    int bits;
    if (sel.isCollapsed) {
      bits = at(sel.baseOffset - 1) & at(sel.baseOffset);
      if (sel.baseOffset == marks.length) bits = at(sel.baseOffset - 1);
    } else {
      bits = ~0;
      var any = false;
      for (var k = sel.start; k < sel.end; k++) {
        if (marks[k] & MdMark.dim != 0) continue;
        if (_text.text.codeUnitAt(k) == 0x0A) continue;
        bits &= marks[k];
        any = true;
      }
      if (!any) bits = 0;
    }
    final line = live.lineAt(sel.start);
    return MdFormat(
      bold: bits & MdMark.bold != 0,
      italic: bits & MdMark.italic != 0,
      code: bits & MdMark.code != 0,
      link: bits & MdMark.link != 0,
      heading: line.kind == MdLineKind.heading ? line.level : 0,
      quote: line.quote != null,
    );
  }

  void _toggleInline(String marker, int bit) {
    if (!_focus.hasFocus && !_text.selection.isValid) return;
    final done = toggleInline(_text.value, _text.live, marker, bit);
    if (done == null) {
      widget.onRefused("That can't be marked there.");
      return;
    }
    _apply(done.text, done.selection);
  }

  void _toggleHeading(int level) {
    if (!_text.selection.isValid) return;
    final done = toggleHeading(_text.value, _text.live, level);
    _apply(done.text, done.selection);
  }

  void _toggleQuote() {
    if (!_text.selection.isValid) return;
    final done = toggleQuote(_text.value, _text.live);
    _apply(done.text, done.selection);
  }

  Future<void> _editLink() async {
    final value = _text.value;
    final sel = value.selection;
    if (!sel.isValid) return;
    final live = _text.live;
    final span = live.links.where(
      (l) =>
          l.target != null &&
          l.all!.start <= sel.start &&
          sel.end <= l.all!.end,
    );
    if (sel.isCollapsed && span.isEmpty) {
      widget.onRefused('Select the text to link first.');
      return;
    }
    final link = span.isEmpty ? null : span.first;
    final url = await widget.askLink(link?.link.href);
    if (url == null || !mounted) return;
    // The text may have moved on while the question was up.
    if (_text.text != value.text) return;
    final href = url.trim();
    final t = value.text;
    if (link != null) {
      final target = link.target!;
      if (href.isEmpty) {
        // Unlinked: only its text is left.
        final label = t.substring(link.range.start, link.range.end);
        final all = link.all!;
        _apply(
          t.replaceRange(all.start, all.end, label),
          TextSelection(
            baseOffset: all.start,
            extentOffset: all.start + label.length,
          ),
        );
      } else {
        _apply(
          t.replaceRange(target.start, target.end, href),
          TextSelection.collapsed(offset: target.start + href.length + 1),
        );
      }
      return;
    }
    if (href.isEmpty) return;
    final label = t.substring(sel.start, sel.end);
    final written = '[$label]($href)';
    _apply(
      t.replaceRange(sel.start, sel.end, written),
      TextSelection.collapsed(offset: sel.start + written.length),
    );
  }

  RenderEditable? get _editable {
    RenderEditable? find(RenderObject? r) {
      if (r == null) return null;
      if (r is RenderEditable) return r;
      RenderEditable? found;
      r.visitChildren((child) => found ??= find(child));
      return found;
    }

    return find(_fieldKey.currentContext?.findRenderObject());
  }

  /// The link under [global], if any.
  MdLink? _linkAt(Offset global) {
    final editable = _editable;
    if (editable == null) return null;
    final position = editable.getPositionForPoint(global);
    final k = position.affinity == TextAffinity.upstream
        ? position.offset - 1
        : position.offset;
    return _text.live.linkAt(k);
  }

  /// Puts the floating bar over the selection, after the frame lays it out.
  void _placeBar() {
    if (!MarkdownRichEditor.floatingBar) return;
    // Hidden while the selection moves, and put up once it has held still:
    // as Medium's, after the selection rather than during it. Drawn between
    // two presses of Shift and an arrow, it threw the next press's line off.
    _settle?.cancel();
    if (_bar.value != null) _bar.value = null;
    _settle = Timer(const Duration(milliseconds: 400), _showBar);
  }

  Timer? _settle;

  void _showBar() {
    if (!mounted) return;
    SchedulerBinding.instance.ensureVisualUpdate();
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final sel = _text.selection;
      final editable = _editable;
      final box = context.findRenderObject() as RenderBox?;
      if (!_focus.hasFocus ||
          _pointerDown ||
          !sel.isValid ||
          sel.isCollapsed ||
          editable == null ||
          box == null ||
          !editable.attached) {
        _bar.value = null;
        return;
      }
      final rects = editable.getBoxesForSelection(sel);
      if (rects.isEmpty) {
        _bar.value = null;
        return;
      }
      final first = rects.first;
      final top = box.globalToLocal(
        editable.localToGlobal(Offset(first.left, first.top)),
      );
      _bar.value = Offset(
        top.dx.clamp(0, (box.size.width - 300).clamp(0, double.infinity)),
        top.dy,
      );
    });
  }

  Timer? _press;
  Offset? _down;

  void _onPointerDown(PointerDownEvent event) {
    _pointerDown = true;
    _bar.value = null;
    final keys = HardwareKeyboard.instance;
    if (keys.isControlPressed || keys.isMetaPressed) {
      final link = _linkAt(event.position);
      if (link != null) widget.onOpenLink(link);
      return;
    }
    _down = event.position;
    _press?.cancel();
    _press = Timer(kLongPressTimeout, () {
      final link = _linkAt(event.position);
      if (link == null) return;
      widget.onOpenLink(link);
      // The word the press selected goes back to a caret.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final sel = _text.selection;
        if (sel.isValid && !sel.isCollapsed) {
          _text.selection = TextSelection.collapsed(offset: sel.end);
        }
      });
    });
  }

  void _onPointerUp(Offset at) {
    _press?.cancel();
    _pointerDown = false;
    _placeBar();
    final precise = _precise;
    _precise = null;
    final down = _down;
    if (precise == null || down == null || (at - down).distance > kTouchSlop) {
      return;
    }
    // The press landed on a section drawn apart, which the field only knows
    // as one character: once the tap has put the caret there, it goes where
    // the press really was.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted || precise > _text.text.length) return;
      final sel = _text.selection;
      if (sel.isValid && sel.isCollapsed && sel.baseOffset != precise) {
        _text.selection = TextSelection.collapsed(offset: precise);
      }
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  /// Every task box drawn now, and the nodes a screen reader finds over them.
  final _tasks = <_TaskMarkState>{};
  final _taskNodes = ValueNotifier<List<_TaskNode>>(const []);
  final _stackKey = GlobalKey();
  bool _taskNodesDue = false;

  /// Places the task boxes' nodes after the frame lays the boxes out, while
  /// a screen reader or anything else asks for semantics: otherwise nothing.
  void _placeTaskNodes() {
    if (_taskNodesDue) return;
    if (!SemanticsBinding.instance.semanticsEnabled &&
        _taskNodes.value.isEmpty) {
      return;
    }
    _taskNodesDue = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _taskNodesDue = false;
      if (!mounted) return;
      final stack = _stackKey.currentContext?.findRenderObject() as RenderBox?;
      final nodes = <_TaskNode>[];
      final t = _text.text;
      if (stack != null && stack.hasSize) {
        final page = Offset.zero & stack.size;
        for (final mark in _tasks) {
          final box = mark.context.findRenderObject() as RenderBox?;
          if (box == null || !box.attached || !box.hasSize) continue;
          // A field's inline widget is placed as if the field were not
          // scrolled: it paints with the scroll added, its transform does not.
          final scrolled = _scroll.hasClients ? _scroll.offset : 0.0;
          final rect =
              stack.globalToLocal(
                box.localToGlobal(Offset.zero) - Offset(0, scrolled),
              ) &
              box.size;
          if (!page.overlaps(rect)) continue;
          final start = mark.widget.start();
          if (start + 3 > t.length) continue;
          var end = t.indexOf('\n', start);
          if (end < 0) end = t.length;
          nodes.add(
            _TaskNode(
              rect,
              t[start + 1] != ' ',
              start,
              t.substring(start + 3, end).trim(),
            ),
          );
        }
      }
      nodes.sort((a, b) => a.start.compareTo(b.start));
      if (!listEquals(nodes, _taskNodes.value)) _taskNodes.value = nodes;
    });
  }

  /// Ticks or clears the task whose box starts at [start]: one character.
  void _toggleTask(int start) {
    final t = _text.text;
    if (start + 3 > t.length || t[start] != '[' || t[start + 2] != ']') return;
    final next = t[start + 1] == ' ' ? 'x' : ' ';
    final sel = _text.selection;
    _typing = false;
    _text.value = TextEditingValue(
      text: t.replaceRange(start + 1, start + 2, next),
      selection: sel.isValid ? sel : TextSelection.collapsed(offset: start + 3),
    );
  }

  /// The sections drawn last time, by their source, to hand back the same
  /// widget for a section that has not changed: the same widget is not built
  /// or laid out again, which is the point of drawing them apart.
  var _sections = <String, List<_SectionView>>{};
  var _sectionsNext = <String, List<_SectionView>>{};

  void _beforeBuild() {
    // What was not asked for again in the last drawing goes.
    _sections = _sectionsNext;
    _sectionsNext = {};
  }

  Widget _section(MdRange section) {
    final live = _text.live;
    final source = live.text.substring(section.start, section.end);
    final kept = _sections[source];
    final view = (kept != null && kept.isNotEmpty)
        ? kept.removeAt(0)
        : _SectionView(
            key: UniqueKey(),
            live: live,
            range: section,
            look: _text.look!,
            swapBuilder: _swap,
            onDown: _sectionDown,
          );
    view.handle.start = section.start;
    (_sectionsNext[source] ??= []).add(view);
    return view;
  }

  /// Where in the text a press on a drawn section went, to put the caret
  /// there once the section is drawn as text.
  int? _precise;

  void _sectionDown(_SectionView view, int offset) {
    final start = view.handle.start;
    _precise = start + offset;
    _text.pinned = {start};
    _text.restyle();
  }

  /// [swap] drawn; [at] says where its source starts now, for a section
  /// drawn apart while the text before it changes.
  Widget _swap(MdSwap swap, String source, {int Function()? at}) {
    final look = _text.look!;
    final p = look.palette;
    final size = look.size;
    final line = size * (look.base.height ?? 1.6);
    Widget block(Widget child) => ConstrainedBox(
      constraints: BoxConstraints(minWidth: look.width, maxWidth: look.width),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: child,
      ),
    );
    return switch (swap.kind) {
      MdSwapKind.bullet => SizedBox(
        width: size * 0.6,
        height: line,
        child: Center(
          child: Container(
            width: size * 0.32,
            height: size * 0.32,
            decoration: BoxDecoration(color: p.text, shape: BoxShape.circle),
          ),
        ),
      ),
      MdSwapKind.task => _TaskMark(
        key: ValueKey('md-task-${swap.range.start}'),
        marks: _tasks,
        checked: swap.checked,
        start: () => at?.call() ?? swap.range.start,
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerUp: (_) => _toggleTask(at?.call() ?? swap.range.start),
          child: Padding(
            padding: const EdgeInsets.only(right: 2),
            child: IgnorePointer(
              child: TuiCheckbox(
                value: swap.checked,
                dense: true,
                onChanged: (_) {},
              ),
            ),
          ),
        ),
      ),
      MdSwapKind.quoteBar => Container(
        width: 3,
        height: line,
        margin: const EdgeInsets.only(right: 8),
        color: p.border,
      ),
      MdSwapKind.rule => SizedBox(
        width: look.width,
        height: line,
        child: Center(child: Container(height: 1, color: p.border)),
      ),
      // A table scrolls sideways in the package's own scroller, and a code
      // block keeps its copy button: neither takes a plain tap, which goes
      // through to the text, puts the caret in the block and shows its
      // source. A diagram is a web view, which would take every touch.
      MdSwapKind.table || MdSwapKind.fence || MdSwapKind.image => block(
        IgnorePointer(
          ignoring:
              swap.kind == MdSwapKind.image ||
              RegExp(r'^ {0,3}(`{3,}|~{3,})\s*mermaid').hasMatch(source),
          child: _Rendered(
            key: ValueKey(source),
            builder: widget.blockBuilder,
            markdown: htmlImage(source) ?? source,
          ),
        ),
      ),
      // A line of its own for what follows: as wide as the column and no
      // height, so the text after it wraps to the next line.
      MdSwapKind.lineBreak => SizedBox(width: look.width, height: 0),
      MdSwapKind.frontMatter => block(_FrontMatter(source: source, look: look)),
      MdSwapKind.details => _Details(source: source, look: look),
    };
  }

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        // A centred column of about 70 characters on a wide screen, and 16 px
        // from the edges on a phone.
        final gutter = width > 720 + 32 ? (width - 720) / 2 : 16.0;
        final column = (width - gutter * 2).clamp(1.0, double.infinity);
        final base = TextStyle(
          fontFamily: _readingFamily,
          fontFamilyFallback: const [
            'Roboto',
            'Segoe UI',
            'Helvetica Neue',
            'Cantarell',
            'DejaVu Sans',
            'sans-serif',
          ],
          fontSize: 16,
          height: 1.6,
          letterSpacing: 0,
          color: p.text,
          fontWeight: FontWeight.w400,
          fontStyle: FontStyle.normal,
          decoration: TextDecoration.none,
        );
        final code = widget.codeFont ?? TextStyle(fontFamily: TermulFonts.mono);
        final look = _text.look;
        if (look == null ||
            look.palette != p ||
            look.width != column ||
            look.code != code ||
            look.base != base) {
          _text.look = MdLiveLook(
            base: base,
            code: code,
            palette: p,
            width: column,
          );
          // Every section drawn apart was drawn in the old look.
          _sectionsNext = {};
        }
        _text.swapBuilder = _swap;
        _text.sectionBuilder = _section;
        _text.beforeBuild = _beforeBuild;
        _placeTaskNodes();
        final field = TextField(
          key: _fieldKey,
          controller: _text,
          focusNode: _focus,
          scrollController: _scroll,
          style: base,
          // A hidden marker's line break, and the hidden source behind a
          // section drawn apart, would otherwise still take a line's height
          // each: the field's strut is the floor under every line, and
          // StrutStyle.disabled takes the text's font size for its own.
          strutStyle: const StrutStyle(fontSize: 0.01, height: 1),
          maxLines: null,
          expands: true,
          textAlignVertical: TextAlignVertical.top,
          keyboardType: TextInputType.multiline,
          textInputAction: TextInputAction.newline,
          // Prose: the keyboard may help as it does in a notes app.
          autocorrect: true,
          enableSuggestions: true,
          cursorColor: p.accent,
          inputFormatters: [_Edits(_onEdit)],
          scrollPadding: const EdgeInsets.all(48),
          // A page, not a field: none of the app's field box, its fill or
          // the accent line it draws round a focused field.
          decoration: InputDecoration(
            filled: false,
            hoverColor: const Color(0x00000000),
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            disabledBorder: InputBorder.none,
            errorBorder: InputBorder.none,
            focusedErrorBorder: InputBorder.none,
            isCollapsed: true,
            contentPadding: EdgeInsets.fromLTRB(gutter, 20, gutter, 48),
          ),
        );
        return Listener(
          // The wheel over the gutters scrolls the page as over the text.
          onPointerSignal: (event) {
            if (event is! PointerScrollEvent || !_scroll.hasClients) return;
            GestureBinding.instance.pointerSignalResolver.register(event, (e) {
              final s = e as PointerScrollEvent;
              final pos = _scroll.position;
              _scroll.jumpTo(
                (pos.pixels + s.scrollDelta.dy).clamp(
                  pos.minScrollExtent,
                  pos.maxScrollExtent,
                ),
              );
            });
          },
          onPointerDown: _onPointerDown,
          onPointerMove: (event) {
            if (_down != null &&
                (event.position - _down!).distance > kTouchSlop) {
              _press?.cancel();
            }
          },
          onPointerUp: (event) => _onPointerUp(event.position),
          onPointerCancel: (_) => _onPointerUp(Offset.infinite),
          child: Stack(
            key: _stackKey,
            children: [
              Positioned.fill(
                child: Focus(
                  canRequestFocus: false,
                  skipTraversal: true,
                  onKeyEvent: _onKey,
                  child: Theme(
                    data: theme.copyWith(
                      textSelectionTheme: TextSelectionThemeData(
                        selectionColor: p.selection,
                        cursorColor: p.accent,
                        selectionHandleColor: p.accent,
                      ),
                    ),
                    child: field,
                  ),
                ),
              ),
              // A checkbox node over each task box, for a screen reader. They
              // take no pointer: a touch goes on to the box below.
              Positioned.fill(
                child: ValueListenableBuilder<List<_TaskNode>>(
                  valueListenable: _taskNodes,
                  builder: (context, nodes, _) => Stack(
                    children: [
                      for (final n in nodes)
                        Positioned.fromRect(
                          rect: n.rect,
                          child: Semantics(
                            container: true,
                            checked: n.checked,
                            label: n.label.isEmpty ? 'Task' : n.label,
                            onTap: () => _toggleTask(n.start),
                            child: const SizedBox.expand(),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              if (MarkdownRichEditor.floatingBar && widget.controller != null)
                ValueListenableBuilder<Offset?>(
                  valueListenable: _bar,
                  // Positioned even while hidden: a Stack child that is not
                  // takes a part in sizing the Stack, the field with it.
                  builder: (context, at, _) => Positioned(
                    left: at?.dx ?? 0,
                    top: at == null
                        ? 0
                        : (at.dy - 44).clamp(0, double.infinity),
                    child: at == null
                        ? const SizedBox.shrink()
                        : MarkdownFloatingBar(controller: widget.controller!),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  static String? get _readingFamily => switch (defaultTargetPlatform) {
    TargetPlatform.android => 'Roboto',
    TargetPlatform.macOS || TargetPlatform.iOS => '.AppleSystemUIFont',
    TargetPlatform.windows => 'Segoe UI',
    _ => 'Cantarell',
  };
}

/// An `<img>` tag as the Markdown picture it stands for, which the block
/// builder draws as Preview does; null for anything else.
@visibleForTesting
String? htmlImage(String source) {
  if (!source.toLowerCase().startsWith('<img')) return null;
  String? attr(String name) {
    final m = RegExp(
      '\\b$name\\s*=\\s*("([^"]*)"|\'([^\']*)\'|([^\\s>]+))',
      caseSensitive: false,
    ).firstMatch(source);
    return m?[2] ?? m?[3] ?? m?[4];
  }

  final src = attr('src');
  if (src == null) return null;
  final alt = (attr('alt') ?? '').replaceAll(RegExp(r'[\[\]]'), '');
  return '![$alt](<$src>)';
}

/// Front matter drawn as a quiet block: each top-level key beside its value,
/// a list or nested lines under a key kept with it.
class _FrontMatter extends StatelessWidget {
  const _FrontMatter({required this.source, required this.look});

  final String source;
  final MdLiveLook look;

  /// The keys and values, in order.
  static List<(String, String)> rows(String source) {
    final lines = source.split('\n');
    final body = lines.length > 2
        ? lines.sublist(1, lines.length - 1)
        : const <String>[];
    final key = RegExp(r'^([A-Za-z0-9_.-]+)\s*:\s?(.*)$');
    final out = <(String, String)>[];
    for (final line in body) {
      final m = key.firstMatch(line);
      if (m != null) {
        out.add((m[1]!, m[2]!.trim()));
      } else if (out.isNotEmpty && line.trim().isNotEmpty) {
        final (k, v) = out.removeLast();
        out.add((k, v.isEmpty ? line.trim() : '$v\n${line.trim()}'));
      } else if (line.trim().isNotEmpty) {
        out.add(('', line.trim()));
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final p = look.palette;
    final small = look.base.copyWith(
      fontSize: look.size * 0.85,
      height: 1.45,
      color: p.muted,
    );
    final keyStyle = small.merge(look.code).copyWith(color: p.dim);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: p.border, width: 2)),
      ),
      child: Table(
        columnWidths: const {0: IntrinsicColumnWidth(), 1: FlexColumnWidth()},
        defaultVerticalAlignment: TableCellVerticalAlignment.top,
        children: [
          for (final (k, v) in rows(source))
            TableRow(
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Text(k, style: keyStyle),
                ),
                Text(v, style: small),
              ],
            ),
        ],
      ),
    );
  }
}

/// `<details>` drawn as its summary with a disclosure mark, what follows it
/// read as the document goes on; its `</details>` draws as nothing.
class _Details extends StatelessWidget {
  const _Details({required this.source, required this.look});

  final String source;
  final MdLiveLook look;

  @override
  Widget build(BuildContext context) {
    if (source.trim().toLowerCase().startsWith('</')) {
      return SizedBox(width: look.width, height: 0);
    }
    final summary = RegExp(
      r'<summary>([^<]*)</summary>',
      caseSensitive: false,
    ).firstMatch(source)?[1]?.trim();
    final p = look.palette;
    return SizedBox(
      width: look.width,
      child: Text(
        '▾ ${summary == null || summary.isEmpty ? 'Details' : summary}',
        style: look.base.copyWith(fontWeight: FontWeight.w600, color: p.text),
      ),
    );
  }
}

/// A task's box as drawn, registered with the editor while it is in the
/// tree: the field gives a screen reader its text as one node and passes on
/// nothing of a widget inside it, so the editor lays a checkbox node of its
/// own over each box from here.
class _TaskMark extends StatefulWidget {
  const _TaskMark({
    super.key,
    required this.marks,
    required this.checked,
    required this.start,
    required this.child,
  });

  final Set<_TaskMarkState> marks;
  final bool checked;

  /// Where its `[ ]` starts in the text now.
  final int Function() start;
  final Widget child;

  @override
  State<_TaskMark> createState() => _TaskMarkState();
}

class _TaskMarkState extends State<_TaskMark> {
  @override
  void initState() {
    super.initState();
    widget.marks.add(this);
  }

  @override
  void didUpdateWidget(_TaskMark old) {
    super.didUpdateWidget(old);
    if (old.marks != widget.marks) {
      old.marks.remove(this);
      widget.marks.add(this);
    }
  }

  @override
  void dispose() {
    widget.marks.remove(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// A task box's node for a screen reader, where the box is drawn.
@immutable
class _TaskNode {
  const _TaskNode(this.rect, this.checked, this.start, this.label);

  final Rect rect;
  final bool checked;
  final int start;
  final String label;

  @override
  bool operator ==(Object other) =>
      other is _TaskNode &&
      other.rect == rect &&
      other.checked == checked &&
      other.start == start &&
      other.label == label;

  @override
  int get hashCode => Object.hash(rect, checked, start, label);
}

/// A rendered block, built once per source so a picture or a diagram is not
/// fetched or laid out again on every key.
/// Where a section drawn apart starts in the text now, which moves as the
/// text before it changes while the section itself does not.
class _SectionHandle {
  _SectionHandle(this.start);

  int start;
}

/// A section of the document with no caret in it, drawn on its own exactly
/// as the field would draw it inline, so that a key typed elsewhere neither
/// builds nor lays out its text again.
///
/// The field holds the section's source as one hidden run behind this, so
/// every offset still means what it means in the file.
class _SectionView extends StatelessWidget {
  _SectionView({
    super.key,
    required this.live,
    required this.range,
    required this.look,
    required this.swapBuilder,
    required this.onDown,
  }) : handle = _SectionHandle(range.start);

  /// The reading the section was drawn from, and where it was then.
  final MdLive live;
  final MdRange range;
  final MdLiveLook look;
  final Widget Function(MdSwap swap, String source, {int Function()? at})
  swapBuilder;

  /// A press on it, at [offset] into it.
  final void Function(_SectionView view, int offset) onDown;

  final _SectionHandle handle;
  final _paragraph = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final t = live.text;
    // The line break that ends it is the field's, which starts the next
    // line; drawn here too it would add an empty line below.
    final to =
        range.end > range.start &&
            range.end < t.length &&
            t.codeUnitAt(range.end - 1) == 0x0A
        ? range.end - 1
        : range.end;
    final span = liveSpan(
      live,
      look,
      const [],
      TextRange.empty,
      (swap, source, {at}) => swapBuilder(
        swap,
        source,
        at: () => handle.start + swap.range.start - range.start,
      ),
      from: range.start,
      to: to,
    );
    return Listener(
      onPointerDown: (event) {
        final paragraph =
            _paragraph.currentContext?.findRenderObject() as RenderParagraph?;
        if (paragraph == null) return;
        final position = paragraph.getPositionForOffset(
          paragraph.globalToLocal(event.position),
        );
        onDown(this, position.offset);
      },
      // A layer of its own: a key typed elsewhere repaints the field, and
      // this is then neither painted again nor, off screen, rasterised.
      child: RepaintBoundary(
        child: SizedBox(
          width: look.width,
          child: RichText(
            key: _paragraph,
            text: span,
            textScaler: MediaQuery.textScalerOf(context),
            textHeightBehavior: DefaultTextHeightBehavior.maybeOf(context),
          ),
        ),
      ),
    );
  }
}

class _Rendered extends StatefulWidget {
  const _Rendered({super.key, required this.builder, required this.markdown});

  final Widget Function(BuildContext context, String markdown) builder;
  final String markdown;

  @override
  State<_Rendered> createState() => _RenderedState();
}

class _RenderedState extends State<_Rendered> {
  Widget? _built;

  @override
  Widget build(BuildContext context) =>
      _built ??= widget.builder(context, widget.markdown);
}

/// Hands every typed change to [onChange], which says what the field shows.
class _Edits extends TextInputFormatter {
  _Edits(this.onChange);

  final TextEditingValue Function(TextEditingValue old, TextEditingValue next)
  onChange;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) => onChange(oldValue, newValue);
}

/// What typing [ins] over [a] to [b] of [text] turns into, when it is a
/// Markdown shortcut; null when it is typed as it is.
///
/// Typed Markdown needs no converting — the text is the source, so `# ` is a
/// heading, `- ` a list item and `**x**` bold the moment they are typed.
/// What is left is what an editor does with Enter and Backspace around them.
@visibleForTesting
TextEditingValue? markdownShortcut(
  String text,
  int a,
  int b,
  String ins, {
  bool shift = false,
  MdLive? live,
}) {
  final enter = ins == '\n' && a == b && !shift;
  final backspace = ins.isEmpty && b == a + 1;
  if (!enter && !backspace) return null;
  live ??= MdLive.parse(text);
  if (ins == '\n' && a == b && !shift) {
    final line = live.lineAt(a);
    final quote = line.quote == null
        ? ''
        : text.substring(line.quote!.start, line.quote!.end);
    final content = text.substring(line.content, line.end);
    if (line.kind == MdLineKind.listItem && a >= line.content) {
      final marker = line.marker!;
      if (content.trim().isEmpty && a == line.end) {
        // Enter on an empty item ends the list.
        return TextEditingValue(
          text: text.replaceRange(marker.start, line.end, ''),
          selection: TextSelection.collapsed(offset: marker.start),
        );
      }
      final written = text.substring(marker.start, marker.end);
      final m = RegExp(r'^([ \t]*)([-*+]|(\d+)([.)]))([ \t]+)(\[[ xX]\] ?)?')
          .firstMatch(written)!;
      final number = m[3];
      final bullet = number == null ? m[2]! : '${int.parse(number) + 1}${m[4]}';
      final next = '\n$quote${m[1]}$bullet${m[5]}${m[6] == null ? '' : '[ ] '}';
      return TextEditingValue(
        text: text.replaceRange(a, a, next),
        selection: TextSelection.collapsed(offset: a + next.length),
      );
    }
    if (line.quote != null && line.kind == MdLineKind.paragraph) {
      if (content.trim().isEmpty && a == line.end) {
        return TextEditingValue(
          text: text.replaceRange(line.start, line.end, ''),
          selection: TextSelection.collapsed(offset: line.start),
        );
      }
      final next = '\n$quote';
      return TextEditingValue(
        text: text.replaceRange(a, a, next),
        selection: TextSelection.collapsed(offset: a + next.length),
      );
    }
    if (line.kind == MdLineKind.fence && a == line.end) {
      final opening = RegExp(r'^( {0,3})(`{3,}|~{3,})[^`]*$')
          .firstMatch(text.substring(line.content, line.end));
      final fence = live.swaps.where(
        (s) => s.kind == MdSwapKind.fence && s.range.start == line.content,
      );
      if (opening != null && fence.isNotEmpty) {
        final body = text.substring(
          fence.first.range.start,
          fence.first.range.end,
        );
        final rows = body.split('\n');
        final closed =
            rows.length > 1 &&
            RegExp(
              '^ {0,3}${RegExp.escape(opening[2]![0])}{${opening[2]!.length},}[ \\t]*\$',
            ).hasMatch(rows.last);
        if (!closed) {
          // A fence typed open is closed at once, the caret inside it.
          final next = '\n$quote\n$quote${opening[1]}${opening[2]}';
          return TextEditingValue(
            text: text.replaceRange(a, a, next),
            selection: TextSelection.collapsed(offset: a + 1 + quote.length),
          );
        }
      }
    }
    return null;
  }
  if (ins.isEmpty && b == a + 1) {
    // Backspace at an item's first character takes the whole marker.
    final line = live.lineAt(b);
    if (line.kind == MdLineKind.listItem &&
        b == line.content &&
        line.marker != null &&
        line.marker!.end == b) {
      return TextEditingValue(
        text: text.replaceRange(line.marker!.start, b, ''),
        selection: TextSelection.collapsed(offset: line.marker!.start),
      );
    }
  }
  return null;
}

/// [marker] put round the selection, or taken off when it is already there:
/// the bytes of the markers alone change.
@visibleForTesting
TextEditingValue? toggleInline(
  TextEditingValue value,
  MdLive live,
  String marker,
  int bit,
) {
  final t = value.text;
  final sel = value.selection;
  final len = marker.length;
  // The span already round the selection, found by its hidden markers.
  for (final pair in _spans(live, bit)) {
    final (open, close) = pair;
    if (open.start <= sel.start &&
        sel.end <= close.end &&
        (sel.isCollapsed ? true : sel.start >= open.start)) {
      final out = t
          .replaceRange(close.start, close.end, '')
          .replaceRange(open.start, open.end, '');
      final shift = open.end - open.start;
      int moved(int k) => k <= open.start
          ? k
          : k <= open.end
          ? open.start
          : k <= close.start
          ? k - shift
          : (k - shift - (close.end - close.start)).clamp(
              open.start,
              out.length,
            );
      return TextEditingValue(
        text: out,
        selection: TextSelection(
          baseOffset: moved(sel.baseOffset),
          extentOffset: moved(sel.extentOffset),
        ),
      );
    }
  }
  if (sel.isCollapsed) {
    final at = sel.baseOffset;
    return TextEditingValue(
      text: t.replaceRange(at, at, marker * 2),
      selection: TextSelection.collapsed(offset: at + len),
    );
  }
  // Each line's own part of the selection, without the spaces at its ends,
  // which Markdown will not take inside a marker.
  final edits = <(int, int)>[];
  for (final line in live.lines) {
    if (line.end < sel.start || line.start > sel.end) continue;
    var s = sel.start > line.content ? sel.start : line.content;
    var e = sel.end < line.end ? sel.end : line.end;
    while (s < e && t[s].trim().isEmpty) {
      s++;
    }
    while (e > s && t[e - 1].trim().isEmpty) {
      e--;
    }
    if (e > s) edits.add((s, e));
  }
  if (edits.isEmpty) return null;
  var out = t;
  for (final (s, e) in edits.reversed) {
    out = out.replaceRange(e, e, marker).replaceRange(s, s, marker);
  }
  final first = edits.first.$1;
  final added = edits.length * len * 2;
  final last = edits.last.$2 + added - len;
  return TextEditingValue(
    text: out,
    selection: TextSelection(baseOffset: first + len, extentOffset: last),
  );
}

/// The open and close markers of every span carrying [bit].
Iterable<(MdRange, MdRange)> _spans(MdLive live, int bit) sync* {
  final hides = live.hides;
  for (var i = 0; i + 1 < hides.length; i++) {
    final open = hides[i];
    final close = hides[i + 1];
    if (open.reveal != close.reveal) continue;
    if (open.range.start != open.reveal.start ||
        close.range.end != close.reveal.end) {
      continue;
    }
    final inner = open.range.end;
    if (inner >= close.range.start) continue;
    final marks = live.marks[inner];
    final dim = live.marks[open.range.start];
    if (marks & bit == 0 || dim & bit == 0) continue;
    // A link's brackets carry no style bit, so this is emphasis or code.
    yield (open.range, close.range);
  }
}

/// The lines under the selection made headings of [level], or plain again
/// when they all are already.
@visibleForTesting
TextEditingValue toggleHeading(TextEditingValue value, MdLive live, int level) {
  final t = value.text;
  final sel = value.selection;
  final lines = live.lines
      .where((l) => l.end >= sel.start && l.start <= sel.end)
      .where((l) => l.kind != MdLineKind.blank)
      .toList();
  if (lines.isEmpty) return value;
  final off = lines.every(
    (l) => l.kind == MdLineKind.heading && l.level == level,
  );
  var out = t;
  var caret = sel.extentOffset;
  for (final l in lines.reversed) {
    final from = l.quote?.end ?? l.start;
    final to = l.kind == MdLineKind.heading && l.content > from
        ? l.content
        : from;
    final prefix = off ? '' : '${'#' * level} ';
    out = out.replaceRange(from, to, prefix);
    final d = prefix.length - (to - from);
    if (from <= caret) {
      caret = (caret + d).clamp(from + prefix.length, out.length);
    }
  }
  return TextEditingValue(
    text: out,
    selection: TextSelection.collapsed(offset: caret),
  );
}

/// The lines under the selection quoted, or unquoted when they all are.
@visibleForTesting
TextEditingValue toggleQuote(TextEditingValue value, MdLive live) {
  final t = value.text;
  final sel = value.selection;
  final lines = live.lines
      .where((l) => l.end >= sel.start && l.start <= sel.end)
      .toList();
  if (lines.isEmpty) return value;
  final off = lines.every((l) => l.quote != null);
  var out = t;
  var caret = sel.extentOffset;
  for (final l in lines.reversed) {
    if (off) {
      final q = t.substring(l.start, l.end);
      final m = RegExp(r'^ {0,3}> ?').firstMatch(q)!;
      out = out.replaceRange(l.start, l.start + m[0]!.length, '');
      if (l.start < caret) {
        caret = (caret - m[0]!.length).clamp(l.start, out.length);
      }
    } else {
      out = out.replaceRange(l.start, l.start, '> ');
      if (l.start <= caret) caret += 2;
    }
  }
  return TextEditingValue(
    text: out,
    selection: TextSelection.collapsed(offset: caret),
  );
}

/// The formatting buttons, shared by the bar floating over a selection and
/// the one over the keyboard.
List<Widget> _formatButtons(MarkdownRichController controller) {
  final f = controller.format;
  Widget mark(String label, String name, bool on, VoidCallback run) =>
      KeyButton(
        label: label,
        logName: name,
        active: on,
        minWidth: 40,
        onTap: f == null ? () {} : run,
      );
  return [
    mark('B', 'bold', f?.bold ?? false, controller.toggleBold),
    mark('I', 'italic', f?.italic ?? false, controller.toggleItalic),
    mark('</>', 'code', f?.code ?? false, controller.toggleCode),
    mark(
      'LINK',
      'link',
      f?.link ?? false,
      () => unawaited(controller.editLink()),
    ),
    mark('H1', 'heading 1', f?.heading == 1, () => controller.toggleHeading(1)),
    mark('H2', 'heading 2', f?.heading == 2, () => controller.toggleHeading(2)),
    mark('❝', 'quote', f?.quote ?? false, controller.toggleQuote),
  ];
}

/// The small bar over a selection on a desktop, as Medium's: bold, italic,
/// code, link, two headings and a quote.
class MarkdownFloatingBar extends StatelessWidget {
  const MarkdownFloatingBar({super.key, required this.controller});

  final MarkdownRichController controller;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    return TextFieldTapRegion(
      child: ExcludeFocus(
        child: Container(
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          decoration: BoxDecoration(
            color: p.panel,
            border: Border.all(color: p.border),
            boxShadow: const [
              BoxShadow(blurRadius: 8, color: Color(0x33000000)),
            ],
          ),
          child: ListenableBuilder(
            listenable: controller,
            builder: (context, _) => Row(
              mainAxisSize: MainAxisSize.min,
              children: _formatButtons(controller),
            ),
          ),
        ),
      ),
    );
  }
}

/// The bar over the keyboard on a phone: undo and redo, then the same
/// formatting as the floating bar, each lit while it is on at the caret.
class MarkdownRichBar extends StatelessWidget {
  const MarkdownRichBar({
    super.key,
    required this.controller,
    required this.history,
    required this.canUndo,
    required this.canRedo,
    required this.onUndo,
    required this.onRedo,
  });

  final MarkdownRichController controller;

  /// What [canUndo] and [canRedo] follow.
  final Listenable history;
  final bool Function() canUndo;
  final bool Function() canRedo;
  final VoidCallback onUndo;
  final VoidCallback onRedo;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    return TextFieldTapRegion(
      child: Material(
        color: p.sidebar,
        shape: Border(top: BorderSide(color: p.border)),
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: 48,
            child: ListenableBuilder(
              listenable: Listenable.merge([controller, history]),
              builder: (context, _) => ExcludeFocus(
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  children: [
                    IconButton(
                      tooltip: 'Undo',
                      onPressed: canUndo() ? onUndo : null,
                      icon: const Icon(Icons.undo),
                    ),
                    IconButton(
                      tooltip: 'Redo',
                      onPressed: canRedo() ? onRedo : null,
                      icon: const Icon(Icons.redo),
                    ),
                    const SizedBox(width: 6),
                    ..._formatButtons(controller),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
