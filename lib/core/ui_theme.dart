import 'package:flutter/material.dart';

/// Asset paths for the official brand artwork (white glyph, tintable).
const String kNivaraMarkAsset = 'assets/branding/nivara_mark.png';
const String kNivaraLogoAsset = 'assets/branding/nivara_logo.png';

/// NIVARA design system.
///
/// One source of truth for the palette, shape language, and the small
/// reusable surfaces (cards, stat tiles, section headers, pills) so every
/// screen in the app looks like one product.
///
/// The palette is brightness-aware: `NivaraColors` resolves through the
/// [NivaraPalette] that follows the ambient `ThemeData.brightness`. The dark
/// palette is byte-for-byte the original tactical palette, so the app looks
/// unchanged by default; `nivaraLightTheme()` adds the light variant.
abstract final class NivaraColors {
  /// Deep ops background (dark) / soft day background (light).
  static Color get bg => _current.bg;
  static Color get surface => _current.surface;
  static Color get surfaceAlt => _current.surfaceAlt;
  static Color get outline => _current.outline;
  static Color get textHi => _current.textHi;
  static Color get textMid => _current.textMid;
  static Color get textLow => _current.textLow;

  /// Accent + accent wash are shared constants across both palettes.
  static const accent = Color(0xFF2DD4BF); // primary teal
  static const accentSoft = Color(0x332DD4BF); // 20% teal wash

  /// Brand cream from the official NIVARA emblem. Dark theme uses the
  /// sampled logo cream; light theme darkens to a bronze in the same hue
  /// family so the mark stays readable on white surfaces.
  static Color get brand => _current.brand;

  /// Signal colors adapt to brightness: the dark-theme tints (red-400,
  /// amber-400, emerald-400, blue-400) are unreadable on white surfaces,
  /// so the light theme uses their 700-shade counterparts.
  static Color get danger => _current.danger;
  static Color get warn => _current.warn;
  static Color get good => _current.good;
  static Color get info => _current.info;

  /// Orange sits between danger and warn for graduated condition tiers
  /// (Critical / Poor / Needs Attention / Fair / Good / Excellent).
  static Color get orange => _current.orange;

  static NivaraPalette _current = NivaraPalette.dark;

  static NivaraPalette get current => _current;

  /// Points the palette at the given brightness. Called by [NivaraApp]'s
  /// theme controller on startup and on every theme switch, right before
  /// `setState` propagates the new `ThemeData`.
  static void syncWith(Brightness brightness) {
    _current =
        brightness == Brightness.light ? NivaraPalette.light : NivaraPalette.dark;
  }
}

/// Neutral color ramp for one brightness.
class NivaraPalette {
  final Color bg;
  final Color surface;
  final Color surfaceAlt;
  final Color outline;
  final Color textHi;
  final Color textMid;
  final Color textLow;
  final Color danger;
  final Color warn;
  final Color good;
  final Color info;
  final Color brand;
  final Color orange;

  const NivaraPalette({
    required this.bg,
    required this.surface,
    required this.surfaceAlt,
    required this.outline,
    required this.textHi,
    required this.textMid,
    required this.textLow,
    required this.danger,
    required this.warn,
    required this.good,
    required this.info,
    required this.brand,
    required this.orange,
  });

  /// The original tactical-dark palette (unchanged).
  static const NivaraPalette dark = NivaraPalette(
    bg: Color(0xFF0A1014), // deep ops background
    surface: Color(0xFF131C22), // cards
    surfaceAlt: Color(0xFF1A252D), // raised elements / wells
    outline: Color(0xFF28343E), // hairlines
    textHi: Color(0xFFEFF6F8),
    textMid: Color(0xFF9AAABB),
    textLow: Color(0xFF5D6B77),
    danger: Color(0xFFF87171),
    warn: Color(0xFFFBBF24),
    good: Color(0xFF34D399),
    info: Color(0xFF60A5FA),
    brand: Color(0xFFD1C6A5), // emblem cream, sampled from the official mark
    orange: Color(0xFFFB923C), // orange-400, readable on dark surfaces
  );

