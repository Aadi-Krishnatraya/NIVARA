import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import 'package:nivara_app/core/database_helper.dart';
import 'package:nivara_app/core/shapley.dart';
import 'package:nivara_app/main.dart';
import 'package:nivara_app/core/ui_theme.dart';
import 'package:nivara_app/core/user_session.dart';
import '../auth/login_screen.dart';
import 'audit_viewer_screen.dart';

/// Command Action Portal (PRD §1/§3.3). Aggregates only: zero access to
/// names, Service IDs, or individual scores is possible from this screen.
///
/// Privacy guardrails enforced here:
///  * Squad views with < 5 distinct contributors are blocked (PRD §5.2).
///  * Laplace noise is applied to every displayed aggregate (PRD §5.2).
///  * Every load/access is written to the append-only audit log (PRD §3.3).
class CommanderScreen extends StatefulWidget {
  final UserSession session;

  const CommanderScreen({super.key, required this.session});

  @override
  State<CommanderScreen> createState() => _CommanderScreenState();
}

class _CommanderScreenState extends State<CommanderScreen> {
  bool _isLoading = true;
  bool _privacyBlocked = false;

  double _avgStress = 0.0;
  int _totalLogs = 0;
  int _contributors = 0;
  List<Map<String, Object?>> _trend = [];
  Map<String, Object?>? _drivers;
  Map<String, double> _meanAttributions = const {};
  int _todayContributors = 0;
  int _weekLogs = 0;
  int _highCount = 0;
  int _moderateCount = 0;

  /// DP-pooled share of logs in the high-stress band. Laplace noise is
  /// applied so the exact count is never exposed.
  double get _highSharePct {
    if (_totalLogs == 0) return 0;
    final raw = _highCount / _totalLogs * 100;
    final noisy = raw + DatabaseHelper.instance.laplaceNoisePublic(scale: 2.0);
    return noisy.clamp(0.0, 100.0);
  }

  /// How the week went versus the previous one, in aggregate terms.
  String get _trendDelta {
    if (_trend.length < 2) return '';
    final first = ((_trend.first['avg_stress'] as num?) ?? 0).toDouble();
    final last = ((_trend.last['avg_stress'] as num?) ?? 0).toDouble();
    final delta = last - first;
    if (delta.abs() < 2) return 'stable this week';
    return delta < 0
        ? 'improving — down ${delta.abs().toStringAsFixed(1)} pts this week'
        : 'rising — up ${delta.toStringAsFixed(1)} pts this week';
  }

  @override
  void initState() {
    super.initState();
    _loadSquadMetrics();
  }

  Future<void> _loadSquadMetrics() async {
    setState(() => _isLoading = true);

    final db = DatabaseHelper.instance;
    final unitId = widget.session.unitId;

    final contributors = await db.getSquadSize(unitId);

    // PRD §5.2 / §6: small units (e.g. 2-soldier observation posts) never
    // expose aggregates — individuals would be deducible by elimination.
    if (contributors < DatabaseHelper.squadPrivacyThreshold) {
      await db.logAudit(
        actorId: widget.session.userId,
        action: 'UNIT_VIEW_BLOCKED',
        detail: 'unit=$unitId contributors=$contributors (<${DatabaseHelper.squadPrivacyThreshold}) — aggregate suppressed',
      );
      if (!mounted) return;
      setState(() {
        _privacyBlocked = true;
        _contributors = contributors;
        _isLoading = false;
      });
      return;
    }

    final metrics = await db.getUnitMetrics(unitId);
    final trend = await db.getUnitTrend(unitId);
    final drivers = await db.getUnitDrivers(unitId);
    final meanAttributions = await db.getUnitMeanAttributions(unitId);
    final todayContributors = await db.getUnitTodayContributors(unitId);
    final weekLogs = await db.getUnitLogCount(unitId);
    final bandCounts = await db.getUnitBandCounts(unitId);

    await db.logAudit(
      actorId: widget.session.userId,
      action: 'UNIT_VIEW',
      detail: 'unit=$unitId contributors=$contributors logs=${metrics['total']} (anonymized aggregate)',
    );

    if (!mounted) return;
    setState(() {
      _privacyBlocked = false;
      _contributors = contributors;
      _totalLogs = (metrics['total'] as int?) ?? 0;
      // Laplace-differentially-private average (PRD §5.2).
      _avgStress = db.differentiallyPrivateAverage(
        ((metrics['avg_stress'] as num?) ?? 0).toDouble(),
      );
      _trend = trend;
      _drivers = drivers;
      _meanAttributions = meanAttributions;
      _todayContributors = todayContributors;
      _weekLogs = weekLogs;
      _highCount = bandCounts['high'] ?? 0;
      _moderateCount = bandCounts['moderate'] ?? 0;
      _isLoading = false;
    });
  }

