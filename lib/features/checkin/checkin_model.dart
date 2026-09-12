import 'dart:convert';

import 'package:nivara_app/core/ml_engine.dart';

/// A single check-in entry with the subjective inputs and the on-device
/// Edge-AI evaluation result (PRD §3.1), including the per-feature Shapley
/// attribution computed at inference time.
class CheckInEntry {
  final double moodScore;
  final double sleepHours;
  final double physicalReadiness;
  final int nightPatrolStreak;
  final int deploymentDays;
  final bool cancelledLeaveRecently;
  final double stressScore;

  /// Feature label → points of stress index (exact Shapley, on-device).
  final Map<String, double> attribution;

  final DateTime timestamp;

  CheckInEntry({
    required this.moodScore,
    required this.sleepHours,
    required this.physicalReadiness,
    required this.nightPatrolStreak,
    required this.deploymentDays,
    required this.cancelledLeaveRecently,
    required this.stressScore,
    this.attribution = const {},
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  StressLevel get level => classifyStress(stressScore);

  /// The strongest model-explained driver of this score, if attribution
  /// was stored with the entry (older rows may not have it).
  ({String label, double points})? get topDriver {
    if (attribution.isEmpty) return null;
    String? bestLabel;
    var bestAbs = 0.0;
    attribution.forEach((label, points) {
      if (points.abs() > bestAbs) {
        bestAbs = points.abs();
        bestLabel = label;
      }
    });
    if (bestLabel == null) return null;
    return (label: bestLabel!, points: attribution[bestLabel!]!);
  }

  factory CheckInEntry.fromMap(Map<String, dynamic> map) {
    Map<String, double> attribution = const {};
    final raw = map['attribution'];
    if (raw is String && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        attribution = decoded.map((k, v) =>
            MapEntry(k, v is num ? v.toDouble() : double.tryParse('$v') ?? 0.0));
      } catch (_) {
        // Legacy/malformed row: treat as unattributed.
      }
    }
    return CheckInEntry(
      moodScore: (map['mood'] as num?)?.toDouble() ?? 3.0,
      sleepHours: (map['sleep_hours'] as num?)?.toDouble() ??
          (map['sleep'] as num?)?.toDouble() ??
          7.0,
      physicalReadiness: (map['physical_readiness'] as num?)?.toDouble() ??
          (map['physical'] as num?)?.toDouble() ??
          3.0,
      nightPatrolStreak: (map['night_patrol_streak'] as num?)?.toInt() ?? 0,
      deploymentDays: (map['deployment_days'] as num?)?.toInt() ?? 0,
      cancelledLeaveRecently: (map['cancelled_leave'] as num?)?.toInt() == 1,
      stressScore: (map['stress_score'] as num?)?.toDouble() ?? 0.0,
      attribution: attribution,
      timestamp: DateTime.parse(map['timestamp'] as String),
    );
  }
}
