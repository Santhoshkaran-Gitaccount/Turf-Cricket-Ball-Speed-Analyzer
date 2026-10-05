import 'package:flutter/material.dart';

import '../../core/formatters.dart';
import '../../domain/entities/delivery.dart';
import '../../domain/entities/session.dart';

class SessionSummaryScreen extends StatelessWidget {
  const SessionSummaryScreen({super.key, required this.session});

  final Session session;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Session Summary'),
        automaticallyImplyLeading: false,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Done')),
          ),
        ],
      ),
      // One scrolling column: details and statistics, then every delivery.
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
          children: [
            Text('Session Details', style: textTheme.titleMedium),
            _row('Session Name', session.name),
            _row('Date', formatDate(session.startTime)),
            // A session closed without End (e.g. the app was killed) has no real duration.
            _row('Duration', session.endTime == null ? 'Not ended' : formatDuration(session.duration)),
            _row('Pitch Length', formatPitchLength(session.pitchLengthMeters)),
            _row('Ball Type', session.ballType.label),
            const Divider(height: 24),
            Text('Statistics', style: textTheme.titleMedium),
            _row('Total Deliveries', '${session.totalDeliveries}'),
            _row('Valid Deliveries', '${session.validCount}'),
            _row('Invalid Deliveries', '${session.invalidCount}'),
            _row('Fastest Ball', formatSpeed(session.fastestKmh)),
            _row('Slowest Ball', formatSpeed(session.slowestKmh)),
            _row('Average Speed', formatSpeed(session.averageKmh)),
            const Divider(height: 24),
            Text('Delivery List', style: textTheme.titleMedium),
            if (session.deliveries.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: Text('No deliveries recorded')),
              )
            else
              for (final delivery in session.deliveries) _DeliveryTile(delivery),
          ],
        ),
      ),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label),
          const SizedBox(width: 16),
          // Long values (a long session name) wrap instead of overflowing.
          Flexible(
            child: Text(value, textAlign: TextAlign.end, style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }
}

class _DeliveryTile extends StatelessWidget {
  const _DeliveryTile(this.delivery);

  final Delivery delivery;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final valid = delivery.isValid;

    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Text(
        'Ball #${delivery.ballNumber}',
        style: TextStyle(fontWeight: FontWeight.w600, color: valid ? null : colors.outline),
      ),
      title: Text(
        valid ? formatSpeed(delivery.speedKmh) : 'Invalid',
        style: TextStyle(fontWeight: FontWeight.w700, color: valid ? null : colors.error),
      ),
      subtitle: valid ? null : Text(delivery.invalidReason!.label),
      trailing: Text(formatTime(delivery.timestamp)),
    );
  }
}
