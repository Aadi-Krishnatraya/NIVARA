import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// PRD §5.1: identities/credentials never touch the database in plaintext.
/// Every soldier gets a unique random salt; the stored verifier is
/// SHA-256(passcode + salt). Salts are generated with a CSPRNG.
class AuthService {
  AuthService._();
  static final AuthService instance = AuthService._();

  final Random _secure = Random.secure();

  /// Cryptographically random hex string (default 32 hex chars = 128 bits).
  String randomHex({int bytes = 16}) {
    final values = List<int>.generate(bytes, (_) => _secure.nextInt(256));
    return values.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Per-user salt for credential storage and for the gateway pseudonym
  /// (PRD §5.1) — unique per account, never reused.
  String newSalt() => randomHex(bytes: 16);

  /// Cryptographically strong DB passphrase (256-bit), generated per device.
  String newDbPassphrase() => randomHex(bytes: 32);

  String hashPasscode(String passcode, String salt) {
    final digest = sha256.convert(utf8.encode('$passcode$salt'));
    return digest.toString();
  }

  bool verifyPasscode({
    required String passcode,
    required String salt,
    required String storedHash,
  }) {
    final computed = hashPasscode(passcode, salt);
    var diff = 0;
    for (var i = 0; i < computed.length; i++) {
      diff |= computed.codeUnitAt(i) ^ storedHash.codeUnitAt(i);
    }
    return diff == 0; // constant-time compare
  }
}
