import 'dart:async';
import 'dart:convert' show HtmlEscape;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show KeyDownEvent, LogicalKeyboardKey;
import 'package:webview_flutter/webview_flutter.dart';

import '../files/html_site.dart';
import 'terminal_page.dart' show openUrl;
import 'tui.dart';

/// A web page in a tab of its own, drawn by Android System WebView — Chrome's
/// engine — inside the app, where a Custom Tab would draw it over the app.
///
/// Owns the view and its bar and nothing else. Where the page has got to is
/// passed up through [onChanged], so the strip can name the tab after it, and
/// the tabs' [IndexedStack] keeps the page alive, scrolled where it was, while
/// another tab is showing.
class WebPage extends StatefulWidget {
  const WebPage({
    super.key,
    required this.initialUrl,
    required this.onChanged,
    this.site,
  });

  /// Starts the site of an HTML file on the host, for a tab that shows a file
  /// rather than a link; the tab closes it with the page, and Reload loads
  /// the page again from the host. The page's origin is the site's loopback
  /// address, which reaches only the files beside it; every other way out of
  /// it goes to [openUrl].
  final Future<HtmlSite> Function()? site;

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

/// How long after a touch a page may still send the user to another app.
const webGestureWindow = Duration(seconds: 1);

/// How long a page may go without a word from the view before the tab says it
/// is not loading.
const webLoadTimeout = Duration(seconds: 30);

/// The time a gesture is stamped and judged by; a test replaces it.
@visibleForTesting
DateTime Function() webGestureClock = DateTime.now;

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
            if (progress < 100) {
              _armStall();
            } else {
              _stall?.cancel();
            }
            setState(() => _progress = progress < 100 ? progress / 100 : null);
          },
          onPageFinished: (_) {
            _asked = null;
            _stall?.cancel();
            if (!mounted) return;
            setState(() => _progress = null);
            unawaited(_readBack());
          },
          // Only the page itself: a picture that fails is the site's line.
          onWebResourceError: (error) {
            if (error.isForMainFrame != true) return;
            _fail(error.description);
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
    if (widget.site == null) {
      _load(_url);
    } else {
      _address.text = '';
      unawaited(_loadSite());
    }
  }

  /// Why the page did not load, in words, until the next load starts.
  String? _loadError;

  Timer? _stall;

  /// Starts the clock on a load that must show some progress, or finish,
  /// within [webLoadTimeout]; each word from the view starts it again.
  void _armStall() {
    _stall?.cancel();
    _stall = Timer(webLoadTimeout, () {
      if (!mounted) return;
      unawaited(_view.runJavaScript('window.stop()'));
      _fail('no answer in ${webLoadTimeout.inSeconds} s');
    });
  }

  /// The page is not coming: said on screen rather than a bar that never
  /// ends.
  void _fail(String reason) {
    _stall?.cancel();
    if (!mounted) return;
    setState(() {
      _progress = null;
      _loadError = reason;
    });
  }

  HtmlSite? _site;
  bool _closed = false;

  /// The site on its way, while it starts; a Reload then waits for it rather
  /// than starting a second one.
  Future<HtmlSite>? _starting;

  /// Starts the site on the first call, forgets what it served on the next
  /// ones, and loads the page from it.
  Future<void> _loadSite() async {
    try {
      var site = _site;
      if (site == null) {
        if (_starting != null) return;
        final starting = _starting = widget.site!();
        try {
          site = await starting;
        } finally {
          _starting = null;
        }
        if (_closed) {
          unawaited(site.close());
          return;
        }
        _site = site;
        site.problems.addListener(_problemsChanged);
      } else {
        site.reset();
      }
      if (mounted) {
        _url = site.url;
        // Not noted in [_asked]: WKWebView, unlike Android's view, asks the
        // delegate about this very request, and holding it back there leaves
        // the page loading for ever.
        setState(() => _loadError = null);
        unawaited(_view.loadRequest(site.url));
        _armStall();
      }
    } catch (error) {
      final why = const HtmlEscape().convert('Could not open the file: $error');
      if (mounted) unawaited(_view.loadHtmlString('<p>$why</p>'));
    }
  }

  void _problemsChanged() {
    if (mounted) setState(() {});
  }

  /// Whether [url] is one of the site's own pages: its loopback origin, under
  /// its token. Anything else the page opens leaves through [openUrl].
  bool _isSite(Uri url) {
    final site = _site;
    return site != null &&
        url.isScheme('http') &&
        url.host == '127.0.0.1' &&
        url.port == site.url.port &&
        url.pathSegments.firstOrNull == site.token;
  }

  /// One line for what the page asked for and did not get.
  String _problemLine(Map<String, String> problems) {
    final token = _site?.token;
    final names = [
      for (final MapEntry(:key, :value) in problems.entries.take(3))
        '${key.startsWith('/$token/') ? key.substring(token!.length + 2) : key}'
            ' ($value)',
    ];
    final more = problems.length > 3 ? ' and ${problems.length - 3} more' : '';
    final count = problems.length;
    return '${count == 1 ? '1 file' : '$count files'} not loaded: '
        '${names.join(', ')}$more';
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
    _closed = true;
    _stall?.cancel();
    _site?.problems.removeListener(_problemsChanged);
    unawaited(_site?.close());
    _address.dispose();
    _addressFocus.dispose();
    _viewFocus.dispose();
    super.dispose();
  }

  /// Reload for a link: the view loads it again, and a failure shown is
  /// forgotten.
  void _reload() {
    setState(() => _loadError = null);
    unawaited(_view.reload());
    _armStall();
  }

  void _load(Uri url) {
    _url = url;
    _asked = url;
    _loadError = null;
    unawaited(_view.loadRequest(url));
    _armStall();
  }

  NavigationDecision _onNavigation(NavigationRequest request) {
    final url = Uri.tryParse(request.url);
    if (url == null) return NavigationDecision.prevent;
    // A file's tab is the file alone: its own site and its own #anchors.
    // Any other address, a web one included, leaves through openUrl.
    final stays = widget.site == null
        ? _shownHere.contains(url.scheme)
        : url.scheme == 'about' ||
              url.scheme == 'data' ||
              _isSite(url) ||
              // A frame inside the page, such as an embedded player, loads
              // as any sub-resource does; only the page itself is held.
              (!request.isMainFrame && _shownHere.contains(url.scheme));
    if (stays && url != _asked) {
      _asked = url;
      return NavigationDecision.navigate;
    }
    // A page can navigate with no touch at all — a meta refresh, a timer —
    // and would otherwise open the browser, the mail app or the dialer in a
    // loop. So a page leaves through the helper only just after the user
    // touched it, or pressed Enter or Space on it.
    final touched = _lastGesture;
    if (touched == null ||
        webGestureClock().difference(touched) > webGestureWindow) {
      return NavigationDecision.prevent;
    }
    // Through the helper without a tab: a mailto: goes where the phone sends
    // it, and a download to the browser, which knows what to do with one.
    if (mounted) unawaited(openUrl(context, url));
    return NavigationDecision.prevent;
  }

  /// When the user last lifted a finger or pointer from the page, or pressed
  /// Enter or Space on it.
  DateTime? _lastGesture;

  void _gesture() => _lastGesture = webGestureClock();

  /// The page is somewhere new: the bar shows it, unless it is being typed
  /// over, and the tab is named after it.
  void _moved(Uri url, String? title) {
    if (!mounted) return;
    _url = url;
    if (widget.site == null && !_addressFocus.hasFocus) {
      _address.text = '$url';
    }
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
      _address.text = widget.site == null ? '$_url' : '';
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
                    : button(
                        'Reload',
                        Icons.refresh,
                        widget.site == null ? _reload : _loadSite,
                      ),
                Expanded(
                  child: TextField(
                    controller: _address,
                    focusNode: _addressFocus,
                    readOnly: widget.site != null,
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
                        borderRadius: BorderRadius.zero,
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
          child: _loading ? TuiProgressBar(value: _progress) : null,
        ),
        if (_loadError case final why?)
          TuiBox(
            expanded: false,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Text(
              'Could not load the page: $why',
              style: theme.textTheme.bodySmall,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        // What the page asked for and did not get — a missing file, one over
        // the limit, a link out of the folder — said here rather than left
        // as a bare space where a picture was meant to be.
        if (_site case final site? when site.problems.value.isNotEmpty)
          TuiBox(
            expanded: false,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Text(
              _problemLine(site.problems.value),
              style: theme.textTheme.bodySmall,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
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
            onKeyEvent: (_, event) {
              if (event is KeyDownEvent &&
                  (event.logicalKey == LogicalKeyboardKey.enter ||
                      event.logicalKey == LogicalKeyboardKey.space)) {
                _gesture();
              }
              return KeyEventResult.skipRemainingHandlers;
            },
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerUp: (_) => _gesture(),
              child: WebViewWidget(controller: _view),
            ),
          ),
        ),
      ],
    );
  }
}
