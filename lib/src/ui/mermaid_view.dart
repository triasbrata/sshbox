import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:webview_flutter/webview_flutter.dart';

import '../platform.dart';

/// Draws a Markdown file's ```mermaid blocks as diagrams, as the builder for
/// `code` in [Markdown.builders]. Any other code, block or inline, is left to
/// the package — and so is a mermaid block where there is no web view to draw
/// it in, Linux and Windows, which show its source as code.
class MermaidBuilder extends MarkdownElementBuilder {
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
    return MermaidView(key: ValueKey(source), source: source);
  }
}

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
