import 'dart:async';

import 'package:flutter/material.dart';

import 'package:nivara_app/core/database_helper.dart';
import 'package:nivara_app/core/shapley.dart';
import 'package:nivara_app/main.dart';
import 'package:nivara_app/core/ui_theme.dart';
import 'package:nivara_app/core/user_session.dart';
import '../auth/login_screen.dart';
import 'audit_viewer_screen.dart';
import 'commander_widgets.dart';
import 'forecast_widgets.dart';
import 'unit_condition.dart';
import 'unit_details_screen.dart';
import 'unit_forecast.dart';

/// Command Action Portal (PRD §1/§3.3). Aggregates only: zero access to
/// names, Service IDs, or individual scores is possible from this screen.
///
/// Privacy guardrails enforced here:
///  * Squad views with < 5 distinct contributors are blocked (PRD §5.2).
///  * Laplace noise is applied to every displayed aggregate (PRD §5.2).
///  * Every load/access is written to the append-only audit log (PRD §3.3).
///
/// Units Under Command: the commander oversees every unit known on this
/// device. Units are auto-sorted worst condition → best so the critical
/// ones are always on top, with search/filter/scale controls for larger
/// formations.
class CommanderScreen extends StatefulWidget {
  final UserSession session;

  const CommanderScreen({super.key, required this.session});

  @override
  State<CommanderScreen> createState() => _CommanderScreenState();
}

class _CommanderScreenState extends State<CommanderScreen> {
  bool _isLoading = true;

  // ---- Own-unit dashboard state (unchanged semantics) ----
  bool _ownSuppressed = false;
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

  // ---- Units Under Command board state ----
  List<UnitSummary> _units = const [];
  List<UnitSummary> _suppressedUnits = const [];
  String _query = '';
  final Set<UnitCondition> _condFilter = {};
  UnitSortOrder _order = UnitSortOrder.worstFirst;
  Timer? _refreshTimer;

  // Early-warning forecasts, keyed by unit id. Unit aggregates only —
  // per-soldier trajectories are never computed anywhere in this app.
  Map<String, UnitForecast> _forecasts = const {};

  // Stable forecasts: the forecast's Laplace-noised slope must be a ONE-TIME
  // release per data version, not re-rolled on every 30s poll — otherwise
  // chips jitter ("HIGH in ~2–3 days" flipping to "stable") and averaging
  // observed releases could cancel the noise. Keyed by data version.
  final Map<String, String> _forecastKeyByUnit = {};
  final Map<String, UnitForecast> _forecastByKey = {};

  @override
  void initState() {
    super.initState();
    _loadSquadMetrics();
    // Near-real-time board: re-poll the vault periodically. Silent refresh —
    // no spinner, and no audit spam (a poll is not a "view").
    _refreshTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _loadSquadMetrics(audit: false, showSpinner: false),
    );
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadSquadMetrics({bool audit = true, bool showSpinner = true}) async {
    if (showSpinner) setState(() => _isLoading = true);

    final db = DatabaseHelper.instance;
    final unitId = widget.session.unitId;

    final contributors = await db.getSquadSize(unitId);

    if (contributors < DatabaseHelper.squadPrivacyThreshold) {
      // PRD §5.2 / §6: small units (e.g. 2-soldier observation posts) never
      // expose aggregates — individuals would be deducible by elimination.
      if (audit) {
        await db.logAudit(
          actorId: widget.session.userId,
          action: 'UNIT_VIEW_BLOCKED',
          detail:
              'unit=$unitId contributors=$contributors (<${DatabaseHelper.squadPrivacyThreshold}) — aggregate suppressed',
        );
      }
      if (!mounted) return;
      setState(() {
        _ownSuppressed = true;
        _contributors = contributors;
      });
    } else {
      final metrics = await db.getUnitMetrics(unitId);
      final trend = await db.getUnitTrend(unitId);
      final drivers = await db.getUnitDrivers(unitId);
      final meanAttributions = await db.getUnitMeanAttributions(unitId);
      final todayContributors = await db.getUnitTodayContributors(unitId);
      final weekLogs = await db.getUnitLogCount(unitId);
      final bandCounts = await db.getUnitBandCounts(unitId);

      if (audit) {
        await db.logAudit(
          actorId: widget.session.userId,
          action: 'UNIT_VIEW',
          detail:
              'unit=$unitId contributors=$contributors logs=${metrics['total']} (anonymized aggregate)',
        );
      }

      if (!mounted) return;
      setState(() {
        _ownSuppressed = false;
        _contributors = contributors;
        _totalLogs = (metrics['total'] as int?) ?? 0;
        // Laplace-differentially-private average (PRD §5.2), released once
        // per data version — polls never re-roll the displayed number.
        _avgStress = db.dpAverageStable(
          unitId,
          ((metrics['avg_stress'] as num?) ?? 0).toDouble(),
        );
        _trend = trend;
        _drivers = drivers;
        _meanAttributions = meanAttributions;
        _todayContributors = todayContributors;
        _weekLogs = weekLogs;
        _highCount = bandCounts['high'] ?? 0;
        _moderateCount = bandCounts['moderate'] ?? 0;
      });
    }

    await _loadUnits();
    if (!mounted) return;
    setState(() => _isLoading = false);
  }

