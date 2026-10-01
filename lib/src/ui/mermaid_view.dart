import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:webview_flutter/webview_flutter.dart';

import '../platform.dart';
import 'toast.dart';
import 'tui.dart';

/// Draws a Markdown file's ```mermaid blocks as diagrams, as the builder for
/// `code` in [Markdown.builders]. Any other code, block or inline, is left to
/// the package — and so is a mermaid block where there is no web view to draw
/// it in, Linux and Windows, which show its source as code.
class MermaidBuilder extends MarkdownElementBuilder {
  /// [copyable] puts a button beside each diagram that copies its source:
  /// chat's, where a reply has no Source view to copy it from.
  MermaidBuilder({this.copyable = false});

  final bool copyable;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    if (!hasWebView) return null;
    if (element.attributes['class'] != 'language-mermaid') return null;
    final source = element.textContent;
    if (!copyable) return MermaidView(key: ValueKey(source), source: source);
    return Row(
      key: ValueKey(source),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: MermaidView(source: source)),
        // Beside it rather than over the web view, as the preview's code
        // blocks keep theirs.
        IconButton(
          tooltip: 'Copy diagram source',
          onPressed: () => copyMermaid(context, source),
          icon: const Icon(Icons.content_copy, size: 18),
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 40, height: 40),
        ),
      ],
    );
  }
}

void copyMermaid(BuildContext context, String source) {
  unawaited(Clipboard.setData(ClipboardData(text: source)));
  showToast(context, 'Copied', type: TuiToastType.success);
}

final _fence = RegExp(r'^ {0,3}(`{3,}|~{3,})(.*)$');

/// [markdown] with a fence still open at its end — a reply that has not
/// finished arriving — as plain code when it is a mermaid one, so a diagram
/// is drawn once its closing fence is there rather than tried at every chunk
/// of a source still being written.
String holdOpenMermaid(String markdown) {
  final lines = markdown.split('\n');
  String? open;
  var at = -1;
  for (var i = 0; i < lines.length; i++) {
    final m = _fence.firstMatch(lines[i]);
    if (m == null) continue;
    final mark = m[1]!;
    final info = m[2]!;
    if (open == null) {
      // A backtick in a backtick fence's info makes it no fence.
      if (mark.startsWith('`') && info.contains('`')) continue;
      open = mark;
      at = i;
    } else if (mark[0] == open[0] &&
        mark.length >= open.length &&
        info.trim().isEmpty) {
      open = null;
    }
  }
  if (open == null) return markdown;
  final m = _fence.firstMatch(lines[at])!;
  if (m[2]!.trim().split(RegExp(r'\s')).first != 'mermaid') return markdown;
  lines[at] = lines[at].substring(0, lines[at].length - m[2]!.length);
  return lines.join('\n');
}

/// The first word of every kind of diagram Mermaid 12 draws.
const _diagrams = {
  'graph',
  'flowchart',
  'sequenceDiagram',
  'classDiagram',
  'classDiagram-v2',
  'stateDiagram',
  'stateDiagram-v2',
  'erDiagram',
  'journey',
  'gantt',
  'pie',
  'quadrantChart',
  'requirementDiagram',
  'gitGraph',
  'C4Context',
  'C4Container',
  'C4Component',
  'C4Dynamic',
  'C4Deployment',
  'mindmap',
  'timeline',
  'zenuml',
  'sankey',
  'sankey-beta',
  'xychart',
  'xychart-beta',
  'block',
  'block-beta',
  'packet',
  'packet-beta',
  'kanban',
  'architecture',
  'architecture-beta',
  'radar-beta',
  'treemap',
  'treemap-beta',
};

/// The Mermaid source in a terminal selection, or null when it holds none:
/// a ```mermaid fence around it and the indent a program draws a code block
/// with are taken off, and what is left is Mermaid only when its first line,
/// past a front matter block and `%%` comments, names a kind of diagram.
String? mermaidSource(String selection) {
  var lines = [for (final line in selection.split('\n')) line.trimRight()];
  bool blank(String line) => line.trim().isEmpty;
  while (lines.isNotEmpty && blank(lines.first)) {
    lines.removeAt(0);
  }
  while (lines.isNotEmpty && blank(lines.last)) {
    lines.removeLast();
  }
  if (lines.isEmpty) return null;
  if (RegExp(r'^\s*(`{3,}|~{3,})\s*mermaid$').hasMatch(lines.first)) {
    lines.removeAt(0);
    if (lines.isNotEmpty &&
        RegExp(r'^\s*(`{3,}|~{3,})$').hasMatch(lines.last)) {
      lines.removeLast();
    }
  }
  final indent = lines
      .where((line) => !blank(line))
      .map((line) => line.length - line.trimLeft().length)
      .fold<int?>(null, (least, n) => least == null || n < least ? n : least);
  if (indent == null) return null;
  lines = [for (final line in lines) blank(line) ? '' : line.substring(indent)];

  var i = 0;
  if (lines.first == '---') {
    i = lines.indexOf('---', 1) + 1;
    if (i == 0) return null;
  }
  while (i < lines.length && (blank(lines[i]) || lines[i].startsWith('%%'))) {
    i++;
  }
  if (i == lines.length) return null;
  final word = lines[i].split(RegExp(r'[\s;]')).first;
  if (!_diagrams.contains(word)) return null;
  return '${lines.join('\n')}\n';
}

