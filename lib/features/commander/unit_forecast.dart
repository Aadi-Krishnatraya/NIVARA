/// 72-hour early-warning forecast for a UNIT's aggregate stress index.
///
/// PURE logic — no Flutter, no DB. The commander portal feeds it the unit's
/// daily aggregate series (day, avg, log-count) plus its differentially-
/// private average; the forecast fits a log-count-weighted linear trend and
/// projects when the aggregate index would cross the HIGH band (67).
///
/// Privacy posture (by design):
///  * Operates on unit aggregates ONLY — there is no API to forecast a
///    soldier; per-person trajectories are never computed anywhere.
///  * The caller injects a Laplace noise draw on the trend slope so the
///    projected trajectory carries the same DP treatment as every other
///    displayed aggregate.
///  * Crossing times are snapped to coarse buckets ("2–3 days") — precise
///    timing would imply more information than the operation needs.
library;

/// Tier labels for the projection outcome, worst to best.
enum ForecastTier {
  insufficient,
  improving,
  stable,
  watch,
  imminent,
  alreadyHigh,
}

/// One day of a unit's aggregate history.
class DailyPoint {
  final DateTime day;
  final double avg;

  /// Check-ins aggregated that day — used to weight the trend fit.
  final int logs;

  const DailyPoint({required this.day, required this.avg, this.logs = 1});
}

/// The HIGH-band edge of the stress index (PRD §3.1 bands).
const double kHighBandThreshold = 67;

class UnitForecast {
  final ForecastTier tier;

  /// Fitted (and DP-noised) trend, stress-index points per day.
  final double slopePerDay;

  /// Differentially-private average the projection starts from.
  final double anchorScore;

  /// Anchor + 3 days of trend, clamped to 0–100.
  final double projected72h;

  /// Projected days until the index crosses the HIGH band; null when no
  /// crossing is projected within the horizon (or already above it).
  final double? daysToCrossing;

  final String headline;

  /// Coarse crossing bucket ("2–3 days"); empty when not applicable.
  final String bucketLabel;

  final int historyDays;

  const UnitForecast({
    required this.tier,
    required this.slopePerDay,
    required this.anchorScore,
    required this.projected72h,
    required this.daysToCrossing,
    required this.headline,
    required this.bucketLabel,
    required this.historyDays,
  });

  /// True when the board should flag this unit on the early-warning chip.
  bool get showsRisk =>
      tier == ForecastTier.imminent || tier == ForecastTier.watch;
}

/// Coarse human bucket for a crossing time. Deliberately imprecise.
String crossingBucketLabel(double days) {
  if (days < 1.5) return '1 day';
  if (days < 3.5) return '2–3 days';
  if (days < 7) return '4–6 days';
  return '1–2 weeks';
}