  /// Builds the Units Under Command board from aggregate queries only.
  /// Every unit's displayed average carries its own Laplace draw, matching
  /// the per-unit dashboard's DP treatment.
  Future<void> _loadUnits() async {
    final db = DatabaseHelper.instance;
    final overview = await db.getAllUnitsOverview();
    final knownUnits = await db.getAllKnownUnitIds();
    final todayByUnit = await db.getTodayContributorsByUnit();

    final visible = <UnitSummary>[];
    final suppressed = <UnitSummary>[];
    final seen = <String>{};
    final forecasts = <String, UnitForecast>{};

    for (final r in overview) {
      final unit = (r['unit'] as String).toUpperCase();
      seen.add(unit);
      final contributors = (r['contributors'] as int?) ?? 0;
      final totalLogs = (r['total_logs'] as int?) ?? 0;
      final rawAvg = ((r['avg_stress'] as num?) ?? 0).toDouble();
      final lastTs = DateTime.tryParse((r['last_ts'] ?? '') as String);
      final isSuppressed = contributors < DatabaseHelper.squadPrivacyThreshold;
      final summary = UnitSummary(
        unitId: unit,
        contributors: contributors,
        totalLogs: totalLogs,
        stressAvg: totalLogs == 0
            ? 0
            : db.dpAverageStable(unit, rawAvg), // one release per data version
        privacySuppressed: isSuppressed,
        lastCheckIn: lastTs,
        todayContributors: todayByUnit[unit] ?? 0,
      );
      isSuppressed ? suppressed.add(summary) : visible.add(summary);

      if (!isSuppressed) {
        // Early warning per unit: DP trend over the daily aggregate series.
        // The noisy slope is a one-time release per data version — see the
        // cache fields — so silent polls never re-roll it.
        final series = await db.getUnitDailySeries(unit);
        final version =
            '$unit|${summary.stressAvg.toStringAsFixed(2)}|$totalLogs|${series.length}';
        final cachedKey = _forecastKeyByUnit[unit];
        if (cachedKey != null && cachedKey == version) {
          forecasts[unit] = _forecastByKey[cachedKey]!;
        } else {
          final f = computeUnitForecast(
            series: series,
            anchorScore: summary.stressAvg,
            noiseScale: 0.15,
            noise: db.laplaceNoisePublic,
          );
          if (_forecastByKey.length > 300) {
            _forecastByKey.clear();
            _forecastKeyByUnit.clear();
          }
          _forecastByKey[version] = f;
          _forecastKeyByUnit[unit] = version;
          forecasts[unit] = f;
        }
      }
    }

    // Units with registered personnel but no check-ins yet still belong on
    // the board (as "No Data") so nothing under command is invisible.
    for (final unit in knownUnits.where((u) => !seen.contains(u))) {
      final contributors = await db.getSquadSize(unit);
      final summary = UnitSummary(
        unitId: unit,
        contributors: contributors,
        totalLogs: 0,
        stressAvg: 0,
        privacySuppressed: contributors < DatabaseHelper.squadPrivacyThreshold,
        lastCheckIn: null,
        todayContributors: 0,
      );
      summary.privacySuppressed ? suppressed.add(summary) : visible.add(summary);
    }

    // The commander's own unit is always under command, even with no data.
    final own = widget.session.unitId.toUpperCase();
    if (!seen.contains(own) && !knownUnits.contains(own)) {
      suppressed.add(UnitSummary(
        unitId: own,
        contributors: 0,
        totalLogs: 0,
        stressAvg: 0,
        privacySuppressed: true,
        lastCheckIn: null,
        todayContributors: 0,
      ));
    }

    // Worst condition → best condition, always. Critical on top.
    visible.sort(compareWorstFirst);
    suppressed.sort((a, b) => a.unitId.compareTo(b.unitId));
    _units = visible;
    _suppressedUnits = suppressed;
    _forecasts = forecasts;
  }

