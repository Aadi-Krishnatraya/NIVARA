import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import 'package:nivara_app/core/database_helper.dart';
import 'package:nivara_app/core/ml_engine.dart';
import 'package:nivara_app/core/ui_theme.dart';
import 'package:nivara_app/core/user_session.dart';
import 'package:nivara_app/features/checkin/checkin_model.dart';

/// Personal history view. Only the signed-in soldier's own rows are read —
/// this is the Confidential Troop Portal boundary (PRD §1).
class StressTrendsScreen extends StatefulWidget {
  final UserSession? session;

  const StressTrendsScreen({super.key, this.session});

  @override
  State<StressTrendsScreen> createState() => _StressTrendsScreenState();
}

class _StressTrendsScreenState extends State<StressTrendsScreen> {
  List<Map<String, Object?>> _checkIns = [];
  bool _isLoading = true;
  double? _avg;
  double? _trendDelta; // today vs previous 7-day average

  UserSession? get _session => widget.session;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    final userId = _session?.userId;
    if (userId == null) {
      setState(() {
        _isLoading = false;
        _checkIns = [];
      });
      return;
    }

    setState(() => _isLoading = true);

    try {
      final rows = await DatabaseHelper.instance.getCheckInsForUser(userId);
      if (!mounted) return;

      double? avg;
      double? delta;
      if (rows.isNotEmpty) {
        final scores = rows.map((r) => (r['stress_score'] as num).toDouble()).toList();
        avg = scores.reduce((a, b) => a + b) / scores.length;

        final now = DateTime.now();
        final todayScores = <double>[];
        final weekScores = <double>[];
        for (final r in rows) {
          final ts = DateTime.parse(r['timestamp'] as String);
          final score = (r['stress_score'] as num).toDouble();
          if (_sameDay(ts, now)) {
            todayScores.add(score);
          } else if (now.difference(ts).inDays <= 7) {
            weekScores.add(score);
          }
        }
        if (todayScores.isNotEmpty && weekScores.isNotEmpty) {
          final today = todayScores.reduce((a, b) => a + b) / todayScores.length;
          final week = weekScores.reduce((a, b) => a + b) / weekScores.length;
          delta = today - week;
        }
      }

      setState(() {
        _checkIns = rows;
        _avg = avg;
        _trendDelta = delta;
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('Error loading trend data: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  Color _bandColor(StressLevel level) => switch (level) {
        StressLevel.high => NivaraColors.danger,
        StressLevel.moderate => NivaraColors.warn,
        StressLevel.low => NivaraColors.good,
      };

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(
          child: CircularProgressIndicator(color: NivaraColors.accent));
    }

    if (_checkIns.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: NivaraColors.surfaceAlt,
                border: Border.all(color: NivaraColors.outline),
              ),
              child: Icon(Icons.show_chart, size: 40, color: NivaraColors.textLow),
            ),
            SizedBox(height: 18),
            Text(
              'No Check-In Data Yet',
              style: TextStyle(
                  color: NivaraColors.textHi,
                  fontSize: 17,
                  fontWeight: FontWeight.w700),
            ),
            SizedBox(height: 8),
            Text(
              'Submit a check-in to see your trends graph.',
              style: TextStyle(color: NivaraColors.textMid, fontSize: 13),
            ),
            const SizedBox(height: 20),
            OutlinedButton.icon(
              onPressed: _loadData,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Refresh'),
            ),
          ],
        ),
      );
    }

    final spots = <FlSpot>[];
    for (var i = 0; i < _checkIns.length; i++) {
      final score = (_checkIns[i]['stress_score'] as num).toDouble();
      spots.add(FlSpot(i.toDouble(), score));
    }
    final latest = _checkIns.last;
    final latestEntry = CheckInEntry.fromMap(Map<String, dynamic>.from(latest));
    final latestColor = _bandColor(latestEntry.level);
    final deltaText = _trendDelta == null
        ? '— vs 7-day avg'
        : '${_trendDelta! >= 0 ? '+' : ''}${_trendDelta!.toStringAsFixed(0)} vs 7-day avg';
    final deltaColor = _trendDelta == null
        ? NivaraColors.textLow
        : _trendDelta! > 2
            ? NivaraColors.danger
            : NivaraColors.good;

    return Padding(
      padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Stress & Wellness History',
                  style: TextStyle(
                      color: NivaraColors.textHi,
                      fontSize: 17,
                      fontWeight: FontWeight.w700),
                ),
              ),
              IconButton(
                icon: Icon(Icons.refresh, color: NivaraColors.accent, size: 20),
                tooltip: 'Refresh',
                onPressed: _loadData,
              ),
            ],
          ),
          SizedBox(height: 4),
          // Latest-score hero.
          Container(
            padding: EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: NivaraColors.surface,
              borderRadius: BorderRadius.circular(NivaraRadius.card),
              border: Border.all(color: latestColor.withValues(alpha: 0.4)),
            ),
            child: Row(
              children: [
                Text(
                  latestEntry.stressScore.toStringAsFixed(0),
                  style: TextStyle(
                    color: latestColor,
                    fontSize: 42,
                    fontWeight: FontWeight.w800,
                    height: 1,
                  ),
                ),
                SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('LATEST INDEX',
                          style: TextStyle(
                              color: NivaraColors.textLow,
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.8)),
                      const SizedBox(height: 3),
                      Text('${latestEntry.level.label} band',
                          style: TextStyle(
                              color: latestColor,
                              fontSize: 13,
                              fontWeight: FontWeight.w700)),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Container(
                      padding: EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                      decoration: BoxDecoration(
                        color: deltaColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(NivaraRadius.pill),
                      ),
                      child: Text(deltaText,
                          style: TextStyle(
                              color: deltaColor,
                              fontSize: 11.5,
                              fontWeight: FontWeight.w700)),
                    ),
                    SizedBox(height: 8),
                    Text(
                      'avg ${_avg!.toStringAsFixed(0)}',
                      style: TextStyle(
                          color: NivaraColors.textMid,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 200,
            child: LineChart(
              LineChartData(
                minY: 0,
                maxY: 100,
                gridData: FlGridData(
                  show: true,
                  drawVerticalLine: false,
                  horizontalInterval: 25,
                  getDrawingHorizontalLine: (v) => FlLine(
                    color: NivaraColors.outline,
                    strokeWidth: 1,
                  ),
                ),
                titlesData: FlTitlesData(
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      interval: 25,
                      reservedSize: 26,
                      getTitlesWidget: (v, _) => Text(
                        v.toInt().toString(),
                        style: TextStyle(color: NivaraColors.textLow, fontSize: 10),
                      ),
                    ),
                  ),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      interval: (_checkIns.length / 5).clamp(1, 5).toDouble().roundToDouble(),
                      getTitlesWidget: (v, _) {
                        final idx = v.toInt();
                        if (idx < 0 || idx >= _checkIns.length) return const SizedBox();
                        final ts = DateTime.parse(_checkIns[idx]['timestamp'] as String);
                        return Padding(
                          padding: EdgeInsets.only(top: 4),
                          child: Text(
                            '${ts.day}/${ts.month}',
                            style: TextStyle(color: NivaraColors.textLow, fontSize: 10),
                          ),
                        );
                      },
                    ),
                  ),
                  rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                ),
                borderData: FlBorderData(show: false),
                lineBarsData: [
                  LineChartBarData(
                    spots: spots,
                    isCurved: true,
                    barWidth: 2.5,
                    color: NivaraColors.accent,
                    dotData: FlDotData(show: false),
                    belowBarData: BarAreaData(
                      show: true,
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          NivaraColors.accent.withValues(alpha: 0.22),
                          NivaraColors.accent.withValues(alpha: 0.0),
                        ],
                      ),
                    ),
                  ),
                ],
                lineTouchData: LineTouchData(
                  touchTooltipData: LineTouchTooltipData(
                    getTooltipColor: (_) => NivaraColors.surfaceAlt,
                    getTooltipItems: (touched) => touched.map((spot) {
                      final idx = spot.x.toInt();
                      final ts = DateTime.parse(_checkIns[idx]['timestamp'] as String);
                      return LineTooltipItem(
                        '${spot.y.toStringAsFixed(0)} · ${ts.day}/${ts.month}',
                        TextStyle(
                            color: NivaraColors.textHi,
                            fontSize: 12,
                            fontWeight: FontWeight.w600),
                      );
                    }).toList(),
                  ),
                ),
              ),
            ),
          ),
          SizedBox(height: 18),
          Text(
            'Recent Records',
            style: TextStyle(
                color: NivaraColors.textHi,
                fontSize: 15,
                fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.only(bottom: 16),
              itemCount: _checkIns.length,
              itemBuilder: (context, index) {
                // Newest first in the list.
                final item = _checkIns[_checkIns.length - 1 - index];
                final entry = CheckInEntry.fromMap(Map<String, dynamic>.from(item));
                final ts = entry.timestamp;
                final color = _bandColor(entry.level);
                return Container(
                  margin: EdgeInsets.only(bottom: 8),
                  padding: EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: NivaraColors.surface,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: NivaraColors.outline),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: 0.13),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          entry.stressScore.toStringAsFixed(0),
                          style: TextStyle(
                              color: color,
                              fontSize: 16,
                              fontWeight: FontWeight.w800),
                        ),
                      ),
                      SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Text(
                                  '${entry.stressScore.toStringAsFixed(0)}/100',
                                  style: TextStyle(
                                      color: NivaraColors.textHi,
                                      fontSize: 13.5,
                                      fontWeight: FontWeight.w700),
                                ),
                                const SizedBox(width: 6),
                                Text(entry.level.label,
                                    style: TextStyle(
                                        color: color,
                                        fontSize: 10.5,
                                        fontWeight: FontWeight.w700,
                                        letterSpacing: 0.4)),
                              ],
                            ),
                            SizedBox(height: 2),
                            Text(
                              'Mood ${entry.moodScore.toStringAsFixed(1)} · Sleep ${entry.sleepHours.toStringAsFixed(1)}h · Readiness ${entry.physicalReadiness.toStringAsFixed(1)}'
                              '${entry.topDriver == null ? '' : '\nModel-explained: ${entry.topDriver!.label} ${entry.topDriver!.points >= 0 ? '+' : ''}${entry.topDriver!.points.toStringAsFixed(1)} pts'}',
                              style: TextStyle(
                                  color: NivaraColors.textMid, fontSize: 11.5, height: 1.35),
                            ),
                          ],
                        ),
                      ),
                      Text(
                        '${ts.day}/${ts.month}',
                        style: TextStyle(color: NivaraColors.textLow, fontSize: 11.5),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
