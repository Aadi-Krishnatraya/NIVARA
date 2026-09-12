import 'dart:convert';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:nivara_app/core/shapley.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

/// Severity bands for the 0–100 stress index (PRD §3.1).
enum StressLevel { low, moderate, high }

extension StressLevelX on StressLevel {
  String get label => switch (this) {
        StressLevel.low => 'LOW',
        StressLevel.moderate => 'MODERATE',
        StressLevel.high => 'HIGH',
      };
}

StressLevel classifyStress(double score) {
  if (score >= 67) return StressLevel.high;
  if (score >= 34) return StressLevel.moderate;
  return StressLevel.low;
}

/// Feature vector for the on-device model, in trained order:
/// [mood 1-5, sleep hours, readiness 1-5, night-patrol streak,
///  deployment days, cancelled-leaves flag].
///
/// Streak / deployment / leaves come from the soldier's own operational
/// context entry (self-declared, stored only in the local encrypted vault).
List<double> stressFeatures({
  required double mood,
  required double sleepHours,
  required double readiness,
  required int nightPatrolStreak,
  required int deploymentDays,
  required bool cancelledLeaveRecently,
}) {
  return [
    mood,
    sleepHours,
    readiness,
    nightPatrolStreak.clamp(0, 30).toDouble(),
    deploymentDays.clamp(0, 365).toDouble(),
    cancelledLeaveRecently ? 1.0 : 0.0,
  ];
}

/// Real Edge AI: executes the quantized stress model locally on the device
/// CPU via TensorFlow Lite. Inference runs inside a background isolate so
/// the UI never drops frames. No network is involved — 100% offline.
class MLEngine {
  MLEngine._();
  static final MLEngine instance = MLEngine._();

  static const String _modelAsset = 'assets/models/stress_model.tflite';

  IsolateInterpreter? _interpreter;
  List<int>? _inputShape;
  List<int>? _outputShape;
  double _inScale = 1.0;
  int _inZeroPoint = 0;
  double _outScale = 1.0;
  int _outZeroPoint = 0;
  List<double>? _referencePoint;
  double? _referenceScore;

  /// Neutral soldier every Shapley coalition substitutes in (training-set
  /// median, exported by the training pipeline into model_meta.json).
  List<double> get referencePoint {
    final ref = _referencePoint;
    if (ref == null) {
      throw StateError('MLEngine.load() must complete first');
    }
    return ref;
  }

  /// Model output for the reference soldier, measured on-device.
  double get referenceScore {
    final score = _referenceScore;
    if (score == null) {
      throw StateError('MLEngine.load() must complete first');
    }
    return score;
  }

  bool get isReady => _interpreter != null;

  Future<void> load() async {
    if (_interpreter != null) return;

    final options = InterpreterOptions()..threads = 2;
    Interpreter interpreter;
    try {
      interpreter = await Interpreter.fromAsset(_modelAsset, options: options);
    } on Error {
      // Emulator/desktop fallback path if asset loading is unavailable.
      final raw = await rootBundle.load(_modelAsset);
      interpreter = Interpreter.fromBuffer(raw.buffer.asUint8List(), options: options);
    }

    interpreter.allocateTensors();
    _inputShape = interpreter.getInputTensor(0).shape;
    _outputShape = interpreter.getOutputTensor(0).shape;

    final inParams = interpreter.getInputTensor(0).params;
    final outParams = interpreter.getOutputTensor(0).params;
    _inScale = inParams.scale;
    _inZeroPoint = inParams.zeroPoint;
    _outScale = outParams.scale;
    _outZeroPoint = outParams.zeroPoint;

    // Shapley reference soldier from the training pipeline's metadata.
    try {
      final metaRaw = await rootBundle.loadString('assets/models/model_meta.json');
      final meta = jsonDecode(metaRaw) as Map<String, dynamic>;
      final explain = meta['explainability'] as Map<String, dynamic>?;
      final ref = (explain?['reference_point'] as List?)
          ?.map((e) => (e as num).toDouble())
          .toList();
      if (ref != null && ref.length == _inputShape!.last) {
        _referencePoint = ref;
      }
    } catch (_) {
      // Metadata unavailable — Shapley features degrade gracefully below.
    }
    _referencePoint ??= List<double>.filled(_inputShape!.last, 0);

    // Hand ownership to a background isolate for non-blocking inference.
    _interpreter = await IsolateInterpreter.create(address: interpreter.address);

    // Measure the deployed (quantized) model's own baseline so Shapley sums
    // match what the UI displays — the float-model baseline differs slightly.
    _referenceScore = await predict(_referencePoint!);
  }

  /// Runs one forward pass and returns the dequantized stress index (0-100).
  ///
  /// Int8 quantized model: inputs are quantized with the tensor's scale and
  /// zero-point, outputs are dequantized symmetrically. All math happens
  /// on-device; nothing leaves the process.
  Future<double> predict(List<double> features) async {
    final out = await predictBatch([features]);
    return out.single;
  }

