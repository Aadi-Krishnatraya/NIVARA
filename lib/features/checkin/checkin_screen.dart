import 'package:flutter/material.dart';

import 'package:nivara_app/core/database_helper.dart';
import 'package:nivara_app/core/ml_engine.dart';
import 'package:nivara_app/core/shapley.dart';
import 'package:nivara_app/core/ui_theme.dart';
import 'package:nivara_app/core/user_session.dart';

/// Ultra-low friction daily check-in (PRD §3.1).
///
/// The stress index is computed by the quantized neural network running on
/// this device's CPU (TensorFlow Lite, background isolate). Inputs combine
/// the soldier's subjective self-report with their operational context
/// (night-patrol streak, deployment duration, cancelled leave). Nothing is
/// hardcoded and nothing leaves the device.
class DailyCheckInScreen extends StatefulWidget {
  final UserSession session;
  final VoidCallback? onEntrySaved;

  const DailyCheckInScreen({
    super.key,
    required this.session,
    this.onEntrySaved,
  });

  @override
  State<DailyCheckInScreen> createState() => _DailyCheckInScreenState();
}

class _DailyCheckInScreenState extends State<DailyCheckInScreen> {
  double _mood = 3.0;
  double _sleep = 7.0;
  double _readiness = 3.0;
  int _nightStreak = 0;
  int _deploymentDays = 30;
  bool _cancelledLeave = false;

