// Ported from TUI-Termul/termul at 27d94c6fc16502efd103ba217f9e0b52bb164dc5,
// lib/components/tui_diff_view.dart. MIT License, Copyright (c) 2026 TUI-Termul: see
// LICENSE beside this file.
//
// As upstream.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'termul_palette.dart';
import 'termul_theme.dart';
import 'tui_tooltip.dart';

/// Kind of a diff line — tint is subtle; the `+`/`−`/space prefix carries meaning.
enum TuiDiffLineKind { context, added, removed }

/// One side of a split row, or one unified line.
class TuiDiffLine {
  const TuiDiffLine({required this.kind, required this.text, this.number});

  final TuiDiffLineKind kind;
  final String text;
  final int? number;

  String get prefix => switch (kind) {
    TuiDiffLineKind.added => '+',
    TuiDiffLineKind.removed => '−',
    TuiDiffLineKind.context => ' ',
  };
}

/// One visual row in a file diff.
sealed class TuiDiffRow {
  const TuiDiffRow();
}

/// `@@ -a,b +c,d @@` header with optional expand-context actions.
class TuiDiffHunkRow extends TuiDiffRow {
  const TuiDiffHunkRow({
    required this.header,
    this.onExpandAbove,
    this.onExpandBelow,
  });

  final String header;
  final VoidCallback? onExpandAbove;
  final VoidCallback? onExpandBelow;
}

/// Unified (single-column) line.
class TuiDiffUnifiedRow extends TuiDiffRow {
  const TuiDiffUnifiedRow(this.line);
  final TuiDiffLine line;
}

/// Split (side-by-side) line — either side may be empty for pure add/remove.
class TuiDiffSplitRow extends TuiDiffRow {
  const TuiDiffSplitRow({this.oldLine, this.newLine});
  final TuiDiffLine? oldLine;
  final TuiDiffLine? newLine;
}

/// One file in a multi-file diff.
class TuiDiffFile {
  const TuiDiffFile({
    required this.path,
    required this.rows,
    this.added = 0,
    this.removed = 0,
    this.folded = false,
    this.binary = false,
    this.tooLarge = false,
    this.language,
  });

  final String path;
  final List<TuiDiffRow> rows;
  final int added;
  final int removed;
  final bool folded;
  final bool binary;
  final bool tooLarge;
  final String? language;
}

/// Width at which [TuiDiffView] prefers split over unified when mode is auto.
const tuiDiffSplitBreakpoint = 900.0;

/// GitHub-style five-block change meter.
class TuiChangeBar extends StatelessWidget {
  const TuiChangeBar({super.key, required this.added, required this.removed});

  final int added;
  final int removed;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    final total = added + removed;
    final green = total < 5
        ? added
        : (total == 0 ? 0 : (added * 5 / total).round().clamp(0, 5));
    final red = total < 5 ? removed : (5 - green);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var n = 0; n < 5; n++)
          Container(
            width: 8,
            height: 8,
            margin: const EdgeInsets.only(right: 1),
            color: n < green
                ? p.green
                : n < green + red
                ? p.red
                : p.border,
          ),
      ],
    );
  }
}

/// Side-by-side / unified diff viewer for one or more files.
///
/// Pass [split]: `true`/`false` to force a mode, or `null` to follow width
/// ([tuiDiffSplitBreakpoint]). Syntax colouring is left to the host — pass
/// plain [TuiDiffLine.text]; wrap externally if you need spans.
class TuiDiffView extends StatelessWidget {
  const TuiDiffView({
    super.key,
    required this.files,
    this.split,
    this.splitBreakpoint = tuiDiffSplitBreakpoint,
    this.onToggleFold,
    this.onCopyPath,
    this.onFileMenu,
  });

  final List<TuiDiffFile> files;

