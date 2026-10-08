import 'dart:async';
import 'dart:math';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../core/formatters.dart';
import '../../data/camera_settings_store.dart';
import '../../domain/detection/frame.dart' show ChromaPlanes;
import '../../domain/detection/view_transform.dart';
import '../../domain/entities/session.dart';
import '../tracking/tracking_controller.dart';
import '../tracking/tracking_state.dart';
import '../widgets/delivery_result_card.dart';
import '../widgets/notice_banner.dart';
import '../widgets/pitch_guide_overlay.dart';
import '../widgets/stat.dart';
import 'session_summary_screen.dart';

class CameraScreen extends ConsumerStatefulWidget {
  const CameraScreen({super.key, required this.session});

  final Session session;

  @override
  ConsumerState<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends ConsumerState<CameraScreen> with WidgetsBindingObserver {
  /// Camera settings tried in order. Android often accepts a frame rate it
  /// cannot deliver, so each is measured, and a lower resolution (enough for
  /// detection, which works on a coarse grid) is tried when 60 FPS is not reached.
  static const _configs = [
    (ResolutionPreset.high, 120),
    (ResolutionPreset.high, 60),
    (ResolutionPreset.medium, 120),
    (ResolutionPreset.medium, 60),
  ];

  /// A camera setting delivering this much is kept; slightly lower readings
  /// are measurement noise.
  static const _minFps = 55;

  /// Below this the screen says the frame rate has dropped. Timing is fitted
  /// over the whole flight, so speeds stay close at lower rates too; the line
  /// only tells the user, it is not a fault.
  static const _warnBelowFps = 45;

  /// While waiting for a delivery, exposure is unlocked this often so it
  /// follows the light (sun, clouds, floodlights), then locked again.
  static const _remeterInterval = Duration(seconds: 8);
  static const _remeterDuration = Duration(milliseconds: 800);

  /// Exposure bias while tracking. A darker exposure makes the camera use a
  /// shorter shutter time, so a fast ball is a sharp spot rather than a faint
  /// streak; detection allows for a dimmer picture. Clamped to what the
  /// camera supports.
  static const _trackingExposureOffset = -1.0;

  /// Time autofocus is given to settle on the far stumps before it is locked.
  static const _focusSettleTime = Duration(milliseconds: 1500);

  CameraController? _camera;
  bool _openingCamera = false;
  bool _restarting = false;
  DateTime? _focusSetAt;
  int? _requestedFps;
  Timer? _remeterTimer;

  /// True while exposure is adjusting; frames are not used meanwhile, since
  /// the brightness change would look like motion.
  bool _remetering = false;
  String? _error;
  double _screenAspect = 16 / 9;

  /// The app is portrait, this screen included.
  bool _landscape = false;

  DeviceOrientation get _orientation =>
      _landscape ? DeviceOrientation.landscapeLeft : DeviceOrientation.portraitUp;

  TrackingController get _controller => ref.read(trackingControllerProvider(widget.session).notifier);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // The phone sits untouched on a tripod; a screen timeout would close the
    // camera and stop tracking mid-session.
    WakelockPlus.enable();
    _initCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    WakelockPlus.disable();
    _remeterTimer?.cancel();
    if (_landscape) SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    _camera?.dispose();
    super.dispose();
  }

  /// Waits (briefly) for the screen to finish turning to [orientation].
  Future<void> _waitFor(Orientation orientation) async {
    for (var i = 0; i < 20; i++) {
      if (!mounted || MediaQuery.orientationOf(context) == orientation) return;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.inactive:
        // Android does not let a background app keep the camera: release it,
        // and pause tracking so the session waits for the user.
        final camera = _camera;
        if (camera == null) return;
        _controller.pause();
        _camera = null;
        setState(() {});
        camera.dispose();
      case AppLifecycleState.resumed:
        // The camera was released above, so reopen it.
        if (_camera == null) _initCamera();
      default:
        break;
    }
  }

  Future<void> _initCamera() async {
    if (_openingCamera) return;
    _openingCamera = true;
    setState(() => _error = null);
    try {
      await _openCamera();
    } finally {
      _openingCamera = false;
    }
  }