  double? _evaluatedScore;
  List<ShapleyContribution> _contributions = const [];
  double _referenceScore = 0;
  int _inferenceMs = 0;
  bool _evaluating = false;
  bool _submitting = false;
  bool _engineReady = false;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    await MLEngine.instance.load();
    final ctx = await DatabaseHelper.instance.getOperationalContext(widget.session.userId);
    if (!mounted) return;
    setState(() {
      _engineReady = MLEngine.instance.isReady;
      _nightStreak = ctx['night_patrol_streak'] ?? 0;
      _deploymentDays = ctx['deployment_days'] ?? 0;
      _cancelledLeave = (ctx['cancelled_leave'] ?? 0) == 1;
    });
  }

  Color get _bandColor {
    final level = classifyStress(_evaluatedScore ?? 0);
    return switch (level) {
      StressLevel.high => NivaraColors.danger,
      StressLevel.moderate => NivaraColors.warn,
      StressLevel.low => NivaraColors.good,
    };
  }

  Future<void> _runEvaluation() async {
    setState(() => _evaluating = true);
    final eval = await MLEngine.instance.evaluateWithExplanation(
      mood: _mood,
      sleepHours: _sleep,
      readiness: _readiness,
      nightPatrolStreak: _nightStreak,
      deploymentDays: _deploymentDays,
      cancelledLeaveRecently: _cancelledLeave,
    );
    if (!mounted) return;
    setState(() {
      _evaluatedScore = eval.score;
      _contributions = eval.contributions;
      _referenceScore = eval.referenceScore;
      _inferenceMs = eval.inferenceMs;
      _evaluating = false;
    });
  }

  Future<void> _submit() async {
    final score = _evaluatedScore;
    if (score == null || _submitting) return;
    setState(() => _submitting = true);

    try {
      // Persist the operational context first so future evaluations start
      // from the soldier's current reality.
      await DatabaseHelper.instance.saveOperationalContext(
        widget.session.userId,
        nightPatrolStreak: _nightStreak,
        deploymentDays: _deploymentDays,
        cancelledLeaveRecently: _cancelledLeave,
      );
      await DatabaseHelper.instance.insertCheckIn(
        userId: widget.session.userId,
        unitId: widget.session.unitId,
        mood: _mood,
        sleepHours: _sleep,
        readiness: _readiness,
        stressScore: score,
        attribution: {
          for (final c in _contributions) c.label: c.value,
        },
      );

      if (!mounted) return;
      setState(() => _submitting = false);
      widget.onEntrySaved?.call();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              'Scored ${score.toStringAsFixed(0)}/100 on-device — stored in the encrypted vault only'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text('Error: $e'),
            backgroundColor: NivaraColors.danger),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NivaraColors.bg,
      appBar: AppBar(
        title: const Text('Daily Check-In'),
      ),
      body: !_engineReady
          ? const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: NivaraColors.accent),
                  SizedBox(height: 12),
                  Text('Loading on-device model…',
                      style: TextStyle(color: NivaraColors.textMid, fontSize: 12.5)),
                ],
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
              children: [
                _SectionLabel(
                    icon: Icons.favorite_outline,
                    title: 'Subjective report',
                    hint: 'Three taps. Stays on this device.'),
                _slider(
                  icon: Icons.mood_outlined,
                  label: 'Mood',
                  valueText: '${_mood.toStringAsFixed(1)} / 5',
                  value: _mood, min: 1, max: 5, divisions: 40,
                  onChanged: (v) => setState(() { _mood = v; _evaluatedScore = null; }),
                ),
                _slider(
                  icon: Icons.bedtime_outlined,
                  label: 'Sleep last night',
                  valueText: '${_sleep.toStringAsFixed(1)} hrs',
                  value: _sleep, min: 0, max: 12, divisions: 48,
                  onChanged: (v) => setState(() { _sleep = v; _evaluatedScore = null; }),
                ),
                _slider(
                  icon: Icons.directions_run,
                  label: 'Physical readiness',
                  valueText: '${_readiness.toStringAsFixed(1)} / 5',
                  value: _readiness, min: 1, max: 5, divisions: 40,
                  onChanged: (v) => setState(() { _readiness = v; _evaluatedScore = null; }),
                ),
                const SizedBox(height: 14),
                _SectionLabel(
                    icon: Icons.terrain_outlined,
                    title: 'Operational context',
                    hint: 'Feeds the model — set by your unit reality.'),
                _slider(
                  icon: Icons.dark_mode_outlined,
                  label: 'Consecutive night patrols',
                  valueText: '$_nightStreak days',
                  value: _nightStreak.toDouble(), min: 0, max: 14, divisions: 14,
                  onChanged: (v) => setState(() { _nightStreak = v.round(); _evaluatedScore = null; }),
                ),
                _slider(
                  icon: Icons.public,
                  label: 'Deployment duration',
                  valueText: '$_deploymentDays days',
                  value: _deploymentDays.toDouble(), min: 0, max: 365, divisions: 73,
                  onChanged: (v) => setState(() { _deploymentDays = v.round(); _evaluatedScore = null; }),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  activeThumbColor: NivaraColors.accent,
                  title: const Text('Leave cancelled in last 30 days',
                      style: TextStyle(color: NivaraColors.textMid, fontSize: 13.5)),
                  value: _cancelledLeave,
                  onChanged: (v) => setState(() { _cancelledLeave = v; _evaluatedScore = null; }),
                ),
                const SizedBox(height: 10),

                // Edge-AI evaluation panel.
                AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: NivaraColors.surface,
                    borderRadius: BorderRadius.circular(NivaraRadius.card),
                    border: Border.all(
                      color: _evaluatedScore == null
                          ? NivaraColors.outline
                          : _bandColor.withValues(alpha: 0.55),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SectionHeader(
                        icon: Icons.memory,
                        title: 'On-device neural evaluation',
                        tint: NivaraColors.accent,
                        pill: 'TFLite · int8 · offline',
                      ),
                      const SizedBox(height: 14),
                      if (_evaluatedScore == null)
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: _evaluating ? null : _runEvaluation,
                            icon: _evaluating
                                ? const SizedBox(
                                    width: 16, height: 16,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2, color: NivaraColors.accent))
                                : const Icon(Icons.bolt, size: 18),
                            label: Text(_evaluating
                                ? 'Running inference…'
                                : 'Run evaluation'),
                          ),
                        )
                      else ...[
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              _evaluatedScore!.toStringAsFixed(0),
                              style: TextStyle(
                                  color: _bandColor,
                                  fontSize: 46,
                                  fontWeight: FontWeight.w800,
                                  height: 1),
                            ),
                            Padding(
                              padding: const EdgeInsets.only(left: 6, bottom: 7),
                              child: Text(
                                  '/ 100 · ${classifyStress(_evaluatedScore!).label}',
                                  style: TextStyle(
                                      color: _bandColor,
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600)),
                            ),
                            const Spacer(),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: NivaraColors.surfaceAlt,
                                borderRadius:
                                    BorderRadius.circular(NivaraRadius.pill),
                              ),
                              child: Text('$_inferenceMs ms on CPU',
                                  style: const TextStyle(
                                      color: NivaraColors.textLow, fontSize: 10.5)),
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        if (_contributions.isNotEmpty)
                          _shapleyPanel()
                        else
                          const Padding(
                            padding: EdgeInsets.only(bottom: 8),
                            child: Text('Explaining this score on-device…',
                                style: TextStyle(
                                    color: NivaraColors.textLow, fontSize: 12)),
                          ),
                        const SizedBox(height: 14),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton(
                            onPressed: _submitting ? null : _submit,
                            child: _submitting
                                ? const SizedBox(
                                    width: 20, height: 20,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2, color: Color(0xFF04211D)))
                                : const Text('Log this check-in'),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Icon(Icons.enhanced_encryption,
                        size: 13, color: NivaraColors.textLow),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Model: 3-layer MLP, full-int8 quantized, trained on synthetic '
                        'operational data (SDV-style). Every score is explained by '
                        'exact Shapley values over all 64 coalitions, evaluated as a '
                        'single batch on this CPU — real game-theoretic XAI, offline.',
                        style: TextStyle(
                            color: NivaraColors.textLow, fontSize: 10.5, height: 1.45),
                      ),
                    ),
                  ],
                ),
              ],
            ),
    );
  }

  /// Game-theoretic explanation of THIS score: exact Shapley values from
  /// the deployed int8 model. Red pushes the index up, teal pulls it down.
  Widget _shapleyPanel() {
    final maxAbs = _contributions
        .map((c) => c.value.abs())
        .reduce((a, b) => a > b ? a : b);
    return Container(
      margin: const EdgeInsets.only(top: 2),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: NivaraColors.bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: NivaraColors.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Why this score — exact Shapley (on-device)',
              style: TextStyle(
                  color: NivaraColors.textHi,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700)),
          Text(
            'baseline soldier on this device scores ${_referenceScore.toStringAsFixed(0)}',
            style: const TextStyle(color: NivaraColors.textLow, fontSize: 10.5),
          ),
          const SizedBox(height: 10),
          ..._contributions.map((c) {
            final color = c.isRisk ? NivaraColors.danger : NivaraColors.good;
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(c.label,
                            style: const TextStyle(
                                color: NivaraColors.textMid, fontSize: 12)),
                      ),
                      Text('${c.signedPoints} pts',
                          style: TextStyle(
                              color: color,
                              fontSize: 12,
                              fontWeight: FontWeight.w700)),
                    ],
                  ),
                  const SizedBox(height: 4),
                  LayoutBuilder(builder: (context, constraints) {
                    final half = constraints.maxWidth / 2;
                    final barW = half * (c.value.abs() / (maxAbs <= 0 ? 1 : maxAbs)).clamp(0.04, 1.0);
                    return SizedBox(
                      height: 5,
                      child: Row(
                        children: [
                          SizedBox(width: half, child: c.isProtective
                              ? Row(children: [
                                  Expanded(child: Container()),
                                  Container(width: barW, decoration: BoxDecoration(
                                      color: color,
                                      borderRadius: const BorderRadius.horizontal(
                                          left: Radius.circular(3)))),
                                ])
                              : Container()),
                          SizedBox(width: half, child: c.isRisk
                              ? Align(alignment: Alignment.centerLeft, child: Container(
                                  width: barW, decoration: const BoxDecoration(
                                      color: NivaraColors.danger,
                                      borderRadius: BorderRadius.horizontal(
                                          right: Radius.circular(3)))))
                              : Container()),
                        ],
                      ),
                    );
                  }),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _slider({
    required IconData icon,
    required String label,
    required String valueText,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required ValueChanged<double> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: NivaraColors.surfaceAlt,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, size: 18, color: NivaraColors.accent),
          ),
          Expanded(
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              divisions: divisions,
              label: valueText,
              onChanged: onChanged,
            ),
          ),
          SizedBox(
            width: 86,
            child: Text(valueText,
                textAlign: TextAlign.right,
                style: const TextStyle(
                    color: NivaraColors.textHi,
                    fontSize: 13,
                    fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final IconData icon;
  final String title;
  final String hint;

  const _SectionLabel({required this.icon, required this.title, required this.hint});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 6),
      child: Row(
        children: [
          Icon(icon, size: 15, color: NivaraColors.accent),
          const SizedBox(width: 7),
          Text(title,
              style: const TextStyle(
                  color: NivaraColors.textHi,
                  fontSize: 14,
                  fontWeight: FontWeight.w700)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(hint,
                style: const TextStyle(color: NivaraColors.textLow, fontSize: 11)),
          ),
        ],
      ),
    );
  }
}
