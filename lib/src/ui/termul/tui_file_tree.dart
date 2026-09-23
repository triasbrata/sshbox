// Ported from TUI-Termul/termul at 27d94c6fc16502efd103ba217f9e0b52bb164dc5,
// lib/components/tui_file_tree.dart. MIT License, Copyright (c) 2026 TUI-Termul: see
// LICENSE beside this file.
//
// Changed for Jeansh:
// A glyph button is a node of its own, named by its word, with the glyph
// left out, so a screen reader, an e2e flow and a finder reach it by that
// word.

import 'package:flutter/material.dart';

import 'termul_theme.dart';
import 'tui_text.dart';
import 'tui_tooltip.dart';

/// Entry kind for [TuiFileNode].
enum TuiFileKind { file, folder, symlink }

/// One visible row in [TuiFileTree] — host owns expand/listing state.
class TuiFileNode {
  const TuiFileNode({
    required this.id,
    required this.name,
    required this.kind,
    this.depth = 0,
    this.expanded = false,
    this.loading = false,
    this.error = false,
    this.glyph,
  });

  /// Stable id (usually remote path).
  final String id;
  final String name;
  final TuiFileKind kind;
  final int depth;

  /// Folders only — whether children are shown.
  final bool expanded;
  final bool loading;
  final bool error;

  /// Optional lead glyph override (e.g. language mark).
  final String? glyph;
}

/// Dense VS Code–style explorer: indent guides, chevrons, toolbar, filter.
///
/// Presentation only — listings, upload, and FS ops stay with the host.
class TuiFileTree extends StatelessWidget {
  const TuiFileTree({
    super.key,
    required this.nodes,
    this.title,
    this.rootLabel,
    this.selectedId,
    this.filtering = false,
    this.filterController,
    this.filterFocusNode,
    this.onFilterChanged,
    this.onToggleFilter,
    this.showDotfiles = false,
    this.onToggleDotfiles,
    this.loading = false,
    this.errorMessage,
    this.emptyMessage = 'Empty folder',
    this.onSelect,
    this.onToggleExpand,
    this.onContextMenu,
    this.onRootPressed,
    this.onNewFile,
    this.onNewFolder,
    this.onUpload,
    this.onRefresh,
    this.onCollapseAll,
    this.onClose,
    this.rowHeight = 32,
    this.indent = 16,
    this.width,
  });

  final List<TuiFileNode> nodes;

  /// Host / session label beside EXPLORER.
  final String? title;
  final String? rootLabel;
  final String? selectedId;

  final bool filtering;
  final TextEditingController? filterController;
  final FocusNode? filterFocusNode;
  final ValueChanged<String>? onFilterChanged;
  final VoidCallback? onToggleFilter;

  final bool showDotfiles;
  final VoidCallback? onToggleDotfiles;

  final bool loading;
  final String? errorMessage;
  final String emptyMessage;

  final ValueChanged<TuiFileNode>? onSelect;
  final ValueChanged<TuiFileNode>? onToggleExpand;

  /// Long-press / secondary tap — host opens [showTuiMenu].
  final void Function(TuiFileNode node, Offset globalPosition)? onContextMenu;

  final VoidCallback? onRootPressed;
  final VoidCallback? onNewFile;
  final VoidCallback? onNewFolder;
  final VoidCallback? onUpload;
  final VoidCallback? onRefresh;
  final VoidCallback? onCollapseAll;
  final VoidCallback? onClose;

  final double rowHeight;
  final double indent;
  final double? width;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;

    return Container(
      width: width,
      decoration: BoxDecoration(
        color: p.sidebar,
        border: Border(right: BorderSide(color: p.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ExplorerBar(
            title: title,
            filtering: filtering,
            filterController: filterController,
            filterFocusNode: filterFocusNode,
            onFilterChanged: onFilterChanged,
            onToggleFilter: onToggleFilter,
            showDotfiles: showDotfiles,
            onToggleDotfiles: onToggleDotfiles,
            onClose: onClose,
            busy: loading,
          ),
          if (rootLabel != null)
            _RootHeader(
              label: rootLabel!,
              onRootPressed: onRootPressed,
              onNewFile: onNewFile,
              onNewFolder: onNewFolder,
              onUpload: onUpload,
              onRefresh: onRefresh,
              onCollapseAll: onCollapseAll,
              busy: loading,
            ),
          Expanded(child: _body(context)),
        ],
      ),
    );
  }