  Future<void> _openCamera() async {
    try {
      final cameras = await availableCameras();
      final back = cameras.where((c) => c.lensDirection == CameraLensDirection.back);
      if (back.isEmpty) {
        setState(() => _error = 'No back camera found on this device.');
        return;
      }

      CameraController create((ResolutionPreset, int) config) => CameraController(
            back.first,
            config.$1,
            fps: config.$2,
            enableAudio: false,
            // Detection only needs the brightness plane, which YUV provides directly.
            imageFormatGroup: ImageFormatGroup.yuv420,
          );

      final cameraName = back.first.name;

      // The setting measured on an earlier visit opens straight away.
      if (await CameraSettingsStore.load(cameraName) case (final preset, final fps, final measured)) {
        final camera = create((preset, fps));
        try {
          await camera.initialize();
          await camera.lockCaptureOrientation(_orientation);
          if (!mounted) {
            await _disposeQuietly(camera);
            return;
          }
          setState(() {
            _camera = camera;
            _requestedFps = measured.round();
          });
          return;
        } on CameraException catch (e) {
          await _disposeQuietly(camera);
          if (e.code.contains('AccessDenied')) rethrow;
          // The remembered setting no longer works (e.g. after an update): measure again.
          await CameraSettingsStore.forget(cameraName);
        }
      }

      // First visit: only one camera can be open at a time, so each setting is
      // measured and closed before the next; the first to reach the minimum is kept open.
      (ResolutionPreset, int)? bestConfig;
      var bestFps = 0.0;
      CameraController? chosen;
      for (final config in _configs) {
        final camera = create(config);
        final double measured;
        try {
          await camera.initialize();
          await camera.lockCaptureOrientation(_orientation);
          measured = await _measureFps(camera);
        } on CameraException catch (e) {
          await _disposeQuietly(camera);
          if (e.code.contains('AccessDenied')) rethrow;
          continue;
        }
        if (!mounted) {
          await _disposeQuietly(camera);
          return;
        }
        if (measured > bestFps) {
          bestConfig = config;
          bestFps = measured;
        }
        if (measured >= _minFps) {
          chosen = camera;
          break;
        }
        await _disposeQuietly(camera);
      }
      if (bestConfig == null) {
        setState(() => _error = 'Could not open the camera.');
        return;
      }
      // None reached the minimum: reopen the fastest. It still works; the screen warns about it.
      if (chosen == null) {
        chosen = create(bestConfig);
        await chosen.initialize();
        await chosen.lockCaptureOrientation(_orientation);
      }
      await CameraSettingsStore.save(cameraName, bestConfig, bestFps);
      if (!mounted) {
        await _disposeQuietly(chosen);
        return;
      }
      setState(() {
        _camera = chosen;
        _requestedFps = bestFps.round();
      });
    } on CameraException catch (e) {
      setState(
        () => _error = e.code.contains('AccessDenied')
            ? 'Camera permission is required. Please allow camera access in Settings.'
            : 'Could not open the camera: ${e.description ?? e.code}',
      );
    }
  }

  /// Closes a camera that was only opened to measure it. The Android camera
  /// plugin throws when closing one whose preview was never shown; it is
  /// closed all the same, so that error is ignored.
  Future<void> _disposeQuietly(CameraController camera) async {
    try {
      await camera.dispose();
    } on PlatformException {
      // See above.
    }
  }

  /// The frame rate [camera] actually delivers, measured over about a second
  /// after a short warm-up.
  Future<double> _measureFps(CameraController camera) async {
    final clock = Stopwatch()..start();
    const warmUpMicros = 200000;
    var frames = 0;
    int? first;
    int? last;
    await camera.startImageStream((_) {
      final now = clock.elapsedMicroseconds;
      if (now < warmUpMicros) return;
      frames++;
      first ??= now;
      last = now;
    });
    await Future<void>.delayed(const Duration(milliseconds: 1000));
    await camera.stopImageStream();
    if (frames < 2) return 0;
    return (frames - 1) * 1e6 / (last! - first!);
  }

