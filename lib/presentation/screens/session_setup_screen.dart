import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/formatters.dart';
import '../../domain/entities/session.dart';
import '../providers.dart';
import 'camera_screen.dart';

class SessionSetupScreen extends ConsumerStatefulWidget {
  const SessionSetupScreen({super.key});

  @override
  ConsumerState<SessionSetupScreen> createState() => _SessionSetupScreenState();
}

class _SessionSetupScreenState extends ConsumerState<SessionSetupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _customLengthController = TextEditingController();

  /// Selected preset length, or null when "Custom Length" is chosen.
  double? _presetLength = 20.12;
  BallType _ballType = BallType.tennis;

  @override
  void dispose() {
    _nameController.dispose();
    _customLengthController.dispose();
    super.dispose();
  }

  String? _validateCustomLength(String? value) {
    final meters = double.tryParse(value?.trim() ?? '');
    if (meters == null) return 'Enter the pitch length in meters';
    if (!PitchLength.isValid(meters)) {
      return 'Must be between ${PitchLength.minMeters.toInt()} and ${PitchLength.maxMeters.toInt()} meters';
    }
    return null;
  }

  Future<void> _startSession() async {
    if (!_formKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();

    final Session session;
    try {
      session = await ref.read(startSessionProvider)(
        name: _nameController.text.trim(),
        pitchLengthMeters: _presetLength ?? double.parse(_customLengthController.text.trim()),
        ballType: _ballType,
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not save session: $error')));
      }
      return;
    }
    if (!mounted) return;

    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => CameraScreen(session: session)));
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('New Session')),
      body: GestureDetector(
        // Tapping outside a field closes the keyboard.
        onTap: () => FocusScope.of(context).unfocus(),
        behavior: HitTestBehavior.translucent,
        child: SafeArea(
          child: Form(
            key: _formKey,
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Session Name', style: textTheme.titleMedium),
                      const SizedBox(height: 8),
                      TextFormField(
                        controller: _nameController,
                        textCapitalization: TextCapitalization.words,
                        textInputAction: TextInputAction.done,
                        onFieldSubmitted: (_) => FocusScope.of(context).unfocus(),
                        decoration: const InputDecoration(
                          hintText: 'e.g. Evening Practice',
                          border: OutlineInputBorder(),
                        ),
                        validator: (value) =>
                            (value == null || value.trim().isEmpty) ? 'Enter a session name' : null,
                      ),
                      const SizedBox(height: 20),
                      Text('Pitch Length', style: textTheme.titleMedium),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final meters in PitchLength.presets)
                            ChoiceChip(
                              label: Text(formatPitchLength(meters)),
                              selected: _presetLength == meters,
                              onSelected: (_) => setState(() => _presetLength = meters),
                            ),
                          ChoiceChip(
                            label: const Text('Custom Length'),
                            selected: _presetLength == null,
                            onSelected: (_) => setState(() => _presetLength = null),
                          ),
                        ],
                      ),
                      if (_presetLength == null) ...[
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: _customLengthController,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          textInputAction: TextInputAction.done,
                          onFieldSubmitted: (_) => FocusScope.of(context).unfocus(),
                          decoration: InputDecoration(
                            labelText: 'Custom length',
                            suffixText: 'meters',
                            helperText:
                                '${PitchLength.minMeters.toInt()} – ${PitchLength.maxMeters.toInt()} meters',
                            border: const OutlineInputBorder(),
                          ),
                          validator: _validateCustomLength,
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 24),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text('Ball Type', style: textTheme.titleMedium),
                      const SizedBox(height: 8),
                      SegmentedButton<BallType>(
                        showSelectedIcon: false,
                        segments: [
                          for (final type in BallType.values)
                            ButtonSegment(value: type, label: Text(type.shortLabel)),
                        ],
                        selected: {_ballType},
                        onSelectionChanged: (selection) => setState(() => _ballType = selection.first),
                      ),
                      const SizedBox(height: 28),
                      FilledButton.icon(
                        onPressed: _startSession,
                        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                        icon: const Icon(Icons.videocam),
                        label: const Text('Open Camera'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