  Widget _body(BuildContext context) {
    final p = TermulThemeData.of(context).palette;

    if (errorMessage != null && errorMessage!.isNotEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                errorMessage!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: TermulFonts.mono,
                  fontSize: 12,
                  color: p.red,
                  height: 1.45,
                ),
              ),
              if (onRefresh != null) ...[
                const SizedBox(height: 12),
                InkWell(
                  onTap: onRefresh,
                  child: Text(
                    'retry',
                    style: TextStyle(
                      fontFamily: TermulFonts.mono,
                      fontSize: 12,
                      color: p.accent,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      );
    }

    if (loading && nodes.isEmpty) {
      return Center(
        child: Text(
          'loading…',
          style: TextStyle(
            fontFamily: TermulFonts.mono,
            fontSize: 12,
            color: p.dim,
          ),
        ),
      );
    }

    if (nodes.isEmpty) {
      return Center(
        child: Text(
          emptyMessage,
          style: TextStyle(
            fontFamily: TermulFonts.mono,
            fontSize: 12,
            color: p.dim,
          ),
        ),
      );
    }

    return ListView.builder(
      itemCount: nodes.length,
      itemExtent: rowHeight,
      itemBuilder: (context, i) {
        final node = nodes[i];
        return _FileRow(
          node: node,
          selected: node.id == selectedId,
          indent: indent,
          rowHeight: rowHeight,
          onSelect: onSelect,
          onToggleExpand: onToggleExpand,
          onContextMenu: onContextMenu,
        );
      },
    );
  }
}

class _ExplorerBar extends StatelessWidget {
  const _ExplorerBar({
    required this.title,
    required this.filtering,
    required this.filterController,
    required this.filterFocusNode,
    required this.onFilterChanged,
    required this.onToggleFilter,
    required this.showDotfiles,
    required this.onToggleDotfiles,
    required this.onClose,
    required this.busy,
  });

  final String? title;
  final bool filtering;
  final TextEditingController? filterController;
  final FocusNode? filterFocusNode;
  final ValueChanged<String>? onFilterChanged;
  final VoidCallback? onToggleFilter;
  final bool showDotfiles;
  final VoidCallback? onToggleDotfiles;
  final VoidCallback? onClose;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    final mono = TextStyle(
      fontFamily: TermulFonts.mono,
      fontSize: 12,
      color: p.text,
    );