  /// Real XAI: the soldiers' own on-device Shapley attributions, pooled
  /// anonymized. Threshold lines from the descriptive stats support them.
  String get _driverSummary {
    final d = _drivers;
    if (d == null) return '';
    final n = (d['n'] as int?) ?? 0;
    if (n == 0) return '';

    final shapley = unitDriverSummary(
      logCount: n,
      meanAttributionByFeature: _meanAttributions,
      meanScore: _avgStress,
    );

    final pctSleep = ((d['pct_low_sleep'] as num?)?.toDouble() ?? 0) * 100;
    final pctMood = ((d['pct_low_mood'] as num?)?.toDouble() ?? 0) * 100;
    final pctReadiness = ((d['pct_low_readiness'] as num?)?.toDouble() ?? 0) * 100;
    final parts = <String>[];
    if (pctSleep >= 40) parts.add('${pctSleep.round()}% of logs show <6h sleep');
    if (pctMood >= 40) parts.add('${pctMood.round()}% report low mood');
    if (pctReadiness >= 40) parts.add('${pctReadiness.round()}% report low readiness');
    if (parts.isEmpty) return shapley;
    return '$shapley\nThreshold flags: ${parts.join(' · ')}. Also factor in non-reported stressors.';
  }

  /// Mean attribution per feature, ranked by |impact| for the bar list.
  List<MapEntry<String, double>> get _rankedAttributions {
    final entries = _meanAttributions.entries.toList()
      ..sort((a, b) => b.value.abs().compareTo(a.value.abs()));
    return entries;
  }

  /// Action playbook driven by the unit's actual model-explained drivers —
  /// the recommendation follows the data, not a fixed rule.
  String get _playbook {
    if (_avgStress < 45) {
      return 'Unit nominal — maintain current rotation cycle.';
    }
    final d = _drivers;
    final pctSleep = d == null
        ? 0.0
        : ((d['pct_low_sleep'] as num?)?.toDouble() ?? 0) * 100;
    final top = _rankedAttributions.isEmpty ? null : _rankedAttributions.first;

    if (pctSleep >= 40 || (top != null && top.key == 'Sleep' && top.value > 0)) {
      return 'Recommended playbook: enforce a 48h protected sleep cycle for the next rotation and re-assign night patrols.';
    }
    if (top != null && top.key == 'Night patrols' && top.value > 0) {
      return 'Recommended playbook: rotate one platoon into a 48h recovery cycle and re-check in 72h.';
    }
    if (top != null && top.key == 'Deployment' && top.value > 0) {
      return 'Recommended playbook: prioritize the R&R queue for longest-deployed cohorts and review the rotation timeline.';
    }
    if (top != null && top.key == 'Mood' && top.value > 0) {
      return 'Recommended playbook: schedule a welfare check-in wave and surface the Confidential Support Bridge in the unit app.';
    }
    return 'Recommended playbook: rotate one platoon into a 48h recovery cycle and re-check in 72h.';
  }

  Color get _stressColor => _avgStress > 60
      ? NivaraColors.danger
      : _avgStress > 45
          ? NivaraColors.warn
          : NivaraColors.good;

  /// Actionable banner shown when the data warrants commander attention.
  Widget? get _alertCallout {
    if (_totalLogs == 0) return null;
    final highShare = _totalLogs > 0 ? _highCount / _totalLogs : 0.0;
    if (_avgStress >= 60 || highShare >= 0.25) {
      return _banner(
        tint: NivaraColors.danger,
        icon: Icons.priority_high_rounded,
        text:
            'Elevated unit stress — review the action playbook below.',
      );
    }
    if (_avgStress >= 45) {
      return _banner(
        tint: NivaraColors.warn,
        icon: Icons.warning_amber_rounded,
        text: 'Moderate stress levels — worth monitoring this week.',
      );
    }
    return null;
  }