  /// `null` = auto from width.
  final bool? split;
  final double splitBreakpoint;
  final void Function(int fileIndex)? onToggleFold;
  final void Function(int fileIndex)? onCopyPath;
  final void Function(int fileIndex, Offset global)? onFileMenu;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final useSplit = split ?? constraints.maxWidth >= splitBreakpoint;
        return ListView.builder(
          itemCount: files.length,
          itemBuilder: (context, i) => _FileBlock(
            index: i,
            file: files[i],
            split: useSplit,
            onToggleFold: onToggleFold,
            onCopyPath: onCopyPath,
            onFileMenu: onFileMenu,
          ),
        );
      },
    );
  }
}

class _FileBlock extends StatelessWidget {
  const _FileBlock({
    required this.index,
    required this.file,
    required this.split,
    this.onToggleFold,
    this.onCopyPath,
    this.onFileMenu,
  });

  final int index;
  final TuiDiffFile file;
  final bool split;
  final void Function(int fileIndex)? onToggleFold;
  final void Function(int fileIndex)? onCopyPath;
  final void Function(int fileIndex, Offset global)? onFileMenu;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        border: Border.all(color: p.border),
        color: p.panel,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _FileHeader(
            file: file,
            onToggleFold: onToggleFold == null
                ? null
                : () => onToggleFold!(index),
            onCopyPath: onCopyPath == null ? null : () => onCopyPath!(index),
            onMenu: onFileMenu == null ? null : (at) => onFileMenu!(index, at),
          ),
          if (file.binary)
            const _Notice('Binary file not shown.')
          else if (file.tooLarge)
            const _Notice('Diff too large to render.')
          else if (file.folded)
            const SizedBox.shrink()
          else
            for (final row in file.rows)
              switch (row) {
                TuiDiffHunkRow(
                  :final header,
                  :final onExpandAbove,
                  :final onExpandBelow,
                ) =>
                  _HunkHeader(
                    header: header,
                    onExpandAbove: onExpandAbove,
                    onExpandBelow: onExpandBelow,
                  ),
                TuiDiffUnifiedRow(:final line) => _UnifiedLine(line: line),
                TuiDiffSplitRow(:final oldLine, :final newLine) =>
                  split
                      ? _SplitLine(oldLine: oldLine, newLine: newLine)
                      : _UnifiedLine(line: _asUnified(oldLine, newLine)),
              },
        ],
      ),
    );
  }
}

TuiDiffLine _asUnified(TuiDiffLine? oldLine, TuiDiffLine? newLine) {
  if (oldLine != null &&
      newLine != null &&
      oldLine.kind == TuiDiffLineKind.context) {
    return newLine;
  }
  if (oldLine?.kind == TuiDiffLineKind.removed) return oldLine!;
  if (newLine != null) return newLine;
  return oldLine ?? const TuiDiffLine(kind: TuiDiffLineKind.context, text: '');
}

class _FileHeader extends StatelessWidget {
  const _FileHeader({
    required this.file,
    this.onToggleFold,
    this.onCopyPath,
    this.onMenu,
  });

