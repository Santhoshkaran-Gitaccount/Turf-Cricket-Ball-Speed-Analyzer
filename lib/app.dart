import 'package:flutter/material.dart';

import 'presentation/screens/home_screen.dart';

class BallSpeedApp extends StatelessWidget {
  const BallSpeedApp({super.key});

  /// The app's colours. The launcher icon, splash screen and logo are drawn
  /// from this too (tool/icon/generate_icon_test.dart), so they always match.
  static final colorScheme = ColorScheme.fromSeed(
    seedColor: Colors.green,
    brightness: Brightness.dark,
  );

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Ball Speed Analyzer',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorScheme: colorScheme),
      home: const HomeScreen(),
    );
  }
}