  /// Day variant: soft paper background, white cards, graphite text.
  /// Signal colors darken to their 700-shades so they stay readable on
  /// white cards (the 400-shades wash out completely).
  static const NivaraPalette light = NivaraPalette(
    bg: Color(0xFFF3F6F8),
    surface: Color(0xFFFFFFFF),
    surfaceAlt: Color(0xFFE8EEF1),
    outline: Color(0xFFD3DDE3),
    textHi: Color(0xFF17222A),
    textMid: Color(0xFF4A5A66),
    textLow: Color(0xFF7A8B96),
    danger: Color(0xFFB91C1C), // red-700
    warn: Color(0xFFB45309), // amber-700
    good: Color(0xFF047857), // emerald-700
    info: Color(0xFF1D4ED8), // blue-700
    brand: Color(0xFF77683C), // bronze — same hue family as the emblem cream
    orange: Color(0xFFC2410C), // orange-700, readable on white surfaces
  );
}

abstract final class NivaraRadius {
  static const card = 18.0;
  static const field = 14.0;
  static const pill = 999.0;
}

/// The app-wide dark theme. Material 3, teal-seeded.
ThemeData nivaraTheme() => _buildTheme(Brightness.dark);

/// The app-wide light theme. Same shape language, day palette.
ThemeData nivaraLightTheme() => _buildTheme(Brightness.light);

ThemeData _buildTheme(Brightness brightness) {
  final isDark = brightness == Brightness.dark;
  final p = isDark ? NivaraPalette.dark : NivaraPalette.light;
  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: (isDark ? const ColorScheme.dark() : const ColorScheme.light())
        .copyWith(
      primary: NivaraColors.accent,
      onPrimary: const Color(0xFF04211D),
      secondary: NivaraColors.accent,
      surface: p.surface,
      onSurface: p.textHi,
      surfaceContainerHighest: p.surfaceAlt,
      error: NivaraColors.danger,
    ),
    scaffoldBackgroundColor: p.bg,
  );

  return base.copyWith(
    appBarTheme: AppBarTheme(
      backgroundColor: p.bg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: p.textHi,
        fontSize: 17,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.2,
      ),
      iconTheme: IconThemeData(color: p.textMid),
    ),
    cardTheme: CardThemeData(
      color: p.surface,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(NivaraRadius.card)),
      ),
      margin: EdgeInsets.zero,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.surfaceAlt,
      hintStyle: TextStyle(color: p.textLow),
      labelStyle: TextStyle(color: p.textMid),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
      border: const OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(NivaraRadius.field)),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: const BorderRadius.all(Radius.circular(NivaraRadius.field)),
        borderSide: BorderSide(color: Colors.transparent),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: const BorderRadius.all(Radius.circular(NivaraRadius.field)),
        borderSide: const BorderSide(color: NivaraColors.accent, width: 1.4),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: const BorderRadius.all(Radius.circular(NivaraRadius.field)),
        borderSide: BorderSide(color: p.danger, width: 1.2),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: const BorderRadius.all(Radius.circular(NivaraRadius.field)),
        borderSide: BorderSide(color: p.danger, width: 1.4),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: NivaraColors.accent,
        foregroundColor: const Color(0xFF04211D),
        minimumSize: const Size.fromHeight(52),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(NivaraRadius.field)),
        ),
        textStyle: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14.5),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: p.textHi,
        minimumSize: const Size.fromHeight(48),
        side: BorderSide(color: p.outline),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(NivaraRadius.field)),
        ),
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected)
                ? NivaraColors.accentSoft
                : p.surfaceAlt),
        foregroundColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected)
                ? NivaraColors.accent
                : p.textMid),
        side: WidgetStateProperty.resolveWith((states) => BorderSide(
              color: states.contains(WidgetState.selected)
                  ? NivaraColors.accent.withValues(alpha: 0.6)
                  : p.outline,
            )),
        shape: WidgetStateProperty.all(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: NivaraColors.accent,
      inactiveTrackColor: p.surfaceAlt,
      thumbColor: NivaraColors.accent,
      overlayColor: NivaraColors.accentSoft,
      trackHeight: 4,
      valueIndicatorColor: p.surfaceAlt,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? NivaraColors.accent : p.textLow),
      trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? NivaraColors.accentSoft
              : p.surfaceAlt),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: p.surfaceAlt,
      contentTextStyle: TextStyle(color: p.textHi, fontSize: 13),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(12)),
      ),
    ),
    bottomNavigationBarTheme: BottomNavigationBarThemeData(
      backgroundColor: p.surface,
      selectedItemColor: NivaraColors.accent,
      unselectedItemColor: p.textLow,
      type: BottomNavigationBarType.fixed,
      selectedLabelStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
      unselectedLabelStyle: const TextStyle(fontSize: 11),
    ),
    dividerTheme: DividerThemeData(color: p.outline, thickness: 1),
    splashFactory: InkSparkle.splashFactory,
  );
}

