import 'package:flutter/material.dart';

import 'package:nivara_app/core/ui_theme.dart';
import 'unit_forecast.dart';

/// Early-warning forecast widgets for the command portal. Unit aggregates
/// only — there is deliberately no per-soldier forecast surface anywhere.

/// Tint for a forecast tier on the board chip.
Color forecastTint(ForecastTier tier) => switch (tier) {
      ForecastTier.imminent => NivaraColors.danger,
      ForecastTier.watch => NivaraColors.orange,
      ForecastTier.stable => NivaraColors.good,
      ForecastTier.improving => NivaraColors.good,
      ForecastTier.alreadyHigh => NivaraColors.danger,
      ForecastTier.insufficient => NivaraColors.textLow,
    };

IconData forecastIcon(ForecastTier tier) => switch (tier) {
      ForecastTier.imminent => Icons.online_prediction_rounded,
      ForecastTier.watch => Icons.trending_up_rounded,
      ForecastTier.stable => Icons.trending_flat_rounded,
      ForecastTier.improving => Icons.trending_down_rounded,
      ForecastTier.alreadyHigh => Icons.priority_high_rounded,
      ForecastTier.insufficient => Icons.hourglass_empty_rounded,
    };

/// Compact chip for the Units Under Command card: "⚠ HIGH in ~2–3 days".
class ForecastChip extends StatelessWidget {
  final UnitForecast forecast;

  const ForecastChip({super.key, required this.forecast});

  @override
  Widget build(BuildContext context) {
    if (forecast.tier == ForecastTier.insufficient) return const SizedBox.shrink();
    final tint = forecastTint(forecast.tier);
    final label = switch (forecast.tier) {
      ForecastTier.imminent =>
        'HIGH in ~${forecast.bucketLabel}',
      ForecastTier.watch => 'HIGH in ~${forecast.bucketLabel}',
      ForecastTier.improving => 'improving',
      ForecastTier.stable => 'stable 14d',
      ForecastTier.alreadyHigh => 'HIGH now',
      ForecastTier.insufficient => '',
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(NivaraRadius.pill),
        border: Border.all(color: tint.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(forecastIcon(forecast.tier), size: 10, color: tint),
          const SizedBox(width: 3),
          Text(label,
              style: TextStyle(
                  color: tint,
                  fontSize: 9,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.4)),
        ],
      ),
    );
  }
}

/// Full forecast card for the unit details view: projection ribbon from the
/// DP average across the next 14 days with the HIGH-band line drawn in.
class ForecastCard extends StatelessWidget {
  final UnitForecast forecast;

  const ForecastCard({super.key, required this.forecast});

  @override
  Widget build(BuildContext context) {
    final tint = forecastTint(forecast.tier);
    return NivaraCard(
      border: forecast.showsRisk ? tint.withValues(alpha: 0.45) : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(
            icon: Icons.online_prediction_rounded,
            title: '72-Hour Early Warning',
            tint: tint,
            pill: 'unit aggregate · DP',
          ),
          const SizedBox(height: 6),
          Text(
            'Trend-fit projection of the anonymized daily aggregates. '
            'Computed on-device from unit-level data only — no individual '
            'trajectory is ever modeled.',
            style: TextStyle(
                color: NivaraColors.textLow, fontSize: 10.5, height: 1.4),
          ),
          const SizedBox(height: 14),
          _ribbon(),
          const SizedBox(height: 14),
          Row(
            children: [
              Icon(forecastIcon(forecast.tier), size: 15, color: tint),
              const SizedBox(width: 7),
              Expanded(
                child: Text(forecast.headline,
                    style: TextStyle(
                        color: tint,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w800,
                        height: 1.35)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              _stat('DP avg now', forecast.anchorScore.toStringAsFixed(0)),
              const SizedBox(width: 14),
              _stat('in 72h', forecast.projected72h.toStringAsFixed(0)),
              const SizedBox(width: 14),
              _stat('trend',
                  '${forecast.slopePerDay >= 0 ? '+' : ''}${forecast.slopePerDay.toStringAsFixed(1)}/day'),
              const Spacer(),
              Text(
                'HIGH band ≥ ${kHighBandThreshold.toStringAsFixed(0)}',
                style: TextStyle(color: NivaraColors.textLow, fontSize: 9.5),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 14-day projection ribbon: gradient bar from the DP average along the
  /// trend, with the HIGH-band threshold drawn as a dashed line.
  Widget _ribbon() {
    final danger = NivaraColors.danger;
    final start = forecast.anchorScore;
    final slope = forecast.slopePerDay;
    // Where the trajectory meets the HIGH line (for the marker).
    final cross = forecast.daysToCrossing;
    const span = 14.0;

    Widget bar(double day) {
      final v = (start + slope * day).clamp(0.0, 100.0);
      final tint = v >= 67
          ? danger
          : v >= 45
              ? NivaraColors.warn
              : NivaraColors.good;
      return Column(
        children: [
          Container(
            width: 9,
            height: 52 * (v / 100),
            decoration: BoxDecoration(
              color: tint.withValues(alpha: v >= 67 ? 0.85 : 0.45),
              borderRadius: BorderRadius.circular(3),
            ),
          ),
          const SizedBox(height: 4),
          Text('D$day'.replaceAll('.0', ''),
              style:
                  TextStyle(color: NivaraColors.textLow, fontSize: 8.5)),
        ],
      );
    }

    return SizedBox(
      height: 74,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (final day in const [0.0, 1.0, 2.0, 3.0, 7.0, 14.0])
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: bar(day),
            ),
          const Spacer(),
          if (cross != null && cross <= span)
            Column(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Icon(Icons.flag_rounded, size: 16, color: danger),
                Text('cross ~D${cross.toStringAsFixed(0)}',
                    style:
                        TextStyle(color: danger, fontSize: 8.5)),
              ],
            ),
        ],
      ),
    );
  }

  Widget _stat(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(value,
            style: TextStyle(
                color: NivaraColors.textHi,
                fontSize: 14,
                fontWeight: FontWeight.w800,
                height: 1)),
        const SizedBox(height: 2),
        Text(label,
            style: TextStyle(color: NivaraColors.textLow, fontSize: 9.5)),
      ],
    );
  }
}