  final TuiDiffFile file;
  final VoidCallback? onToggleFold;
  final VoidCallback? onCopyPath;
  final void Function(Offset global)? onMenu;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    return Material(
      color: p.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 4, 6),
        child: Row(
          children: [
            InkWell(
              onTap: onToggleFold,
              hoverColor: p.selection,
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Text(
                  file.folded ? '▸' : '▾',
                  style: TextStyle(
                    fontFamily: TermulFonts.mono,
                    fontSize: 12,
                    color: p.dim,
                  ),
                ),
              ),
            ),
            TuiChangeBar(added: file.added, removed: file.removed),
            const SizedBox(width: 8),
            Text(
              '+${file.added}',
              style: TextStyle(
                fontFamily: TermulFonts.mono,
                fontSize: 11,
                color: p.green,
              ),
            ),
            const SizedBox(width: 4),
            Text(
              '−${file.removed}',
              style: TextStyle(
                fontFamily: TermulFonts.mono,
                fontSize: 11,
                color: p.red,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                file.path,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: TermulFonts.mono,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: p.text,
                ),
              ),
            ),
            if (file.language != null)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Text(
                  file.language!,
                  style: TextStyle(
                    fontFamily: TermulFonts.mono,
                    fontSize: 10,
                    color: p.dim,
                  ),
                ),
              ),
            if (onCopyPath != null)
              TuiIconButton(
                icon: '⎘',
                tooltip: 'Copy path',
                size: 32,
                iconSize: 14,
                onPressed: onCopyPath,
              ),
            if (onMenu != null)
              Builder(
                builder: (ctx) => TuiIconButton(
                  icon: '⋮',
                  tooltip: 'File menu',
                  size: 32,
                  onPressed: () {
                    final box = ctx.findRenderObject()! as RenderBox;
                    final at = box.localToGlobal(
                      Offset(box.size.width / 2, box.size.height),
                    );
                    onMenu!(at);
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _HunkHeader extends StatelessWidget {
  const _HunkHeader({
    required this.header,
    this.onExpandAbove,
    this.onExpandBelow,
  });

  final String header;
  final VoidCallback? onExpandAbove;
  final VoidCallback? onExpandBelow;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    return Container(
      color: p.selection,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          if (onExpandAbove != null)
            _ExpandBtn(
              label: '▲',
              tooltip: 'Expand above',
              onTap: onExpandAbove!,
            ),
          Expanded(
            child: Text(
              header,
              style: TextStyle(
                fontFamily: TermulFonts.mono,
                fontSize: 11,
                color: p.cyan,
              ),
            ),
          ),
          if (onExpandBelow != null)
            _ExpandBtn(
              label: '▼',
              tooltip: 'Expand below',
              onTap: onExpandBelow!,
            ),
        ],
      ),
    );
  }
}

class _ExpandBtn extends StatelessWidget {
  const _ExpandBtn({
    required this.label,
    required this.tooltip,
    required this.onTap,
  });

  final String label;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    return TuiTooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        hoverColor: p.selection,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: Text(
            label,
            style: TextStyle(
              fontFamily: TermulFonts.mono,
              fontSize: 10,
              color: p.accent,
            ),
          ),
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Text(
        text,
        style: TextStyle(
          fontFamily: TermulFonts.mono,
          fontSize: 12,
          color: p.muted,
        ),
      ),
    );
  }
}

class _UnifiedLine extends StatelessWidget {
  const _UnifiedLine({required this.line});
  final TuiDiffLine line;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    return ColoredBox(
      color: _tint(p, line.kind),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Gutter(number: line.number, width: 44),
          _Prefix(line.prefix),
          Expanded(child: _Code(line.text)),
        ],
      ),
    );
  }
}

class _SplitLine extends StatelessWidget {
  const _SplitLine({this.oldLine, this.newLine});
  final TuiDiffLine? oldLine;
  final TuiDiffLine? newLine;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: _Side(line: oldLine, fallbackKind: TuiDiffLineKind.removed),
          ),
          VerticalDivider(width: 1, thickness: 1, color: p.border),
          Expanded(
            child: _Side(line: newLine, fallbackKind: TuiDiffLineKind.added),
          ),
        ],
      ),
    );
  }
}

class _Side extends StatelessWidget {
  const _Side({required this.line, required this.fallbackKind});
  final TuiDiffLine? line;
  final TuiDiffLineKind fallbackKind;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    if (line == null) {
      return ColoredBox(
        color: _tint(p, fallbackKind).withValues(alpha: 0.35),
        child: const SizedBox(height: 20),
      );
    }
    return ColoredBox(
      color: _tint(p, line!.kind),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Gutter(number: line!.number, width: 40),
          _Prefix(line!.prefix),
          Expanded(child: _Code(line!.text)),
        ],
      ),
    );
  }
}

class _Gutter extends StatelessWidget {
  const _Gutter({required this.number, required this.width});
  final int? number;
  final double width;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    return SizedBox(
      width: width,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Text(
          number?.toString() ?? '',
          textAlign: TextAlign.right,
          style: TextStyle(
            fontFamily: TermulFonts.mono,
            fontSize: 11,
            height: 1.45,
            color: p.dim,
          ),
        ),
      ),
    );
  }
}

