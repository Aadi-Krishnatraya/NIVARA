import 'package:flutter/material.dart';

/// NIVARA design system.
///
/// One source of truth for the tactical-dark palette, shape language, and
/// the small reusable surfaces (cards, stat tiles, section headers, pills)
/// so every screen in the app looks like one product.
abstract final class NivaraColors {
  static const bg = Color(0xFF0A1014); // deep ops background
  static const surface = Color(0xFF131C22); // cards
  static const surfaceAlt = Color(0xFF1A252D); // raised elements / wells
  static const outline = Color(0xFF28343E); // hairlines
  static const accent = Color(0xFF2DD4BF); // primary teal
  static const accentSoft = Color(0x332DD4BF); // 20% teal wash
  static const danger = Color(0xFFF87171);
  static const warn = Color(0xFFFBBF24);
  static const good = Color(0xFF34D399);
  static const info = Color(0xFF60A5FA);
  static const textHi = Color(0xFFEFF6F8);
  static const textMid = Color(0xFF9AAABB);
  static const textLow = Color(0xFF5D6B77);
}

abstract final class NivaraRadius {
  static const card = 18.0;
  static const field = 14.0;
  static const pill = 999.0;
}

/// The app-wide dark theme. Material 3, teal-seeded.
ThemeData nivaraTheme() {
  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: const ColorScheme.dark(
      primary: NivaraColors.accent,
      onPrimary: Color(0xFF04211D),
      secondary: NivaraColors.accent,
      surface: NivaraColors.surface,
      onSurface: NivaraColors.textHi,
      surfaceContainerHighest: NivaraColors.surfaceAlt,
      error: NivaraColors.danger,
    ),
    scaffoldBackgroundColor: NivaraColors.bg,
  );

  return base.copyWith(
    appBarTheme: const AppBarTheme(
      backgroundColor: NivaraColors.bg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: NivaraColors.textHi,
        fontSize: 17,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.2,
      ),
      iconTheme: IconThemeData(color: NivaraColors.textMid),
    ),
    cardTheme: const CardThemeData(
      color: NivaraColors.surface,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(NivaraRadius.card)),
      ),
      margin: EdgeInsets.zero,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: NivaraColors.surfaceAlt,
      hintStyle: const TextStyle(color: NivaraColors.textLow),
      labelStyle: const TextStyle(color: NivaraColors.textMid),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
      border: const OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(NivaraRadius.field)),
        borderSide: BorderSide.none,
      ),
      enabledBorder: const OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(NivaraRadius.field)),
        borderSide: BorderSide(color: Colors.transparent),
      ),
      focusedBorder: const OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(NivaraRadius.field)),
        borderSide: BorderSide(color: NivaraColors.accent, width: 1.4),
      ),
      errorBorder: const OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(NivaraRadius.field)),
        borderSide: BorderSide(color: NivaraColors.danger, width: 1.2),
      ),
      focusedErrorBorder: const OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(NivaraRadius.field)),
        borderSide: BorderSide(color: NivaraColors.danger, width: 1.4),
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
        foregroundColor: NivaraColors.textHi,
        minimumSize: const Size.fromHeight(48),
        side: const BorderSide(color: NivaraColors.outline),
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
                : NivaraColors.surfaceAlt),
        foregroundColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected)
                ? NivaraColors.accent
                : NivaraColors.textMid),
        side: WidgetStateProperty.resolveWith((states) => BorderSide(
              color: states.contains(WidgetState.selected)
                  ? NivaraColors.accent.withValues(alpha: 0.6)
                  : NivaraColors.outline,
            )),
        shape: WidgetStateProperty.all(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
    ),
    sliderTheme: const SliderThemeData(
      activeTrackColor: NivaraColors.accent,
      inactiveTrackColor: NivaraColors.surfaceAlt,
      thumbColor: NivaraColors.accent,
      overlayColor: NivaraColors.accentSoft,
      trackHeight: 4,
      valueIndicatorColor: NivaraColors.surfaceAlt,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? NivaraColors.accent : NivaraColors.textLow),
      trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? NivaraColors.accentSoft
              : NivaraColors.surfaceAlt),
    ),
    snackBarTheme: const SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: NivaraColors.surfaceAlt,
      contentTextStyle: TextStyle(color: NivaraColors.textHi, fontSize: 13),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(12)),
      ),
    ),
    bottomNavigationBarTheme: const BottomNavigationBarThemeData(
      backgroundColor: NivaraColors.surface,
      selectedItemColor: NivaraColors.accent,
      unselectedItemColor: NivaraColors.textLow,
      type: BottomNavigationBarType.fixed,
      selectedLabelStyle: TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
      unselectedLabelStyle: TextStyle(fontSize: 11),
    ),
    dividerTheme: const DividerThemeData(color: NivaraColors.outline, thickness: 1),
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
              style: const TextStyle(
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
                    style: const TextStyle(
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

/// Brand glyph: shield inside a teal glow ring. Used on splash + auth.
class NivaraMark extends StatelessWidget {
  final double size;
  const NivaraMark({super.key, this.size = 88});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [NivaraColors.accent.withValues(alpha: 0.22), Colors.transparent],
        ),
        border: Border.all(color: NivaraColors.accent.withValues(alpha: 0.45), width: 1.5),
      ),
      child: Icon(Icons.shield_outlined, size: size * 0.46, color: NivaraColors.accent),
    );
  }
}
