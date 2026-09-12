import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:nivara_app/core/database_helper.dart';
import 'package:nivara_app/core/shapley.dart';
import 'package:nivara_app/core/ui_theme.dart';
import 'package:nivara_app/core/user_session.dart';
import 'commander_widgets.dart';
import 'unit_condition.dart';

/// Unit Details (Units Under Command → select unit). Focused aggregate view
/// for one unit plus the commander controls. Same privacy rules as the
/// board: aggregates below the squad threshold are blocked, every access
/// and every control action is audit-logged, all displayed numbers carry
/// differential privacy.
class UnitDetailsScreen extends StatefulWidget {
  final UserSession session;
  final String unitId;

  const UnitDetailsScreen({
    super.key,
    required this.session,
    required this.unitId,
  });

  @override
  State<UnitDetailsScreen> createState() => _UnitDetailsScreenState();
}

class _UnitDetailsScreenState extends State<UnitDetailsScreen> {
  bool _isLoading = true;
  bool _privacyBlocked = false;
  int _suppressedContributors = 0;

  double _avgStress = 0.0;
  int _totalLogs = 0;
  int _contributors = 0;
  int _weekLogs = 0;
  int _todayContributors = 0;
  int _highCount = 0;
  int _moderateCount = 0;
  DateTime? _lastCheckIn;
  List<Map<String, Object?>> _trend = [];
  Map<String, Object?>? _drivers;
  Map<String, double> _meanAttributions = const {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _isLoading = true);
    final db = DatabaseHelper.instance;

    final bundle = await db.getUnitDetailBundle(widget.unitId);

    if (!mounted) return;
    if (bundle == null) {
      final contributors = await db.getSquadSize(widget.unitId);
      await db.logAudit(
        actorId: widget.session.userId,
        action: 'UNIT_VIEW_BLOCKED',
        detail:
            'unit=${widget.unitId} contributors=$contributors (<${DatabaseHelper.squadPrivacyThreshold}) — detail suppressed',
      );
      if (!mounted) return;
      setState(() {
        _privacyBlocked = true;
        _suppressedContributors = contributors;
        _isLoading = false;
      });
      return;
    }

    final metrics = bundle['metrics']! as Map<String, Object?>;
    final lastTs = await db.getUnitLastCheckIn(widget.unitId);
    await db.logAudit(
      actorId: widget.session.userId,
      action: 'UNIT_VIEW',
      detail:
          'unit=${widget.unitId} contributors=${bundle['contributors']} logs=${metrics['total']} (anonymized aggregate detail)',
    );

