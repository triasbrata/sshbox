import 'package:flutter/gestures.dart';

import '../telemetry/app_log.dart';

/// A trackpad's scroll, made to end before the next one begins.
///
/// A Mac hands Flutter a two-finger scroll as a pan: a start, its updates and
/// an end. Flutter's macOS engine drops that end, and the next start with it,
/// while it believes a pinch or a rotation is still under way
/// (FlutterViewController's dispatchMouseEvent:phase:), and a pinch whose own
/// end never came leaves it believing so for good. Every later scroll then
/// reaches the app as more updates of the first one: one pan that never ends.
///
/// A Scrollable's drag recogniser holds that pan for ever. Once anything
/// stops the drag it drove — a touch on the trackpad while a scroll still
/// glides, a mouse wheel — the recogniser stays won by the pan and starts no
/// other, so nothing a trackpad does scrolls it again. Under a program that
/// reads the mouse, as Claude Code does, that is the wheel the program never
/// hears while PageUp and PageDown still work (Sentry JEANSH-G).
///
/// So a pan still open when a new one starts is ended first, and updates
/// that come back after [gap] with no end between are a new pan: the old one
/// is ended and a new one started where the pointer is, its pan, scale and
/// rotation counted from there.
class PanZoomHeal {
  PanZoomHeal({this.gap = const Duration(milliseconds: 300)});

  /// Longer than a hand's pause inside one scroll, where a Mac sends nothing
  /// while the fingers rest: splitting there costs only a glide.
  final Duration gap;

  final _open =
      <
        int,
        ({
          int pointer,
          Duration last,
          Offset position,
          Offset pan,
          double scale,
          double rotation,
        })
      >{};

  List<PointerEvent> convert(PointerEvent event) {
    final device = event.device;
    final open = _open[device];
    switch (event) {
      case PointerPanZoomStartEvent():
        final out = <PointerEvent>[];
        if (open != null && open.pointer != event.pointer) {
          out.add(_end(event, open.pointer, open.position));
        }
        _open[device] = (
          pointer: event.pointer,
          last: event.timeStamp,
          position: event.position,
          pan: Offset.zero,
          scale: 1,
          rotation: 0,
        );
        return out..add(event);
      case PointerPanZoomUpdateEvent():
        if (open == null || open.pointer != event.pointer) return [event];
        final out = <PointerEvent>[];
        var base = (pan: open.pan, scale: open.scale, rotation: open.rotation);
        if (event.timeStamp - open.last > gap) {
          appLog.add('trackpad: a scroll with no end was ended');
          out
            ..add(_end(event, open.pointer, open.position))
            ..add(
              PointerPanZoomStartEvent(
                viewId: event.viewId,
                timeStamp: event.timeStamp,
                device: device,
                pointer: event.pointer,
                position: event.position,
                synthesized: true,
              ),
            );
          // The pan from before this update is the new one's zero. A pinch's
          // scale and rotation have no delta to tell this update's own part
          // apart, so the new one counts from this update's.
          base = (
            pan: event.pan - event.panDelta,
            scale: event.scale,
            rotation: event.rotation,
          );
        }
        _open[device] = (
          pointer: event.pointer,
          last: event.timeStamp,
          position: event.position,
          pan: base.pan,
          scale: base.scale,
          rotation: base.rotation,
        );
        final rebased =
            base.pan == Offset.zero && base.scale == 1 && base.rotation == 0
            ? event
            : PointerPanZoomUpdateEvent(
                viewId: event.viewId,
                timeStamp: event.timeStamp,
                device: device,
                pointer: event.pointer,
                position: event.position,
                embedderId: event.embedderId,
                pan: event.pan - base.pan,
                panDelta: event.panDelta,
                scale: event.scale / base.scale,
                rotation: event.rotation - base.rotation,
                synthesized: event.synthesized,
              );
        return out..add(rebased);
      case PointerPanZoomEndEvent():
        // An end for a pan already ended here goes nowhere.
        if (open == null || open.pointer != event.pointer) return const [];
        _open.remove(device);
        return [event];
      default:
        return [event];
    }
  }

  static PointerPanZoomEndEvent _end(
    PointerEvent event,
    int pointer,
    Offset position,
  ) => PointerPanZoomEndEvent(
    viewId: event.viewId,
    timeStamp: event.timeStamp,
    device: event.device,
    pointer: pointer,
    position: position,
    synthesized: true,
  );
}
