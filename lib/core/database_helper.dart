import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';

import 'auth_service.dart';
import 'ml_engine.dart';
import 'user_session.dart';


/// AES-256 encrypted local vault (SQLCipher). The DB passphrase is a
/// 256-bit CSPRNG value generated on first launch and stored in device
/// preferences — nothing about this device's database is guessable or
/// hardcoded. All data stays on-device until an explicit sync phase.
class DatabaseHelper {
  DatabaseHelper._();
  static final DatabaseHelper instance = DatabaseHelper._();

  static Database? _database;
  static const String _dbFileName = 'nivara_vault.db';
  static const String _keyPrefName = 'nivara.db.passphrase';

  final AuthService _auth = AuthService.instance;
  final Random _random = Random.secure();

  /// Differential privacy parameters (PRD §5.2: Laplace noise on aggregates).
  static const double epsilon = 1.5;
  static const double sensitivity = 8.0;

  /// PRD §5.2: squad views with fewer than 5 active personnel are disabled.
  static const int squadPrivacyThreshold = 5;

  Future<Database> get database async => _database ??= await _open();

  Future<Database> _open() async {
    final prefs = await SharedPreferences.getInstance();
    var passphrase = prefs.getString(_keyPrefName);
    if (passphrase == null || passphrase.isEmpty) {
      passphrase = _auth.newDbPassphrase();
      await prefs.setString(_keyPrefName, passphrase);
    }

    final path = join(await getDatabasesPath(), _dbFileName);
    return openDatabase(
      path,
      password: passphrase,
      version: 4,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  // -------------------------------------------------------------------------
  // Schema
  // -------------------------------------------------------------------------
  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE users (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        salt TEXT NOT NULL,
        passcode_hash TEXT NOT NULL,
        role TEXT NOT NULL,
        unit_id TEXT NOT NULL,
        created_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE profiles (
        user_id TEXT PRIMARY KEY,
        night_patrol_streak INTEGER NOT NULL DEFAULT 0,
        deployment_days INTEGER NOT NULL DEFAULT 0,
        cancelled_leave INTEGER NOT NULL DEFAULT 0,
        updated_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE check_ins (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id TEXT NOT NULL,
        unit_id TEXT NOT NULL,
        mood REAL NOT NULL,
        sleep_hours REAL NOT NULL,
        physical_readiness REAL NOT NULL,
        stress_score REAL NOT NULL,
        attribution TEXT,
        timestamp TEXT NOT NULL,
        synced INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute('''
      CREATE TABLE audit_log (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        actor_id TEXT NOT NULL,
        action TEXT NOT NULL,
        detail TEXT NOT NULL,
        timestamp TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE contacts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        phone TEXT NOT NULL,
        category TEXT NOT NULL
      )
    ''');
    await db.execute('CREATE INDEX idx_checkins_user ON check_ins(user_id)');
    await db.execute('CREATE INDEX idx_checkins_unit ON check_ins(unit_id)');

    // Editable pre-loaded support directory (PRD §3.1). Users can change or
    // remove these; they are placeholders the unit fills with real numbers.
    await db.insert('audit_log', {
      'actor_id': 'system',
      'action': 'INIT',
      'detail': 'Encrypted vault created; passphrase generated on-device',
      'timestamp': DateTime.now().toIso8601String(),
    });
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 3) {
      // v1/v2 demo schema had seeded users and a narrower check_in table.
      // v3 is credential-based: rebuild the data tables locally.
      await db.execute('DROP TABLE IF EXISTS users');
      await db.execute('DROP TABLE IF EXISTS check_ins');
      await db.execute('DROP TABLE IF EXISTS audit_log');
      await _onCreate(db, newVersion);
      return;
    }
    if (oldVersion < 4) {
      // v4: per-check-in Shapley attributions (feature → points of stress).
      await db.execute('ALTER TABLE check_ins ADD COLUMN attribution TEXT');
    }
  }

  Future<void> seedDefaultContacts() async {
    final db = await database;
    final existing = Sqflite.firstIntValue(
      await db.rawQuery('SELECT COUNT(*) FROM contacts'),
    );
    if (existing != null && existing > 0) return;
    const defaults = [
      ('Peer Support Helpline', '1800-000-0000', 'peer'),
      ('Base Medical Officer', '1800-000-0001', 'medical'),
      ('Family Welfare Desk', '1800-000-0002', 'family'),
    ];
    final batch = db.batch();
    for (final (name, phone, category) in defaults) {
      batch.insert('contacts', {
        'name': name,
        'phone': phone,
        'category': category,
      });
    }
    await batch.commit(noResult: true);
  }

  // -------------------------------------------------------------------------
  // Registration & authentication (no default accounts exist)
  // -------------------------------------------------------------------------
  Future<UserSession> registerUser({
    required String name,
    required String passcode,
    required UserRole role,
    required String unitId,
  }) async {
    final trimmedName = name.trim();
    final trimmedUnit = unitId.trim().toUpperCase();
    if (trimmedName.isEmpty) throw ArgumentError('Name is required');
    if (trimmedUnit.isEmpty) throw ArgumentError('Unit is required');
    if (passcode.length < 4) {
      throw ArgumentError('Passcode must be at least 4 characters');
    }

    final db = await database;
    final duplicate = await db.query(
      'users',
      where: 'name = ? COLLATE NOCASE AND role = ?',
      whereArgs: [trimmedName, role.name],
      limit: 1,
    );
    if (duplicate.isNotEmpty) {
      throw StateError('An account with this name and role already exists');
    }

    final salt = _auth.newSalt();
    final id = '${role.name.substring(0, 3)}_${_auth.randomHex(bytes: 6)}';
    await db.insert('users', {
      'id': id,
      'name': trimmedName,
      'salt': salt,
      'passcode_hash': _auth.hashPasscode(passcode, salt),
      'role': role.name,
      'unit_id': trimmedUnit,
      'created_at': DateTime.now().toIso8601String(),
    });
    await db.insert('profiles', {
      'user_id': id,
      'night_patrol_streak': 0,
      'deployment_days': 0,
      'cancelled_leave': 0,
      'updated_at': DateTime.now().toIso8601String(),
    });

    return UserSession(
      userId: id,
      name: trimmedName,
      unitId: trimmedUnit,
      role: role,
    );
  }

  Future<UserSession?> authenticate(String name, String passcode) async {
    final db = await database;
    final rows = await db.query(
      'users',
      where: 'name = ? COLLATE NOCASE',
      whereArgs: [name.trim()],
      limit: 1,
    );
    if (rows.isEmpty) return null;

    final row = rows.first;
    final ok = _auth.verifyPasscode(
      passcode: passcode,
      salt: row['salt'] as String,
      storedHash: row['passcode_hash'] as String,
    );
    if (!ok) return null;

    return UserSession(
      userId: row['id'] as String,
      name: row['name'] as String,
      unitId: row['unit_id'] as String,
      role: row['role'] == UserRole.commander.name
          ? UserRole.commander
          : UserRole.soldier,
    );
  }

  // -------------------------------------------------------------------------
  // Operational context (objective factors feeding the model)
  // -------------------------------------------------------------------------
  Future<Map<String, int>> getOperationalContext(String userId) async {
    final db = await database;
    final rows = await db.query(
      'profiles',
      where: 'user_id = ?',
      whereArgs: [userId],
      limit: 1,
    );
    if (rows.isEmpty) {
      return {'night_patrol_streak': 0, 'deployment_days': 0, 'cancelled_leave': 0};
    }
    final r = rows.first;
    return {
      'night_patrol_streak': r['night_patrol_streak'] as int? ?? 0,
      'deployment_days': r['deployment_days'] as int? ?? 0,
      'cancelled_leave': r['cancelled_leave'] as int? ?? 0,
    };
  }

  Future<void> saveOperationalContext(
    String userId, {
    required int nightPatrolStreak,
    required int deploymentDays,
    required bool cancelledLeaveRecently,
  }) async {
    final db = await database;
    await db.insert(
      'profiles',
      {
        'user_id': userId,
        'night_patrol_streak': nightPatrolStreak.clamp(0, 60),
        'deployment_days': deploymentDays.clamp(0, 730),
        'cancelled_leave': cancelledLeaveRecently ? 1 : 0,
        'updated_at': DateTime.now().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // -------------------------------------------------------------------------
  // Check-ins
  // -------------------------------------------------------------------------
  Future<int> insertCheckIn({
    required String userId,
    required String unitId,
    required double mood,
    required double sleepHours,
    required double readiness,
    required double stressScore,
    Map<String, double>? attribution,
  }) async {
    final db = await database;
    return db.insert('check_ins', {
      'user_id': userId,
      'unit_id': unitId,
      'mood': mood,
      'sleep_hours': sleepHours,
      'physical_readiness': readiness,
      'stress_score': stressScore,
      'attribution': attribution == null
          ? null
          : jsonEncode(attribution.map((k, v) =>
              MapEntry(k, double.parse(v.toStringAsFixed(3))))),
      'timestamp': DateTime.now().toIso8601String(),
      'synced': 0,
    });
  }

  Future<List<Map<String, Object?>>> getCheckInsForUser(String userId) async {
    final db = await database;
    return db.query(
      'check_ins',
      where: 'user_id = ?',
      whereArgs: [userId],
      orderBy: 'timestamp ASC',
    );
  }

  // -------------------------------------------------------------------------
  // Commander aggregates (anonymized by design — no identity columns read)
  // -------------------------------------------------------------------------
  Future<int> getSquadSize(String unitId) async {
    final db = await database;
    final rows = await db.rawQuery(
      'SELECT COUNT(DISTINCT user_id) AS n FROM check_ins WHERE unit_id = ?',
      [unitId],
    );
    return Sqflite.firstIntValue(rows) ?? 0;
  }

  Future<Map<String, Object?>> getUnitMetrics(String unitId) async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT COUNT(*) AS total,
             COUNT(DISTINCT user_id) AS contributors,
             AVG(stress_score) AS avg_stress
      FROM check_ins
      WHERE unit_id = ?
    ''', [unitId]);
    return rows.first;
  }

  Future<List<Map<String, Object?>>> getUnitTrend(String unitId, {int days = 7}) async {
    final db = await database;
    return db.rawQuery('''
      SELECT date(timestamp) AS day, AVG(stress_score) AS avg_stress
      FROM check_ins
      WHERE unit_id = ? AND date(timestamp) >= date('now', ?)
      GROUP BY day
      ORDER BY day ASC
    ''', [unitId, '-${days - 1} days']);
  }

  /// Aggregate-only count of check-ins inside the last [days] days for the
  /// unit. No identity columns are selected.
  Future<int> getUnitLogCount(String unitId, {int days = 7}) async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT COUNT(*) AS n FROM check_ins
      WHERE unit_id = ? AND date(timestamp) >= date('now', ?)
    ''', [unitId, '-${days - 1} days']);
    return Sqflite.firstIntValue(rows) ?? 0;
  }

  /// How many distinct contributors have checked in today (unit aggregate).
  Future<int> getUnitTodayContributors(String unitId) async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT COUNT(DISTINCT user_id) AS n FROM check_ins
      WHERE unit_id = ? AND date(timestamp) = date('now')
    ''', [unitId]);
    return Sqflite.firstIntValue(rows) ?? 0;
  }

  /// Log counts per severity band (unit-wide). Callers add Laplace noise
  /// before displaying shares, keeping the display differentially private.
  Future<Map<String, int>> getUnitBandCounts(String unitId) async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT
        SUM(CASE WHEN stress_score >= 67 THEN 1 ELSE 0 END) AS high,
        SUM(CASE WHEN stress_score >= 34 AND stress_score < 67 THEN 1 ELSE 0 END) AS moderate,
        SUM(CASE WHEN stress_score < 34 THEN 1 ELSE 0 END) AS low
      FROM check_ins WHERE unit_id = ?
    ''', [unitId]);
    final r = rows.first;
    return {
      'high': (r['high'] as int?) ?? 0,
      'moderate': (r['moderate'] as int?) ?? 0,
      'low': (r['low'] as int?) ?? 0,
    };
  }

  // -------------------------------------------------------------------------
  // Units Under Command — all-units overview (aggregates only, identity-safe)
  // -------------------------------------------------------------------------

  /// One aggregate row per unit known on this device. Only unit-level
  /// counters are read — never names or user ids. Per PRD §5.2 the caller
  /// must suppress rows where contributors < squadPrivacyThreshold.
  Future<List<Map<String, Object?>>> getAllUnitsOverview() async {
    final db = await database;
    return db.rawQuery('''
      SELECT unit_id AS unit,
             COUNT(DISTINCT user_id) AS contributors,
             COUNT(*) AS total_logs,
             AVG(stress_score) AS avg_stress,
             MAX(timestamp) AS last_ts
      FROM check_ins
      GROUP BY unit_id
      ORDER BY unit_id ASC
    ''');
  }

  /// Distinct contributors per unit who checked in today (identity-safe).
  Future<Map<String, int>> getTodayContributorsByUnit() async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT unit_id AS unit, COUNT(DISTINCT user_id) AS n
      FROM check_ins
      WHERE date(timestamp) = date('now')
      GROUP BY unit_id
    ''');
    return {
      for (final r in rows) (r['unit'] as String): (r['n'] as int?) ?? 0,
    };
  }

  /// Most recent check-in timestamp for a unit (null when none).
  Future<DateTime?> getUnitLastCheckIn(String unitId) async {
    final db = await database;
    final rows = await db.rawQuery(
      'SELECT MAX(timestamp) AS ts FROM check_ins WHERE unit_id = ?',
      [unitId],
    );
    final ts = rows.first['ts'] as String?;
    return ts == null ? null : DateTime.tryParse(ts);
  }

  /// Every unit known on this device (registered personnel may exist before
  /// the unit's first check-in). Reads the unit_id column only — identity-safe.
  Future<Set<String>> getAllKnownUnitIds() async {
    final db = await database;
    final rows = await db.rawQuery('SELECT DISTINCT unit_id FROM users');
    return {for (final r in rows) (r['unit_id'] as String).toUpperCase()};
  }

  /// Load a single unit's full aggregate bundle for the details view.
  /// Returns null when the unit is below the privacy threshold — the
  /// caller then renders the blocked state instead of any aggregate.
  Future<Map<String, Object?>?> getUnitDetailBundle(String unitId) async {
    final contributors = await getSquadSize(unitId);
    if (contributors < squadPrivacyThreshold) return null;
    final metrics = await getUnitMetrics(unitId);
    final trend = await getUnitTrend(unitId);
    final drivers = await getUnitDrivers(unitId);
    final attributions = await getUnitMeanAttributions(unitId);
    final bandCounts = await getUnitBandCounts(unitId);
    final weekLogs = await getUnitLogCount(unitId);
    final todayContributors = await getUnitTodayContributors(unitId);
    return {
      'contributors': contributors,
      'metrics': metrics,
      'trend': trend,
      'drivers': drivers,
      'attributions': attributions,
      'bandCounts': bandCounts,
      'weekLogs': weekLogs,
      'todayContributors': todayContributors,
    };
  }

  /// Real XAI (PRD §3.2): pools the per-check-in Shapley attributions of the
  /// whole unit into mean model-explained drivers. Identity never leaves the
  /// aggregation — only feature-level means are returned.
  Future<Map<String, double>> getUnitMeanAttributions(String unitId) async {
    final db = await database;
    final rows = await db.rawQuery(
      'SELECT attribution FROM check_ins WHERE unit_id = ? AND attribution IS NOT NULL',
      [unitId],
    );
    final sums = <String, double>{};
    final counts = <String, int>{};
    for (final row in rows) {
      try {
        final map = jsonDecode(row['attribution'] as String) as Map<String, dynamic>;
        map.forEach((feature, points) {
          final p = points is num
              ? points.toDouble()
              : double.tryParse('$points') ?? 0.0;
          sums[feature] = (sums[feature] ?? 0) + p;
          counts[feature] = (counts[feature] ?? 0) + 1;
        });
      } catch (_) {
        // Malformed row — ignore it rather than corrupt the aggregate.
      }
    }
    return sums.map((feature, sum) => MapEntry(feature, counts[feature]! > 0 ? sum / counts[feature]! : 0.0));
  }

  /// XAI-style driver breakdown (PRD §3.2): objective factors behind the
  /// aggregate stress level, rendered as explainable causes on the dashboard.
  Future<Map<String, Object?>> getUnitDrivers(String unitId) async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT COUNT(*) AS n,
             AVG(mood) AS avg_mood,
             AVG(sleep_hours) AS avg_sleep,
             AVG(physical_readiness) AS avg_readiness,
             AVG(CASE WHEN sleep_hours < 6.0 THEN 1.0 ELSE 0.0 END) AS pct_low_sleep,
             AVG(CASE WHEN physical_readiness < 2.5 THEN 1.0 ELSE 0.0 END) AS pct_low_readiness,
             AVG(CASE WHEN mood < 2.5 THEN 1.0 ELSE 0.0 END) AS pct_low_mood
      FROM check_ins
      WHERE unit_id = ?
    ''', [unitId]);
    return rows.first;
  }

