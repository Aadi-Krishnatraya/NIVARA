import 'package:flutter/material.dart';

import 'package:nivara_app/core/database_helper.dart';
import 'package:nivara_app/core/ui_theme.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';
import '../../main.dart';
import '../commander/commander_screen.dart';
import 'registration_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _name = TextEditingController();
  final _passcode = TextEditingController();
  bool _busy = false;
  bool _hasAccounts = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _checkFirstRun();
  }

  @override
  void dispose() {
    _name.dispose();
    _passcode.dispose();
    super.dispose();
  }

  Future<void> _checkFirstRun() async {
    final db = await DatabaseHelper.instance.database;
    final count = Sqflite.firstIntValue(
      await db.rawQuery('SELECT COUNT(*) FROM users'),
    );
    if (!mounted) return;
    setState(() => _hasAccounts = (count ?? 0) > 0);
  }

  Future<void> _submit() async {
    if (_name.text.trim().isEmpty || _passcode.text.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });

    final session = await DatabaseHelper.instance.authenticate(
      _name.text,
      _passcode.text,
    );

    if (!mounted) return;
    if (session == null) {
      await DatabaseHelper.instance.logAudit(
        actorId: 'unknown',
        action: 'AUTH_FAIL',
        detail: 'Failed login attempt (credential verification failed)',
      );
      setState(() {
        _busy = false;
        _error = 'Invalid name or passcode.';
      });
      return;
    }

    await DatabaseHelper.instance.logAudit(
      actorId: session.userId,
      action: 'AUTH_OK',
      detail: 'role=${session.role.name} unit=${session.unitId}',
    );
    if (!mounted) return;

    final destination = session.isCommander
        ? CommanderScreen(session: session)
        : SoldierMainContainer(session: session);
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => destination),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NivaraColors.bg,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: EdgeInsets.symmetric(horizontal: 28, vertical: 24),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(height: 12),
                  Center(child: NivaraMark(size: 84)),
                  SizedBox(height: 22),
                  Text(
                    'NIVARA',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: NivaraColors.textHi,
                        fontSize: 30,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 6),
                  ),
                  SizedBox(height: 6),
                  Text(
                    'WELLNESS INTELLIGENCE · NEVER LEAVES THE DEVICE',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: NivaraColors.textLow,
                        fontSize: 9.5,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 1.6),
                  ),
                  SizedBox(height: 36),
                  TextField(
                    controller: _name,
                    textCapitalization: TextCapitalization.words,
                    style: TextStyle(color: NivaraColors.textHi),
                    decoration: InputDecoration(
                      labelText: 'Name / Service name',
                      prefixIcon:
                          Icon(Icons.badge_outlined, size: 20, color: NivaraColors.accent),
                    ),
                  ),
                  SizedBox(height: 14),
                  TextField(
                    controller: _passcode,
                    obscureText: true,
                    keyboardType: TextInputType.number,
                    style: TextStyle(
                        color: NivaraColors.textHi, letterSpacing: 4),
                    onSubmitted: (_) => _submit(),
                    decoration: const InputDecoration(
                      labelText: 'Passcode',
                      prefixIcon: Icon(Icons.key_outlined, size: 20, color: NivaraColors.accent),
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 14),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        color: NivaraColors.danger.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                            color: NivaraColors.danger.withValues(alpha: 0.35)),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.error_outline,
                              size: 16, color: NivaraColors.danger),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(_error!,
                                style: TextStyle(
                                    color: NivaraColors.danger, fontSize: 12.5)),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 22),
                  FilledButton(
                    onPressed: _busy ? null : _submit,
                    child: _busy
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Color(0xFF04211D)))
                        : const Text('AUTHENTICATE'),
                  ),
                  const SizedBox(height: 10),
                  TextButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => RegistrationScreen()),
                    ),
                    child: Text(
                      _hasAccounts
                          ? 'New device or new personnel? Provision an account'
                          : 'No accounts yet — provision the first one',
                      style: TextStyle(
                          color: NivaraColors.accent,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600),
                    ),
                  ),
                  SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.lock_outline,
                          size: 12, color: NivaraColors.textLow),
                      SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          'Credentials verified against salted SHA-256 hashes. '
                          'Raw passcodes are never stored (PRD §5.1).',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              color: NivaraColors.textLow,
                              fontSize: 10.5,
                              height: 1.45),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
