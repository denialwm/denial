import 'package:flutter/widgets.dart';

import '../theme/shell_theme.dart';

class GesturePill extends StatelessWidget {
  const GesturePill({super.key, required this.armed});

  final bool armed;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 90),
      curve: Curves.easeOutCubic,
      width: armed ? 132 : 116,
      height: 5,
      decoration: BoxDecoration(
        color: armed
            ? context.shellColors.gestureArmed
            : context.shellColors.gesturePill,
        borderRadius: BorderRadius.circular(3),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: context.shellColors.shadowSoft,
            blurRadius: 10,
            offset: Offset(0, 2),
          ),
        ],
      ),
    );
  }
}
