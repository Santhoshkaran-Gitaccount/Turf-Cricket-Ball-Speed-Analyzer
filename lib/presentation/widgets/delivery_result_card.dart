import 'package:flutter/material.dart';

import '../../core/formatters.dart';
import '../../domain/entities/tracking.dart';
import 'stat.dart';

/// Shown after every valid delivery until the user saves or discards it, or
/// it saves itself after [autoSaveDelay].
class DeliveryResultCard extends StatelessWidget {
  const DeliveryResultCard({
    super.key,
    required this.delivery,
    required this.ballNumber,
    required this.stats,
    required this.autoSaveDelay,
    required this.onSave,
    required this.onDiscard,
  });

  final DeliveryMeasurement delivery;
  final int ballNumber;
  final ({int fastest, double average}) stats;
  final Duration autoSaveDelay;
  final VoidCallback onSave;
  final VoidCallback onDiscard;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SizedBox(
        width: 340,
        child: Card(
          color: Colors.black87,
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Counts down to the automatic save.
              TweenAnimationBuilder<double>(
                tween: Tween(begin: 1, end: 0),
                duration: autoSaveDelay,
                builder: (context, value, _) => LinearProgressIndicator(value: value, minHeight: 3),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Ball #$ballNumber', style: const TextStyle(color: Colors.white70, fontSize: 16)),
                    Text(
                      formatSpeed(delivery.speedKmh),
                      style: const TextStyle(color: Colors.white, fontSize: 48, fontWeight: FontWeight.w800),
                    ),
                    Text(delivery.end.label, style: const TextStyle(color: Colors.white54, fontSize: 12)),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        Stat(label: 'Fastest Ball', value: formatSpeed(stats.fastest)),
                        Stat(label: 'Average Speed', value: formatSpeed(stats.average)),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: onDiscard,
                            style: OutlinedButton.styleFrom(foregroundColor: Colors.white),
                            icon: const Icon(Icons.delete_outline),
                            label: const Text('Discard'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: onSave,
                            icon: const Icon(Icons.check),
                            label: const Text('Save'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
