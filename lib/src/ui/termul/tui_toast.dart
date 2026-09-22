// Ported from TUI-Termul/termul at 27d94c6fc16502efd103ba217f9e0b52bb164dc5,
// lib/components/tui_toast.dart. MIT License, Copyright (c) 2026 TUI-Termul: see
// LICENSE beside this file.
//
// As upstream.

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'termul_theme.dart';

/// What a toast is about. Shown as a glyph — never as a colour wash.
enum TuiToastType { info, success, warning, error }

extension TuiToastTypeX on TuiToastType {
  /// Mono mark inside the type square.
  String get glyph => switch (this) {
    TuiToastType.info => 'i',
    TuiToastType.success => '+',
    TuiToastType.warning => '!',
    TuiToastType.error => 'x',
  };

  String get semanticsLabel => name;
}

/// Optional button on a toast (Settings, Open, Copy, Retry, …).
class TuiToastAction {
  const TuiToastAction({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;
}

/// Default lifetime for info / success / warning.
const tuiToastDuration = Duration(seconds: 3);

/// Default lifetime for errors — time to read and reach an action.
const tuiToastErrorDuration = Duration(seconds: 5);

/// Max stacked toasts; a fourth drops the oldest.
const tuiToastMaxStack = 3;

/// Shows a Termul toast above every page. Requires a [TuiToastHost] ancestor
/// (wire via `MaterialApp.builder`).
///
/// [title] is the primary line. [body] is an optional second line in muted
/// type. Passing the same title+body while one is still up is a no-op.
void showTuiToast(
  BuildContext context, {
  required String title,
  String? body,
  TuiToastType type = TuiToastType.info,
  TuiToastAction? action,
  Duration? duration,
}) {
  TuiToastController.read(context).show(
    title: title,
    body: body,
    type: type,
    action: action,
    duration:
        duration ??
        (type == TuiToastType.error ? tuiToastErrorDuration : tuiToastDuration),
  );
}

/// Owns the toast stack and paints it above [child] without eating taps beside
/// the cards (only the cards themselves hit-test).
class TuiToastHost extends StatefulWidget {
  const TuiToastHost({super.key, required this.child});

  final Widget child;

  @override
  State<TuiToastHost> createState() => _TuiToastHostState();
}

class _TuiToastHostState extends State<TuiToastHost> {
  late final TuiToastController _controller = TuiToastController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _TuiToastScope(
      controller: _controller,
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.child,
          // Align expands, but only the column's box receives hits — taps
          // beside / between cards go through to [child].
          ListenableBuilder(
            listenable: _controller,
            builder: (context, _) {
              if (_controller._entries.isEmpty) {
                return const SizedBox.shrink();
              }
              final maxW = MediaQuery.sizeOf(context).width * 0.8;
              return SafeArea(
                child: Align(
                  alignment: Alignment.topCenter,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: maxW),
                      child: SizedBox(
                        width: maxW,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (final entry in _controller._entries) ...[
                              _ToastListItem(
                                key: ValueKey(entry.id),
                                entry: entry,
                                onDismiss: () => _controller.dismiss(entry.id),
                              ),
                              const SizedBox(height: 8),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

/// Imperative API for the toast stack.
class TuiToastController extends ChangeNotifier {
  final List<_ToastEntry> _entries = [];

  static TuiToastController of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<_TuiToastScope>();
    assert(
      scope != null,
      'showTuiToast requires a TuiToastHost ancestor '
      '(wrap MaterialApp.builder with TuiToastHost).',
    );
    return scope!.controller;
  }

  /// Like [of], but does not register a dependency — for one-shot show calls.
  static TuiToastController read(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<_TuiToastScope>();
    assert(scope != null, 'showTuiToast requires a TuiToastHost ancestor.');
    return scope!.controller;
  }

  void show({
    required String title,
    String? body,
    TuiToastType type = TuiToastType.info,
    TuiToastAction? action,
    required Duration duration,
  }) {
    final key = '$title\n${body ?? ''}';
    if (_entries.any((e) => e.dedupeKey == key)) return;

    final entry = _ToastEntry(
      id: 'toast-${DateTime.now().microsecondsSinceEpoch}-$_seq',
      dedupeKey: key,
      title: title,
      body: body,
      type: type,
      action: action,
      duration: duration,
    );
    _seq++;
    _entries.insert(0, entry);
    while (_entries.length > tuiToastMaxStack) {
      _entries.removeLast();
    }
    notifyListeners();
  }

  void dismiss(String id) {
    final before = _entries.length;
    _entries.removeWhere((e) => e.id == id);
    if (_entries.length != before) notifyListeners();
  }

  void dismissAll() {
    if (_entries.isEmpty) return;
    _entries.clear();
    notifyListeners();
  }

  int _seq = 0;
}

class _TuiToastScope extends InheritedWidget {
  const _TuiToastScope({required this.controller, required super.child});

  final TuiToastController controller;

  @override
  bool updateShouldNotify(_TuiToastScope oldWidget) =>
      controller != oldWidget.controller;
}

class _ToastEntry {
  _ToastEntry({
    required this.id,
    required this.dedupeKey,
    required this.title,
    required this.body,
    required this.type,
    required this.action,
    required this.duration,
  });

  final String id;
  final String dedupeKey;
  final String title;
  final String? body;
  final TuiToastType type;
  final TuiToastAction? action;
  final Duration duration;
}

class _ToastListItem extends StatelessWidget {
  const _ToastListItem({
    super.key,
    required this.entry,
    required this.onDismiss,
  });

  final _ToastEntry entry;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return TuiToastCard(
      title: entry.title,
      body: entry.body,
      type: entry.type,
      action: entry.action,
      duration: entry.duration,
      onDismiss: onDismiss,
    );
  }
}

/// Visual toast card — public for gallery / tests.
///
/// Type is a glyph square in the same ink as the copy. A thin countdown bar
/// runs along the bottom. Hover or press pauses the timer; horizontal swipe
/// or the × closes early. An optional action closes then fires.
class TuiToastCard extends StatefulWidget {
  const TuiToastCard({
    super.key,
    required this.title,
    this.body,
    this.type = TuiToastType.info,
    this.action,
    this.duration = tuiToastDuration,
    this.onDismiss,
    this.progress,
  });

  final String title;
  final String? body;
  final TuiToastType type;
  final TuiToastAction? action;
  final Duration duration;
  final VoidCallback? onDismiss;

  /// When set (0–1 remaining), drives the bar without an internal timer —
  /// used by tests. Leave null for live countdown.
  final double? progress;

  @override
  State<TuiToastCard> createState() => _TuiToastCardState();
}

class _TuiToastCardState extends State<TuiToastCard>
    with SingleTickerProviderStateMixin {
  AnimationController? _timer;
  double _dragDx = 0;
  bool _dismissing = false;

  bool get _externalProgress => widget.progress != null;

  @override
  void initState() {
    super.initState();
    if (!_externalProgress) {
      _timer = AnimationController(vsync: this, duration: widget.duration)
        ..addStatusListener((status) {
          if (status == AnimationStatus.completed) _close();
        })
        ..forward();
    }
  }

  @override
  void didUpdateWidget(covariant TuiToastCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.duration != widget.duration && _timer != null) {
      final value = _timer!.value;
      _timer!.duration = widget.duration;
      _timer!.value = value;
    }
  }

  @override
  void dispose() {
    _timer?.dispose();
    super.dispose();
  }

  void _pause() => _timer?.stop();

  void _resume() {
    if (_timer == null || _timer!.isCompleted || _dismissing) return;
    _timer!.forward();
  }

  void _close() {
    if (_dismissing) return;
    _dismissing = true;
    widget.onDismiss?.call();
  }

  void _onAction() {
    final action = widget.action;
    _close();
    // Fire after scheduling dismiss so the stack can drop this frame first.
    if (action != null) {
      SchedulerBinding.instance.addPostFrameCallback((_) => action.onPressed());
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    final theme = Theme.of(context);

    Widget card = Material(
      color: p.panel,
      elevation: 0,
      shape: RoundedRectangleBorder(side: BorderSide(color: p.border)),
      child: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 4, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _TypeMark(type: widget.type),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        widget.title,
                        style: theme.textTheme.bodyMedium!.copyWith(
                          color: p.text,
                          fontWeight: FontWeight.w500,
                          height: 1.35,
                        ),
                      ),
                      if (widget.body != null && widget.body!.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          widget.body!,
                          style: theme.textTheme.bodySmall!.copyWith(
                            color: p.muted,
                            height: 1.4,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (widget.action != null)
                  _ToastTextButton(
                    label: widget.action!.label,
                    onPressed: _onAction,
                  ),
                _ToastIconButton(
                  tooltip: 'Close',
                  onPressed: _close,
                  child: Text(
                    '×',
                    style: TextStyle(
                      fontFamily: TermulFonts.mono,
                      fontSize: 16,
                      height: 1,
                      color: p.dim,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: AnimatedBuilder(
              animation: Listenable.merge([?_timer]),
              builder: (context, _) {
                final left = widget.progress ?? (1.0 - (_timer?.value ?? 0.0));
                return Align(
                  alignment: Alignment.centerLeft,
                  child: FractionallySizedBox(
                    widthFactor: left.clamp(0.0, 1.0),
                    child: Container(
                      height: 2,
                      color: p.text.withValues(alpha: 0.28),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );

    card = MouseRegion(
      onEnter: (_) => _pause(),
      onExit: (_) => _resume(),
      child: Listener(
        onPointerDown: (_) => _pause(),
        onPointerUp: (_) => _resume(),
        onPointerCancel: (_) => _resume(),
        child: card,
      ),
    );

    return Semantics(
      liveRegion: true,
      label:
          '${widget.type.semanticsLabel}: ${widget.title}'
          '${widget.body != null ? '. ${widget.body}' : ''}',
      child: GestureDetector(
        onHorizontalDragUpdate: (d) {
          setState(() => _dragDx += d.delta.dx);
        },
        onHorizontalDragEnd: (d) {
          final shouldClose =
              _dragDx.abs() > 64 || (d.primaryVelocity?.abs() ?? 0) > 800;
          if (shouldClose) {
            _close();
          } else {
            setState(() => _dragDx = 0);
          }
        },
        onHorizontalDragCancel: () => setState(() => _dragDx = 0),
        child: Opacity(
          opacity: (1.0 - (_dragDx.abs() / 160)).clamp(0.35, 1.0),
          child: Transform.translate(offset: Offset(_dragDx, 0), child: card),
        ),
      ),
    );
  }
}

class _TypeMark extends StatelessWidget {
  const _TypeMark({required this.type});

  final TuiToastType type;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    return Semantics(
      label: type.semanticsLabel,
      excludeSemantics: true,
      child: Container(
        width: 22,
        height: 22,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          border: Border.all(color: p.border),
          color: p.surface,
        ),
        child: Text(
          type.glyph,
          style: TextStyle(
            fontFamily: TermulFonts.mono,
            fontSize: 11,
            fontWeight: FontWeight.w500,
            height: 1,
            color: p.text,
          ),
        ),
      ),
    );
  }
}

class _ToastTextButton extends StatelessWidget {
  const _ToastTextButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    return InkWell(
      onTap: onPressed,
      hoverColor: p.selection,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Text(
          label.toUpperCase(),
          style: TextStyle(
            fontFamily: TermulFonts.mono,
            fontSize: 11,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.4,
            color: p.accent,
            height: 1.2,
          ),
        ),
      ),
    );
  }
}

class _ToastIconButton extends StatelessWidget {
  const _ToastIconButton({
    required this.onPressed,
    required this.child,
    this.tooltip,
  });

  final VoidCallback onPressed;
  final Widget child;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    // No Tooltip: toast host sits in MaterialApp.builder, above the
    // navigator Overlay Tooltips need.
    return Semantics(
      button: true,
      label: tooltip ?? 'Close',
      child: InkWell(
        onTap: onPressed,
        hoverColor: p.selection,
        child: SizedBox(width: 36, height: 36, child: Center(child: child)),
      ),
    );
  }
}
