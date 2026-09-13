/// On-device face-mood assist model (check-in "Face Mood" feature).
///
/// Pure logic layer: maps ML Kit face classifications (smiling probability,
/// left/right eye-open probability, head Euler angles) to a suggested mood on
/// the app's existing 1–5 scale. No camera, no platform code, no I/O — fully
/// unit-testable and deterministic apart from the optional hysteresis seed.
///
/// Privacy contract (mirrors the Edge-AI stance, PRD §5.2):
///  * frames exist only in memory inside the capture sheet and are never
///    written to disk, never uploaded, never included in any sync payload;
///  * only the resulting scalar suggestion is offered to the user, who stays
///    in control of the final value (the slider is never force-set).
library;

/// Classification snapshot for one camera frame.
class FaceSignal {
  /// ML Kit `smilingProbability` (0..1); null when the face landmark is
  /// unavailable in this frame.
  final double? smilingProbability;

  /// ML Kit `leftEyeOpenProbability` + `rightEyeOpenProbability` (0..1).
  final double? leftEyeOpenProbability;
  final double? rightEyeOpenProbability;

  /// Head pose (degrees). |rotZ| beyond ~20° suggests a strained posture.
  final double? headEulerAngleZ;

  const FaceSignal({
    this.smilingProbability,
    this.leftEyeOpenProbability,
    this.rightEyeOpenProbability,
    this.headEulerAngleZ,
  });

  /// Composite eye-openness (0..1), averaging the eyes that reported.
  double? get eyeOpenProbability {
    final values = [
      leftEyeOpenProbability,
      rightEyeOpenProbability,
    ].whereType<double>().toList();
    if (values.isEmpty) return null;
    return values.reduce((a, b) => a + b) / values.length;
  }

  /// True when this frame carries a usable smile/eye signal.
  bool get isUsable =>
      (smilingProbability != null || eyeOpenProbability != null);
}

/// Result of scoring one or more frames.
class MoodEstimate {
  /// Suggested mood on the check-in scale (1..5), rounded to 0.5 steps.
  final double suggestedMood;

  /// 0..1 confidence — how strongly the frames agreed.
  final double confidence;

  /// Short, judge-friendly explanation of what drove the suggestion.
  final String rationale;

  const MoodEstimate({
    required this.suggestedMood,
    required this.confidence,
    required this.rationale,
  });
}

/// Weighted signal → mood mapping (tuned so a neutral resting face lands
/// near the slider's midpoint, matching the 1–5 anchor semantics).
class FaceMoodModel {
  /// Weight of the smile signal relative to eye/posture signals. Smiling is
  /// the dominant expression channel; eyes act as a fatigue modifier.
  static const double smileWeight = 0.75;

  /// Weight of the eye-openness signal (fatigue proxy) — the remainder.
  static const double eyeWeight = 1.0 - smileWeight;

  /// Head-tilt penalty applied on top of the blended score (0..1 scale).
  static const double posturePenaltyMax = 0.15;

  /// Number of frames aggregated before a suggestion is offered.
  static const int defaultFrameTarget = 5;

  /// Map one frame to a 1..5 mood value (before aggregation).
  ///
  /// Signal semantics:
  ///  * smile 0 → exhausted end of the scale; smile 1 → excellent;
  ///  * eyes fully open → alert (nudges up); heavy droop → fatigued;
  ///  * strong head tilt strains the estimate slightly downward.
  double frameMood(FaceSignal signal) {
    double score = 0.5; // start at the neutral midpoint

    final smile = signal.smilingProbability;
    if (smile != null) {
      score += smileWeight * (smile - 0.5);
    }

    final eyes = signal.eyeOpenProbability;
    if (eyes != null) {
      // Open eyes nudge up, droopy eyes nudge down — gentler than smile.
      score += eyeWeight * 0.5 * (eyes - 0.5);
    }

    final tilt = signal.headEulerAngleZ?.abs();
    if (tilt != null && tilt > 20) {
      final penalty = posturePenaltyMax * ((tilt - 20).clamp(0, 60) / 60);
      score -= penalty;
    }

    // Blend back into the 1..5 scale: neutral (0.5) → 3.0.
    final mood = 1.0 + score * 4.0;
    return mood.clamp(1.0, 5.0).toDouble();
  }

  /// Aggregate [frames] into a single suggestion on the app's 0.5 grid.
  ///
  /// Uses the median frame mood (robust to single-frame blink/smile noise),
  /// then rounds to 0.5 steps like the coarsening used elsewhere in the app.
  /// Confidence grows with usable frames and inter-frame agreement.
  MoodEstimate estimate(List<FaceSignal> frames) {
    final usable = frames.where((f) => f.isUsable).toList();
    if (usable.isEmpty) {
      return const MoodEstimate(
        suggestedMood: 3.0,
        confidence: 0,
        rationale: 'No usable face signal — set mood manually',
      );
    }

    final moods = usable.map(frameMood).toList()..sort();
    final median = moods[moods.length ~/ 2];

    // Agreement: share of frames within ±0.75 of the median.
    final agreeing =
        moods.where((m) => (m - median).abs() <= 0.75).length / moods.length;
    final coverage = (usable.length / defaultFrameTarget).clamp(0.0, 1.0);
    final confidence = (0.55 * agreeing + 0.45 * coverage).clamp(0.0, 1.0);

    // Grid: 0.5 steps across 1..5 (same granularity as the mood slider).
    final grid = ((median - 1.0) * 2).round() / 2 + 1.0;
    final suggested = grid.clamp(1.0, 5.0).toDouble();

    return MoodEstimate(
      suggestedMood: suggested,
      confidence: confidence,
      rationale: rationaleFor(usable, suggested),
    );
  }

  String rationaleFor(List<FaceSignal> frames, double suggested) {
    final smiles = frames
        .map((f) => f.smilingProbability)
        .whereType<double>()
        .toList();
    final eyes = frames.map((f) => f.eyeOpenProbability).whereType<double>().toList();
    final avgSmile =
        smiles.isEmpty ? null : smiles.reduce((a, b) => a + b) / smiles.length;
    final avgEyes = eyes.isEmpty ? null : eyes.reduce((a, b) => a + b) / eyes.length;

    final parts = <String>[];
    if (avgSmile != null) {
      parts.add(avgSmile >= 0.65
          ? 'clear smile detected'
          : avgSmile <= 0.25
              ? 'flat/strained expression'
              : 'neutral expression');
    }
    if (avgEyes != null) {
      parts.add(avgEyes <= 0.4 ? 'heavy eye fatigue' : 'eyes alert');
    }
    if (parts.isEmpty) return 'Estimated from face signals';
    return '${parts.join(', ')} → suggested mood ${suggested.toStringAsFixed(1)}';
  }
}
