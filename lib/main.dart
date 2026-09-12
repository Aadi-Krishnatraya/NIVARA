import 'package:flutter/material.dart';

import 'core/database_helper.dart';
import 'core/ml_engine.dart';
import 'core/ui_theme.dart';
import 'core/user_session.dart';
import 'features/auth/login_screen.dart';
import 'features/checkin/checkin_screen.dart';
import 'features/analytics/screens/stress_trends_screen.dart';
import 'features/coping/coping_screen.dart';
import 'features/support/support_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const NivaraApp());
}

/// Application root. On startup it (1) generates/loads the per-device
/// encrypted-vault passphrase, (2) pre-warms the quantized TFLite model in
/// its background isolate, and (3) ensures the editable support directory
/// exists. No account, score, or contact is hardcoded anywhere.
class NivaraApp extends StatefulWidget {
  const NivaraApp({super.key});

  @override
  State<NivaraApp> createState() => _NivaraAppState();
}

class _NivaraAppState extends State<NivaraApp> {
  bool _booting = true;
  String? _bootError;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    try {
      // Touches the vault (creates passphrase on first run).
      await DatabaseHelper.instance.database;
      await DatabaseHelper.instance.seedDefaultContacts();
      // Loads the real model into the isolate interpreter.
      await MLEngine.instance.load();
    } catch (e) {
      setState(() => _bootError = '$e');
    }
    if (mounted) setState(() => _booting = false);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'NIVARA',
      debugShowCheckedModeBanner: false,
      theme: nivaraTheme(),
      home: _booting
          ? const _BootSplash()
          : _bootError != null
              ? _BootError(message: _bootError!)
              : const LoginScreen(),
    );
  }
}

class _BootSplash extends StatelessWidget {
  const _BootSplash();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NivaraColors.bg,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const NivaraMark(size: 92),
            const SizedBox(height: 24),
            const Text('NIVARA',
                style: TextStyle(
                    color: NivaraColors.textHi,
                    fontSize: 28,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 6)),
            const SizedBox(height: 6),
            Text('OPERATIONAL READINESS · ON-DEVICE',
                style: TextStyle(
                    color: NivaraColors.textLow,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 2.2)),
            const SizedBox(height: 36),
            const SizedBox(
              width: 26,
              height: 26,
              child: CircularProgressIndicator(
                  strokeWidth: 2.4, color: NivaraColors.accent),
            ),
            const SizedBox(height: 18),
            const Text('Preparing encrypted vault and on-device model…',
                style: TextStyle(color: NivaraColors.textLow, fontSize: 11.5)),
          ],
        ),
      ),
    );
  }
}

class _BootError extends StatelessWidget {
  final String message;
  const _BootError({required this.message});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NivaraColors.bg,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 56, color: NivaraColors.danger),
              const SizedBox(height: 16),
              const Text('Startup failure',
                  style: TextStyle(
                      color: NivaraColors.textHi,
                      fontSize: 18,
                      fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text(message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: NivaraColors.textMid, fontSize: 12)),
            ],
          ),
        ),
      ),
    );
  }
}

class SoldierMainContainer extends StatefulWidget {
  final UserSession session;

  const SoldierMainContainer({super.key, required this.session});

  @override
  State<SoldierMainContainer> createState() => _SoldierMainContainerState();
}

class _SoldierMainContainerState extends State<SoldierMainContainer> {
  int _currentIndex = 0;
  int _trendsVisits = 0;

  void _onTabTapped(int index) {
    setState(() {
      _currentIndex = index;
      // Re-keying forces the trends screen to re-query the vault on every
      // visit, so a freshly logged check-in appears immediately.
      if (index == 1) _trendsVisits++;
    });
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      DailyCheckInScreen(session: widget.session),
      StressTrendsScreen(
        key: ValueKey('trends-$_trendsVisits'),
        session: widget.session,
      ),
      const CopingLibraryScreen(),
      const ConfidentialSupportScreen(),
    ];

    return Scaffold(
      backgroundColor: NivaraColors.bg,
      appBar: AppBar(
        title: Text('Soldier View (${widget.session.name})'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Log out',
            onPressed: () {
              Navigator.of(context).pushAndRemoveUntil(
                MaterialPageRoute(builder: (_) => const LoginScreen()),
                (route) => false,
              );
            },
          )
        ],
      ),
      body: IndexedStack(index: _currentIndex, children: pages),
      bottomNavigationBar: NavigationBarTheme(
        data: NavigationBarThemeData(
          backgroundColor: NivaraColors.surface,
          indicatorColor: NivaraColors.accentSoft,
          iconTheme: WidgetStateProperty.resolveWith((s) => IconThemeData(
              color: s.contains(WidgetState.selected)
                  ? NivaraColors.accent
                  : NivaraColors.textLow)),
          labelTextStyle: WidgetStateProperty.resolveWith((s) => TextStyle(
              fontSize: 11,
              fontWeight: s.contains(WidgetState.selected)
                  ? FontWeight.w700
                  : FontWeight.w500,
              color: s.contains(WidgetState.selected)
                  ? NivaraColors.accent
                  : NivaraColors.textLow)),
        ),
        child: NavigationBar(
          height: 68,
          selectedIndex: _currentIndex,
          onDestinationSelected: _onTabTapped,
          destinations: const [
            NavigationDestination(
                icon: Icon(Icons.edit_calendar_outlined),
                selectedIcon: Icon(Icons.edit_calendar),
                label: 'Check-In'),
            NavigationDestination(
                icon: Icon(Icons.show_chart_outlined),
                selectedIcon: Icon(Icons.show_chart),
                label: 'Trends'),
            NavigationDestination(
                icon: Icon(Icons.self_improvement_outlined),
                selectedIcon: Icon(Icons.self_improvement),
                label: 'Coping'),
            NavigationDestination(
                icon: Icon(Icons.support_agent_outlined),
                selectedIcon: Icon(Icons.support_agent),
                label: 'Support'),
          ],
        ),
      ),
    );
  }
}
