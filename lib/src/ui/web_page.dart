import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'terminal_page.dart' show openUrl;

/// A web page in a tab of its own, drawn by Android System WebView — Chrome's
/// engine — inside the app, where a Custom Tab would draw it over the app.
///
/// Owns the view and its bar and nothing else. Where the page has got to is
/// passed up through [onChanged], so the strip can name the tab after it, and
/// the tabs' [IndexedStack] keeps the page alive, scrolled where it was, while
/// another tab is showing.
class WebPage extends StatefulWidget {
  const WebPage({super.key, required this.initialUrl, required this.onChanged});

  /// Where the page opens. Where it goes after that is the page's own doing,
  /// so a new value here is not loaded.
  final Uri initialUrl;

  /// Where the page is now, and its title once it has one.
  final void Function(Uri url, String? title) onChanged;

  @override
  State<WebPage> createState() => _WebPageState();
}

/// What the view shows itself. Anything else a page opens goes to [openUrl],
/// which hands a `mailto:` or a `tel:` to the app for it and refuses the
/// rest — an `intent:`, or this app's own `sshbox:` — since a page can
/// navigate with no tap at all.
const _shownHere = {'http', 'https', 'about', 'data', 'blob'};

class _WebPageState extends State<WebPage> {
  final _view = WebViewController();
  final _address = TextEditingController();
  final _addressFocus = FocusNode();

  late Uri _url = widget.initialUrl;

  /// How far the page has loaded, 0 to 1, while it loads; null once it has.
  double? _progress;
  bool _canGoBack = false;
  bool _canGoForward = false;

  /// The address this tab last agreed to load, until a page finishes there.
  /// Android hands a download back as one more navigation to its address,
  /// and loading that again only downloads it again, round and round — so an
  /// address asked for twice before anything has loaded goes to the browser.
  ///
  /// ponytail: a page that redirects to its own address, or a link tapped
  /// twice before it loads, reads as a download too. A download handler of
  /// our own is the real fix.
  Uri? _asked;

  bool get _loading => _progress != null;

