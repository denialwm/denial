import 'package:flutter/material.dart';

class PageDots extends StatelessWidget {
  const PageDots({super.key, required this.count, required this.active});

  final int count;
  final int active;

  @override
  Widget build(BuildContext context) {
    if (count <= 1) {
      return const SizedBox(height: 8);
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var index = 0; index < count; index += 1)
          AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            width: index == active ? 20 : 7,
            height: 7,
            margin: const EdgeInsets.symmetric(horizontal: 4),
            decoration: BoxDecoration(
              color: index == active
                  ? const Color(0xddf7f7f8)
                  : const Color(0x55f7f7f8),
              borderRadius: BorderRadius.circular(4),
            ),
          ),
      ],
    );
  }
}
