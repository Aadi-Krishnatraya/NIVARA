import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

import '../../core/ui_theme.dart';
import 'face_mood_model.dart';

/// "Face Mood" capture sheet (check-in assist).
///
/// Opens the front camera, runs ML Kit face detection on streamed frames
/// entirely in memory, aggregates the smile/eye/posture signals into a mood
/// suggestion, and hands it back to the check-in screen. The user can accept
/// or dismiss it — the suggestion never overrides the slider silently.
///
/// Privacy: frames are never written to disk, never uploaded, and never leave
/// the sheet's scope. Closing the sheet disposes the camera immediately.
class FaceMoodCaptureSheet extends StatefulWidget {
  const FaceMoodCaptureSheet({super.key});

  /// Returns the estimate, or null if the user dismissed / no signal.
  static Future<MoodEstimate?> show(BuildContext context) {
    return showModalBottomSheet<MoodEstimate>(
      context: context,
      isScrollControlled: true,
      backgroundColor: NivaraColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (_) => const FaceMoodCaptureSheet(),
    );
  }

  @override
  State<FaceMoodCaptureSheet> createState() => _FaceMoodCaptureSheetState();
}

class _FaceMoodCaptureSheetState extends State<FaceMoodCaptureSheet> {
  final FaceMoodModel _model = FaceMoodModel();
  CameraController? _controller;
  FaceDetector? _detector;
  String? _error;
  bool _initializing = true;

  final List<FaceSignal> _signals = [];
  bool _busy = false;
  bool _done = false;

