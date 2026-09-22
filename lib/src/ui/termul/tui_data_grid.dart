// Ported from TUI-Termul/termul at 27d94c6fc16502efd103ba217f9e0b52bb164dc5,
// lib/components/tui_data_grid.dart. MIT License, Copyright (c) 2026 TUI-Termul: see
// LICENSE beside this file.
//
// As upstream.

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'termul_theme.dart';

/// Column header for [TuiDataGrid].
class TuiDataGridColumn {
  const TuiDataGridColumn({
    required this.id,
    required this.label,
    this.width = 140,
  });

  final String id;
  final String label;
  final double width;
}

/// One cell — [value] `null` renders as NULL.
class TuiDataGridCell {
  const TuiDataGridCell({this.value, this.dirty = false});

  final String? value;
  final bool dirty;
}

/// One result row.
class TuiDataGridRow {
  const TuiDataGridRow({
    required this.id,
    required this.cells,
    this.isNew = false,
    this.deleted = false,
  });

  final String id;
  final List<TuiDataGridCell> cells;
  final bool isNew;
  final bool deleted;
}

/// Scrollable database result grid — mono cells, dirty/new/deleted states.
///
/// Horizontal scroll on narrow viewports; columns keep [TuiDataGridColumn.width].
/// Editing is host-driven via [onCellTap] (open your own editor / sheet).
class TuiDataGrid extends StatelessWidget {
  const TuiDataGrid({
    super.key,
    required this.columns,
    required this.rows,
    this.selected,
    this.onSelect,
    this.onCellTap,
    this.readOnly = false,
    this.errorBanner,
    this.minColumnWidth = 100,
  });

  final List<TuiDataGridColumn> columns;
  final List<TuiDataGridRow> rows;

  /// `(rowIndex, columnIndex)` of the focused cell.
  final (int, int)? selected;
  final ValueChanged<(int, int)>? onSelect;

  /// Fired when a cell is activated (tap). Host opens an editor.
  final void Function(int row, int column)? onCellTap;
  final bool readOnly;
  final String? errorBanner;
  final double minColumnWidth;

  List<double> get _widths => [
    for (final c in columns) math.max(c.width, minColumnWidth),
  ];

