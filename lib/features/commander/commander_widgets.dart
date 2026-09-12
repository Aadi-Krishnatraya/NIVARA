import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import 'package:nivara_app/core/database_helper.dart';
import 'package:nivara_app/core/ui_theme.dart';

/// Shared aggregate-building blocks for the command portal. Both the Units
/// Under Command overview and the per-unit details view render the exact
/// same cards, so the two surfaces can never drift apart visually.
///
/// Every widget here displays differentially-private aggregates only — no
/// widget accepts (or could render) per-soldier identity.

/// Color for a stress average on the 0–100 index.
Color stressBandColor(double stressAvg) => stressAvg > 60
    ? NivaraColors.danger
    : stressAvg > 45
        ? NivaraColors.warn
        : NivaraColors.good;

/// Actionable banner (elevated stress, moderate stress, …).
class CommanderBanner extends StatelessWidget {
  final Color tint;
  final IconData icon;
  final String text;

  const CommanderBanner({
    super.key,
    required this.tint,
    required this.icon,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(NivaraRadius.card),
        border: Border.all(color: tint.withValues(alpha: 0.40)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: tint),
          const SizedBox(width: 12),
          Expanded(
            child: Text(text,
                style: TextStyle(
                    color: tint,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    height: 1.35)),
          ),
        ],
      ),
    );
  }
}

/// Generic titled info card.
class CommanderInfoCard extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String body;

  const CommanderInfoCard({
    super.key,
    required this.icon,
    required this.color,
    required this.title,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    return NivaraCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(icon: icon, title: title, tint: color),
          const SizedBox(height: 10),
          Text(body,
              style: TextStyle(
                  color: NivaraColors.textMid, fontSize: 12.5, height: 1.5)),
        ],
      ),
    );
  }
}

/// Circular DP-average gauge with per-band share legend.
class CommanderOverviewCard extends StatelessWidget {
  final double stressAvg;
  final int totalLogs;
  final int contributors;
  final int highCount;
  final int moderateCount;
  final String? footnote;

  const CommanderOverviewCard({
    super.key,
    required this.stressAvg,
    required this.totalLogs,
    required this.contributors,
    required this.highCount,
    required this.moderateCount,
    this.footnote,
  });

  double _sharePct(int count) {
    if (totalLogs == 0) return 0;
    final raw = count / totalLogs * 100;
    // Laplace noise on displayed shares — same DP treatment as the average.
    final noisy = raw + DatabaseHelper.instance.laplaceNoisePublic(scale: 2.0);
    return noisy.clamp(0.0, 100.0);
  }

