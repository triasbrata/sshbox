import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/telemetry/app_log.dart';
import 'package:sshbox/src/ui/pan_zoom_heal.dart';

const _ms = Duration(milliseconds: 1);

PointerPanZoomStartEvent start(
  int pointer,
  int at, {
  Offset position = Offset.zero,
}) => PointerPanZoomStartEvent(
  pointer: pointer,
  device: 1,
  timeStamp: _ms * at,
  position: position,
);

PointerPanZoomUpdateEvent update(
  int pointer,
  int at, {
  required Offset pan,
  required Offset delta,
  double scale = 1,
  double rotation = 0,
  Offset position = Offset.zero,
}) => PointerPanZoomUpdateEvent(
  pointer: pointer,
  device: 1,
  timeStamp: _ms * at,
  position: position,
  pan: pan,
  panDelta: delta,
  scale: scale,
  rotation: rotation,
);

PointerPanZoomEndEvent end(int pointer, int at) =>
    PointerPanZoomEndEvent(pointer: pointer, device: 1, timeStamp: _ms * at);

String shape(List<PointerEvent> events) => events
    .map(
      (e) => switch (e) {
        PointerPanZoomStartEvent() => 'start ${e.pointer}',
        PointerPanZoomUpdateEvent() =>
          'update ${e.pointer} ${e.pan.dy} ${e.panDelta.dy} ${e.scale} '
              '${e.rotation}',
        PointerPanZoomEndEvent() => 'end ${e.pointer}',
        _ => e.runtimeType.toString(),
      },
    )
    .join(', ');

void main() {
  test('a whole scroll goes through as it came', () {
    final heal = PanZoomHeal();
    final out = [
      for (final e in [
        start(1, 0),
        update(1, 16, pan: const Offset(0, 4), delta: const Offset(0, 4)),
        // A pause shorter than the gap, the fingers resting.
        update(1, 250, pan: const Offset(0, 9), delta: const Offset(0, 5)),
        end(1, 260),
      ])
        ...heal.convert(e),
    ];
    expect(
      shape(out),
      'start 1, update 1 4.0 4.0 1.0 0.0, '
      'update 1 9.0 5.0 1.0 0.0, end 1',
    );
  });

  test('anything but a trackpad scroll goes through untouched', () {
    final heal = PanZoomHeal();
    const down = PointerDownEvent(pointer: 3, device: 1);
    expect(heal.convert(down), [same(down)]);
    // An update or an end for a scroll it never saw start.
    final stray = update(4, 0, pan: Offset.zero, delta: Offset.zero);
    expect(heal.convert(stray), [same(stray)]);
    expect(heal.convert(end(4, 1)), isEmpty);
  });

  test('a scroll still open when the next one starts is ended first', () {
    final heal = PanZoomHeal();
    heal.convert(start(1, 0));
    heal.convert(
      update(1, 16, pan: const Offset(0, 4), delta: const Offset(0, 4)),
    );
    expect(shape(heal.convert(start(2, 5000))), 'end 1, start 2');
    // The old one's own end, if it ever comes, has nothing left to end.
    expect(heal.convert(end(1, 5001)), isEmpty);
    expect(shape(heal.convert(end(2, 5002))), 'end 2');
  });

  test('updates coming back after the gap with no end are a new scroll, '
      'counted from where they resume', () {
    final log = appLog.length;
    final heal = PanZoomHeal();
    heal.convert(start(1, 0));
    heal.convert(
      update(1, 16, pan: const Offset(0, 40), delta: const Offset(0, 40)),
    );
    // macOS dropped the end: the next scroll is more of the same pointer.
    final out = heal.convert(
      update(
        1,
        3000,
        pan: const Offset(0, 46),
        delta: const Offset(0, 6),
        scale: 2,
        rotation: 0.5,
        position: const Offset(30, 40),
      ),
    );
    expect(shape(out), 'end 1, start 1, update 1 6.0 6.0 1.0 0.0');
    expect(out[1].position, const Offset(30, 40));
    expect(out.take(2).every((e) => e.synthesized), isTrue);
    expect(
      shape(
        heal.convert(
          update(
            1,
            3016,
            pan: const Offset(0, 50),
            delta: const Offset(0, 4),
            scale: 3,
            rotation: 0.75,
          ),
        ),
      ),
      'update 1 10.0 4.0 1.5 0.25',
    );
    expect(appLog.length, log + 1);
    expect(
      appLog.current,
      endsWith('trackpad: a scroll with no end was ended'),
    );
  });
}
