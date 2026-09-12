import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

/// Owns the app theme mode (dark / light / system), persisted through
/// shared_preferences. Kept as a singleton so any screen can flip the
/// theme — matching the [MLEngine.instance] pattern used elsewhere.
/// Also watches the platform brightness so SYSTEM mode follows the OS.
class ThemeController extends ChangeNotifier with WidgetsBindingObserver {
  ThemeController._() {
    WidgetsBinding.instance.addObserver(this);
  }

  static final ThemeController instance = ThemeController._();

  static const _prefKey = 'nivara.theme_mode';

  ThemeMode _mode = ThemeMode.dark;
  ThemeMode get mode => _mode;
  bool get isDark => _mode != ThemeMode.light;

  /// Restores the persisted mode and syncs the static palette. Called once
  /// during boot, before the first frame.
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _mode = switch (prefs.getString(_prefKey)) {
      'light' => ThemeMode.light,
      'system' => ThemeMode.system,
      _ => ThemeMode.dark,
    };
    syncPalette();
  }

  Future<void> setMode(ThemeMode mode) async {
    if (mode == _mode) return;
    _mode = mode;
    syncPalette();
    // Notify IMMEDIATELY (before the async pref write) so every listening
    // widget rebuilds on the next frame — without this the theme switch
    // only lands when some unrelated rebuild happens.
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKey, mode.name);
  }

  /// Toggles between the dark and light palettes.
  Future<void> toggle() =>
      setMode(isDark ? ThemeMode.light : ThemeMode.dark);

  /// Re-resolves the static [NivaraColors] palette from the current mode
  /// (and, for system mode, the platform brightness). Called by [NivaraApp]
  /// whenever the theme changes or the OS switches light/dark.
  void syncPalette() {
    final brightness = switch (_mode) {
      ThemeMode.light => Brightness.light,
      ThemeMode.dark => Brightness.dark,
      ThemeMode.system =>
        WidgetsBinding.instance.platformDispatcher.platformBrightness,
    };
    NivaraColors.syncWith(brightness);
  }

  @override
  void didChangePlatformBrightness() {
    super.didChangePlatformBrightness();
    // Only matters in system mode: re-sync the static palette and rebuild.
    if (_mode == ThemeMode.system) {
      syncPalette();
      notifyListeners();
    }
  }
}

/// Application root. On startup it (1) restores the persisted theme,
/// (2) generates/loads the per-device encrypted-vault passphrase, (3) pre-warms
/// the quantized TFLite model in its background isolate, and (4) ensures the
/// editable support directory exists. No account, score, or contact is
/// hardcoded anywhere.
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
      await ThemeController.instance.load();
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
    return ListenableBuilder(
      listenable: ThemeController.instance,
      builder: (context, _) => MaterialApp(
        title: 'NIVARA',
        debugShowCheckedModeBanner: false,
        themeMode: ThemeController.instance.mode,
        theme: nivaraLightTheme(),
        darkTheme: nivaraTheme(),
        home: _booting
            ? const _BootSplash()
            : _bootError != null
                ? _BootError(message: _bootError!)
                : const LoginScreen(),
      ),
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
            NivaraMark(size: 92),
            SizedBox(height: 24),
            Text('NIVARA',
                style: TextStyle(
                    color: NivaraColors.textHi,
                    fontSize: 28,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 6)),
            SizedBox(height: 6),
            Text('OPERATIONAL READINESS · ON-DEVICE',
                style: TextStyle(
                    color: NivaraColors.textLow,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 2.2)),
            SizedBox(height: 36),
            SizedBox(
              width: 26,
              height: 26,
              child: CircularProgressIndicator(
                  strokeWidth: 2.4, color: NivaraColors.accent),
            ),
            SizedBox(height: 18),
            Text('Preparing encrypted vault and on-device model…',
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
          padding: EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, size: 56, color: NivaraColors.danger),
              SizedBox(height: 16),
              Text('Startup failure',
                  style: TextStyle(
                      color: NivaraColors.textHi,
                      fontSize: 18,
                      fontWeight: FontWeight.bold)),
              SizedBox(height: 8),
              Text(message,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: NivaraColors.textMid, fontSize: 12)),
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
            icon: Icon(ThemeController.instance.isDark
                ? Icons.light_mode_outlined
                : Icons.dark_mode_outlined),
            tooltip: 'Switch theme',
            onPressed: () => ThemeController.instance.toggle(),
          ),
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