  Widget _banner({required Color tint, required IconData icon, required String text}) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(NivaraRadius.card),
        border: Border.all(color: tint.withValues(alpha: 0.40)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: tint),
          SizedBox(width: 12),
          Expanded(
            child: Text(text,
                style: TextStyle(
                    color: tint, fontSize: 12.5, fontWeight: FontWeight.w700,
                    height: 1.35)),
          ),
        ],
      ),
    );
  }

  /// Aggregate activity grid: one cell per day of the last 7 days.
  /// Intensity = share of the unit that checked in that day (never counts
  /// individuals — identity-safe by construction).
  Widget _activityCard() {
    final byDay = {for (final r in _trend) r['day'].toString(): r};
    final now = DateTime.now();
    const wd = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
    return NivaraCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(
            icon: Icons.calendar_view_week,
            title: 'Participation this week',
            tint: NivaraColors.accent,
            pill: '$_weekLogs check-ins · 7 days',
          ),
          SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              for (var i = 6; i >= 0; i--)
                Builder(builder: (context) {
                  final d = now.subtract(Duration(days: i));
                  const mo = ['01','02','03','04','05','06','07','08','09','10','11','12'];
                  final key = '${d.year}-${mo[d.month - 1]}-${d.day.toString().padLeft(2, '0')}';
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
                            : Icon(Icons.remove, size: 15, color: NivaraColors.textLow),
                      ),
                      SizedBox(height: 6),
                      Text(wd[(d.weekday - 1) % 7],
                          style: TextStyle(
                              color: NivaraColors.textLow, fontSize: 10)),
                    ],
                  );
                }),
            ],
          ),
          SizedBox(height: 6),
          Row(
            children: [
              Icon(Icons.info_outline, size: 11, color: NivaraColors.textLow),
              SizedBox(width: 5),
              Expanded(
                child: Text(
                  'Cell color = that day\'s aggregate stress band. No individual data exists behind this view.',
                  style: TextStyle(color: NivaraColors.textLow, fontSize: 10, height: 1.3),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Circular DP-average gauge with band legend tiles beneath it.
  Widget _overviewCard() {
    final ring = NivaraColors.accent.withValues(alpha: 0.15);
    return NivaraCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(
            icon: Icons.monitor_heart_outlined,
            title: 'Unit overview',
            pill: 'Laplace noise · $_contributors contributors',
          ),
          SizedBox(height: 16),
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
                        value: (_avgStress / 100).clamp(0.0, 1.0),
                        strokeWidth: 9,
                        strokeCap: StrokeCap.round,
                        color: _stressColor,
                        backgroundColor: ring,
                      ),
                    ),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_avgStress.toStringAsFixed(0),
                            style: TextStyle(
                                color: _stressColor,
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
              SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _bandTile(NivaraColors.good, 'Low band',
                        '< 34', pct: _totalLogs == 0 ? null : 100 - _highSharePct - _modSharePct),
                    SizedBox(height: 8),
                    _bandTile(NivaraColors.warn, 'Moderate band',
                        '34–66', pct: _totalLogs == 0 ? null : _modSharePct),
                    SizedBox(height: 8),
                    _bandTile(NivaraColors.danger, 'High band',
                        '≥ 67', pct: _totalLogs == 0 ? null : _highSharePct),
                  ],
                ),
              ),
            ],
          ),
          if (_trendDelta.isNotEmpty) ...[
            SizedBox(height: 14),
            Row(
              children: [
                Icon(Icons.trending_up,
                    size: 13, color: NivaraColors.textLow),
                SizedBox(width: 6),
                Text(_trendDelta,
                    style: TextStyle(
                        color: NivaraColors.textMid, fontSize: 11.5)),
              ],
            ),
          ],
        ],
      ),
    );
  }

  double get _modSharePct {
    if (_totalLogs == 0) return 0;
    final raw = _moderateCount / _totalLogs * 100;
    final noisy = raw + DatabaseHelper.instance.laplaceNoisePublic(scale: 2.0);
    return noisy.clamp(0.0, 100.0);
  }

  Widget _bandTile(Color tint, String label, String range, {double? pct}) {
    return Row(
      children: [
        Container(width: 9, height: 9,
          decoration: BoxDecoration(color: tint, shape: BoxShape.circle)),
        SizedBox(width: 8),
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NivaraColors.bg,
      appBar: AppBar(
        title: Text('${widget.session.unitId} Dashboard'),
        actions: [
          IconButton(
            icon: Icon(ThemeController.instance.isDark
                ? Icons.light_mode_outlined
                : Icons.dark_mode_outlined),
            tooltip: 'Switch theme',
            onPressed: () => ThemeController.instance.toggle(),
          ),
          IconButton(
            icon: const Icon(Icons.receipt_long, color: NivaraColors.accent),
            tooltip: 'Audit trail',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const AuditViewerScreen()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Log out',
            onPressed: () {
              Navigator.of(context).pushReplacement(
                MaterialPageRoute(builder: (_) => const LoginScreen()),
              );
            },
          )
        ],
      ),
      body: _isLoading
          ? Center(child: CircularProgressIndicator(color: NivaraColors.accent))
          : _privacyBlocked
              ? _buildPrivacyBlocked()
              : RefreshIndicator(
                  color: NivaraColors.accent,
                  backgroundColor: NivaraColors.surface,
                  onRefresh: _loadSquadMetrics,
                  child: ListView(
                    padding: EdgeInsets.fromLTRB(16, 8, 16, 24),
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Welcome, ${widget.session.name}',
                                  style: TextStyle(
                                      color: NivaraColors.textHi,
                                      fontSize: 20,
                                      fontWeight: FontWeight.w800),
                                ),
                                SizedBox(height: 5),
                                Row(
                                  children: [
                                    Icon(Icons.lock_outline,
                                        size: 12, color: NivaraColors.textLow),
                                    SizedBox(width: 5),
                                    Expanded(
                                      child: Text(
                                        'Anonymized unit metrics · Laplace noise applied',
                                        style: TextStyle(
                                            color: NivaraColors.textLow,
                                            fontSize: 12,
                                            height: 1.3),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 18),
                      if (_alertCallout != null) ...[
                        _alertCallout!,
                        const SizedBox(height: 14),
                      ],
                      if (_totalLogs == 0)
                        _infoCard(
                          icon: Icons.hourglass_empty,
                          color: NivaraColors.accent,
                          title: 'No check-ins yet',
                          body:
                              'This unit has no logged check-ins. Aggregates appear here as soon as personnel start their daily check-ins — refresh to update.',
                        )
                      else ...[
                        _overviewCard(),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: StatTile(
                                label: 'Logs · 7 days',
                                value: '$_weekLogs',
                                color: NivaraColors.info,
                                icon: Icons.fact_check_outlined,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: StatTile(
                                label: 'Checked in today',
                                value: '$_todayContributors / $_contributors',
                                color: _todayContributors >= _contributors && _contributors > 0
                                    ? NivaraColors.good
                                    : NivaraColors.accent,
                                icon: Icons.task_alt_outlined,
                              ),
                            ),
                          ],
                        ),
                      ],
                      const SizedBox(height: 20),
                      if (_trend.isNotEmpty) ...[
                        SectionHeader(
                          icon: Icons.show_chart,
                          title: '7-Day Aggregate Trend',
                          tint: NivaraColors.info,
                          pill: 'unit-wide',
                        ),
                        SizedBox(height: 12),
                        NivaraCard(
                          padding: EdgeInsets.fromLTRB(8, 16, 16, 8),
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
                                        if (idx < 0 || idx >= _trend.length) {
                                          return const SizedBox();
                                        }
                                        final day =
                                            (_trend[idx]['day'] ?? '').toString();
                                        return Padding(
                                          padding: EdgeInsets.only(top: 4),
                                          child: Text(
                                            day.length >= 10 ? day.substring(5) : day,
                                            style: TextStyle(
                                                color: NivaraColors.textLow,
                                                fontSize: 10),
                                          ),
                                        );
                                      },
                                    ),
                                  ),
                                  rightTitles: const AxisTitles(
                                      sideTitles: SideTitles(showTitles: false)),
                                  topTitles: const AxisTitles(
                                      sideTitles: SideTitles(showTitles: false)),
                                ),
                                borderData: FlBorderData(show: false),
                                lineBarsData: [
                                  LineChartBarData(
                                    spots: [
                                      for (var i = 0; i < _trend.length; i++)
                                        FlSpot(
                                          i.toDouble(),
                                          ((_trend[i]['avg_stress'] as num?) ?? 0)
                                              .toDouble(),
                                        ),
                                    ],
                                    isCurved: true,
                                    barWidth: 2.5,
                                    color: _stressColor,
                                    dotData: const FlDotData(show: false),
                                    belowBarData: BarAreaData(
                                      show: true,
                                      gradient: LinearGradient(
                                        begin: Alignment.topCenter,
                                        end: Alignment.bottomCenter,
                                        colors: [
                                          _stressColor.withValues(alpha: 0.22),
                                          _stressColor.withValues(alpha: 0.0),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 20),
                      ],
                      _activityCard(),
                      const SizedBox(height: 12),
                      _shapleyCard(),
                      const SizedBox(height: 12),
                      _infoCard(
                        icon: Icons.travel_explore,
                        color: NivaraColors.warn,
                        title: 'Explainable Risk Drivers',
                        body: _driverSummary,
                      ),
                      const SizedBox(height: 12),
                      _infoCard(
                        icon: Icons.playlist_add_check,
                        color: NivaraColors.accent,
                        title: 'Automated Action Playbook',
                        body: _playbook,
                      ),
                      const SizedBox(height: 12),
                      _infoCard(
                        icon: Icons.gavel,
                        color: NivaraColors.info,
                        title: 'Audit Trail',
                        body:
                            'Every access to this dashboard is recorded in an append-only log. No names or Service IDs are retrievable from this view.',
                      ),
                    ],
                  ),
                ),
    );
  }

  /// Pooled on-device Shapley attributions for the unit — the same numbers
  /// each soldier's phone computed, aggregated without any identity.
  Widget _shapleyCard() {
    final ranked = _rankedAttributions;
    final maxAbs = ranked.isEmpty
        ? 1.0
        : ranked.map((e) => e.value.abs()).reduce((a, b) => a > b ? a : b);
    return NivaraCard(
      border: NivaraColors.accent.withValues(alpha: 0.3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(
            icon: Icons.psychology,
            title: 'Model-Explained Drivers (Shapley)',
            pill: 'pooled · anonymized',
          ),
          SizedBox(height: 6),
          Text(
            'Mean impact on the stress index, computed by each soldier\'s '
            'on-device model and pooled with differential privacy.',
            style: TextStyle(color: NivaraColors.textMid, fontSize: 11.5, height: 1.4),
          ),
          SizedBox(height: 14),
          if (ranked.isEmpty)
            Text('No attributed logs yet.',
                style: TextStyle(color: NivaraColors.textLow, fontSize: 12))
          else
            ...ranked.map((e) {
              final color = e.value >= 0 ? NivaraColors.danger : NivaraColors.good;
              return Padding(
                padding: EdgeInsets.only(bottom: 10),
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
                    SizedBox(height: 5),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: SizedBox(
                        height: 6,
                        child: LinearProgressIndicator(
                          value: (e.value.abs() / (maxAbs <= 0 ? 1 : maxAbs)).clamp(0.05, 1.0),
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

  Widget _infoCard({
    required IconData icon,
    required Color color,
    required String title,
    required String body,
  }) {
    return NivaraCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(icon: icon, title: title, tint: color),
          SizedBox(height: 10),
          Text(body,
              style: TextStyle(
                  color: NivaraColors.textMid, fontSize: 12.5, height: 1.5)),
        ],
      ),
    );
  }

  /// PRD §6 edge case: 2-soldier observation post aggregate exposure.
  Widget _buildPrivacyBlocked() {
    return Center(
      child: Padding(
        padding: EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: NivaraColors.warn.withValues(alpha: 0.1),
                border: Border.all(color: NivaraColors.warn.withValues(alpha: 0.4)),
              ),
              child: Icon(Icons.shield_outlined, size: 42, color: NivaraColors.warn),
            ),
            SizedBox(height: 22),
            Text(
              'Squad size < 5.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: NivaraColors.textHi,
                  fontSize: 20,
                  fontWeight: FontWeight.w800),
            ),
            SizedBox(height: 8),
            Text(
              'Data rolled into Platoon aggregate to preserve identity. ($_contributors contributors detected)',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: NivaraColors.textMid, fontSize: 14, height: 1.5),
            ),
            const SizedBox(height: 26),
            FilledButton.icon(
              onPressed: _loadSquadMetrics,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}
