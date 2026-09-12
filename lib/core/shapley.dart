/// Exact Shapley value computation for the 6-feature stress model.
///
/// This is real, game-theoretic XAI — not heuristic attribution:
/// for feature i,
///   phi_i = sum over coalitions S not containing i of
///           |S|! (n-|S|-1)! / n! * ( f(S ∪ {i}) − f(S) )
/// computed by explicitly evaluating the deployed model on every one of the
/// 2^6 = 64 coalitions (marginal-contribution form; exact for n <= 12).
///
/// A coalition replaces feature j with the model's *reference soldier*
/// (training-set median, exported by the training pipeline). Because f is
/// the very quantized TFLite graph that produced the score, the attribution
/// is consistent with the displayed number by construction.
///
/// All math is pure Dart — this file has no Flutter dependency and is unit
/// testable without a device.
library;

/// Index order matches the trained feature vector:
/// 0 mood 1-5 · 1 sleep hours · 2 readiness 1-5 · 3 night-patrol streak ·
/// 4 deployment days · 5 cancelled-leave flag.
const List<String> kStressFeatureNames = [
  'Mood',
  'Sleep',
  'Readiness',
  'Night patrols',
  'Deployment',
  'Lost leave',
];

/// Human-readable context lines used by the UI and the commander playbook.
const List<String> kStressFeatureDescriptions = [
  'self-reported mood',
  'hours of sleep',
  'physical readiness',
  'consecutive night patrols',
  'days deployed',
  'leave cancelled recently',
];

/// Exact Shapley attribution for one prediction.
///
/// [modelBatch] must evaluate a list of 6-dim feature rows through the
/// deployed model and return the stress index for each row, in order.
/// [instance] is the soldier's actual feature row.
/// [referencePoint] is the neutral soldier every coalition substitutes in.
Future<List<double>> exactShapleyValues({
  required Future<List<double>> Function(List<List<double>> rows) modelBatch,
  required List<double> instance,
  required List<double> referencePoint,
}) {
  final n = instance.length;
  assert(n == referencePoint.length);
  assert(n == kStressFeatureNames.length || n <= 12,
      'exact computation is exponential in n; keep feature count small');

  // Enumerate all 2^n coalitions as bitmasks and evaluate f(S) for each.
  final coalitionCount = 1 << n;
  final rows = List<List<double>>.generate(coalitionCount, (mask) {
    return List<double>.generate(n, (j) => (mask >> j & 1) == 1 ? instance[j] : referencePoint[j]);
  });

  return modelBatch(rows).then((values) {
    // Shapley coalition weights: w(|S|) = |S|! (n-|S|-1)! / n!
    double factorial(int m) {
      var f = 1.0;
      for (var k = 2; k <= m; k++) {
        f *= k;
      }
      return f;
    }

    final nFact = factorial(n);
    final weights = List<double>.generate(n + 1, (s) {
      // s = n-1 has (n-s-1)! = 0! = 1; s = n is never used (no joiner left).
      return factorial(s) * factorial(n - s - 1) / nFact;
    });

    final phi = List<double>.filled(n, 0.0);
    for (var mask = 0; mask < coalitionCount; mask++) {
      final fS = values[mask];
      for (var i = 0; i < n; i++) {
        final bit = 1 << i;
        if (mask & bit != 0) continue; // i must join S, not already be in it
        phi[i] += weights[_popcount(mask)] * (values[mask | bit] - fS);
      }
    }

    // Identity check: sum of attributions equals f(all) − f(none). Snap the
    // last feature so the invariant holds to float precision.
    final residual =
        (values[coalitionCount - 1] - values[0]) - phi.reduce((a, b) => a + b);
    if (phi.isNotEmpty) phi[phi.length - 1] += residual;
    return phi;
  });
}

int _popcount(int x) {
  var count = 0;
  while (x != 0) {
    x &= x - 1;
    count++;
  }
  return count;
}

/// One feature's contribution, formatted for the UI and the audit trail.
class ShapleyContribution {
  final int featureIndex;
  final String label;
  final double value; // points of stress index attributable to this feature

  ShapleyContribution({
    required this.featureIndex,
    required this.label,
    required this.value,
  });

  bool get isRisk => value > 0;
  bool get isProtective => value < 0;

  String get signedPoints =>
      '${value >= 0 ? '+' : ''}${value.toStringAsFixed(1)}';
}

/// Builds the commander-facing XAI summary from unit-wide attribution data.
/// Nothing here inspects identity — only pooled attribution sums.
String unitDriverSummary({
  required int logCount,
  required Map<String, double> meanAttributionByFeature,
  required double meanScore,
}) {
  if (logCount == 0 || meanAttributionByFeature.isEmpty) return '';
  final ranked = meanAttributionByFeature.entries.toList()
    ..sort((a, b) => b.value.abs().compareTo(a.value.abs()));

  final parts = <String>[];
  for (final e in ranked.take(2)) {
    if (e.value.abs() < 1.0) continue;
    parts.add(
        '${e.key} ${e.value >= 0 ? 'raises' : 'lowers'} the index by ${e.value.abs().toStringAsFixed(1)} pts on average');
  }
  if (parts.isEmpty) {
    return 'No dominant driver across $logCount logs — the average index of '
        '${meanScore.toStringAsFixed(0)} sits close to the neutral baseline.';
  }
  return 'Model-explained (Shapley) drivers across $logCount logs: ${parts.join('; ')}.';
}