/// Forecasts when [anchorScore] (the unit's DP average) plus the fitted
/// trend would cross the HIGH band within [horizonDays].
///
/// [noise] + [noiseScale]: optional Laplace draw applied to the fitted
/// slope so the projection itself is differentially private. Production
/// callers pass `DatabaseHelper.instance.laplaceNoisePublic`; tests pass
/// deterministic draws (or nothing).
UnitForecast computeUnitForecast({
  required List<DailyPoint> series,
  required double anchorScore,
  double horizonDays = 14,
  double noiseScale = 0,
  double Function({required double scale})? noise,
}) {
  final pts = [...series]..sort((a, b) => a.day.compareTo(b.day));
  final n = pts.length;

  if (n < 2) {
    return UnitForecast(
      tier: ForecastTier.insufficient,
      slopePerDay: 0,
      anchorScore: anchorScore,
      projected72h: anchorScore.clamp(0, 100),
      daysToCrossing: null,
      headline: 'Not enough daily aggregates to forecast yet',
      bucketLabel: '',
      historyDays: n,
    );
  }

  // Log-count-weighted least squares over days-since-first. Days with more
  // check-ins describe the unit's trajectory more reliably.
  final x0 = pts.first.day;
  final xs = [
    for (final p in pts) p.day.difference(x0).inMilliseconds / 86400000.0,
  ];
  final ws = [for (final p in pts) p.logs < 1 ? 1.0 : p.logs.toDouble()];
  final xBar = _weightedMean(xs, ws);
  final yBar = _weightedMean([for (final p in pts) p.avg], ws);
  var num = 0.0;
  var den = 0.0;
  for (var i = 0; i < n; i++) {
    num += ws[i] * (xs[i] - xBar) * (pts[i].avg - yBar);
    den += ws[i] * (xs[i] - xBar) * (xs[i] - xBar);
  }
  var slope = den > 0 ? num / den : 0.0;
  if (!slope.isFinite) slope = 0.0;
  if (noiseScale > 0 && noise != null) {
    slope += noise(scale: noiseScale);
  }
  // De-noise to 0.1 pts/day resolution; avoids implying spurious precision.
  slope = (slope * 10).roundToDouble() / 10;
  if (slope == -0.0) slope = 0;

  double proj(double days) => (anchorScore + slope * days).clamp(0.0, 100.0);
  final projected72h = proj(3);

  if (anchorScore >= kHighBandThreshold) {
    return UnitForecast(
      tier: ForecastTier.alreadyHigh,
      slopePerDay: slope,
      anchorScore: anchorScore,
      projected72h: projected72h,
      daysToCrossing: null,
      headline: 'Already in the HIGH band — recovery actions take priority',
      bucketLabel: '',
      historyDays: n,
    );
  }

  if (slope > 0) {
    final kStar = (kHighBandThreshold - anchorScore) / slope;
    if (kStar <= 3) {
      final bucket = crossingBucketLabel(kStar);
      return UnitForecast(
        tier: ForecastTier.imminent,
        slopePerDay: slope,
        anchorScore: anchorScore,
        projected72h: projected72h,
        daysToCrossing: kStar,
        headline: 'Projected to cross HIGH in ~$bucket — intervene now',
        bucketLabel: bucket,
        historyDays: n,
      );
    }
    if (kStar <= 7) {
      final bucket = crossingBucketLabel(kStar);
      return UnitForecast(
        tier: ForecastTier.watch,
        slopePerDay: slope,
        anchorScore: anchorScore,
        projected72h: projected72h,
        daysToCrossing: kStar,
        headline: 'On track to cross HIGH in ~$bucket',
        bucketLabel: bucket,
        historyDays: n,
      );
    }
    if (kStar <= horizonDays) {
      return _stable(slope, anchorScore, projected72h, n);
    }
  }

  // Falling or flat trend.
  if (slope < -0.5) {
    return UnitForecast(
      tier: ForecastTier.improving,
      slopePerDay: slope,
      anchorScore: anchorScore,
      projected72h: projected72h,
      daysToCrossing: null,
      headline:
          'Improving — index falling ${slope.abs().toStringAsFixed(1)} pts/day, no HIGH crossing projected',
      bucketLabel: '',
      historyDays: n,
    );
  }
  return _stable(slope, anchorScore, projected72h, n);
}

UnitForecast _stable(
    double slope, double anchor, double projected72h, int historyDays) {
  return UnitForecast(
    tier: ForecastTier.stable,
    slopePerDay: slope,
    anchorScore: anchor,
    projected72h: projected72h,
    daysToCrossing: null,
    headline: 'Projected to stay below HIGH for the next two weeks',
    bucketLabel: '',
    historyDays: historyDays,
  );
}

double _weightedMean(List<double> values, List<double> weights) {
  var sum = 0.0;
  var wSum = 0.0;
  for (var i = 0; i < values.length; i++) {
    sum += values[i] * weights[i];
    wSum += weights[i];
  }
  return wSum == 0 ? 0 : sum / wSum;
}