  /// Lets exposure follow the light for a moment, then locks it again.
  /// Skipped while a ball is in flight or a result is waiting.
  Future<void> _remeter() async {
    final camera = _camera;
    final tracking = ref.read(trackingControllerProvider(widget.session));
    if (camera == null || _remetering || tracking.ballInFlight || tracking.pending != null) return;
    if (tracking.status != TrackingStatus.tracking) return;
    _remetering = true;
    try {
      await camera.setExposureMode(ExposureMode.auto);
      await Future<void>.delayed(_remeterDuration);
      await camera.setExposureMode(ExposureMode.locked);
    } on CameraException {
      // Exposure locking is unsupported; it then follows the light on its own.
    } finally {
      // The first frame after the change is compared with nothing, not with a darker or brighter one.
      _controller.resetDetection();
      _remetering = false;
    }
  }

  Future<void> _startTracking() async {
    final camera = _camera;
    if (camera == null) return;

    await _controller.start();
    if (ref.read(trackingControllerProvider(widget.session)).status != TrackingStatus.tracking) {
      return;
    }
    // Locking before autofocus has settled on the far stumps would keep the
    // far end, where the ball is smallest, blurred for the whole session.
    if (_focusSetAt case final setAt?) {
      final remaining = _focusSettleTime - DateTime.now().difference(setAt);
      if (remaining > Duration.zero) await Future<void>.delayed(remaining);
    }
    // A shorter shutter time, set before exposure is locked on it.
    try {
      final lowest = await camera.getMinExposureOffset();
      await camera.setExposureOffset(max(lowest, _trackingExposureOffset));
    } on CameraException {
      // No exposure compensation on this device; the picture stays as it is.
    }
    // Stop exposure and focus hunting mid-delivery; brightness changes look like motion.
    try {
      await camera.setExposureMode(ExposureMode.locked);
      await camera.setFocusMode(FocusMode.locked);
    } on CameraException {
      // Not every device supports locking; detection still works without it.
    }
    if (!camera.value.isStreamingImages) await camera.startImageStream(_onFrame);
    _remeterTimer?.cancel();
    _remeterTimer = Timer.periodic(_remeterInterval, (_) => _remeter());
  }

  Future<void> _pauseTracking() async {
    _controller.pause();
    await _stopStream();
  }

  Future<void> _stopStream() async {
    _remeterTimer?.cancel();
    _remeterTimer = null;
    final camera = _camera;
    if (camera == null || !camera.value.isStreamingImages) return;
    await camera.stopImageStream();
    try {
      // Back to a normal picture for setting up.
      await camera.setExposureOffset(0);
    } on CameraException {
      // See _startTracking.
    }
    try {
      await camera.setExposureMode(ExposureMode.auto);
      await camera.setFocusMode(FocusMode.auto);
    } on CameraException {
      // See _startTracking.
    }
  }

  void _onFrame(CameraImage image) {
    final camera = _camera;
    if (camera == null || _remetering) return;
    final luma = image.planes.first;
    _controller.processFrame(
      bytes: luma.bytes,
      width: image.width,
      height: image.height,
      bytesPerRow: luma.bytesPerRow,
      rotationDegrees: _rotationDegrees(camera),
      screenAspect: _screenAspect,
      chroma: _chroma(image),
    );
  }

  /// The frame's colour planes: separate U and V on Android, one interleaved
  /// UV plane on iOS. Null if the camera gave something else.
  static ChromaPlanes? _chroma(CameraImage image) {
    final planes = image.planes;
    if (planes.length >= 3) {
      final u = planes[1];
      return ChromaPlanes(
        u: u.bytes,
        v: planes[2].bytes,
        rowStride: u.bytesPerRow,
        pixelStride: u.bytesPerPixel ?? 1,
      );
    }
    if (planes.length == 2) {
      final uv = planes[1];
      return ChromaPlanes(u: uv.bytes, v: uv.bytes, rowStride: uv.bytesPerRow, pixelStride: 2, vOffset: 1);
    }
    return null;
  }

