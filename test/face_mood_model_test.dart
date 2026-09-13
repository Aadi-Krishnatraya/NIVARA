import 'package:flutter_test/flutter_test.dart';
import 'package:nivara_app/features/checkin/face_mood_model.dart';

void main() {
  final model = FaceMoodModel();

  MoodEstimate estimateOf(List<FaceSignal> signals) => model.estimate(signals);

  group('FaceMoodModel — single frame mapping', () {
    test('beaming smile maps to the top of the scale', () {
      final mood = model.frameMood(const FaceSignal(smilingProbability: 1.0));
      expect(mood, greaterThanOrEqualTo(4.5));
    });

    test('flat expression with heavy eyes maps to the low end', () {
      final mood = model.frameMood(const FaceSignal(
        smilingProbability: 0.0,
        leftEyeOpenProbability: 0.0,
        rightEyeOpenProbability: 0.0,
      ));
      expect(mood, lessThanOrEqualTo(2.0));
    });

    test('neutral resting face stays near the midpoint', () {
      final mood = model.frameMood(const FaceSignal(
        smilingProbability: 0.5,
        leftEyeOpenProbability: 0.5,
        rightEyeOpenProbability: 0.5,
      ));
      expect(mood, inExclusiveRange(2.7, 3.3));
    });

    test('extreme head tilt penalizes the estimate', () {
      final straight = model.frameMood(const FaceSignal(smilingProbability: 0.5));
      final tilted = model.frameMood(const FaceSignal(
        smilingProbability: 0.5,
        headEulerAngleZ: 55,
      ));
      expect(tilted, lessThan(straight));
    });

    test('result always stays on the 1..5 scale', () {
      for (final smile in [0.0, 0.25, 0.5, 0.75, 1.0]) {
        final mood = model.frameMood(FaceSignal(smilingProbability: smile));
        expect(mood, inInclusiveRange(1.0, 5.0));
      }
    });
  });

  group('FaceMoodModel — aggregation', () {
    test('empty/unused frames yield a neutral low-confidence fallback', () {
      final result = estimateOf(const []);
      expect(result.suggestedMood, 3.0);
      expect(result.confidence, 0);
      expect(result.rationale, contains('manually'));
    });

    test('consistent happy frames snap to 0.5 grid with high confidence', () {
      final signals = List.generate(
        5,
        (_) => const FaceSignal(
          smilingProbability: 0.9,
          leftEyeOpenProbability: 0.9,
          rightEyeOpenProbability: 0.9,
        ),
      );
      final result = estimateOf(signals);
      expect(result.suggestedMood, greaterThanOrEqualTo(4.0));
      expect(result.suggestedMood * 2, (result.suggestedMood * 2).roundToDouble());
      expect(result.confidence, greaterThan(0.7));
      expect(result.rationale, contains('smile'));
    });

    test('median is robust to one outlier frame', () {
      final happy = const FaceSignal(smilingProbability: 0.9);
      final sad = const FaceSignal(smilingProbability: 0.0);
      final result = estimateOf([happy, happy, happy, happy, sad]);
      expect(result.suggestedMood, greaterThanOrEqualTo(4.0));
    });

    test('blinks do not collapse the score', () {
      // Eye-open signals vary; smile stays consistently mid.
      final signals = [
        const FaceSignal(smilingProbability: 0.5, leftEyeOpenProbability: 0.9, rightEyeOpenProbability: 0.9),
        const FaceSignal(smilingProbability: 0.5, leftEyeOpenProbability: 0.1, rightEyeOpenProbability: 0.1),
        const FaceSignal(smilingProbability: 0.5, leftEyeOpenProbability: 0.8, rightEyeOpenProbability: 0.8),
      ];
      final result = estimateOf(signals);
      expect(result.suggestedMood, inInclusiveRange(2.0, 4.0));
    });

    test('suggestion lands on the 0.5 grid for ragged inputs', () {
      final signals = List.generate(
        5,
        (i) => FaceSignal(smilingProbability: 0.2 + i * 0.11),
      );
      final result = estimateOf(signals);
      expect((result.suggestedMood * 2) % 1, 0);
      expect(result.suggestedMood, inInclusiveRange(1.0, 5.0));
    });
  });

  group('FaceSignal', () {
    test('eyeOpenProbability averages available eyes only', () {
      const one = FaceSignal(leftEyeOpenProbability: 0.2);
      expect(one.eyeOpenProbability, 0.2);
      const both = FaceSignal(leftEyeOpenProbability: 0.2, rightEyeOpenProbability: 0.6);
      expect(both.eyeOpenProbability, closeTo(0.4, 1e-9));
      const none = FaceSignal();
      expect(none.eyeOpenProbability, isNull);
      expect(none.isUsable, isFalse);
    });
  });
}
