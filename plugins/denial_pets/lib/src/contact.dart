/// Where a held pet's contact shadow shows: near the edge or corner it holds
/// on by, fading out within [contactReach] of it, so only what touches the
/// window casts, such as a sitting pet's skirt and thighs, and what reaches
/// further, such as its feet, casts nothing. Plain Dart, so it is tested
/// without an engine; `contact_shadow.dart` draws it.
///
/// Its sizes are shares of the pet's drawn height, so a pet casts the same
/// shadow at any size.
library;

/// How far from its hold a pet's shadow reaches: a tenth of its height.
const contactReach = 0.1;

/// How far below the pet its shadow falls.
const contactDrop = 0.01;

/// How soft its shadow is: a blur's sigma.
const contactSoftness = 0.01;

const _top = 1;
const _bottom = 2;
const _left = 4;
const _right = 8;

typedef ContactPoint = ({double x, double y});

/// How the shadow fades, in the pet's drawn rectangle.
sealed class ContactFade {
  const ContactFade();
}

/// Across an edge: along the line from [from] to [to], at right angles to the
/// edge. The shadow is full where the line crosses the edge, halfway, and
/// gone at both ends.
final class AcrossEdge extends ContactFade {
  const AcrossEdge(this.from, this.to);

  final ContactPoint from;
  final ContactPoint to;
}

/// Around a corner: full at [center] and gone [radius] from it.
final class AroundCorner extends ContactFade {
  const AroundCorner(this.center, this.radius);

  final ContactPoint center;
  final double radius;
}

/// How the shadow of a pet held by [hold], a protocol hold value, at its
/// [anchor] fades out within [reach]; null for a value that is no hold.
ContactFade? contactFade({
  required int hold,
  required ContactPoint anchor,
  required double reach,
}) {
  final (:x, :y) = anchor;
  return switch (hold) {
    _top || _bottom => AcrossEdge((x: x, y: y - reach), (x: x, y: y + reach)),
    _left || _right => AcrossEdge((x: x - reach, y: y), (x: x + reach, y: y)),
    16 || 32 || 64 || 128 => AroundCorner(anchor, reach),
    _ => null,
  };
}