/// Standard content card with the shared surface + radius.
class NivaraCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? border;
  final Gradient? gradient;

  const NivaraCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.border,
    this.gradient,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: gradient == null ? NivaraColors.surface : null,
        gradient: gradient,
        borderRadius: BorderRadius.circular(NivaraRadius.card),
        border: Border.all(color: border ?? NivaraColors.outline),
      ),
      child: child,
    );
  }
}

/// Section header: small icon chip + label, optionally with a trailing pill.
class SectionHeader extends StatelessWidget {
  final IconData icon;
  final String title;
  final Color tint;
  final String? pill;

  const SectionHeader({
    super.key,
    required this.icon,
    required this.title,
    this.tint = NivaraColors.accent,
    this.pill,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: tint.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(9),
          ),
          child: Icon(icon, size: 17, color: tint),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(title,
              style: TextStyle(
                  color: NivaraColors.textHi,
                  fontSize: 14.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.1)),
        ),
        if (pill != null)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
            decoration: BoxDecoration(
              color: tint.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(NivaraRadius.pill),
            ),
            child: Text(pill!,
                style: TextStyle(color: tint, fontSize: 10, fontWeight: FontWeight.w600)),
          ),
      ],
    );
  }
}

/// Compact stat tile used on dashboards (value + caption + accent).
class StatTile extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  final IconData? icon;

  const StatTile({
    super.key,
    required this.label,
    required this.value,
    required this.color,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return NivaraCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (icon != null) ...[
                Icon(icon, size: 14, color: color),
                const SizedBox(width: 6),
              ],
              Expanded(
                child: Text(label.toUpperCase(),
                    style: TextStyle(
                        color: NivaraColors.textLow,
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.8),
                    overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(value,
              style: TextStyle(
                  color: color, fontSize: 26, fontWeight: FontWeight.w800, height: 1)),
        ],
      ),
    );
  }
}

/// The official NIVARA emblem (soldier silhouette in the letter N), tinted
/// per theme. An optional teal glow ring keeps the auth/boot presentation
/// consistent with the original design language.
class NivaraMark extends StatelessWidget {
  final double size;
  final bool glow;

  const NivaraMark({super.key, this.size = 88, this.glow = true});

  @override
  Widget build(BuildContext context) {
    final mark = Image.asset(
      kNivaraMarkAsset,
      width: size,
      height: size,
      fit: BoxFit.contain,
      color: NivaraColors.brand,
    );
    if (!glow) return mark;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [NivaraColors.accent.withValues(alpha: 0.20), Colors.transparent],
        ),
        border: Border.all(color: NivaraColors.accent.withValues(alpha: 0.40), width: 1.4),
      ),
      padding: EdgeInsets.all(size * 0.17),
      child: mark,
    );
  }
}

/// The official NIVARA wordmark ("NIVARA" + star), tinted per theme.
class NivaraWordmark extends StatelessWidget {
  final double height;
  final Color? color;

  const NivaraWordmark({super.key, this.height = 26, this.color});

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      kNivaraLogoAsset,
      height: height,
      fit: BoxFit.contain,
      color: color ?? NivaraColors.textHi,
    );
  }
}
