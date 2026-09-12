import 'package:flutter/material.dart';

import 'package:nivara_app/core/ui_theme.dart';

/// Condition model for the Units Under Command board.
///
/// A unit's condition is derived from its differentially-private aggregate
/// stress average: readiness = 100 − stress, banded into six labeled tiers
/// so the commander can triage at a glance. Pure logic — no DB or widget
/// code — so the tier mapping and worst-first ordering are unit-testable.

/// Graduated condition tiers, worst to best.
enum UnitCondition {
  critical,
  poor,
  needsAttention,
  fair,
  good,
  excellent,
  /// Unit has no (or too few) check-ins — condition unknown.
  unknown;

  /// Readiness thresholds: this tier's inclusive lower bound on the 0–100
  /// readiness scale (100 − stress). Bands are calibrated to the operational
  /// spec's example readings: 20% → Critical, 48% → Poor, 60% → Needs
  /// Attention, 72% → Fair, 88% → Good, 98% → Excellent.
  double get minReadiness => switch (this) {
        critical => 0,
        poor => 21,
        needsAttention => 55,
        fair => 70,
        good => 85,
        excellent => 95,
        unknown => 0,
      };

  Color get tint => switch (this) {
        critical => NivaraColors.danger,
        poor => NivaraColors.orange,
        needsAttention => NivaraColors.warn,
        fair => NivaraColors.warn,
        good => NivaraColors.good,
        excellent => NivaraColors.good,
        unknown => NivaraColors.textLow,
      };

  IconData get icon => switch (this) {
        critical => Icons.error_rounded,
        poor => Icons.report_problem_rounded,
        needsAttention => Icons.warning_amber_rounded,
        fair => Icons.info_outline_rounded,
        good => Icons.check_circle_outline_rounded,
        excellent => Icons.verified_outlined,
        unknown => Icons.help_outline_rounded,
      };

  String get label => switch (this) {
        critical => 'Critical',
        poor => 'Poor',
        needsAttention => 'Needs Attention',
        fair => 'Fair',
        good => 'Good',
        excellent => 'Excellent',
        unknown => 'No Data',
      };
}

/// Derives the condition tier from a readiness percentage (0–100).
UnitCondition conditionFromReadiness(double readiness) {
  final r = readiness.clamp(0.0, 100.0);
  return switch (r) {
    >= 95 => UnitCondition.excellent,
    >= 85 => UnitCondition.good,
    >= 70 => UnitCondition.fair,
    >= 55 => UnitCondition.needsAttention,
    > 20 => UnitCondition.poor,
    _ => UnitCondition.critical, // 0–20% readiness is critical
  };
}

/// Convenience wrapper: condition straight from the DP stress average.
UnitCondition conditionFromStress(double stressAvg) =>
    conditionFromReadiness(100 - stressAvg);

/// One aggregate row of the Units Under Command board. Everything on it is
/// a unit-level aggregate — no per-soldier identity is involved anywhere.
class UnitSummary {
  final String unitId;
  final int contributors;
  final int totalLogs;

  /// Differentially-private average stress (Laplace already applied).
  final double stressAvg;

  /// Units below the squad-privacy threshold are never displayed — the
  /// commander only sees that a suppressed unit exists (and can still see
  /// its own participation heartbeat), never its aggregate data.
  final bool privacySuppressed;

  /// Most recent check-in timestamp for the unit (null = none yet).
  final DateTime? lastCheckIn;

  /// Distinct contributors who checked in today.
  final int todayContributors;

  const UnitSummary({
    required this.unitId,
    required this.contributors,
    required this.totalLogs,
    required this.stressAvg,
    required this.privacySuppressed,
    required this.lastCheckIn,
    required this.todayContributors,
  });

  /// Readiness = 100 − DP stress average (PRD convention: lower stress is
  /// better). Unknown when there are no logs.
  double get readiness => totalLogs == 0 ? 0 : (100 - stressAvg).clamp(0.0, 100.0);

  UnitCondition get condition =>
      totalLogs == 0 ? UnitCondition.unknown : conditionFromStress(stressAvg);

  /// true when the unit's aggregate is visible and its condition is one of
  /// the two worst tiers.
  bool get needsImmediateAttention =>
      !privacySuppressed &&
      (condition == UnitCondition.critical || condition == UnitCondition.poor);
}

/// Sorts summaries worst-first: suppressed/unknown units hold the bottom of
/// the list (by name), visible units order by readiness ascending, ties
/// broken by last check-in (stale first) then unit id — deterministic.
int compareWorstFirst(UnitSummary a, UnitSummary b) {
  if (a.privacySuppressed != b.privacySuppressed) {
    return a.privacySuppressed ? 1 : -1;
  }
  if (a.privacySuppressed && b.privacySuppressed) {
    return a.unitId.compareTo(b.unitId);
  }
  if (a.totalLogs == 0 || b.totalLogs == 0) {
    if (a.totalLogs == 0 && b.totalLogs == 0) return a.unitId.compareTo(b.unitId);
    return a.totalLogs == 0 ? 1 : -1;
  }
  final byReadiness = a.readiness.compareTo(b.readiness);
  if (byReadiness != 0) return byReadiness;
  final aLast = a.lastCheckIn?.millisecondsSinceEpoch ?? 0;
  final bLast = b.lastCheckIn?.millisecondsSinceEpoch ?? 0;
  final byFreshness = aLast.compareTo(bLast);
  if (byFreshness != 0) return byFreshness;
  return a.unitId.compareTo(b.unitId);
}

/// Filters and orders a list of summaries per the commander's controls.
/// Default order is always worst-first; other orders are explicit choices.
List<UnitSummary> applyUnitFilters(
  List<UnitSummary> units, {
  String query = '',
  Set<UnitCondition> conditionFilter = const {},
  UnitSortOrder order = UnitSortOrder.worstFirst,
}) {
  final q = query.trim().toUpperCase();
  var out = units.where((u) {
    if (q.isNotEmpty && !u.unitId.toUpperCase().contains(q)) return false;
    if (conditionFilter.isNotEmpty && !conditionFilter.contains(u.condition)) {
      return false;
    }
    return true;
  }).toList();

  int cmp(UnitSummary a, UnitSummary b) => switch (order) {
        UnitSortOrder.worstFirst => compareWorstFirst(a, b),
        UnitSortOrder.nameAsc => a.unitId.compareTo(b.unitId),
        UnitSortOrder.readinessDesc =>
          (b.privacySuppressed == a.privacySuppressed)
              ? (b.totalLogs == 0 || a.totalLogs == 0)
                  ? compareWorstFirst(a, b)
                  : b.readiness.compareTo(a.readiness)
              : compareWorstFirst(a, b),
      };
  out.sort(cmp);
  return out;
}

enum UnitSortOrder { worstFirst, nameAsc, readinessDesc }