  List<UnitSummary> get _filteredUnits => applyUnitFilters(
        _units,
        query: _query,
        conditionFilter: _condFilter,
        order: _order,
      );

  /// Early-warning forecast for the commander's own unit.
  UnitForecast? get _ownForecast {
    final f = _forecasts[widget.session.unitId.toUpperCase()];
    return f != null && f.tier != ForecastTier.insufficient ? f : null;
  }

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

  String get _playbook {
    if (_avgStress < 45) {
      return 'Unit nominal — maintain current rotation cycle.';
    }
    final d = _drivers;
    final pctSleep = d == null
        ? 0.0
        : ((d['pct_low_sleep'] as num?)?.toDouble() ?? 0) * 100;
    final ranked = _meanAttributions.entries.toList()
      ..sort((a, b) => b.value.abs().compareTo(a.value.abs()));
    final top = ranked.isEmpty ? null : ranked.first;

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

  Future<void> _openUnit(UnitSummary unit) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => UnitDetailsScreen(
          session: widget.session,
          unitId: unit.unitId,
        ),
      ),
    );
    // Returning from details: refresh the board (state may have changed).
    if (mounted) await _loadSquadMetrics(audit: false, showSpinner: false);
  }

  String _lastUpdateText(DateTime? ts) {
    if (ts == null) return 'no updates yet';
    final d = DateTime.now().difference(ts);
    if (d.inMinutes < 1) return 'updated just now';
    if (d.inHours < 1) return 'updated ${d.inMinutes}m ago';
    if (d.inDays < 1) return 'updated ${d.inHours}h ago';
    return 'updated ${d.inDays}d ago';
  }

  @override
  Widget build(BuildContext context) {
    // Full-screen privacy block ONLY when the commander's own unit is
    // suppressed AND no other unit's aggregates are visible — otherwise
    // multi-unit commanders would lose the whole portal over one small squad.
    final fullBlock = _ownSuppressed && _units.isEmpty;
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
              _refreshTimer?.cancel();
              Navigator.of(context).pushReplacement(
                MaterialPageRoute(builder: (_) => const LoginScreen()),
              );
            },
          )
        ],
      ),
      body: _isLoading
          ? Center(child: CircularProgressIndicator(color: NivaraColors.accent))
          : fullBlock
              ? _buildPrivacyBlocked()
              : RefreshIndicator(
                  color: NivaraColors.accent,
                  backgroundColor: NivaraColors.surface,
                  onRefresh: () => _loadSquadMetrics(),
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
                      _unitsBoard(),
                      const SizedBox(height: 20),
                      if (_ownSuppressed)
                        CommanderInfoCard(
                          icon: Icons.shield_outlined,
                          color: NivaraColors.warn,
                          title: 'Own unit aggregates held',
                          body:
                              '${widget.session.unitId} has fewer than ${DatabaseHelper.squadPrivacyThreshold} contributors, so its aggregates are suppressed (PRD §5.2). Participation is all that is shown.',
                        )
                      else ...[
                        if (_alertForOwnUnit != null) ...[
                          _alertForOwnUnit!,
                          const SizedBox(height: 14),
                        ],
                        if (_totalLogs == 0)
                          CommanderInfoCard(
                            icon: Icons.hourglass_empty,
                            color: NivaraColors.accent,
                            title: 'No check-ins yet',
                            body:
                                'This unit has no logged check-ins. Aggregates appear here as soon as personnel start their daily check-ins — refresh to update.',
                          )
                        else ...[
                          CommanderOverviewCard(
                            stressAvg: _avgStress,
                            totalLogs: _totalLogs,
                            contributors: _contributors,
                            highCount: _highCount,
                            moderateCount: _moderateCount,
                            footnote:
                                _trendDelta.isEmpty ? null : _trendDelta,
                            dpScope: widget.session.unitId,
                          ),
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
                                  value:
                                      '$_todayContributors / $_contributors',
                                  color: _todayContributors >= _contributors &&
                                          _contributors > 0
                                      ? NivaraColors.good
                                      : NivaraColors.accent,
                                  icon: Icons.task_alt_outlined,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 20),
                          if (_ownForecast != null) ...[
                            ForecastCard(forecast: _ownForecast!),
                            const SizedBox(height: 12),
                          ],
                          CommanderTrendCard(
                              trend: _trend, stressAvg: _avgStress),
                          const SizedBox(height: 20),
                          CommanderActivityCard(
                              trend: _trend, weekLogs: _weekLogs),
                          const SizedBox(height: 12),
                          CommanderShapleyCard(
                              attributions: _meanAttributions),
                          const SizedBox(height: 12),
                          CommanderInfoCard(
                            icon: Icons.travel_explore,
                            color: NivaraColors.warn,
                            title: 'Explainable Risk Drivers',
                            body: _driverSummary,
                          ),
                          const SizedBox(height: 12),
                          CommanderInfoCard(
                            icon: Icons.playlist_add_check,
                            color: NivaraColors.accent,
                            title: 'Automated Action Playbook',
                            body: _playbook,
                          ),
                        ],
                      ],
                      const SizedBox(height: 12),
                      CommanderInfoCard(
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

  Widget? get _alertForOwnUnit {
    if (_totalLogs == 0) return null;
    final highShare = _highCount / _totalLogs;
    if (_avgStress >= 60 || highShare >= 0.25) {
      return CommanderBanner(
        tint: NivaraColors.danger,
        icon: Icons.priority_high_rounded,
        text: 'Elevated unit stress — review the action playbook below.',
      );
    }
    if (_avgStress >= 45) {
      return CommanderBanner(
        tint: NivaraColors.warn,
        icon: Icons.warning_amber_rounded,
        text: 'Moderate stress levels — worth monitoring this week.',
      );
    }
    return null;
  }

  // =========================================================================
  // Units Under Command board
  // =========================================================================

  Widget _unitsBoard() {
    final filtered = _filteredUnits;
    final attentionCount =
        _units.where((u) => u.needsImmediateAttention).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          icon: Icons.account_tree_outlined,
          title: 'Units Under Command',
          tint: NivaraColors.accent,
          pill: '${_units.length + _suppressedUnits.length} total',
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: StatTile(
                label: 'Units',
                value: '${_units.length + _suppressedUnits.length}',
                color: NivaraColors.accent,
                icon: Icons.account_tree_outlined,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: StatTile(
                label: 'Need attention',
                value: '$attentionCount',
                color: attentionCount > 0
                    ? NivaraColors.danger
                    : NivaraColors.good,
                icon: Icons.priority_high_rounded,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: StatTile(
                label: 'Privacy-held',
                value: '${_suppressedUnits.length}',
                color: NivaraColors.info,
                icon: Icons.lock_outline,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _boardControls(),
        const SizedBox(height: 10),
        if (filtered.isEmpty)
          NivaraCard(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 18),
              child: Center(
                child: Text(
                  _units.isEmpty
                      ? 'No unit aggregates available yet.'
                      : 'No units match the current search or filter.',
                  style: TextStyle(color: NivaraColors.textLow, fontSize: 12.5),
                ),
              ),
            ),
          )
        else
          ...filtered.map(_unitCard),
        if (_suppressedUnits.isNotEmpty) ...[
          const SizedBox(height: 14),
          Row(
            children: [
              Icon(Icons.lock_outline, size: 12, color: NivaraColors.textLow),
              const SizedBox(width: 6),
              Text(
                'PRIVACY-HELD UNITS — AGGREGATES SUPPRESSED (< ${DatabaseHelper.squadPrivacyThreshold} CONTRIBUTORS)',
                style: TextStyle(
                    color: NivaraColors.textLow,
                    fontSize: 9.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ..._suppressedUnits
              .where((u) =>
                  _query.trim().isEmpty ||
                  u.unitId.toUpperCase().contains(_query.trim().toUpperCase()))
              .map(_suppressedCard),
        ],
      ],
    );
  }

  Widget _boardControls() {
    final presentTiers = UnitCondition.values
        .where((c) => c != UnitCondition.unknown && _units.any((u) => u.condition == c))
        .toList()
      ..sort((a, b) => a.minReadiness.compareTo(b.minReadiness));
    return Column(
      children: [
        TextField(
          onChanged: (v) => setState(() => _query = v),
          style: TextStyle(color: NivaraColors.textHi, fontSize: 13.5),
          decoration: InputDecoration(
            hintText: 'Search units…',
            prefixIcon: Icon(Icons.search,
                size: 20, color: NivaraColors.textLow),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: SizedBox(
                height: 34,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    _filterChip(
                        label: 'Attention',
                        tint: NivaraColors.danger,
                        selected: _condFilter.contains(UnitCondition.critical) &&
                            _condFilter.contains(UnitCondition.poor),
                        onTap: () => setState(() {
                              final on = _condFilter.contains(UnitCondition.critical) &&
                                  _condFilter.contains(UnitCondition.poor);
                              _condFilter.removeAll(
                                  {UnitCondition.critical, UnitCondition.poor});
                              if (!on) {
                                _condFilter.addAll(
                                    {UnitCondition.critical, UnitCondition.poor});
                              }
                            })),
                    for (final c in presentTiers)
                      _filterChip(
                        label: c.label,
                        tint: c.tint,
                        selected: _condFilter.contains(c),
                        onTap: () => setState(() =>
                            _condFilter.contains(c)
                                ? _condFilter.remove(c)
                                : _condFilter.add(c)),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            PopupMenuButton<UnitSortOrder>(
              tooltip: 'Sort order',
              onSelected: (o) => setState(() => _order = o),
              icon: Icon(Icons.sort,
                  size: 20, color: NivaraColors.textMid),
              itemBuilder: (_) => const [
                PopupMenuItem(
                    value: UnitSortOrder.worstFirst,
                    child: Text('Worst condition first')),
                PopupMenuItem(
                    value: UnitSortOrder.readinessDesc,
                    child: Text('Readiness high → low')),
                PopupMenuItem(
                    value: UnitSortOrder.nameAsc,
                    child: Text('Unit name A → Z')),
              ],
            ),
          ],
        ),
      ],
    );
  }

  Widget _filterChip({
    required String label,
    required Color tint,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(NivaraRadius.pill),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
          decoration: BoxDecoration(
            color: selected ? tint.withValues(alpha: 0.16) : NivaraColors.surface,
            borderRadius: BorderRadius.circular(NivaraRadius.pill),
            border: Border.all(
                color: selected ? tint.withValues(alpha: 0.6) : NivaraColors.outline),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (selected)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Icon(Icons.check, size: 12, color: tint),
                ),
              Text(label,
                  style: TextStyle(
                      color: selected ? tint : NivaraColors.textMid,
                      fontSize: 11,
                      fontWeight: FontWeight.w700)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _unitCard(UnitSummary u) {
    final c = u.condition;
    final isCritical = c == UnitCondition.critical;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        decoration: BoxDecoration(
          color: NivaraColors.surface,
          borderRadius: BorderRadius.circular(NivaraRadius.card),
          border: Border.all(
              color: isCritical
                  ? NivaraColors.danger.withValues(alpha: 0.7)
                  : c == UnitCondition.poor
                      ? NivaraColors.orange.withValues(alpha: 0.45)
                      : NivaraColors.outline),
          boxShadow: isCritical
              ? [
                  BoxShadow(
                    color: NivaraColors.danger.withValues(alpha: 0.12),
                    blurRadius: 10,
                    offset: const Offset(0, 2),
                  ),
                ]
              : const [],
        ),
        child: InkWell(
          onTap: () => _openUnit(u),
          borderRadius: BorderRadius.circular(NivaraRadius.card),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    color: c.tint.withValues(alpha: 0.13),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: c.tint.withValues(alpha: 0.4)),
                  ),
                  child: Icon(c.icon, size: 24, color: c.tint),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(u.unitId,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    color: NivaraColors.textHi,
                                    fontSize: 14.5,
                                    fontWeight: FontWeight.w800)),
                          ),
                          const SizedBox(width: 7),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 7, vertical: 2),
                            decoration: BoxDecoration(
                              color: c.tint.withValues(alpha: 0.13),
                              borderRadius:
                                  BorderRadius.circular(NivaraRadius.pill),
                            ),
                            child: Text(c.label.toUpperCase(),
                                style: TextStyle(
                                    color: c.tint,
                                    fontSize: 9,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 0.5)),
                          ),
                          if (isCritical) ...[
                            const SizedBox(width: 6),
                            CriticalPulseDot(color: NivaraColors.danger),
                          ],
                        ],
                      ),
                      const SizedBox(height: 5),
                      Row(
                        children: [
                          Icon(Icons.groups_2_outlined,
                              size: 12, color: NivaraColors.textLow),
                          const SizedBox(width: 3),
                          Text('${u.contributors}',
                              style: TextStyle(
                                  color: NivaraColors.textMid, fontSize: 11)),
                          const SizedBox(width: 10),
                          Icon(Icons.fact_check_outlined,
                              size: 12, color: NivaraColors.textLow),
                          const SizedBox(width: 3),
                          Text('${u.totalLogs}',
                              style: TextStyle(
                                  color: NivaraColors.textMid, fontSize: 11)),
                          const SizedBox(width: 10),
                          if (u.todayContributors > 0) ...[
                            Icon(Icons.task_alt_outlined,
                                size: 12, color: NivaraColors.good),
                            const SizedBox(width: 3),
                            Text('today',
                                style: TextStyle(
                                    color: NivaraColors.good, fontSize: 11)),
                            const SizedBox(width: 10),
                          ],
                          Expanded(
                            child: Text(
                              _lastUpdateText(u.lastCheckIn),
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  color: NivaraColors.textLow, fontSize: 10.5),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      if (_forecasts[u.unitId] != null &&
                          _forecasts[u.unitId]!.tier != ForecastTier.insufficient)
                        ForecastChip(forecast: _forecasts[u.unitId]!),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text('${u.readiness.toStringAsFixed(0)}%',
                        style: TextStyle(
                            color: c.tint,
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                            height: 1)),
                    const SizedBox(height: 2),
                    Text('readiness',
                        style: TextStyle(
                            color: NivaraColors.textLow, fontSize: 9)),
                    const SizedBox(height: 2),
                    Icon(Icons.chevron_right,
                        size: 16, color: NivaraColors.textLow),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _suppressedCard(UnitSummary u) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: NivaraColors.surface,
          borderRadius: BorderRadius.circular(NivaraRadius.card),
          border: Border.all(color: NivaraColors.outline),
        ),
        child: Row(
          children: [
            Icon(Icons.lock_outline, size: 16, color: NivaraColors.textLow),
            const SizedBox(width: 10),
            Expanded(
              child: Text(u.unitId,
                  style: TextStyle(
                      color: NivaraColors.textMid,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600)),
            ),
            Text('${u.contributors} contributors',
                style: TextStyle(color: NivaraColors.textLow, fontSize: 11)),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: NivaraColors.textLow.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(NivaraRadius.pill),
              ),
              child: Text('HELD',
                  style: TextStyle(
                      color: NivaraColors.textLow,
                      fontSize: 9,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.5)),
            ),
          ],
        ),
      ),
    );
  }

  /// PRD §6 edge case: commander's own unit below the threshold AND no other
  /// visible units — nothing can be shown without identity exposure.
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
                border:
                    Border.all(color: NivaraColors.warn.withValues(alpha: 0.4)),
              ),
              child:
                  Icon(Icons.shield_outlined, size: 42, color: NivaraColors.warn),
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
              onPressed: () => _loadSquadMetrics(),
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}
