import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';

import 'app.dart';
import 'data/repositories/deferred_session_repository.dart';
import 'data/repositories/hive_session_repository.dart';
import 'domain/repositories/session_repository.dart';
import 'presentation/providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // The whole app is portrait only; the phone sits upright on a tripod
  // behind the keeper.
  // Not awaited: the first screen should not wait on the platform.
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

  // Offline-first: everything is stored on the device with Hive. Opening it
  // reads every stored delivery, so it runs while the home screen shows.
  final repository = DeferredSessionRepository(
    Hive.initFlutter().then<SessionRepository>((_) => HiveSessionRepository.open()),
  );

  runApp(
    ProviderScope(
      overrides: [sessionRepositoryProvider.overrideWithValue(repository)],
      child: const BallSpeedApp(),
    ),
  );
}