    return SizedBox(
      height: 40,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: p.border)),
        ),
        child: Row(
          children: [
            if (onClose != null)
              _GlyphBtn(label: 'Close files', glyph: '×', onPressed: onClose),
            Expanded(
              child: filtering && filterController != null
                  ? Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: TextField(
                        controller: filterController,
                        focusNode: filterFocusNode,
                        autofocus: true,
                        style: mono,
                        cursorColor: p.accent,
                        decoration: InputDecoration(
                          hintText: 'Filter the tree',
                          hintStyle: mono.copyWith(color: p.dim),
                          border: InputBorder.none,
                          isDense: true,
                        ),
                        onChanged: onFilterChanged,
                      ),
                    )
                  : Padding(
                      padding: const EdgeInsets.only(left: 12),
                      child: Text.rich(
                        TextSpan(
                          text: 'EXPLORER',
                          style: TextStyle(
                            fontFamily: TermulFonts.mono,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 1.1,
                            color: p.text,
                          ),
                          children: [
                            if (title != null && title!.isNotEmpty)
                              TextSpan(
                                text: '   $title',
                                style: TextStyle(
                                  letterSpacing: 0,
                                  fontWeight: FontWeight.w400,
                                  color: p.dim,
                                ),
                              ),
                          ],
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
            ),
            _GlyphBtn(
              label: filtering ? 'Clear filter' : 'Filter by name',
              glyph: filtering ? '×' : '/',
              onPressed: onToggleFilter,
            ),
            if (onToggleDotfiles != null)
              _GlyphBtn(
                label: showDotfiles ? 'Hide dotfiles' : 'Show dotfiles',
                glyph: showDotfiles ? '·' : '◌',
                selected: showDotfiles,
                onPressed: onToggleDotfiles,
              ),
            if (busy)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    color: p.accent,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _RootHeader extends StatelessWidget {
  const _RootHeader({
    required this.label,
    required this.onRootPressed,
    required this.onNewFile,
    required this.onNewFolder,
    required this.onUpload,
    required this.onRefresh,
    required this.onCollapseAll,
    required this.busy,
  });

  final String label;
  final VoidCallback? onRootPressed;
  final VoidCallback? onNewFile;
  final VoidCallback? onNewFolder;
  final VoidCallback? onUpload;
  final VoidCallback? onRefresh;
  final VoidCallback? onCollapseAll;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    final enabled = !busy;

    return SizedBox(
      height: 36,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: p.surface,
          border: Border(bottom: BorderSide(color: p.border)),
        ),
        child: Row(
          children: [
            Expanded(
              child: InkWell(
                onTap: enabled ? onRootPressed : null,
                child: Padding(
                  padding: const EdgeInsets.only(left: 12),
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          label.toUpperCase(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: TermulFonts.mono,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.6,
                            color: p.text,
                          ),
                        ),
                      ),
                      if (onRootPressed != null)
                        Text(
                          ' ▾',
                          style: TextStyle(
                            fontFamily: TermulFonts.mono,
                            fontSize: 11,
                            color: p.dim,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            _GlyphBtn(
              label: 'New file',
              glyph: '+',
              onPressed: enabled ? onNewFile : null,
            ),
            _GlyphBtn(
              label: 'New folder',
              glyph: '▣',
              onPressed: enabled ? onNewFolder : null,
            ),
            _GlyphBtn(
              label: 'Upload here',
              glyph: '↑',
              onPressed: enabled ? onUpload : null,
            ),
            _GlyphBtn(
              label: 'Refresh',
              glyph: '↻',
              onPressed: enabled ? onRefresh : null,
            ),
            _GlyphBtn(
              label: 'Collapse all',
              glyph: '⇈',
              onPressed: enabled ? onCollapseAll : null,
            ),
            const SizedBox(width: 2),
          ],
        ),
      ),
    );
  }
}

class _GlyphBtn extends StatelessWidget {
  const _GlyphBtn({
    required this.label,
    required this.glyph,
    this.onPressed,
    this.selected = false,
  });

  final String label;
  final String glyph;
  final VoidCallback? onPressed;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    final enabled = onPressed != null;

    // Avoid emoji — ASCII / box marks only.
    final mark = glyph;

    return TuiTooltip(
      message: label,
      excludeFromSemantics: true,
      child: Semantics(
        container: true,
        button: true,
        enabled: enabled,
        label: label,
        child: InkWell(
          onTap: onPressed,
          child: SizedBox(
            width: 32,
            height: 32,
            child: Center(
              child: ExcludeSemantics(
                child: Text(
                  mark,
                  style: TextStyle(
                    fontFamily: TermulFonts.mono,
                    fontSize: 13,
                    color: !enabled
                        ? p.dim
                        : selected
                        ? p.accent
                        : p.text,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FileRow extends StatelessWidget {
  const _FileRow({
    required this.node,
    required this.selected,
    required this.indent,
    required this.rowHeight,
    required this.onSelect,
    required this.onToggleExpand,
    required this.onContextMenu,
  });

  final TuiFileNode node;
  final bool selected;
  final double indent;
  final double rowHeight;
  final ValueChanged<TuiFileNode>? onSelect;
  final ValueChanged<TuiFileNode>? onToggleExpand;
  final void Function(TuiFileNode node, Offset globalPosition)? onContextMenu;

  String get _lead {
    if (node.glyph != null) return node.glyph!;
    return switch (node.kind) {
      TuiFileKind.folder when node.loading => '…',
      TuiFileKind.folder when node.error => '!',
      TuiFileKind.folder when node.expanded => '▾',
      TuiFileKind.folder => '▸',
      TuiFileKind.symlink => '↗',
      TuiFileKind.file => '·',
    };
  }

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    Offset? downAt;

    return Material(
      color: selected ? p.selection : Colors.transparent,
      child: InkWell(
        onTap: () {
          if (node.kind == TuiFileKind.folder) {
            onToggleExpand?.call(node);
          }
          onSelect?.call(node);
        },
        onTapDown: (d) => downAt = d.globalPosition,
        onLongPress: onContextMenu == null
            ? null
            : () => onContextMenu!(node, downAt ?? Offset.zero),
        onSecondaryTapDown: onContextMenu == null
            ? null
            : (d) => onContextMenu!(node, d.globalPosition),
        child: SizedBox(
          height: rowHeight,
          child: Row(
            children: [
              const SizedBox(width: 8),
              for (var level = 0; level < node.depth; level++)
                SizedBox(
                  width: indent,
                  child: Center(
                    child: Container(
                      width: 1,
                      height: rowHeight,
                      color: p.border,
                    ),
                  ),
                ),
              SizedBox(
                width: indent,
                child: Center(
                  child: Text(
                    _lead,
                    style: TextStyle(
                      fontFamily: TermulFonts.mono,
                      fontSize: 13,
                      color: node.error
                          ? p.red
                          : node.kind == TuiFileKind.folder
                          ? p.accent
                          : p.dim,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: TuiText(
                  node.name,
                  size: 13,
                  tone: selected ? TuiTextTone.accent : TuiTextTone.normal,
                ),
              ),
              if (node.kind == TuiFileKind.symlink)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Text(
                    'link',
                    style: TextStyle(
                      fontFamily: TermulFonts.mono,
                      fontSize: 10,
                      color: p.dim,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Flattens a nested map of folder → children for demos / simple hosts.
///
/// [childrenOf] returns immediate children; [expanded] which folders are open.
List<TuiFileNode> tuiFileTreeFlatten({
  required List<TuiFileNode> roots,
  required Set<String> expanded,
  required List<TuiFileNode> Function(String folderId) childrenOf,
  Set<String> loading = const {},
  Set<String> errors = const {},
}) {
  final out = <TuiFileNode>[];

  void walk(TuiFileNode node) {
    final isFolder = node.kind == TuiFileKind.folder;
    final open = expanded.contains(node.id);
    out.add(
      TuiFileNode(
        id: node.id,
        name: node.name,
        kind: node.kind,
        depth: node.depth,
        expanded: open,
        loading: loading.contains(node.id),
        error: errors.contains(node.id),
        glyph: node.glyph,
      ),
    );
    if (isFolder && open && !loading.contains(node.id)) {
      for (final child in childrenOf(node.id)) {
        walk(
          TuiFileNode(
            id: child.id,
            name: child.name,
            kind: child.kind,
            depth: node.depth + 1,
            glyph: child.glyph,
          ),
        );
      }
    }
  }

  for (final r in roots) {
    walk(r);
  }
  return out;
}
