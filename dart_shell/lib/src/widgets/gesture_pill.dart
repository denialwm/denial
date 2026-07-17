import 'package:flutter/widgets.dart';

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
        color: armed ? const Color(0xff8ee6c1) : const Color(0xdff7f7f8),
        borderRadius: BorderRadius.circular(3),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x66000000),
            blurRadius: 10,
            offset: Offset(0, 2),
          ),
        ],
      ),
    );
  }
}
