import 'package:flutter/material.dart';

/// A small label over a value, for speeds and counts on dark overlays.
class Stat extends StatelessWidget {
  const Stat({super.key, required this.label, required this.value, this.large = false});

  final String label;
  final String value;
  final bool large;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12)),
        Text(
          value,
          style: TextStyle(
            color: Colors.white,
            fontSize: large ? 28 : 18,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}