/// [source] drawn in a dialog of its own, with a button to copy it: what a
/// terminal selection's Show as diagram opens.
Future<void> showMermaidDialog(BuildContext context, String source) =>
    showDialog<void>(
      context: context,
      builder: (dialog) => TuiDialog(
        title: 'Diagram',
        maxWidth: 720,
        actions: [
          TuiButton(
            label: 'Close',
            variant: TuiButtonVariant.ghost,
            onPressed: () => Navigator.pop(dialog),
          ),
          TuiButton(
            label: 'Copy source',
            onPressed: () => copyMermaid(dialog, source),
          ),
        ],
        child: SingleChildScrollView(child: MermaidView(source: source)),
      ),
    );

/// One Mermaid diagram, drawn by Mermaid itself (assets/mermaid) in a web
/// view the diagram's height. A wide one scrolls sideways; one Mermaid can't
/// read shows what Mermaid said and the source.
///
/// The source comes from a file on someone's server, so the page is the
/// app's own asset and its Content-Security-Policy lets it load nothing else;
/// it navigates nowhere, runs Mermaid at its strict level, gets the source as
/// JSON, and can say one thing back: a height.
class MermaidView extends StatefulWidget {
  const MermaidView({super.key, required this.source});

  final String source;

  @override
  State<MermaidView> createState() => _MermaidViewState();
}

const _page = 'assets/mermaid/mermaid.html';

/// render.js draws a diagram taller than 4000 dp smaller to fit, and pads it
/// 12 dp above and below.
const _maxHeight = 4024.0;

class _MermaidViewState extends State<MermaidView> {
  /// The height each diagram came to, by its source and colours, so one
  /// scrolled back into view comes back at its size rather than growing under
  /// the reader's thumb.
  ///
  /// ponytail: kept for the app's life, a few hundred bytes a diagram read.
  static final _heights = <(String, String), double>{};

  final _view = WebViewController();
  bool _loaded = false;
  double? _height;

  /// The colours the page draws with, as JSON for render().
  String _options = '';

  @override
  void initState() {
    super.initState();
    unawaited(_view.setJavaScriptMode(JavaScriptMode.unrestricted));
    unawaited(
      _view.addJavaScriptChannel('Height', onMessageReceived: _onHeight),
    );
    unawaited(
      _view.setNavigationDelegate(
        NavigationDelegate(
          // Android asks only about the page's own moves, iOS about loading
          // the page too.
          onNavigationRequest: (request) {
            final url = Uri.tryParse(request.url);
            return url != null &&
                    url.scheme == 'file' &&
                    url.path.endsWith('/$_page')
                ? NavigationDecision.navigate
                : NavigationDecision.prevent;
          },
          onPageFinished: (_) {
            _loaded = true;
            _draw();
          },
        ),
      ),
    );
    unawaited(_view.loadFlutterAsset(_page));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // The preview's code block colour, which the diagram sits in.
    final background = scheme.surfaceContainerHighest;
    final options = jsonEncode({
      'dark': theme.brightness == Brightness.dark,
      'bg': _css(background),
      'fg': _css(scheme.onSurface),
      'error': _css(scheme.error),
    });
    if (options == _options) return;
    _options = options;
    _height = _heights[(widget.source, options)] ?? _height;
    unawaited(_view.setBackgroundColor(background));
    _draw();
  }

  static String _css(Color color) =>
      '#${(color.toARGB32() & 0xffffff).toRadixString(16).padLeft(6, '0')}';

  void _draw() {
    if (!_loaded) return;
    // As data: JSON is a JavaScript literal, so nothing in the source can
    // end the string it comes in.
    unawaited(
      _view.runJavaScript('render(${jsonEncode(widget.source)}, $_options)'),
    );
  }

  /// A number, and nothing else.
  void _onHeight(JavaScriptMessage message) {
    final height = double.tryParse(message.message);
    if (height == null || !height.isFinite || !mounted) return;
    final shown = height.clamp(1.0, _maxHeight);
    _heights[(widget.source, _options)] = shown;
    setState(() => _height = shown);
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: double.infinity,
    height: _height ?? 120,
    child: Stack(
      children: [
        WebViewWidget(
          controller: _view,
          // Sideways drags scroll a wide diagram; the rest scroll the preview.
          gestureRecognizers: {
            Factory<OneSequenceGestureRecognizer>(
              HorizontalDragGestureRecognizer.new,
            ),
          },
        ),
        // Until the page has drawn, or for good if it never can.
        if (_height == null)
          Center(
            child: Icon(
              Icons.account_tree_outlined,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
      ],
    ),
  );
}