  double get _tableWidth => _widths.fold(0, (a, b) => a + b);

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    final widths = _widths;
    final tableWidth = _tableWidth;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (errorBanner != null && errorBanner!.isNotEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            color: p.isLight ? p.deep : p.red.withValues(alpha: 0.2),
            child: Text(
              errorBanner!,
              style: TextStyle(
                fontFamily: TermulFonts.mono,
                fontSize: 12,
                color: p.isLight ? p.panel : p.red,
              ),
            ),
          ),
        Expanded(
          child: Scrollbar(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: tableWidth,
                child: Column(
                  children: [
                    _HeaderRow(columns: columns, widths: widths),
                    Divider(height: 1, thickness: 1, color: p.border),
                    Expanded(
                      child: ListView.builder(
                        itemCount: rows.length,
                        itemBuilder: (context, r) => _DataRow(
                          rowIndex: r,
                          row: rows[r],
                          columns: columns,
                          widths: widths,
                          selected: selected,
                          readOnly: readOnly,
                          onSelect: onSelect,
                          onCellTap: onCellTap,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _HeaderRow extends StatelessWidget {
  const _HeaderRow({required this.columns, required this.widths});

  final List<TuiDataGridColumn> columns;
  final List<double> widths;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    return Container(
      color: p.surface,
      child: Row(
        children: [
          for (var i = 0; i < columns.length; i++)
            SizedBox(
              width: widths[i],
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                child: Text(
                  columns[i].label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: TermulFonts.mono,
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 0.3,
                    color: p.accent,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _DataRow extends StatelessWidget {
  const _DataRow({
    required this.rowIndex,
    required this.row,
    required this.columns,
    required this.widths,
    required this.selected,
    required this.readOnly,
    this.onSelect,
    this.onCellTap,
  });

  final int rowIndex;
  final TuiDataGridRow row;
  final List<TuiDataGridColumn> columns;
  final List<double> widths;
  final (int, int)? selected;
  final bool readOnly;
  final ValueChanged<(int, int)>? onSelect;
  final void Function(int row, int column)? onCellTap;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;

    Color? bg;
    if (row.deleted) {
      bg = p.red.withValues(alpha: p.isLight ? 0.06 : 0.12);
    } else if (row.isNew) {
      bg = p.accent.withValues(alpha: p.isLight ? 0.05 : 0.1);
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        color: bg,
        border: Border(
          left: BorderSide(
            color: row.isNew ? p.accent : Colors.transparent,
            width: 2,
          ),
          bottom: BorderSide(color: p.border),
        ),
      ),
      child: Row(
        children: [
          for (var c = 0; c < columns.length; c++)
            SizedBox(
              width: widths[c],
              child: _Cell(
                value: c < row.cells.length ? row.cells[c].value : null,
                dirty: c < row.cells.length && row.cells[c].dirty,
                deleted: row.deleted,
                selected: selected == (rowIndex, c),
                readOnly: readOnly,
                onTap: () {
                  onSelect?.call((rowIndex, c));
                  if (!readOnly) onCellTap?.call(rowIndex, c);
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _Cell extends StatelessWidget {
  const _Cell({
    required this.value,
    required this.dirty,
    required this.deleted,
    required this.selected,
    required this.readOnly,
    this.onTap,
  });

  final String? value;
  final bool dirty;
  final bool deleted;
  final bool selected;
  final bool readOnly;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    final isNull = value == null;
    final text = isNull ? 'NULL' : value!;

    return Material(
      color: selected
          ? p.selection
          : dirty
          ? p.accent.withValues(alpha: p.isLight ? 0.08 : 0.16)
          : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        hoverColor: p.selection,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: TermulFonts.mono,
              fontSize: 12,
              height: 1.3,
              fontStyle: isNull ? FontStyle.italic : FontStyle.normal,
              decoration: deleted ? TextDecoration.lineThrough : null,
              color: isNull || deleted ? p.dim : p.text,
            ),
          ),
        ),
      ),
    );
  }
}

// ── JSON tree ──────────────────────────────────────────────────────────────

/// One document card — index, copy action, nested [TuiJsonTree].
class TuiJsonCard extends StatelessWidget {
  const TuiJsonCard({
    super.key,
    required this.index,
    required this.data,
    this.onCopy,
  });

  final int index;
  final Map<String, dynamic> data;
  final VoidCallback? onCopy;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: p.panel,
        border: Border.all(color: p.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 4, 0),
            child: Row(
              children: [
                Text(
                  '$index',
                  style: TextStyle(
                    fontFamily: TermulFonts.mono,
                    fontSize: 11,
                    color: p.dim,
                  ),
                ),
                const Spacer(),
                if (onCopy != null)
                  IconButton(
                    tooltip: 'Copy JSON',
                    visualDensity: VisualDensity.compact,
                    icon: Text(
                      '⎘',
                      style: TextStyle(
                        fontFamily: TermulFonts.mono,
                        fontSize: 14,
                        color: p.muted,
                      ),
                    ),
                    onPressed: onCopy,
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: TuiJsonTree(value: data),
          ),
        ],
      ),
    );
  }
}

/// Foldable JSON object / array / scalar tree.
class TuiJsonTree extends StatelessWidget {
  const TuiJsonTree({
    super.key,
    required this.value,
    this.rootName,
    this.maxChildren = 100,
  });

  final Object? value;
  final String? rootName;
  final int maxChildren;

  @override
  Widget build(BuildContext context) {
    if (rootName != null) {
      return TuiJsonNode(
        name: rootName!,
        value: value,
        maxChildren: maxChildren,
      );
    }
    final v = value;
    if (v is Map) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final e in v.entries)
            TuiJsonNode(
              name: '${e.key}',
              value: e.value,
              maxChildren: maxChildren,
            ),
        ],
      );
    }
    if (v is List) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, item) in v.indexed)
            TuiJsonNode(name: '$i', value: item, maxChildren: maxChildren),
        ],
      );
    }
    return TuiJsonNode(name: 'value', value: v, maxChildren: maxChildren);
  }
}

/// One field / index in a JSON tree.
class TuiJsonNode extends StatefulWidget {
  const TuiJsonNode({
    super.key,
    required this.name,
    required this.value,
    this.depth = 0,
    this.maxChildren = 100,
  });

  final String name;
  final Object? value;
  final int depth;
  final int maxChildren;

  @override
  State<TuiJsonNode> createState() => _TuiJsonNodeState();
}

class _TuiJsonNodeState extends State<TuiJsonNode> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    final value = widget.value;

    final wrapped =
        value is Map &&
        value.length == 1 &&
        '${value.keys.first}'.startsWith(r'$');

    final children = switch (value) {
      Map map when map.isNotEmpty && !wrapped => [
        for (final e in map.entries) ('${e.key}', e.value),
      ],
      List list when list.isNotEmpty => [
        for (final (i, item) in list.indexed) ('$i', item),
      ],
      _ => null,
    };

    final indent = 12.0 + widget.depth * 16;

    if (children == null) {
      return Padding(
        padding: EdgeInsets.fromLTRB(indent + 20, 3, 12, 3),
        child: SelectableText.rich(
          TextSpan(
            style: TextStyle(
              fontFamily: TermulFonts.mono,
              fontSize: 12,
              height: 1.35,
              color: p.text,
            ),
            children: [
              TextSpan(
                text: widget.name,
                style: TextStyle(color: p.accent),
              ),
              const TextSpan(text: ': '),
              TextSpan(
                text: _encode(value),
                style: TextStyle(color: value is String ? p.cyan : p.text),
              ),
            ],
          ),
        ),
      );
    }

    final shown = children.take(widget.maxChildren).toList();
    final rest = children.length - shown.length;
    final summary = value is List
        ? 'Array(${children.length})'
        : 'Object(${children.length})';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () => setState(() => _open = !_open),
          hoverColor: p.selection,
          child: Padding(
            padding: EdgeInsets.fromLTRB(indent, 3, 12, 3),
            child: Row(
              children: [
                SizedBox(
                  width: 16,
                  child: Text(
                    _open ? '▾' : '▸',
                    style: TextStyle(
                      fontFamily: TermulFonts.mono,
                      fontSize: 11,
                      color: p.dim,
                    ),
                  ),
                ),
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      style: TextStyle(
                        fontFamily: TermulFonts.mono,
                        fontSize: 12,
                        height: 1.35,
                      ),
                      children: [
                        TextSpan(
                          text: widget.name,
                          style: TextStyle(color: p.accent),
                        ),
                        TextSpan(
                          text: ': $summary',
                          style: TextStyle(color: p.muted),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_open) ...[
          for (final (name, child) in shown)
            TuiJsonNode(
              name: name,
              value: child,
              depth: widget.depth + 1,
              maxChildren: widget.maxChildren,
            ),
          if (rest > 0)
            Padding(
              padding: EdgeInsets.fromLTRB(indent + 20, 2, 12, 4),
              child: Text(
                '… $rest more',
                style: TextStyle(
                  fontFamily: TermulFonts.mono,
                  fontSize: 11,
                  color: p.dim,
                ),
              ),
            ),
        ],
      ],
    );
  }

  String _encode(Object? value) {
    try {
      return jsonEncode(value);
    } catch (_) {
      return '$value';
    }
  }
}
