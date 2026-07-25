import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

const denialWordmarkAsset = 'assets/branding/denial-dark.svg';
const denialWordmarkAspectRatio = 49 / 15;

class DenialWordmark extends StatelessWidget {
  const DenialWordmark({
    required this.semanticsLabel,
    this.fit = BoxFit.contain,
    this.alignment = Alignment.center,
    super.key,
  });

  final String semanticsLabel;
  final BoxFit fit;
  final AlignmentGeometry alignment;

  @override
  Widget build(BuildContext context) {
    return SvgPicture.asset(
      denialWordmarkAsset,
      fit: fit,
      alignment: alignment,
      allowDrawingOutsideViewBox: true,
      clipBehavior: Clip.none,
      semanticsLabel: semanticsLabel,
    );
  }
}