  /// Clockwise rotation that makes sensor images upright for the locked
  /// orientation: the sensor's own angle in portrait, a quarter turn less in landscape.
  int _rotationDegrees(CameraController camera) =>
      (camera.description.sensorOrientation - (_landscape ? 90 : 0)) % 360;

  void _onPreviewTap(Offset position, Size size, ViewTransform view) {
    final tracking = ref.read(trackingControllerProvider(widget.session));
    if (tracking.setupStep == SetupStep.done) return;
    final (x, y) = (position.dx / size.width, position.dy / size.height);
    final (rx, ry) = view.screenToReference(x, y);
    final bowling = tracking.setupStep == SetupStep.tapBowling;
    _controller.tapStumps(rx, ry);
    // Focus and expose for the far end, where the ball is smallest.
    if (bowling) _focusOn(view.screenToImage(x, y));
  }

  Future<void> _focusOn((double, double) point) async {
    final camera = _camera;
    if (camera == null) return;
    final offset = Offset(point.$1.clamp(0, 1), point.$2.clamp(0, 1));
    try {
      await camera.setFocusPoint(offset);
      await camera.setExposurePoint(offset);
      _focusSetAt = DateTime.now();
    } on CameraException {
      // Not supported on every device; the camera keeps focusing on its own.
    }
  }

  /// Reopens the camera and detection when either got stuck, without leaving
  /// the session: pitch length, ball type, stumps and deliveries are kept.
  Future<void> _restart() async {
    setState(() => _restarting = true);
    try {
      await _stopStream();
      await _controller.restart();
      final camera = _camera;
      setState(() => _camera = null);
      if (camera != null) await _disposeQuietly(camera);
      if (!mounted) return;
      await _initCamera();
    } finally {
      if (mounted) setState(() => _restarting = false);
    }
  }

