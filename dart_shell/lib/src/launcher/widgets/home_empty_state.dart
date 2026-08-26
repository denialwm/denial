import 'package:flutter/material.dart';

import '../../theme/tokens.dart';

class HomeEmptyState extends StatelessWidget {
  const HomeEmptyState({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        label,
        style: TextStyle(
          color: ShellMediaColors.lightForeground.withValues(alpha: 0.67),
          fontSize: 16,
          height: 1.2,
          fontWeight: FontWeight.w600,
          letterSpacing: 0,
        ),
      ),
    );
  }
}
