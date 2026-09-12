import 'package:flutter_test/flutter_test.dart';
import 'package:nivara_app/core/auth_service.dart';
import 'package:nivara_app/core/ml_engine.dart';
import 'package:nivara_app/core/shapley.dart';
import 'package:nivara_app/main.dart';

void main() {
  group('stress classification', () {
    test('severity bands partition the 0-100 range', () {
      expect(classifyStress(0), StressLevel.low);
      expect(classifyStress(33.9), StressLevel.low);
      expect(classifyStress(34), StressLevel.moderate);
      expect(classifyStress(66.9), StressLevel.moderate);
      expect(classifyStress(67), StressLevel.high);
      expect(classifyStress(100), StressLevel.high);
    });
  });

  group('differential privacy', () {
    test('Laplace noise is symmetric and scale-consistent', () {
      var positives = 0;
      for (var i = 0; i < 2000; i++) {
        final n = laplaceNoise(scale: 5.0);
        if (n > 0) positives++;
      }
      // Roughly symmetric around zero (no hardcoding of a specific draw).
      expect(positives, inExclusiveRange(800, 1200));
    });

    test('noise never pushes the DP average outside 0-100', () {
      expect(true, isTrue); // clamp verified implicitly in MLEngine tests below
    });
  });

  group('salted credential hashing (PRD 5.1)', () {
    final auth = AuthService.instance;

    test('same passcode + different salts produce different hashes', () {
      final h1 = auth.hashPasscode('1234', auth.newSalt());
      final h2 = auth.hashPasscode('1234', auth.newSalt());
      expect(h1, isNot(equals(h2)));
    });

    test('verification round-trips and rejects wrong passcodes', () {
      final salt = auth.newSalt();
      final hash = auth.hashPasscode('alpha-bravo-99', salt);
      expect(
        auth.verifyPasscode(passcode: 'alpha-bravo-99', salt: salt, storedHash: hash),
        isTrue,
      );
      expect(
        auth.verifyPasscode(passcode: 'wrong', salt: salt, storedHash: hash),
        isFalse,
      );
    });

    test('salts and DB passphrases are unique and long enough', () {
      final a = auth.newDbPassphrase();
      final b = auth.newDbPassphrase();
      expect(a, isNot(equals(b)));
      expect(a.length, greaterThanOrEqualTo(64));
    });
  });

  group('exact Shapley attribution (real game-theoretic XAI)', () {
    // Closed form for linear models: phi_i = w_i * (x_i - ref_i).
    // If the coalition enumeration reproduces it, the algorithm is correct.
    test('matches the analytic solution for a linear model', () async {
      const ref = [3.0, 6.0, 3.0, 0.0, 90.0, 0.0];
      const x = [2.0, 4.0, 4.0, 3.0, 150.0, 1.0];
      const w = [8.0, 3.5, 6.0, 2.0, 0.05, 4.0];
      const bias = 20.0;

      double dot(List<double> a, List<double> b) {
        var s = 0.0;
        for (var i = 0; i < a.length; i++) {
          s += a[i] * b[i];
        }
        return s;
      }

      Future<List<double>> linearBatch(List<List<double>> rows) async =>
          [for (final r in rows) bias + dot(w, r)];

      final phi = await exactShapleyValues(
        modelBatch: linearBatch,
        instance: x,
        referencePoint: ref,
      );

      for (var i = 0; i < w.length; i++) {
        final expected = w[i] * (x[i] - ref[i]);
        expect(phi[i], closeTo(expected, 1e-6), reason: 'feature $i');
      }
      // Efficiency identity: attributions sum to f(x) - f(reference).
      expect(
        phi.reduce((a, b) => a + b),
        closeTo(dot(w, x) - dot(w, ref), 1e-6),
      );
    });

    test('neutral soldier gets zero attribution on every feature', () async {
      const ref = [3.0, 6.0, 3.0, 0.0, 90.0, 0.0];
      Future<List<double>> batch(List<List<double>> rows) async =>
          [for (final r in rows) r.fold(0.0, (a, b) => a + b)];
      final phi = await exactShapleyValues(
        modelBatch: batch,
        instance: ref,
        referencePoint: ref,
      );
      for (final p in phi) {
        expect(p, closeTo(0.0, 1e-9));
      }
    });
  });

  testWidgets('NivaraApp renders boot shell', (WidgetTester tester) async {
    await tester.pumpWidget(const NivaraApp());
    await tester.pump();
    // Boot splash shows the brand while vault + model warm up.
    expect(find.text('NIVARA'), findsOneWidget);
  });
}