  @override
  Widget build(BuildContext context) {
    final color = stressBandColor(stressAvg);
    final highPct = totalLogs == 0 ? null : _sharePct(highCount);
    final modPct = totalLogs == 0 ? null : _sharePct(moderateCount);
    final lowPct = totalLogs == 0 ? null : (100 - highPct! - modPct!).clamp(0.0, 100.0);
    return NivaraCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(
            icon: Icons.monitor_heart_outlined,
            title: 'Aggregate overview',
            pill: 'Laplace noise · $contributors contributors',
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              SizedBox(
                width: 108,
                height: 108,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    SizedBox(
                      width: 108,
                      height: 108,
                      child: CircularProgressIndicator(
                        value: (stressAvg / 100).clamp(0.0, 1.0),
                        strokeWidth: 9,
                        strokeCap: StrokeCap.round,
                        color: color,
                        backgroundColor: NivaraColors.accent.withValues(alpha: 0.15),
                      ),
                    ),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(stressAvg.toStringAsFixed(0),
                            style: TextStyle(
                                color: color,
                                fontSize: 30,
                                fontWeight: FontWeight.w800,
                                height: 1)),
                        Text('/ 100 DP avg',
                            style: TextStyle(
                                color: NivaraColors.textLow, fontSize: 9)),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _bandTile(NivaraColors.good, 'Low band', '< 34', pct: lowPct),
                    const SizedBox(height: 8),
                    _bandTile(NivaraColors.warn, 'Moderate band', '34–66', pct: modPct),
                    const SizedBox(height: 8),
                    _bandTile(NivaraColors.danger, 'High band', '≥ 67', pct: highPct),
                  ],
                ),
              ),
            ],
          ),
          if (footnote != null) ...[
            const SizedBox(height: 14),
            Row(
              children: [
                Icon(Icons.trending_up, size: 13, color: NivaraColors.textLow),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(footnote!,
                      style: TextStyle(
                          color: NivaraColors.textMid, fontSize: 11.5)),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _bandTile(Color tint, String label, String range, {double? pct}) {
    return Row(
      children: [
        Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(color: tint, shape: BoxShape.circle)),
        const SizedBox(width: 8),
        Expanded(
          child: Text('$label ($range)',
              style: TextStyle(color: NivaraColors.textMid, fontSize: 11.5)),
        ),
        Text(pct == null ? '—' : '${pct.toStringAsFixed(0)}%',
            style: TextStyle(
                color: tint, fontSize: 12, fontWeight: FontWeight.w800)),
      ],
    );
  }
}

/// 7-day line chart of the unit's aggregate stress.
class CommanderTrendCard extends StatelessWidget {
  final List<Map<String, Object?>> trend;
  final double stressAvg;

  const CommanderTrendCard({
    super.key,
    required this.trend,
    required this.stressAvg,
  });

  @override
  Widget build(BuildContext context) {
    if (trend.isEmpty) return const SizedBox.shrink();
    final color = stressBandColor(stressAvg);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          icon: Icons.show_chart,
          title: '7-Day Aggregate Trend',
          tint: NivaraColors.info,
          pill: 'unit-wide',
        ),
        const SizedBox(height: 12),
        NivaraCard(
          padding: const EdgeInsets.fromLTRB(8, 16, 16, 8),
          child: SizedBox(
            height: 180,
            child: LineChart(
              LineChartData(
                minY: 0,
                maxY: 100,
                gridData: FlGridData(
                  show: true,
                  drawVerticalLine: false,
                  horizontalInterval: 25,
                  getDrawingHorizontalLine: (v) => FlLine(
                    color: NivaraColors.outline.withValues(alpha: 0.5),
                    strokeWidth: 1,
                  ),
                ),
                titlesData: FlTitlesData(
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      interval: 25,
                      reservedSize: 28,
                      getTitlesWidget: (v, _) => Text(
                        v.toInt().toString(),
                        style: TextStyle(
                            color: NivaraColors.textLow, fontSize: 10),
                      ),
                    ),
                  ),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      getTitlesWidget: (v, _) {
                        final idx = v.toInt();
                        if (idx < 0 || idx >= trend.length) {
                          return const SizedBox();
                        }
                        final day = (trend[idx]['day'] ?? '').toString();
                        return Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            day.length >= 10 ? day.substring(5) : day,
                            style: TextStyle(
                                color: NivaraColors.textLow, fontSize: 10),
                          ),
                        );
                      },
                    ),
                  ),
                  rightTitles:
                      const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  topTitles:
                      const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                ),
                borderData: FlBorderData(show: false),
                lineBarsData: [
                  LineChartBarData(
                    spots: [
                      for (var i = 0; i < trend.length; i++)
                        FlSpot(
                          i.toDouble(),
                          ((trend[i]['avg_stress'] as num?) ?? 0).toDouble(),
                        ),
                    ],
                    isCurved: true,
                    barWidth: 2.5,
                    color: color,
                    dotData: const FlDotData(show: false),
                    belowBarData: BarAreaData(
                      show: true,
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          color.withValues(alpha: 0.22),
                          color.withValues(alpha: 0.0),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Aggregate participation grid: one cell per day of the last 7 days.
class CommanderActivityCard extends StatelessWidget {
  final List<Map<String, Object?>> trend;
  final int weekLogs;

  const CommanderActivityCard({
    super.key,
    required this.trend,
    required this.weekLogs,
  });

  @override
  Widget build(BuildContext context) {
    final byDay = {for (final r in trend) r['day'].toString(): r};
    final now = DateTime.now();
    const wd = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
    const mo = [
      '01', '02', '03', '04', '05', '06',
      '07', '08', '09', '10', '11', '12'
    ];
    return NivaraCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(
            icon: Icons.calendar_view_week,
            title: 'Participation this week',
            tint: NivaraColors.accent,
            pill: '$weekLogs check-ins · 7 days',
          ),
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              for (var i = 6; i >= 0; i--)
                Builder(builder: (context) {
                  final d = now.subtract(Duration(days: i));
                  final key =
                      '${d.year}-${mo[d.month - 1]}-${d.day.toString().padLeft(2, '0')}';
                  final row = byDay[key];
                  final stress = ((row?['avg_stress'] as num?) ?? 0).toDouble();
                  final active = row != null;
                  final Color cell;
                  if (!active) {
                    cell = NivaraColors.surfaceAlt;
                  } else if (stress >= 67) {
                    cell = NivaraColors.danger;
                  } else if (stress >= 34) {
                    cell = NivaraColors.warn;
                  } else {
                    cell = NivaraColors.good;
                  }
                  return Column(
                    children: [
                      Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          color: cell.withValues(alpha: active ? 0.30 : 1.0),
                          borderRadius: BorderRadius.circular(9),
                          border: Border.all(
                              color: active
                                  ? cell.withValues(alpha: 0.65)
                                  : NivaraColors.outline),
                        ),
                        child: active
                            ? Icon(Icons.check, size: 15, color: cell)
                            : Icon(Icons.remove,
                                size: 15, color: NivaraColors.textLow),
                      ),
                      const SizedBox(height: 6),
                      Text(wd[(d.weekday - 1) % 7],
                          style: TextStyle(
                              color: NivaraColors.textLow, fontSize: 10)),
                    ],
                  );
                }),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Icon(Icons.info_outline, size: 11, color: NivaraColors.textLow),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  'Cell color = that day\'s aggregate stress band. No individual data exists behind this view.',
                  style: TextStyle(
                      color: NivaraColors.textLow, fontSize: 10, height: 1.3),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Pooled on-device Shapley attributions for a unit.
class CommanderShapleyCard extends StatelessWidget {
  final Map<String, double> attributions;

  const CommanderShapleyCard({super.key, required this.attributions});

  @override
  Widget build(BuildContext context) {
    final ranked = attributions.entries.toList()
      ..sort((a, b) => b.value.abs().compareTo(a.value.abs()));
    final maxAbs = ranked.isEmpty
        ? 1.0
        : ranked.map((e) => e.value.abs()).reduce((a, b) => a > b ? a : b);
    return NivaraCard(
      border: NivaraColors.accent.withValues(alpha: 0.3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader(
            icon: Icons.psychology,
            title: 'Model-Explained Drivers (Shapley)',
            pill: 'pooled · anonymized',
          ),
          const SizedBox(height: 6),
          Text(
            'Mean impact on the stress index, computed by each soldier\'s '
            'on-device model and pooled with differential privacy.',
            style: TextStyle(
                color: NivaraColors.textMid, fontSize: 11.5, height: 1.4),
          ),
          const SizedBox(height: 14),
          if (ranked.isEmpty)
            Text('No attributed logs yet.',
                style: TextStyle(color: NivaraColors.textLow, fontSize: 12))
          else
            ...ranked.map((e) {
              final color =
                  e.value >= 0 ? NivaraColors.danger : NivaraColors.good;
              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(e.key,
                              style: TextStyle(
                                  color: NivaraColors.textHi,
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w600)),
                        ),
                        Text(
                            '${e.value >= 0 ? '+' : ''}${e.value.toStringAsFixed(1)} pts avg',
                            style: TextStyle(
                                color: color,
                                fontSize: 12,
                                fontWeight: FontWeight.w800)),
                      ],
                    ),
                    const SizedBox(height: 5),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: SizedBox(
                        height: 6,
                        child: LinearProgressIndicator(
                          value: (e.value.abs() / (maxAbs <= 0 ? 1 : maxAbs))
                              .clamp(0.05, 1.0),
                          color: color,
                          backgroundColor: NivaraColors.surfaceAlt,
                          minHeight: 6,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }),
        ],
      ),
    );
  }
}

/// PRD §5.2 edge case: suppressed aggregate (fewer than 5 contributors).
class CommanderPrivacyBlocked extends StatelessWidget {
  final int contributors;
  final String unitId;

  const CommanderPrivacyBlocked({
    super.key,
    required this.contributors,
    this.unitId = 'this unit',
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: NivaraColors.warn.withValues(alpha: 0.1),
                border:
                    Border.all(color: NivaraColors.warn.withValues(alpha: 0.4)),
              ),
              child:
                  Icon(Icons.shield_outlined, size: 42, color: NivaraColors.warn),
            ),
            const SizedBox(height: 22),
            Text(
              'Squad size < 5.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: NivaraColors.textHi,
                  fontSize: 20,
                  fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            Text(
              'Aggregates for $unitId are suppressed to preserve identity. '
              '($contributors contributors detected)',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: NivaraColors.textMid, fontSize: 14, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }
}

/// Pulsing attention dot for critical units — motion draws the eye without
/// relying on color alone (paired with the CRITICAL text label + icon).
class CriticalPulseDot extends StatefulWidget {
  final Color color;
  final double size;

  const CriticalPulseDot({super.key, required this.color, this.size = 9});

  @override
  State<CriticalPulseDot> createState() => _CriticalPulseDotState();
}

class _CriticalPulseDotState extends State<CriticalPulseDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 900))
        ..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween(begin: 0.25, end: 1.0).animate(
        CurvedAnimation(parent: _c, curve: Curves.easeInOut),
      ),
      child: Container(
        width: widget.size,
        height: widget.size,
        decoration:
            BoxDecoration(color: widget.color, shape: BoxShape.circle),
      ),
    );
  }
}