class _Prefix extends StatelessWidget {
  const _Prefix(this.prefix);
  final String prefix;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    return Padding(
      padding: const EdgeInsets.only(right: 4, top: 2),
      child: Text(
        prefix,
        style: TextStyle(
          fontFamily: TermulFonts.mono,
          fontSize: 12,
          height: 1.45,
          color: p.dim,
        ),
      ),
    );
  }
}

class _Code extends StatelessWidget {
  const _Code(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 2),
      child: SelectableText(
        text,
        style: TextStyle(
          fontFamily: TermulFonts.mono,
          fontSize: 12,
          height: 1.45,
          color: p.text,
        ),
      ),
    );
  }
}

Color _tint(TermulPalette p, TuiDiffLineKind kind) => switch (kind) {
  TuiDiffLineKind.added => p.green.withValues(alpha: p.isLight ? 0.12 : 0.2),
  TuiDiffLineKind.removed => p.red.withValues(alpha: p.isLight ? 0.12 : 0.22),
  TuiDiffLineKind.context => Colors.transparent,
};

/// Builds unified rows from a simple patch body (lines starting with +/−/space).
List<TuiDiffRow> tuiDiffRowsFromUnified(String patch) {
  final rows = <TuiDiffRow>[];
  var oldNo = 0;
  var newNo = 0;
  for (final raw in patch.split('\n')) {
    if (raw.startsWith('@@')) {
      rows.add(TuiDiffHunkRow(header: raw));
      final m = RegExp(r'@@ -(\d+)(?:,\d+)? \+(\d+)').firstMatch(raw);
      if (m != null) {
        oldNo = int.parse(m.group(1)!) - 1;
        newNo = int.parse(m.group(2)!) - 1;
      }
      continue;
    }
    if (raw.isEmpty && rows.isEmpty) continue;
    if (raw.startsWith('+')) {
      newNo++;
      rows.add(
        TuiDiffUnifiedRow(
          TuiDiffLine(
            kind: TuiDiffLineKind.added,
            text: raw.length > 1 ? raw.substring(1) : '',
            number: newNo,
          ),
        ),
      );
    } else if (raw.startsWith('-')) {
      oldNo++;
      rows.add(
        TuiDiffUnifiedRow(
          TuiDiffLine(
            kind: TuiDiffLineKind.removed,
            text: raw.length > 1 ? raw.substring(1) : '',
            number: oldNo,
          ),
        ),
      );
    } else {
      oldNo++;
      newNo++;
      final text = raw.startsWith(' ') ? raw.substring(1) : raw;
      rows.add(
        TuiDiffUnifiedRow(
          TuiDiffLine(kind: TuiDiffLineKind.context, text: text, number: newNo),
        ),
      );
    }
  }
  return rows;
}

/// Converts unified rows into split rows (pairs remove+add, else align).
List<TuiDiffRow> tuiDiffRowsToSplit(List<TuiDiffRow> unified) {
  final out = <TuiDiffRow>[];
  for (var i = 0; i < unified.length; i++) {
    final row = unified[i];
    if (row is TuiDiffHunkRow) {
      out.add(row);
      continue;
    }
    if (row is! TuiDiffUnifiedRow) {
      out.add(row);
      continue;
    }
    final line = row.line;
    if (line.kind == TuiDiffLineKind.removed &&
        i + 1 < unified.length &&
        unified[i + 1] is TuiDiffUnifiedRow &&
        (unified[i + 1] as TuiDiffUnifiedRow).line.kind ==
            TuiDiffLineKind.added) {
      final next = (unified[i + 1] as TuiDiffUnifiedRow).line;
      out.add(TuiDiffSplitRow(oldLine: line, newLine: next));
      i++;
    } else if (line.kind == TuiDiffLineKind.removed) {
      out.add(TuiDiffSplitRow(oldLine: line));
    } else if (line.kind == TuiDiffLineKind.added) {
      out.add(TuiDiffSplitRow(newLine: line));
    } else {
      out.add(TuiDiffSplitRow(oldLine: line, newLine: line));
    }
  }
  return out;
}

/// Copies [text] to the clipboard — used by demos / hosts.
Future<void> tuiCopyText(String text) =>
    Clipboard.setData(ClipboardData(text: text));
