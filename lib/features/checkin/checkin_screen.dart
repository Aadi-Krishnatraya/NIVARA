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
  String? _engineError;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    try {
      await MLEngine.instance.load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _engineError = '$e');
      return;
    }
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

  String get _greeting {
    final h = DateTime.now().hour;
    if (h < 12) return 'Good morning';
    if (h < 17) return 'Good afternoon';
    return 'Good evening';
  }

  String get _todayLabel {
    const wd = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const mo = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
                'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final n = DateTime.now();
    return '${wd[n.weekday - 1]}, ${n.day} ${mo[n.month - 1]}';
  }

  /// Live status pill on the hero banner — reflects the current evaluation
  /// state so the page reads at a glance.
  Widget _statusChip() {
    final score = _evaluatedScore;
    final Color tint;
    final IconData icon;
    final String label;
    if (_evaluating) {
      tint = NivaraColors.info;
      icon = Icons.bolt;
      label = 'Evaluating…';
    } else if (score == null) {
      tint = NivaraColors.warn;
      icon = Icons.radio_button_unchecked;
      label = 'Not evaluated';
    } else {
      tint = _bandColor;
      icon = Icons.verified_outlined;
      label = '${score.toStringAsFixed(0)} · ${classifyStress(score).label}';
    }
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(NivaraRadius.pill),
        border: Border.all(color: tint.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: tint),
          SizedBox(width: 5),
          Text(label,
              style: TextStyle(
                  color: tint, fontSize: 11, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final evaluated = _evaluatedScore != null;
    return Scaffold(
      backgroundColor: NivaraColors.bg,
      appBar: AppBar(
        title: Text('Daily Check-In'),
      ),
      floatingActionButton: !_engineReady
          ? null
          : AnimatedSlide(
              duration: Duration(milliseconds: 260),
              curve: Curves.easeOutCubic,
              offset: Offset(0, _submitting ? 0.2 : 0),
              child: FloatingActionButton.extended(
                heroTag: 'checkin-action',
                elevation: 3,
                backgroundColor: evaluated ? NivaraColors.accent : NivaraColors.surfaceAlt,
                foregroundColor: evaluated ? const Color(0xFF04211D) : NivaraColors.textHi,
                onPressed: _submitting || _evaluating
                    ? null
                    : (evaluated ? _submit : _runEvaluation),
                icon: _submitting
                    ? SizedBox(
                        width: 18, height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Color(0xFF04211D)))
                    : Icon(evaluated ? Icons.save_outlined : Icons.bolt, size: 20),
                label: Text(
                  _submitting
                      ? 'Logging…'
                      : evaluated
                          ? 'Log check-in'
                          : 'Run evaluation',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
                ),
              ),
            ),
      body: _engineError != null
          ? Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.memory,
                        size: 48, color: NivaraColors.warn),
                    SizedBox(height: 14),
                    Text('Edge AI unavailable',
                        style: TextStyle(
                            color: NivaraColors.textHi,
                            fontSize: 16,
                            fontWeight: FontWeight.w700)),
                    SizedBox(height: 8),
                    Text(
                      'The on-device stress model could not be loaded, '
                      'so scoring is disabled. Check-ins cannot run '
                      'without the local model.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: NivaraColors.textMid, fontSize: 12.5, height: 1.5),
                    ),
                    const SizedBox(height: 16),
                    OutlinedButton.icon(
                      onPressed: () {
                        setState(() {
                          _engineError = null;
                          _engineReady = false;
                        });
                        _bootstrap();
                      },
                      icon: Icon(Icons.refresh, size: 18),
                      label: Text('Retry'),
                    ),
                  ],
                ),
              ),
            )
          : !_engineReady
          ? Center(
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
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
              children: [
                // Hero banner: greeting + today's context + live status.
                NivaraCard(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      NivaraColors.surface,
                      NivaraColors.surfaceAlt,
                    ],
                  ),
                  padding: EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 42,
                            height: 42,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: NivaraColors.accentSoft,
                              border: Border.all(
                                  color: NivaraColors.accent.withValues(alpha: 0.45)),
                            ),
                            child: Icon(Icons.person_outline,
                                size: 22, color: NivaraColors.accent),
                          ),
                          SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '$_greeting, ${widget.session.name}',
                                  style: TextStyle(
                                      color: NivaraColors.textHi,
                                      fontSize: 16,
                                      fontWeight: FontWeight.w800),
                                  overflow: TextOverflow.ellipsis,
                                ),
                                SizedBox(height: 2),
                                Text(
                                  '$_todayLabel · confidential check-in',
                                  style: TextStyle(
                                      color: NivaraColors.textLow, fontSize: 11.5),
                                ),
                              ],
                            ),
                          ),
                          _statusChip(),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                _SectionLabel(
                    icon: Icons.favorite_outline,
                    title: 'Subjective report',
                    hint: 'Three taps. Stays on this device.'),
                _slider(
                  icon: Icons.mood_outlined,
                  label: 'Mood',
                  valueText: '${_mood.toStringAsFixed(1)} / 5',
                  value: _mood, min: 1, max: 5, divisions: 40,
                  stageIcons: const [
                    Icons.sentiment_very_dissatisfied,
                    Icons.sentiment_dissatisfied,
                    Icons.sentiment_neutral,
                    Icons.sentiment_satisfied,
                    Icons.sentiment_very_satisfied,
                  ],
                  lowHint: 'very low',
                  highHint: 'excellent',
                  onChanged: (v) => setState(() { _mood = v; _evaluatedScore = null; }),
                ),
                _slider(
                  icon: Icons.bedtime_outlined,
                  label: 'Sleep last night',
                  valueText: '${_sleep.toStringAsFixed(1)} hrs',
                  value: _sleep, min: 0, max: 12, divisions: 48,
                  stageIcons: const [
                    Icons.airline_seat_individual_suite,
                    Icons.hotel_outlined,
                    Icons.hotel_class_outlined,
                  ],
                  lowHint: 'no sleep',
                  highHint: 'fully rested',
                  onChanged: (v) => setState(() { _sleep = v; _evaluatedScore = null; }),
                ),
                _slider(
                  icon: Icons.directions_run,
                  label: 'Physical readiness',
                  valueText: '${_readiness.toStringAsFixed(1)} / 5',
                  value: _readiness, min: 1, max: 5, divisions: 40,
                  stageIcons: const [
                    Icons.airline_seat_flat,
                    Icons.airline_seat_recline_normal,
                    Icons.directions_walk,
                    Icons.directions_run,
                    Icons.bolt,
                  ],
                  lowHint: 'exhausted',
                  highHint: 'peak condition',
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
                  tint: NivaraColors.info,
                  lowHint: 'none',
                  highHint: '14 in a row',
                  onChanged: (v) => setState(() { _nightStreak = v.round(); _evaluatedScore = null; }),
                ),
                _slider(
                  icon: Icons.public,
                  label: 'Deployment duration',
                  valueText: '$_deploymentDays days',
                  value: _deploymentDays.toDouble(), min: 0, max: 365, divisions: 73,
                  tint: NivaraColors.warn,
                  lowHint: 'just arrived',
                  highHint: '1 year+',
                  onChanged: (v) => setState(() { _deploymentDays = v.round(); _evaluatedScore = null; }),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  activeThumbColor: NivaraColors.danger,
                  secondary: Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: NivaraColors.danger.withValues(alpha: 0.13),
                      borderRadius: BorderRadius.circular(11),
                      border: Border.all(
                          color: NivaraColors.danger.withValues(alpha: 0.30)),
                    ),
                    child: Icon(Icons.event_busy,
                        size: 19, color: NivaraColors.danger),
                  ),
                  title: Text('Leave cancelled in last 30 days',
                      style: TextStyle(color: NivaraColors.textMid, fontSize: 13.5)),
                  value: _cancelledLeave,
                  onChanged: (v) => setState(() { _cancelledLeave = v; _evaluatedScore = null; }),
                ),
                SizedBox(height: 10),

                // Edge-AI evaluation panel.
                AnimatedContainer(
                  duration: Duration(milliseconds: 300),
                  width: double.infinity,
                  padding: EdgeInsets.all(16),
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
                              padding: EdgeInsets.only(left: 6, bottom: 7),
                              child: Text(
                                  '/ 100 · ${classifyStress(_evaluatedScore!).label}',
                                  style: TextStyle(
                                      color: _bandColor,
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600)),
                            ),
                            Spacer(),
                            Container(
                              padding: EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: NivaraColors.surfaceAlt,
                                borderRadius:
                                    BorderRadius.circular(NivaraRadius.pill),
                              ),
                              child: Text('$_inferenceMs ms on CPU',
                                  style: TextStyle(
                                      color: NivaraColors.textLow, fontSize: 10.5)),
                            ),
                          ],
                        ),
                        SizedBox(height: 14),
                        if (_contributions.isNotEmpty)
                          _shapleyPanel()
                        else
                          Padding(
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
                                ? SizedBox(
                                    width: 20, height: 20,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2, color: Color(0xFF04211D)))
                                : Text('Log this check-in'),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                SizedBox(height: 14),
                Row(
                  children: [
                    Icon(Icons.enhanced_encryption,
                        size: 13, color: NivaraColors.textLow),
                    SizedBox(width: 6),
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
      margin: EdgeInsets.only(top: 2),
      padding: EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: NivaraColors.bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: NivaraColors.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Why this score — exact Shapley (on-device)',
              style: TextStyle(
                  color: NivaraColors.textHi,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700)),
          Text(
            'baseline soldier on this device scores ${_referenceScore.toStringAsFixed(0)}',
            style: TextStyle(color: NivaraColors.textLow, fontSize: 10.5),
          ),
          SizedBox(height: 10),
          ..._contributions.map((c) {
            final color = c.isRisk ? NivaraColors.danger : NivaraColors.good;
            return Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(c.label,
                            style: TextStyle(
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
                                  width: barW, decoration: BoxDecoration(
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

  /// Small anchor caption under a slider (e.g. “1 · 5” with a hint word).
  Widget _anchor(double min, double max, String? low, String? high) {
    return Padding(
      padding: EdgeInsets.only(top: 2, left: 46, right: 98),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(low ?? min.toStringAsFixed(0),
              style: TextStyle(color: NivaraColors.textLow, fontSize: 10)),
          if (high != null)
            Text(high,
                style: TextStyle(color: NivaraColors.textLow, fontSize: 10)),
          if (high == null) Text(max.toStringAsFixed(0),
              style: TextStyle(color: NivaraColors.textLow, fontSize: 10)),
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
    Color tint = NivaraColors.accent,
    List<IconData>? stageIcons,
    double Function(double)? stageT,
    String? lowHint,
    String? highHint,
  }) {
    final t = stageT?.call(value) ?? ((value - min) / (max - min)).clamp(0.0, 1.0);
    return Padding(
      padding: EdgeInsets.only(bottom: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: tint.withValues(alpha: 0.13),
                  borderRadius: BorderRadius.circular(11),
                  border: Border.all(color: tint.withValues(alpha: 0.30)),
                ),
                child: Icon(icon, size: 19, color: tint),
              ),
              SizedBox(width: 8),
              Expanded(
                child: Text(label,
                    style: TextStyle(
                        color: NivaraColors.textMid, fontSize: 12.5)),
              ),
              Text(valueText,
                  style: TextStyle(
                      color: NivaraColors.textHi,
                      fontSize: 13,
                      fontWeight: FontWeight.w700)),
            ],
          ),
          Row(
            children: [
              if (stageIcons != null)
                GestureDetector(
                  onTap: () => onChanged(min + (max - min) * t),
                  child: Container(
                    width: 34,
                    height: 34,
                    alignment: Alignment.center,
                    child: Icon(
                      stageIcons[(t * (stageIcons.length - 1)).round()],
                      size: 22,
                      color: Color.lerp(NivaraColors.textLow, tint, t.clamp(0.0, 1.0)),
                    ),
                  ),
                ),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    activeTrackColor: tint,
                    thumbColor: tint,
                    overlayColor: tint.withValues(alpha: 0.16),
                  ),
                  child: Slider(
                    value: value.clamp(min, max),
                    min: min,
                    max: max,
                    divisions: divisions,
                    label: valueText,
                    onChanged: onChanged,
                  ),
                ),
              ),
            ],
          ),
          if (lowHint != null || highHint != null)
            _anchor(min, max, lowHint, highHint),
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
      padding: EdgeInsets.only(top: 10, bottom: 6),
      child: Row(
        children: [
          Icon(icon, size: 15, color: NivaraColors.accent),
          SizedBox(width: 7),
          Text(title,
              style: TextStyle(
                  color: NivaraColors.textHi,
                  fontSize: 14,
                  fontWeight: FontWeight.w700)),
          SizedBox(width: 8),
          Expanded(
            child: Text(hint,
                style: TextStyle(color: NivaraColors.textLow, fontSize: 11)),
          ),
        ],
      ),
    );
  }
}
