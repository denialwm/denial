import 'package:denial_pets/src/perch.dart';
import 'package:test/test.dart';

PerchBox box(double x, double y, double w, double h) =>
    (left: x, top: y, right: x + w, bottom: y + h);

PerchPoint point(double x, double y) => (x: x, y: y);

/// A window whose input region is its frame without the 1 px border.
PerchTarget window(int id, PerchBox frame) => (
  rect: (
    left: frame.left + 1,
    top: frame.top + 1,
    right: frame.right - 1,
    bottom: frame.bottom - 1,
  ),
  window: id,
  frame: frame,
);

final screens = [box(0, 0, 2560, 1440)];

const top = 1;
const bottom = 2;
const left = 4;
const topLeft = 16;
const edges = top | bottom;
const every = 0xff;

Perch? at(PerchPoint anchor, List<PerchTarget> targets, {int holds = edges}) =>
    perch(anchor: anchor, holds: holds, targets: targets, screens: screens);

void main() {
  test('holds are on the frame', () {
    final frame = box(100, 200, 400, 300);
    expect(perchPoint(frame, top, 0.25), point(200, 200));
    expect(perchPoint(frame, bottom, 0.5), point(300, 500));
    expect(perchPoint(frame, left, 0.5), point(100, 350));
    expect(perchPoint(frame, 8, 1.0), point(500, 500));
    expect(perchPoint(frame, 128, 0.3), point(500, 500));
  });

  test('a pet snaps to an edge within reach and keeps its place along it', () {
    final targets = [window(7, box(100, 200, 400, 300))];
    expect(at(point(200, 190), targets), (window: 7, hold: top, share: 0.25));
    // Just inside the window, near its bottom edge.
    expect(at(point(300, 495), targets)?.hold, bottom);
    // Too far, beside the edge's ends, or far from both edges.
    expect(at(point(200, 180), targets), isNull);
    expect(at(point(90, 200), targets), isNull);
    expect(at(point(105, 350), targets), isNull);
    // A hold the pet does not accept.
    expect(at(point(200, 190), targets, holds: bottom), isNull);
  });

  test('a corner within reach wins over its edges', () {
    final targets = [window(7, box(100, 200, 400, 300))];
    expect(at(point(104, 196), targets, holds: every), (
      window: 7,
      hold: topLeft,
      share: 0.0,
    ));
    expect(at(point(104, 196), targets)?.hold, top);
  });

  test('only what the user sees holds a pet', () {
    final behind = window(7, box(100, 200, 400, 300));
    // A window in front covers the back one's top edge where the pet is.
    final front = window(8, box(150, 100, 200, 200));
    expect(at(point(200, 195), [front, behind]), isNull);
    // Beside the front window the back one's edge shows.
    expect(at(point(400, 195), [front, behind])?.window, 7);
    // A panel without holds of its own covers too.
    final PerchTarget panel = (
      rect: box(0, 180, 2560, 40),
      window: null,
      frame: null,
    );
    expect(at(point(400, 195), [panel, behind]), isNull);
    // An edge off every screen does not hold.
    final below = window(9, box(100, 1440, 400, 300));
    expect(at(point(200, 1435), [below]), isNull);
  });

  test('the frontmost window with a hold in reach takes the pet', () {
    final low = window(7, box(100, 200, 400, 300));
    // Its bottom edge meets the low one's top edge: the front one wins.
    final high = window(8, box(100, 0, 400, 205));
    final found = at(point(200, 204), [high, low]);
    expect((found?.window, found?.hold), (8, bottom));
  });
}