  // -------------------------------------------------------------------------
  // Differential privacy (PRD §5.2)
  // -------------------------------------------------------------------------
  double differentiallyPrivateAverage(double rawAverage) {
    final scale = sensitivity / epsilon;
    return (rawAverage + laplaceNoise(scale: scale, rng: _random))
        .clamp(0.0, 100.0)
        .toDouble();
  }

  /// Exposes a single Laplace draw for dashboard share metrics, so
  /// percentage-style displays carry the same DP protection as averages.
  double laplaceNoisePublic({double scale = 2.0}) =>
      laplaceNoise(scale: scale, rng: _random);

  // -------------------------------------------------------------------------
  // Immutable audit trail (PRD §3.3) — append-only, no update/delete path
  // -------------------------------------------------------------------------
  Future<void> logAudit({
    required String actorId,
    required String action,
    required String detail,
  }) async {
    try {
      final db = await database;
      await db.insert('audit_log', {
        'actor_id': actorId,
        'action': action,
        'detail': detail,
        'timestamp': DateTime.now().toIso8601String(),
      });
    } catch (e) {
      debugPrint('Audit write failed: $e');
    }
  }

  Future<List<Map<String, Object?>>> getAuditLog({int limit = 50}) async {
    final db = await database;
    return db.query('audit_log', orderBy: 'id DESC', limit: limit);
  }

  // -------------------------------------------------------------------------
  // Support directory (fully editable — nothing is fixed)
  // -------------------------------------------------------------------------
  Future<List<Map<String, Object?>>> getContacts() async {
    final db = await database;
    return db.query('contacts', orderBy: 'id ASC');
  }

  Future<int> upsertContact({int? id, required String name, required String phone, required String category}) async {
    final db = await database;
    final row = {'name': name.trim(), 'phone': phone.trim(), 'category': category};
    if (id == null) return db.insert('contacts', row);
    return db.update('contacts', row, where: 'id = ?', whereArgs: [id]);
  }

  Future<int> deleteContact(int id) async {
    final db = await database;
    return db.delete('contacts', where: 'id = ?', whereArgs: [id]);
  }
}