  @override
  void initState() {
    super.initState();
    _address.text = '$_url';
    _addressFocus.addListener(_onAddressFocus);
    unawaited(_view.setJavaScriptMode(JavaScriptMode.unrestricted));
    unawaited(
      _view.setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: _onNavigation,
          onPageStarted: (url) => _moved(Uri.tryParse(url) ?? _url, null),
          onProgress: (progress) {
            if (!mounted) return;
            setState(() => _progress = progress < 100 ? progress / 100 : null);
          },
          onPageFinished: (_) {
            _asked = null;
            if (!mounted) return;
            setState(() => _progress = null);
            unawaited(_readBack());
          },
          // A page that moves itself along — pushState, a hash — loads
          // nothing, so this is the only word of it. A page that is loading
          // is read back when it finishes, with its title rather than the
          // address the view stands in for one until then.
          onUrlChange: (_) {
            if (!_loading) unawaited(_readBack());
          },
        ),
      ),
    );
    _load(_url);
  }

  /// On the [Focus] that hands keys on to the view. It takes no focus itself;
  /// the platform view inside it does.
  final _viewFocus = FocusNode();

  /// Whether the tabs were showing this page when it last looked; null until
  /// its first look.
  bool? _shown;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Shown again after another tab, focus goes back into the page, as a
    // shell's goes back to its terminal, rather than to nothing, where Tab or
    // an arrow would move it onto the bar.
    //
    // ponytail: Flutter's focus only. Android gives the view its own focus on
    // a tap, and keys reach the page once it has that.
    final shown = Visibility.of(context);
    if (shown && _shown == false) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _viewFocus.descendants
            .where((node) => node.canRequestFocus)
            .firstOrNull
            ?.requestFocus();
      });
    }
    _shown = shown;
  }

  @override
  void dispose() {
    _address.dispose();
    _addressFocus.dispose();
    _viewFocus.dispose();
    super.dispose();
  }

  void _load(Uri url) {
    _url = url;
    _asked = url;
    unawaited(_view.loadRequest(url));
  }

  NavigationDecision _onNavigation(NavigationRequest request) {
    final url = Uri.tryParse(request.url);
    if (url == null) return NavigationDecision.prevent;
    if (_shownHere.contains(url.scheme) && url != _asked) {
      _asked = url;
      return NavigationDecision.navigate;
    }
    // Through the helper without a tab: a mailto: goes where the phone sends
    // it, and a download to the browser, which knows what to do with one.
    if (mounted) unawaited(openUrl(context, url));
    return NavigationDecision.prevent;
  }

  /// The page is somewhere new: the bar shows it, unless it is being typed
  /// over, and the tab is named after it.
  void _moved(Uri url, String? title) {
    if (!mounted) return;
    _url = url;
    if (!_addressFocus.hasFocus) _address.text = '$url';
    widget.onChanged(url, title);
  }

  /// Reads back where the view has got to — its history, address and title.
  Future<void> _readBack() async {
    final (back, forward, current, title) = await (
      _view.canGoBack(),
      _view.canGoForward(),
      _view.currentUrl(),
      _view.getTitle(),
    ).wait;
    if (!mounted) return;
    setState(() {
      _canGoBack = back;
      _canGoForward = forward;
    });
    _moved(current == null ? _url : Uri.tryParse(current) ?? _url, title);
  }

  /// ponytail: webview_flutter has no stop, so this is the page's own
  /// `window.stop()` — which is what a browser's stop button does, but a
  /// navigation still waiting on its first byte may carry on regardless.
  void _stop() {
    unawaited(_view.runJavaScript('window.stop()'));
    setState(() => _progress = null);
  }

  /// Loads what was typed in the address bar. An address without a scheme
  /// gets https, as a browser's bar gives it one.
  void _go(String typed) {
    final text = typed.trim();
    final url = Uri.tryParse(text.contains('://') ? text : 'https://$text');
    if (text.isEmpty || url == null) return;
    _load(url);
  }

  /// Editing starts with the whole address selected, ready to be typed over,
  /// and leaving without Go puts back where the page is.
  void _onAddressFocus() {
    if (_addressFocus.hasFocus) {
      _address.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _address.text.length,
      );
    } else {
      _address.text = '$_url';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    IconButton button(String tooltip, IconData icon, VoidCallback? onPressed) =>
        IconButton(
          tooltip: tooltip,
          onPressed: onPressed,
          visualDensity: VisualDensity.compact,
          iconSize: 20,
          icon: Icon(icon),
        );

    return Column(
      children: [
        Material(
          // The page's own colour, as a file tab's app bar wears, so the
          // selected tab runs straight on into it.
          color: theme.colorScheme.surface,
          child: SizedBox(
            height: 44,
            child: Row(
              children: [
                button(
                  'Back',
                  Icons.arrow_back,
                  _canGoBack ? _view.goBack : null,
                ),
                button(
                  'Forward',
                  Icons.arrow_forward,
                  _canGoForward ? _view.goForward : null,
                ),
                _loading
                    ? button('Stop', Icons.close, _stop)
                    : button('Reload', Icons.refresh, _view.reload),
                Expanded(
                  child: TextField(
                    controller: _address,
                    focusNode: _addressFocus,
                    keyboardType: TextInputType.url,
                    textInputAction: TextInputAction.go,
                    autocorrect: false,
                    enableSuggestions: false,
                    style: theme.textTheme.bodyMedium,
                    // The idle tabs' faint fill rather than a form field's
                    // outline: the address is read far more than typed.
                    decoration: InputDecoration(
                      isDense: true,
                      filled: true,
                      fillColor: theme.colorScheme.onSurface.withValues(
                        alpha: 0.08,
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    onSubmitted: _go,
                  ),
                ),
                button(
                  'Open in browser',
                  Icons.open_in_browser,
                  () => openUrl(context, _url),
                ),
              ],
            ),
          ),
        ),
        // A slot of its own rather than over the page, so starting and
        // finishing a load never resizes the view.
        SizedBox(
          height: 2,
          child: _loading ? LinearProgressIndicator(value: _progress) : null,
        ),
        Expanded(
          child: Focus(
            focusNode: _viewFocus,
            // Hardware keys go to the page. The platform view has no key
            // handling of its own, so without this the app's shortcuts take
            // Tab and the arrows to move Flutter's focus — off the page and
            // onto the bar — before a form or a scrolling page ever sees them.
            canRequestFocus: false,
            skipTraversal: true,
            onKeyEvent: (_, _) => KeyEventResult.skipRemainingHandlers,
            child: WebViewWidget(controller: _view),
          ),
        ),
      ],
    );
  }
}