    if (!mounted) return;
    setState(() {
      _privacyBlocked = false;
      _contributors = bundle['contributors'] as int;
      _totalLogs = (metrics['total'] as int?) ?? 0;
      _avgStress = db.differentiallyPrivateAverage(
        ((metrics['avg_stress'] as num?) ?? 0).toDouble(),
      );
      _trend = bundle['trend']! as List<Map<String, Object?>>;
      _drivers = bundle['drivers'] as Map<String, Object?>;
      _meanAttributions = bundle['attributions']! as Map<String, double>;
      final bands = bundle['bandCounts']! as Map<String, int>;
      _highCount = bands['high'] ?? 0;
      _moderateCount = bands['moderate'] ?? 0;
      _weekLogs = bundle['weekLogs'] as int;
      _todayContributors = bundle['todayContributors'] as int;
      _lastCheckIn = lastTs;
      _isLoading = false;
    });
  }

  UnitCondition get _condition => _totalLogs == 0
      ? UnitCondition.unknown
      : conditionFromStress(_avgStress);

  String get _lastUpdateText {
    final t = _lastCheckIn;
    if (t == null) return 'never';
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes}m ago';
    if (d.inDays < 1) return '${d.inHours}h ago';
    return '${d.inDays}d ago';
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
    final pctReadiness =
        ((d['pct_low_readiness'] as num?)?.toDouble() ?? 0) * 100;
    final parts = <String>[];
    if (pctSleep >= 40) parts.add('${pctSleep.round()}% of logs show <6h sleep');
    if (pctMood >= 40) parts.add('${pctMood.round()}% report low mood');
    if (pctReadiness >= 40) {
      parts.add('${pctReadiness.round()}% report low readiness');
    }
    if (parts.isEmpty) return shapley;
    return '$shapley\nThreshold flags: ${parts.join(' · ')}. Also factor in non-reported stressors.';
  }

  String get _playbook {
    if (_totalLogs == 0) {
      return 'No check-ins logged yet — encourage daily check-ins to enable the model-driven playbook.';
    }
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

  Future<void> _action({
    required String title,
    required String auditAction,
    required String auditDetail,
    required Future<void> Function() run,
  }) async {
    await DatabaseHelper.instance.logAudit(
      actorId: widget.session.userId,
      action: auditAction,
      detail: 'unit=${widget.unitId} $auditDetail',
    );
    await run();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$title — $auditDetail (audit-logged)')),
    );
  }

  Future<void> _broadcastNotice() async {
    final confirmed = await _confirm(
      'Broadcast welfare notice',
      'Queue a welfare check-in notice for ${widget.unitId}. The notice is '
          'aggregate-level — no soldier is individually identified or targeted.',
    );
    if (confirmed != true) return;
    await _action(
      title: 'Welfare notice',
      auditAction: 'WELFARE_NOTICE',
      auditDetail: 'welfare notice broadcast',
      run: () async {},
    );
  }

  Future<void> _raisePriority() async {
    final confirmed = await _confirm(
      'Raise welfare priority',
      'Flag ${widget.unitId} for priority welfare review at headquarters. '
          'Only the aggregate condition is shared — never individual data.',
    );
    if (confirmed != true) return;
    await _action(
      title: 'Priority raised',
      auditAction: 'PRIORITY_RAISED',
      auditDetail: 'welfare priority raised',
      run: () async {},
    );
  }

  Future<void> _copySummary() async {
    final summary = {
      'unit': widget.unitId,
      'generated': DateTime.now().toIso8601String(),
      'dp_avg_stress': double.parse(_avgStress.toStringAsFixed(1)),
      'condition': _condition.label,
      'readiness': double.parse(_condition == UnitCondition.unknown
          ? '0'
          : (100 - _avgStress).toStringAsFixed(1)),
      'contributors': _contributors,
      'total_logs': _totalLogs,
      'logs_7d': _weekLogs,
    };
    await _action(
      title: 'Summary copied',
      auditAction: 'SUMMARY_EXPORT',
      auditDetail: 'anonymized aggregate summary exported to clipboard',
      run: () async {
        await Clipboard.setData(ClipboardData(text: summary.toString()));
      },
    );
  }

  Future<bool?> _confirm(String title, String body) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: NivaraColors.surface,
        title: Text(title,
            style: TextStyle(
                color: NivaraColors.textHi,
                fontSize: 16,
                fontWeight: FontWeight.w800)),
        content: Text(body,
            style:
                TextStyle(color: NivaraColors.textMid, fontSize: 12.5, height: 1.5)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text('Cancel',
                style: TextStyle(color: NivaraColors.textMid)),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final unitId = widget.unitId;
    return Scaffold(
      backgroundColor: NivaraColors.bg,
      appBar: AppBar(
        title: Text('$unitId — Unit Details'),
      ),
      body: _isLoading
          ? Center(
              child: CircularProgressIndicator(color: NivaraColors.accent))
          : _privacyBlocked
              ? CommanderPrivacyBlocked(
                  contributors: _suppressedContributors, unitId: unitId)
              : RefreshIndicator(
                  color: NivaraColors.accent,
                  backgroundColor: NivaraColors.surface,
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                    children: [
                      _conditionHero(),
                      const SizedBox(height: 14),
                      if (_condition == UnitCondition.critical ||
                          _condition == UnitCondition.poor)
                        CommanderBanner(
                          tint: _condition.tint,
                          icon: _condition.icon,
                          text:
                              '${_condition.label} condition — immediate attention recommended. Review the playbook below.',
                        )
                      else if (_condition == UnitCondition.needsAttention)
                        CommanderBanner(
                          tint: _condition.tint,
                          icon: _condition.icon,
                          text:
                              'Needs attention — monitor this unit closely this week.',
                        ),
                      if (_condition == UnitCondition.critical ||
                          _condition == UnitCondition.poor ||
                          _condition == UnitCondition.needsAttention)
                        const SizedBox(height: 14),
                      if (_totalLogs == 0)
                        CommanderInfoCard(
                          icon: Icons.hourglass_empty,
                          color: NivaraColors.accent,
                          title: 'No check-ins yet',
                          body:
                              'This unit has no logged check-ins. Aggregates appear here as soon as personnel start their daily check-ins.',
                        )
                      else ...[
                        CommanderOverviewCard(
                          stressAvg: _avgStress,
                          totalLogs: _totalLogs,
                          contributors: _contributors,
                          highCount: _highCount,
                          moderateCount: _moderateCount,
                          footnote: _trendDelta.isEmpty ? null : _trendDelta,
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
                                value: '$_todayContributors / $_contributors',
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
                        CommanderTrendCard(
                            trend: _trend, stressAvg: _avgStress),
                        const SizedBox(height: 20),
                        CommanderActivityCard(
                            trend: _trend, weekLogs: _weekLogs),
                        const SizedBox(height: 12),
                        _historyCard(),
                        const SizedBox(height: 12),
                        CommanderShapleyCard(attributions: _meanAttributions),
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
                      const SizedBox(height: 12),
                      _actionsCard(),
                      const SizedBox(height: 12),
                      CommanderInfoCard(
                        icon: Icons.gavel,
                        color: NivaraColors.info,
                        title: 'Audit Trail',
                        body:
                            'Every access to this unit detail and every control action is recorded in the append-only audit log. No names or Service IDs are retrievable from this view.',
                      ),
                    ],
                  ),
                ),
    );
  }

  /// Identity-safe status history: the last 7 daily aggregates.
  Widget _historyCard() {
    if (_trend.isEmpty) return const SizedBox.shrink();
    return NivaraCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(
            icon: Icons.history,
            title: 'Recent status history',
            tint: NivaraColors.info,
            pill: 'daily aggregates',
          ),
          const SizedBox(height: 10),
          ..._trend.reversed.take(7).map((r) {
            final day = (r['day'] ?? '').toString();
            final avg = ((r['avg_stress'] as num?) ?? 0).toDouble();
            final c = conditionFromStress(avg);
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Icon(c.icon, size: 14, color: c.tint),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(day,
                        style: TextStyle(
                            color: NivaraColors.textMid, fontSize: 12)),
                  ),
                  Text('${avg.toStringAsFixed(0)} · ${c.label}',
                      style: TextStyle(
                          color: c.tint,
                          fontSize: 12,
                          fontWeight: FontWeight.w700)),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _conditionHero() {
    final c = _condition;
    final readiness = _totalLogs == 0 ? null : (100 - _avgStress).clamp(0.0, 100.0);
    return NivaraCard(
      border: c == UnitCondition.unknown
          ? null
          : c.tint.withValues(alpha: 0.45),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
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
                    Text(widget.unitId,
                        style: TextStyle(
                            color: NivaraColors.textHi,
                            fontSize: 18,
                            fontWeight: FontWeight.w800)),
                    const SizedBox(height: 3),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: c.tint.withValues(alpha: 0.13),
                        borderRadius:
                            BorderRadius.circular(NivaraRadius.pill),
                      ),
                      child: Text(c.label.toUpperCase(),
                          style: TextStyle(
                              color: c.tint,
                              fontSize: 10.5,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.6)),
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    readiness == null ? '—' : '${readiness.toStringAsFixed(0)}%',
                    style: TextStyle(
                        color: c.tint,
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                        height: 1),
                  ),
                  Text('readiness',
                      style: TextStyle(
                          color: NivaraColors.textLow, fontSize: 9.5)),
                ],
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              _metaChip(Icons.groups_2_outlined, '$_contributors personnel'),
              const SizedBox(width: 8),
              _metaChip(
                  Icons.fact_check_outlined, '$_totalLogs check-ins'),
              const SizedBox(width: 8),
              _metaChip(Icons.schedule, 'updated $_lastUpdateText'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _metaChip(IconData icon, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: NivaraColors.surfaceAlt,
        borderRadius: BorderRadius.circular(NivaraRadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: NivaraColors.textLow),
          const SizedBox(width: 5),
          Text(text,
              style:
                  TextStyle(color: NivaraColors.textMid, fontSize: 10.5)),
        ],
      ),
    );
  }

  /// Commander controls — every action is audit-logged.
  Widget _actionsCard() {
    return NivaraCard(
      border: NivaraColors.accent.withValues(alpha: 0.3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader(
            icon: Icons.tune,
            title: 'Commander actions',
            pill: 'audit-logged',
          ),
          const SizedBox(height: 6),
          _actionTile(
            icon: Icons.campaign_outlined,
            tint: NivaraColors.accent,
            title: 'Broadcast welfare notice',
            caption: 'Queue a unit-wide welfare check-in nudge',
            onTap: _broadcastNotice,
          ),
          Divider(color: NivaraColors.outline, height: 1),
          _actionTile(
            icon: Icons.priority_high_rounded,
            tint: NivaraColors.warn,
            title: 'Raise welfare priority',
            caption: 'Flag this unit for priority review at HQ',
            onTap: _raisePriority,
          ),
          Divider(color: NivaraColors.outline, height: 1),
          _actionTile(
            icon: Icons.ios_share,
            tint: NivaraColors.info,
            title: 'Export aggregate summary',
            caption: 'Copy the anonymized DP summary to clipboard',
            onTap: _copySummary,
          ),
          Divider(color: NivaraColors.outline, height: 1),
          _actionTile(
            icon: Icons.refresh,
            tint: NivaraColors.good,
            title: 'Refresh data',
            caption: 'Re-query the encrypted vault for fresh aggregates',
            onTap: _load,
          ),
        ],
      ),
    );
  }

  Widget _actionTile({
    required IconData icon,
    required Color tint,
    required String title,
    required String caption,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 2),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: tint.withValues(alpha: 0.13),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, size: 18, color: tint),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(
                          color: NivaraColors.textHi,
                          fontSize: 13,
                          fontWeight: FontWeight.w700)),
                  const SizedBox(height: 1),
                  Text(caption,
                      style: TextStyle(
                          color: NivaraColors.textLow, fontSize: 11)),
                ],
              ),
            ),
            Icon(Icons.chevron_right,
                size: 18, color: NivaraColors.textLow),
          ],
        ),
      ),
    );
  }
}