  Future<void> _endSession() async {
    await _stopStream();
    await _controller.end();
    // The summary is portrait, like the rest of the app.
    if (_landscape) {
      _landscape = false;
      await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
      await _waitFor(Orientation.portrait);
    }
    if (!mounted) return;
    Navigator.of(context)
        .pushReplacement(MaterialPageRoute(builder: (_) => SessionSummaryScreen(session: widget.session)));
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final tracking = ref.watch(trackingControllerProvider(session));
    final camera = _camera;
    final ready = camera != null && camera.value.isInitialized;
    final size = MediaQuery.sizeOf(context);
    _screenAspect = size.width / size.height;
    final landscape = size.width > size.height;
    final colors = Theme.of(context).colorScheme;
    final view = camera == null || !ready
        ? null
        : ViewTransform(
            // The preview aspect ratio is reported for the sensor's landscape orientation.
            imageAspect: landscape ? camera.value.aspectRatio : 1 / camera.value.aspectRatio,
            screenAspect: _screenAspect,
          );
    // The pitch can be set up, and its guide is shown, whenever not tracking.
    final settingUp = ready && tracking.status != TrackingStatus.tracking;

    return Scaffold(
      backgroundColor: Colors.black,
      // The camera view never takes text input; a keyboard left open from
      // session setup must not shrink it.
      resizeToAvoidBottomInset: false,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (_error != null)
            _ErrorView(message: _error!, onRetry: _initCamera)
          else if (!ready)
            const Center(child: CircularProgressIndicator())
          else ...[
            _FullScreenPreview(camera: camera, landscape: landscape),
            if (settingUp) ...[
              PitchGuideOverlay(
                color: colors.primary,
                geometry: tracking.geometry,
                view: view,
                marker: tracking.battingTap,
              ),
              // Taps on the preview mark the stumps.
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapUp: (details) => _onPreviewTap(details.localPosition, size, view!),
              ),
            ],
          ],
          if (tracking.pending case final delivery?)
            DeliveryResultCard(
              key: ObjectKey(delivery),
              delivery: delivery,
              ballNumber: session.nextBallNumber,
              stats: session.statsWith(delivery.speedKmh),
              autoSaveDelay: TrackingController.autoSaveDelay,
              onSave: _controller.savePending,
              onDiscard: _controller.discardPending,
            ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: landscape
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [_buildTopBar(tracking), const Spacer(), _buildStats()],
                          ),
                        ),
                        const SizedBox(width: 16),
                        SizedBox(
                          width: 200,
                          child: Center(child: _buildControls(tracking, ready, vertical: true)),
                        ),
                      ],
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _buildTopBar(tracking),
                        const Spacer(),
                        Align(alignment: Alignment.bottomLeft, child: _buildStats()),
                        const SizedBox(height: 12),
                        _buildControls(tracking, ready),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }

  /// The most important problem to show at the top of the screen, if any.
  String? _warning(TrackingState tracking) {
    final isTracking = tracking.status == TrackingStatus.tracking;
    if (isTracking && !tracking.pitchVisible) return 'Pitch not fully visible. Check the camera view.';
    if (isTracking && !tracking.cameraSteady) return 'Camera is moving. Keep the phone still on a tripod.';
    if (tracking.notice case final message?) return message;
    final fps = tracking.measuredFps;
    if (isTracking && fps != null && fps < _warnBelowFps) {
      // Against what the camera delivered when it was opened, so a drop
      // (dimmer light, a busy phone) is told apart from a camera that only
      // ever runs this fast.
      final now = fps.round();
      final usual = _requestedFps;
      if (usual != null && usual - now >= 3) return 'Camera running at $now FPS (down from $usual)';
      return 'Camera running at $now FPS';
    }
    return null;
  }

  /// Session info with the restart button beside it, and any warning below.
  Widget _buildTopBar(TrackingState tracking) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Align(alignment: Alignment.topLeft, child: _buildSessionInfo(tracking)),
            ),
            const SizedBox(width: 8),
            IconButton.filledTonal(
              onPressed: _restarting ? null : _restart,
              tooltip: 'Restart camera and detection',
              icon: const Icon(Icons.restart_alt),
            ),
          ],
        ),
        // Below the info panel, so it never covers it.
        if (_warning(tracking) case final message?)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: NoticeBanner(message: message),
          ),
      ],
    );
  }

  Widget _buildSessionInfo(TrackingState tracking) {
    final session = widget.session;
    final fps = tracking.measuredFps?.round() ?? _requestedFps;
    // The status goes on its own line above the details, which wrap.
    return _Panel(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _TrackingBadge(state: tracking, nextBallNumber: session.nextBallNumber),
          const SizedBox(height: 4),
          Flexible(
            child: Text(
              [
                session.name,
                formatPitchLength(session.pitchLengthMeters),
                'Balls: ${session.totalDeliveries}',
                if (fps != null) '$fps FPS',
                if (tracking.usingModel) 'AI',
                // Frame processing time, for tuning on real devices.
                if (kDebugMode && tracking.processingMs != null)
                  '${tracking.processingMs!.toStringAsFixed(1)} ms',
              ].join('  •  '),
              style: const TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStats() {
    final session = widget.session;
    return _Panel(
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Stat(label: 'Last Ball', value: formatSpeed(session.lastKmh), large: true),
            const SizedBox(width: 24),
            Stat(label: 'Fastest', value: formatSpeed(session.fastestKmh)),
            const SizedBox(width: 24),
            Stat(label: 'Average', value: formatSpeed(session.averageKmh)),
          ],
        ),
      ),
    );
  }

  /// Start, Pause and End: in a row along the bottom in portrait, stacked on
  /// the right in landscape.
  Widget _buildControls(TrackingState tracking, bool ready, {bool vertical = false}) {
    final isTracking = tracking.status == TrackingStatus.tracking;
    final buttons = [
      FilledButton.icon(
        onPressed: ready && !isTracking ? _startTracking : null,
        icon: const Icon(Icons.play_arrow),
        label: Text(tracking.status == TrackingStatus.paused ? 'Resume' : 'Start'),
      ),
      FilledButton.tonalIcon(
        onPressed: isTracking ? _pauseTracking : null,
        icon: const Icon(Icons.pause),
        label: const Text('Pause'),
      ),
      OutlinedButton.icon(
        onPressed: _endSession,
        style: OutlinedButton.styleFrom(foregroundColor: Colors.white, backgroundColor: Colors.black54),
        icon: const Icon(Icons.flag),
        label: const Text('End'),
      ),
    ];
    const gap = SizedBox(width: 8, height: 12);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (ready && !isTracking)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _SetupPrompt(
              step: tracking.setupStep,
              alignEnd: vertical,
              onReset: tracking.setupStep == SetupStep.tapBatting ? null : _controller.resetSetup,
            ),
          ),
        if (vertical)
          for (final (i, button) in buttons.indexed) ...[if (i > 0) gap, button]
        else
          Row(
            children: [
              for (final (i, button) in buttons.indexed) ...[if (i > 0) gap, Expanded(child: button)],
            ],
          ),
      ],
    );
  }
}