  /// Evaluates a batch of feature rows in a single TFLite call. The deployed
  /// graph takes a dynamic batch dimension, which is what makes on-device
  /// exact Shapley feasible: all 64 coalitions run as ONE inference.
  Future<List<double>> predictBatch(List<List<double>> batch) async {
    final interpreter = _interpreter;
    if (interpreter == null) {
      throw StateError('MLEngine.load() must complete before predict()');
    }
    if (batch.isEmpty) return const [];
    final width = _inputShape!.last;

    final input = List.generate(
      batch.length,
      (r) => List.generate(
        width,
        (j) => _quantize(batch[r][j], _inScale, _inZeroPoint),
      ),
      growable: false,
    );
    final output = List.generate(
      batch.length,
      (_) => List.filled(_outputShape!.last, 0, growable: false),
      growable: false,
    );

    await interpreter.run(input, output);

    return [
      for (final row in output)
        ((row[0].toDouble() - _outZeroPoint) * _outScale).clamp(0.0, 100.0),
    ];
  }

  /// Convenience wrapper used across the UI.
  Future<double> predictStress({
    required double mood,
    required double sleepHours,
    required double readiness,
    required int nightPatrolStreak,
    required int deploymentDays,
    required bool cancelledLeaveRecently,
  }) async {
    final out = await evaluateWithExplanation(
      mood: mood,
      sleepHours: sleepHours,
      readiness: readiness,
      nightPatrolStreak: nightPatrolStreak,
      deploymentDays: deploymentDays,
      cancelledLeaveRecently: cancelledLeaveRecently,
    );
    return out.score;
  }

  /// Full Edge-AI evaluation: score + exact Shapley attribution, all
  /// computed on-device (64-coalition batch = 1 TFLite invocation).
  Future<StressEvaluation> evaluateWithExplanation({
    required double mood,
    required double sleepHours,
    required double readiness,
    required int nightPatrolStreak,
    required int deploymentDays,
    required bool cancelledLeaveRecently,
  }) async {
    final features = stressFeatures(
      mood: mood,
      sleepHours: sleepHours,
      readiness: readiness,
      nightPatrolStreak: nightPatrolStreak,
      deploymentDays: deploymentDays,
      cancelledLeaveRecently: cancelledLeaveRecently,
    );
    final sw = Stopwatch()..start();
    final score = await predict(features);
    final phi = await exactShapleyValues(
      modelBatch: predictBatch,
      instance: features,
      referencePoint: referencePoint,
    );
    sw.stop();

    final contributions = <ShapleyContribution>[
      for (var i = 0; i < phi.length; i++)
        ShapleyContribution(
          featureIndex: i,
          label: kStressFeatureNames[i],
          value: phi[i],
        ),
    ];
    contributions.sort((a, b) => b.value.abs().compareTo(a.value.abs()));

    return StressEvaluation(
      score: score,
      contributions: contributions,
      referenceScore: referenceScore,
      inferenceMs: sw.elapsedMilliseconds,
    );
  }

  static int _quantize(double value, double scale, int zeroPoint) {
    final q = (value / scale).round() + zeroPoint;
    return q.clamp(-128, 127);
  }

  void dispose() {
    _interpreter?.close();
    _interpreter = null;
  }
}

/// One complete on-device evaluation: the score, its game-theoretic
/// explanation, and timing.
class StressEvaluation {
  final double score;
  final List<ShapleyContribution> contributions;
  final double referenceScore;
  final int inferenceMs;

  StressEvaluation({
    required this.score,
    required this.contributions,
    required this.referenceScore,
    required this.inferenceMs,
  });

  /// Sum of all attributions — must equal score − referenceScore (the
  /// Shapley efficiency identity).
  double get attributionSum =>
      contributions.fold(0.0, (sum, c) => sum + c.value);
}

/// Kept for audit-trail math and tests that need a deterministic reference;
/// NOT used for on-device scoring (that is the TFLite model's job).
double heuristicStressReference({
  required double mood,
  required double sleepHours,
  required double readiness,
}) {
  final moodFactor = (5.0 - mood) * 12.0;
  final sleepFactor = (8.0 - sleepHours).clamp(0.0, 8.0).toDouble() * 4.5;
  final readinessFactor = (5.0 - readiness) * 8.0;
  return (moodFactor + sleepFactor + readinessFactor).clamp(0.0, 100.0);
}

double laplaceNoise({required double scale, Random? rng}) {
  final random = rng ?? Random.secure();
  final u = random.nextDouble() - 0.5;
  if (u == 0) return 0;
  return -scale * (u.isNegative ? -1 : 1) * log(1 - 2 * u.abs());
}
