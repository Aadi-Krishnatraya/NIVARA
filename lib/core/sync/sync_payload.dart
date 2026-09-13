/// Anonymized sync payload for the NIVARA internal sync protocol
/// (nivara-sync/1 — see docs/sync_protocol.md §5).
///
/// What leaves the phone is a strict projection of what the Edge-AI engine
/// already computed at check-in time: the stress index (locally DP-noised),
/// the 6 coarsened model features, and the Shapley attribution map.
/// Identity, exact timestamps and raw inputs NEVER appear here.
library;

import 'dart:convert';
import 'dart:math';

/// Protocol version negotiated with the sync service.
const String kSyncProtocol = 'nivara-sync/1';

/// Coarsen a continuous feature to [step] grid steps (docs §5.3).
double coarsen(double value, double step) => (value / step).roundToDouble() * step;

/// A single anonymized contribution — one past check-in.
class SyncContribution {
  /// Fresh random id per check-in; the server can never link two windows.
  final String contributionId;

  /// Locally DP-noised stress index (Laplace, eps = 1.5 — see [localDpNoise]).
  final double stressIndex;

  /// The 6 coarsened model features (stressFeatures() projection).
  final Map<String, double> features;

  /// Per-check-in Shapley attribution (feature → points of stress).
  final Map<String, double> shapley;

  /// Day-granularity window labels — never the exact timestamp.
  final String windowStart;
  final String windowEnd;

  const SyncContribution({
    required this.contributionId,
    required this.stressIndex,
    required this.features,
    required this.shapley,
    required this.windowStart,
    required this.windowEnd,
  });

  Map<String, Object?> toJson() => {
        'contributionId': contributionId,
        'stressIndex': stressIndex,
        'features': features,
        'shapley': shapley,
        'windowStart': windowStart,
        'windowEnd': windowEnd,
      };
}

/// The full upload envelope for POST /sync/contribute.
class SyncPayload {
  final String protocol;
  final String unitId;
  final String windowId;
  final String windowNonce;
  final List<SyncContribution> contributions;

  const SyncPayload({
    required this.protocol,
    required this.unitId,
    required this.windowId,
    required this.windowNonce,
    required this.contributions,
  });

  Map<String, Object?> toJson() => {
        'protocol': protocol,
        'unitId': unitId,
        'windowId': windowId,
        'windowNonce': windowNonce,
        'contributions': contributions.map((c) => c.toJson()).toList(),
      };
}

/// Builder that turns local vault rows into the wire payload.
class SyncPayloadBuilder {
  final Random _random;

  SyncPayloadBuilder({Random? random}) : _random = random ?? Random.secure();

  /// Local differential privacy: one Laplace draw on the stress index,
  /// eps = 1.5, sensitivity 100 (index bounded [0, 100]). Mirrors
  /// DatabaseHelper.differentiallyPrivateAverage so the phone applies the
  /// same DP math before anything leaves the device (local layer).
  double localDpNoise(double index, {double epsilon = 1.5}) {
    final scale = 100 / epsilon;
    final u = (_random.nextDouble()) - 0.5;
    if (u == 0) return index.clamp(0.0, 100.0).toDouble();
    final noisy = index - scale * (u.isNegative ? -1 : 1) * log(1 - 2 * u.abs());
    return noisy.clamp(0.0, 100.0).toDouble();
  }

  /// Fresh random contribution id — never derived from userId or time.
  String _newContributionId() {
    final bytes = List<int>.generate(6, (_) => _random.nextInt(256));
    return 'c_${bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
  }

  /// Build one contribution from a vault check-in row (unsynced).
  SyncContribution contributionFromRow(Map<String, Object?> row) {
    final mood = coarsen((row['mood'] as num).toDouble(), 0.5);
    final sleepHours = coarsen((row['sleep_hours'] as num).toDouble(), 0.5);
    final selfReadiness = coarsen((row['physical_readiness'] as num).toDouble(), 0.5);
    final nightPatrolStreak = ((row['night_patrol_streak'] as num?) ?? 0).toDouble();
    final deploymentDays = coarsen(((row['deployment_days'] as num?) ?? 0).toDouble(), 5);
    final cancelledLeave = (((row['cancelled_leave'] as num?) ?? 0) == 0 ? 0.0 : 1.0);

    final ts = DateTime.parse(row['timestamp'] as String);
    final dayStart = DateTime.utc(ts.year, ts.month, ts.day);
    final dayEnd = dayStart.add(const Duration(days: 1)).subtract(const Duration(milliseconds: 1));

    Map<String, double> shapley = const {};
    final rawAttr = row['attribution'];
    if (rawAttr is String && rawAttr.isNotEmpty) {
      try {
        final decoded = (jsonDecode(rawAttr) as Map).cast<String, dynamic>();
        shapley = decoded.map((k, v) => MapEntry(k, (v as num).toDouble()));
      } catch (_) {
        // Malformed row — sync without attributions rather than fail.
      }
    }

    return SyncContribution(
      contributionId: _newContributionId(),
      stressIndex: localDpNoise((row['stress_score'] as num).toDouble()),
      features: {
        'mood': mood,
        'sleepHours': sleepHours,
        'selfReadiness': selfReadiness,
        'nightPatrolStreak': nightPatrolStreak,
        'deploymentDays': deploymentDays,
        'cancelledLeave': cancelledLeave,
      },
      shapley: shapley,
      windowStart: dayStart.toIso8601String(),
      windowEnd: dayEnd.toIso8601String(),
    );
  }

  SyncPayload buildPayload({
    required String unitId,
    required List<Map<String, Object?>> unsyncedRows,
  }) {
    final windowId = DateTime.now().toUtc().toIso8601String().slice(0, 10);
    final nonceBytes = List<int>.generate(8, (_) => _random.nextInt(256));
    final windowNonce = nonceBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return SyncPayload(
      protocol: kSyncProtocol,
      unitId: unitId.toUpperCase(),
      windowId: windowId,
      windowNonce: windowNonce,
      contributions: unsyncedRows.map(contributionFromRow).toList(),
    );
  }
}

extension on String {
  String slice(int start, int end) => substring(start, end < length ? end : length);
}