  // Live diagnostics — make every pipeline stage observable in the UI so a
  // silent failure can never masquerade as a hang.
  int _framesSeen = 0;
  int _facesSeen = 0;
  String? _lastDetectionError;
  Timer? _watchdog;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        if (!mounted) return;
        setState(() {
          _error =
              'No camera is available on this device (common on emulators — enable a front camera in the emulator settings or test on a phone).';
          _initializing = false;
        });
        return;
      }
      final front = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );
      final controller = CameraController(
        front,
        ResolutionPreset.low, // tiny buffers — frames never leave memory
        enableAudio: false,
        imageFormatGroup:
            defaultTargetPlatform == TargetPlatform.iOS
                ? ImageFormatGroup.bgra8888
                : ImageFormatGroup.yuv420,
      );
      // CRITICAL: register on the state BEFORE awaiting anything, so the
      // preview builder, frame handler and dispose path all see it.
      _controller = controller;
      await controller.initialize();
      _detector = FaceDetector(
        options: FaceDetectorOptions(
          enableClassification: true, // smile + eye-open probabilities
          enableLandmarks: false,
          enableTracking: false,
          performanceMode: FaceDetectorMode.fast,
        ),
      );
      if (!mounted) return;
      setState(() => _initializing = false);
      await controller.startImageStream(_onFrame);
      // Watchdog: if no usable signal arrives within 10 s, say WHY instead
      // of spinning forever.
      _watchdog = Timer(const Duration(seconds: 10), () {
        if (_done || !mounted || _signals.isNotEmpty) return;
        setState(() {
          _error = _lastDetectionError != null
              ? 'Face detection failed on this device: $_lastDetectionError'
              : 'No face detected — center your face in the frame with even lighting. (frames: $_framesSeen, faces: $_facesSeen)';
        });
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is CameraException ? _friendlyCameraError(e) : 'Camera unavailable: $e';
        _initializing = false;
      });
    }
  }

  /// Map camera plugin error codes to actionable messages.
  static String _friendlyCameraError(CameraException e) {
    switch (e.code) {
      case 'CameraAccessDenied':
      case 'CAMERA_ACCESS_DENIED':
      case 'cameraPermission':
        return 'Camera permission denied. Allow NIVARA to use the camera (Settings → Apps → NIVARA → Permissions), then try again.';
      case 'CameraAccessDeniedWithoutPrompt':
      case 'CameraAccessRestricted':
        return 'Camera access is blocked for NIVARA — re-enable it in system settings.';
      default:
        return 'Camera error (${e.code}): ${e.description ?? 'unknown'}';
    }
  }

  /// Throttled frame handler: skip while a detection is in flight, stop once
  /// enough usable frames are aggregated. Every failure mode lands in
  /// diagnostics (counters / _lastDetectionError) instead of being swallowed.
  Future<void> _onFrame(CameraImage image) async {
    if (_busy || _done || _signals.length >= FaceMoodModel.defaultFrameTarget) {
      if (!_done && _signals.length >= FaceMoodModel.defaultFrameTarget) {
        _finish();
      }
      return;
    }
    _busy = true;
    _framesSeen++;
    try {
      final detector = _detector;
      final controller = _controller;
      if (detector == null || controller == null || !controller.value.isInitialized) return;

      final input = _toInputImage(image, controller);
      if (input == null) return;
      final faces = await detector.processImage(input);
      if (_done) return;

      if (faces.isEmpty) {
        // No face in this frame — keep streaming; counters feed the hint.
        if (mounted && _facesSeen == 0 && _framesSeen % 15 == 0) setState(() {});
        return;
      }
      _facesSeen += faces.length;
      final face = faces.first;
      _signals.add(FaceSignal(
        smilingProbability: face.smilingProbability,
        leftEyeOpenProbability: face.leftEyeOpenProbability,
        rightEyeOpenProbability: face.rightEyeOpenProbability,
        headEulerAngleZ: face.headEulerAngleZ?.toDouble(),
      ));
      // A detection that succeeds once clears the watchdog path.
      _lastDetectionError = null;
      if (mounted) setState(() {});
      if (_signals.length >= FaceMoodModel.defaultFrameTarget) _finish();
    } catch (e) {
      // Never crash the sheet — but surface the failure on-screen (once) so
      // "not processing" always has a visible reason.
      _lastDetectionError ??= '$e';
      if (mounted && _error == null && _signals.isEmpty) {
        setState(() => _error = 'Processing issue: $_lastDetectionError');
      }
    } finally {
      _busy = false;
    }
  }

  InputImage? _toInputImage(CameraImage image, CameraController controller) {
    // iOS delivers bgra8888 single-plane — the concat recipe is correct there.
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      final WriteBuffer buffer = WriteBuffer();
      for (final plane in image.planes) {
        buffer.putUint8List(plane.bytes);
      }
      final bytes = buffer.done().buffer.asUint8List();
      final metadata = InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: _rotationFromDegrees(controller.description.sensorOrientation),
        format: InputImageFormat.bgra8888,
        bytesPerRow: image.planes.first.bytesPerRow,
      );
      return InputImage.fromBytes(bytes: bytes, metadata: metadata);
    }

    // Android: the naive plane-concat triggers InputImageConverterError on
    // most devices (row-stride padding makes the buffer size wrong for ML
    // Kit). Build a tightly-packed NV21 buffer ourselves instead — ML Kit
    // accepts NV21 reliably on every device tested.
    if (image.format.group != ImageFormatGroup.yuv420) return null;
    final bytes = _yuv420ToNv21(image);
    final metadata = InputImageMetadata(
      size: Size(image.width.toDouble(), image.height.toDouble()),
      rotation: _rotationFromDegrees(controller.description.sensorOrientation),
      format: InputImageFormat.nv21,
      bytesPerRow: image.width, // NV21 is tightly packed
    );
    return InputImage.fromBytes(bytes: bytes, metadata: metadata);
  }

  /// Convert the camera's yuv_420_888 planes to NV21, honoring row strides
  /// and pixel strides (manufacturer padding is common and is exactly what
  /// breaks the naive concat approach).
  static Uint8List _yuv420ToNv21(CameraImage image) {
    final width = image.width;
    final height = image.height;
    final yPlane = image.planes[0];
    final uPlane = image.planes[1];
    final vPlane = image.planes[2];

    final chromaWidth = (width + 1) ~/ 2;
    final chromaHeight = (height + 1) ~/ 2;
    final nv21 = Uint8List(width * height + 2 * chromaWidth * chromaHeight);

    // Luma: row-wise copy honoring bytesPerRow padding.
    int out = 0;
    for (int row = 0; row < height; row++) {
      nv21.setRange(out, out + width, yPlane.bytes, row * yPlane.bytesPerRow);
      out += width;
    }

    // Chroma: NV21 wants interleaved V,U pairs for each 2x2 block.
    final vPixelStride = vPlane.bytesPerPixel ?? 1;
    final uPixelStride = uPlane.bytesPerPixel ?? 1;
    for (int row = 0; row < chromaHeight; row++) {
      for (int col = 0; col < chromaWidth; col++) {
        final vIndex = row * vPlane.bytesPerRow + col * vPixelStride;
        final uIndex = row * uPlane.bytesPerRow + col * uPixelStride;
        if (vIndex < vPlane.bytes.length && uIndex < uPlane.bytes.length) {
          nv21[out++] = vPlane.bytes[vIndex];
          nv21[out++] = uPlane.bytes[uIndex];
        }
      }
    }
    return nv21;
  }

  /// ML Kit's rotation enum has no degree-based factory in this version.
  static InputImageRotation _rotationFromDegrees(int degrees) {
    switch (degrees) {
      case 90:
        return InputImageRotation.rotation90deg;
      case 180:
        return InputImageRotation.rotation180deg;
      case 270:
        return InputImageRotation.rotation270deg;
      default:
        return InputImageRotation.rotation0deg;
    }
  }

  void _finish() {
    if (_done) return;
    _done = true;
    _watchdog?.cancel();
    final estimate = _model.estimate(List<FaceSignal>.unmodifiable(_signals));
    // Stop the stream before popping so no late frames call setState/pop.
    final controller = _controller;
    if (controller != null && controller.value.isStreamingImages) {
      controller.stopImageStream().catchError((_) {});
    }
    if (!mounted) return;
    Navigator.of(context).pop(estimate);
  }

  @override
  void dispose() {
    _done = true;
    _watchdog?.cancel();
    final controller = _controller;
    _controller = null;
    // Fire-and-forget teardown; the sheet is closing either way.
    () async {
      try {
        if (controller != null) {
          if (controller.value.isStreamingImages) await controller.stopImageStream();
          await controller.dispose();
        }
        await _detector?.close();
      } catch (_) {}
    }();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final progress = (_signals.length / FaceMoodModel.defaultFrameTarget).clamp(0.0, 1.0);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
        // Scrollable so diagnostics text can never overflow the sheet.
        child: SingleChildScrollView(
          child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              const Icon(Icons.face_retouching_natural, color: NivaraColors.accent, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text('Face mood assist',
                    style: TextStyle(
                        color: NivaraColors.textHi,
                        fontSize: 16,
                        fontWeight: FontWeight.w800)),
              ),
              IconButton(
                icon: Icon(Icons.close, color: NivaraColors.textLow),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ]),
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: SizedBox(
                height: 260,
                child: _buildCameraPreview(),
              ),
            ),
            const SizedBox(height: 12),
            LinearProgressIndicator(
              value: _error == null ? progress : 0,
              minHeight: 4,
              borderRadius: BorderRadius.circular(2),
              color: NivaraColors.accent,
              backgroundColor: NivaraColors.bg,
            ),
            const SizedBox(height: 10),
            Text(
              _error ??
                  (_signals.isEmpty
                      ? (_facesSeen > 0
                          ? 'Face found — reading signals…'
                          : 'Look at the camera — hold a natural expression')
                      : 'Reading signals… ${_signals.length}/${FaceMoodModel.defaultFrameTarget} frames'),
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: _error != null ? NivaraColors.danger : NivaraColors.textMid,
                  fontSize: 12.5),
            ),
            if (_error != null && _lastDetectionError != null)
              Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text(
                  'frames=$_framesSeen faces=$_facesSeen — $_lastDetectionError',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: NivaraColors.textLow, fontSize: 10),
                ),
              ),
            const SizedBox(height: 8),
            Row(children: [
              Icon(Icons.shield_outlined, size: 13, color: NivaraColors.textLow),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Processed in memory only — frames are never stored, uploaded, or synced.',
                  style: TextStyle(color: NivaraColors.textLow, fontSize: 10.5, height: 1.3),
                ),
              ),
            ]),
          ],
          ), // Column
        ), // SingleChildScrollView
      ), // Padding
    ); // SafeArea
  }

  Widget _buildCameraPreview() {
    final controller = _controller;
    if (_initializing || controller == null || !controller.value.isInitialized) {
      return Container(
        color: NivaraColors.bg,
        alignment: Alignment.center,
        child: SizedBox(
          width: 26,
          height: 26,
          child: CircularProgressIndicator(strokeWidth: 2.4),
        ),
      );
    }
    if (_error != null) {
      return Container(
        color: NivaraColors.bg,
        alignment: Alignment.center,
        padding: const EdgeInsets.all(16),
        child: Text(
          _error!,
          textAlign: TextAlign.center,
          style: TextStyle(color: NivaraColors.danger, fontSize: 12.5),
        ),
      );
    }
    return CameraPreview(controller);
  }
}