/// Fills the whole screen with the preview, cropping the edges instead of letterboxing.
class _FullScreenPreview extends StatelessWidget {
  const _FullScreenPreview({required this.camera, required this.landscape});

  final CameraController camera;
  final bool landscape;

  @override
  Widget build(BuildContext context) {
    // The reported aspect ratio is for landscape; CameraPreview turns the
    // image upright for portrait itself.
    final ratio = camera.value.aspectRatio;
    return ClipRect(
      child: SizedBox.expand(
        child: FittedBox(
          fit: BoxFit.cover,
          child: SizedBox(
            width: landscape ? 100 * ratio : 100,
            height: landscape ? 100 : 100 * ratio,
            child: CameraPreview(camera),
          ),
        ),
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)),
      child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8), child: child),
    );
  }
}

class _TrackingBadge extends StatelessWidget {
  const _TrackingBadge({required this.state, required this.nextBallNumber});

  final TrackingState state;

  /// Number of the next ball to be saved; the one on the result card, if any.
  final int nextBallNumber;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (state.status) {
      TrackingStatus.idle => ('READY', Colors.white54),
      TrackingStatus.tracking when state.ballInFlight => ('BALL IN FLIGHT', Colors.yellowAccent),
      // After the first ball, say which ball is next so it does not look as
      // if the app started over.
      TrackingStatus.tracking when state.pending != null => ('BALL #$nextBallNumber DONE', Colors.lightGreenAccent),
      TrackingStatus.tracking when nextBallNumber > 1 => ('READY FOR BALL #$nextBallNumber', Colors.lightGreenAccent),
      TrackingStatus.tracking => ('WAITING FOR DELIVERY', Colors.redAccent),
      TrackingStatus.paused => ('PAUSED', Colors.amber),
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.circle, size: 10, color: color),
        const SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 12),
        ),
      ],
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.videocam_off, color: Colors.white70, size: 48),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white),
            ),
            const SizedBox(height: 16),
            FilledButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}

/// Tells the user which stumps to tap next, or that the pitch is set.
class _SetupPrompt extends StatelessWidget {
  const _SetupPrompt({required this.step, required this.alignEnd, this.onReset});

  final SetupStep step;
  final bool alignEnd;
  final VoidCallback? onReset;

  @override
  Widget build(BuildContext context) {
    final (icon, text, color) = switch (step) {
      SetupStep.tapBatting => (Icons.touch_app, 'Tap the batting stumps (near you)', Colors.white),
      SetupStep.tapBowling => (Icons.touch_app, 'Now tap the bowling stumps (far end)', Colors.yellowAccent),
      SetupStep.done => (Icons.check_circle, 'Pitch set. Ready to start', Colors.lightGreenAccent),
    };
    return DecoratedBox(
      decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
        child: Row(
          mainAxisAlignment: alignEnd ? MainAxisAlignment.end : MainAxisAlignment.center,
          children: [
            Icon(icon, color: color, size: 18),
            const SizedBox(width: 8),
            Flexible(
              child: Text(text, style: TextStyle(color: color)),
            ),
            if (onReset != null)
              TextButton(
                onPressed: onReset,
                style: TextButton.styleFrom(foregroundColor: Colors.white70),
                child: const Text('Reset'),
              )
            else
              const SizedBox(width: 8, height: 40),
          ],
        ),
      ),
    );
  }
}
