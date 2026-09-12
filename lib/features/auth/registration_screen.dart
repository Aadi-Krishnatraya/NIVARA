import 'package:flutter/material.dart';

import 'package:nivara_app/core/database_helper.dart';
import 'package:nivara_app/core/ui_theme.dart';
import 'package:nivara_app/core/user_session.dart';
import '../../main.dart';
import '../commander/commander_screen.dart';

/// First-run account creation. There are no default users: the first person
/// to launch the app provisions their own identity. Passcodes are stored
/// only as salted SHA-256 verifiers (PRD §5.1).
class RegistrationScreen extends StatefulWidget {
  final String? initialUnit;

  const RegistrationScreen({super.key, this.initialUnit});

  @override
  State<RegistrationScreen> createState() => _RegistrationScreenState();
}

class _RegistrationScreenState extends State<RegistrationScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _unit = TextEditingController();
  final _passcode = TextEditingController();
  final _confirm = TextEditingController();
  UserRole _role = UserRole.soldier;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _unit.dispose();
    _passcode.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final session = await DatabaseHelper.instance.registerUser(
        name: _name.text,
        passcode: _passcode.text,
        role: _role,
        unitId: _unit.text,
      );
      await DatabaseHelper.instance.logAudit(
        actorId: session.userId,
        action: 'REGISTER',
        detail: 'role=${session.role.name} unit=${session.unitId} (credential hashed, salted)',
      );

      if (!mounted) return;
      final destination = session.isCommander
          ? CommanderScreen(session: session)
          : SoldierMainContainer(session: session);
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => destination),
        (route) => false,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.toString().replaceFirst(RegExp(r'^[A-Za-z]+\('), '').replaceFirst(RegExp(r'\)$'), '');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NivaraColors.bg,
      appBar: AppBar(title: Text('Provision Account')),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: EdgeInsets.fromLTRB(24, 8, 24, 24),
            children: [
              Center(child: NivaraMark(size: 64)),
              SizedBox(height: 10),
              Text(
                'Create the first identity on this device.\n'
                'Credentials are hashed with a unique random salt.',
                textAlign: TextAlign.center,
                style: TextStyle(color: NivaraColors.textMid, fontSize: 12.5, height: 1.45),
              ),
              SizedBox(height: 24),
              TextFormField(
                controller: _name,
                textCapitalization: TextCapitalization.words,
                style: TextStyle(color: NivaraColors.textHi),
                decoration: _decor('Full name / Service name', Icons.badge_outlined),
                validator: (v) =>
                    (v == null || v.trim().length < 3) ? 'Enter at least 3 characters' : null,
              ),
              SizedBox(height: 14),
              TextFormField(
                controller: _unit,
                textCapitalization: TextCapitalization.characters,
                style: TextStyle(color: NivaraColors.textHi, letterSpacing: 1.2),
                decoration: _decor('Unit (e.g. ALPHA_SQUAD)', Icons.groups_2_outlined),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Unit is required' : null,
              ),
              const SizedBox(height: 16),
              _roleCard(
                selected: _role == UserRole.soldier,
                icon: Icons.military_tech_outlined,
                title: 'Soldier',
                subtitle: 'Confidential check-ins · trends · support bridge',
                onTap: () => setState(() => _role = UserRole.soldier),
              ),
              SizedBox(height: 8),
              _roleCard(
                selected: _role == UserRole.commander,
                icon: Icons.shield_outlined,
                title: 'Commander',
                subtitle: 'Anonymized unit aggregates only — never individual data',
                onTap: () => setState(() => _role = UserRole.commander),
              ),
              SizedBox(height: 16),
              TextFormField(
                controller: _passcode,
                obscureText: true,
                keyboardType: TextInputType.number,
                style: TextStyle(color: NivaraColors.textHi, letterSpacing: 4),
                decoration: _decor('Passcode (min 4 characters)', Icons.key_outlined),
                validator: (v) =>
                    (v == null || v.length < 4) ? 'Minimum 4 characters' : null,
              ),
              SizedBox(height: 14),
              TextFormField(
                controller: _confirm,
                obscureText: true,
                keyboardType: TextInputType.number,
                style: TextStyle(color: NivaraColors.textHi, letterSpacing: 4),
                decoration: _decor('Confirm passcode', Icons.key_outlined),
                validator: (v) =>
                    v != _passcode.text ? 'Passcodes do not match' : null,
              ),
              if (_error != null) ...[
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: NivaraColors.danger.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: NivaraColors.danger.withValues(alpha: 0.35)),
                  ),
                  child: Text(_error!,
                      style: TextStyle(color: NivaraColors.danger, fontSize: 12.5),
                      textAlign: TextAlign.center),
                ),
              ],
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _busy ? null : _submit,
                child: _busy
                    ? const SizedBox(
                        width: 20, height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Color(0xFF04211D)))
                    : const Text('CREATE ACCOUNT'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _roleCard({
    required bool selected,
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: EdgeInsets.all(13),
        decoration: BoxDecoration(
          color: selected ? NivaraColors.accentSoft : NivaraColors.surfaceAlt,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
              color: selected
                  ? NivaraColors.accent.withValues(alpha: 0.6)
                  : NivaraColors.outline),
        ),
        child: Row(
          children: [
            Icon(icon,
                size: 22,
                color: selected ? NivaraColors.accent : NivaraColors.textLow),
            SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(
                          color:
                              selected ? NivaraColors.accent : NivaraColors.textHi,
                          fontSize: 14,
                          fontWeight: FontWeight.w700)),
                  SizedBox(height: 2),
                  Text(subtitle,
                      style: TextStyle(
                          color: selected
                              ? NivaraColors.accent.withValues(alpha: 0.75)
                              : NivaraColors.textLow,
                          fontSize: 11,
                          height: 1.3)),
                ],
              ),
            ),
            Icon(
                selected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                size: 18,
                color: selected ? NivaraColors.accent : NivaraColors.textLow),
          ],
        ),
      ),
    );
  }

  InputDecoration _decor(String label, IconData icon) {
    return InputDecoration(labelText: label, prefixIcon: Icon(icon, size: 20, color: NivaraColors.accent));
  }
}
