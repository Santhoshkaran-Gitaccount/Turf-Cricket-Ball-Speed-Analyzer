import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/formatters.dart';
import '../../domain/entities/session.dart';
import '../providers.dart';
import 'session_summary_screen.dart';

/// Every past session stored on the phone, newest first. Tapping one opens
/// its full summary.
class HistoryScreen extends ConsumerWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(sessionHistoryProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('History')),
      body: SafeArea(
        child: switch (history) {
          AsyncData(:final value) when value.isEmpty => const Center(child: Text('No sessions yet')),
          AsyncData(:final value) => ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: value.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) => _SessionTile(value[i]),
            ),
          AsyncError(:final error) => Center(child: Text('Could not load history: $error')),
          _ => const Center(child: CircularProgressIndicator()),
        },
      ),
    );
  }
}

class _SessionTile extends StatelessWidget {
  const _SessionTile(this.session);

  final Session session;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(session.name, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(
        [
          '${formatDate(session.startTime)}, ${formatTime(session.startTime)}',
          '${session.totalDeliveries} balls',
          formatPitchLength(session.pitchLengthMeters),
        ].join('  •  '),
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(formatSpeed(session.fastestKmh), style: const TextStyle(fontWeight: FontWeight.w700)),
          const Text('Fastest', style: TextStyle(fontSize: 12)),
        ],
      ),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => SessionSummaryScreen(session: session)),
      ),
    );
  }
}
