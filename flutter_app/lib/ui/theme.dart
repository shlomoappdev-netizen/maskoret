import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// The app's look — the same palette and shapes as the iPhone/Mac app (Components.swift, SummaryView.swift and the
/// app icon), with "glass" surfaces like iOS / macOS 26: translucent, blurring what's behind, a thin light border.
class AppColors {
  /// From the app icon / AccentColor (0.05, 0.55, 0.47) and the hero gradient's second stop (0.07, 0.38, 0.55).
  static const teal = Color(0xFF0D8C78);
  static const blue = Color(0xFF12618C);
  static const gold = Color(0xFFF5C542);

  /// The hero card when the month ends negative (0.80, 0.25, 0.25) → (0.55, 0.12, 0.30).
  static const red1 = Color(0xFFCC4040);
  static const red2 = Color(0xFF8C1F4D);

  static Color positive(BuildContext c) =>
      Theme.of(c).brightness == Brightness.dark ? const Color(0xFF30D158) : const Color(0xFF248A3D);
  static Color negative(BuildContext c) =>
      Theme.of(c).brightness == Brightness.dark ? const Color(0xFFFF453A) : const Color(0xFFD70015);

  /// The donut's colors (SummaryView.slices).
  static const pink = Color(0xFFFF2D55);
  static const purple = Color(0xFFAF52DE);
  static const tealChart = Color(0xFF30B0C7);
  static const indigo = Color(0xFF5856D6);
  static const sky = Color(0xFF007AFF);
  static const orange = Color(0xFFFF9500);
  static const green = Color(0xFF34C759);
}

/// Numbers: tabular figures, so columns of amounts line up (like `.monospacedDigit()` in SwiftUI).
const tabular = [FontFeature.tabularFigures()];

ThemeData buildTheme(Brightness b) {
  final dark = b == Brightness.dark;
  final scheme = ColorScheme.fromSeed(seedColor: AppColors.teal, brightness: b).copyWith(
    primary: dark ? const Color(0xFF3FC7AE) : AppColors.teal,
    secondary: AppColors.blue,
    surface: dark ? const Color(0xFF101A1E) : const Color(0xFFF6F9FA),
  );
  final base = ThemeData(colorScheme: scheme, useMaterial3: true, brightness: b);
  final text = GoogleFonts.heeboTextTheme(base.textTheme).apply(
    bodyColor: scheme.onSurface,
    displayColor: scheme.onSurface,
  );
  final rounded = RoundedRectangleBorder(borderRadius: BorderRadius.circular(12));
  return base.copyWith(
    textTheme: text,
    scaffoldBackgroundColor: Colors.transparent,
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: text.titleLarge?.copyWith(fontWeight: FontWeight.w700),
    ),
    cardTheme: const CardThemeData(elevation: 0, color: Colors.transparent, margin: EdgeInsets.zero),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: rounded,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        textStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(shape: rounded, padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12)),
    ),
    textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(shape: rounded)),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: scheme.primary,
      foregroundColor: Colors.white,
      elevation: 2,
      shape: const StadiumBorder(),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: dark ? Colors.white.withValues(alpha: 0.06) : Colors.white.withValues(alpha: 0.7),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: dark ? const Color(0xF0141F24) : const Color(0xF2FFFFFF),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(26))),
      showDragHandle: true,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: dark ? const Color(0xF0141F24) : const Color(0xF7FFFFFF),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      indicatorColor: scheme.primary.withValues(alpha: 0.16),
      labelTextStyle: WidgetStatePropertyAll(text.labelSmall?.copyWith(fontWeight: FontWeight.w600)),
    ),
    listTileTheme: ListTileThemeData(shape: rounded),
    dividerTheme: DividerThemeData(color: scheme.onSurface.withValues(alpha: 0.08), thickness: 1),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        selectedBackgroundColor: scheme.primary.withValues(alpha: 0.16),
        shape: rounded,
      ),
    ),
  );
}

/// The window's background: a soft gradient with a few blurred color glows, so the glass has something to blur.
class GlassBackground extends StatelessWidget {
  const GlassBackground({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    Widget glow(Color c, double size) => Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(colors: [c, c.withValues(alpha: 0)]),
          ),
        );
    return Stack(children: [
      Positioned.fill(
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: AlignmentDirectional.topStart,
              end: AlignmentDirectional.bottomEnd,
              colors: dark
                  ? const [Color(0xFF0A1517), Color(0xFF0C1A24), Color(0xFF0B1418)]
                  : const [Color(0xFFE9F6F3), Color(0xFFF2F6FB), Color(0xFFEAF1F7)],
            ),
          ),
        ),
      ),
      PositionedDirectional(top: -120, start: -80, child: glow(AppColors.teal.withValues(alpha: dark ? 0.30 : 0.22), 420)),
      PositionedDirectional(top: 260, end: -140, child: glow(AppColors.blue.withValues(alpha: dark ? 0.28 : 0.16), 460)),
      PositionedDirectional(bottom: -160, start: 40, child: glow(AppColors.gold.withValues(alpha: dark ? 0.10 : 0.14), 380)),
      // One blur group for every glass surface on the page (much cheaper than separate backdrops).
      Positioned.fill(child: BackdropGroup(child: child)),
    ]);
  }
}

/// A glass surface: blurs what's behind it, a translucent tint, a thin light border and a soft shadow.
class Glass extends StatelessWidget {
  const Glass({
    super.key,
    required this.child,
    this.radius = 18,
    this.padding = EdgeInsets.zero,
    this.blur = 22,
    this.tint,
    this.borderRadius,
    this.shadow = true,
  });
  final Widget child;
  final double radius;
  final EdgeInsetsGeometry padding;
  final double blur;
  final Color? tint;
  final BorderRadius? borderRadius;
  final bool shadow;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final r = borderRadius ?? BorderRadius.circular(radius);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: r,
        boxShadow: shadow
            ? [
                BoxShadow(
                  color: Colors.black.withValues(alpha: dark ? 0.35 : 0.07),
                  blurRadius: 24,
                  offset: const Offset(0, 8),
                ),
              ]
            : null,
      ),
      child: ClipRRect(
        borderRadius: r,
        child: BackdropFilter.grouped(
          filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: r,
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: tint != null
                    ? [tint!, tint!]
                    : dark
                        ? [Colors.white.withValues(alpha: 0.10), Colors.white.withValues(alpha: 0.05)]
                        : [Colors.white.withValues(alpha: 0.78), Colors.white.withValues(alpha: 0.58)],
              ),
              border: Border.all(color: Colors.white.withValues(alpha: dark ? 0.12 : 0.75), width: 1),
            ),
            child: Padding(padding: padding, child: child),
          ),
        ),
      ),
    );
  }
}

/// A small number tile — StatTile in Components.swift: an icon and a grey caption above a large number.
class StatTile extends StatelessWidget {
  const StatTile({super.key, required this.title, required this.value, required this.icon, this.valueColor});
  final String title;
  final String value;
  final IconData icon;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Glass(
      radius: 14,
      padding: const EdgeInsets.all(14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          Icon(icon, size: 15, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Expanded(
            child: Text(title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ),
        ]),
        const SizedBox(height: 6),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: AlignmentDirectional.centerStart,
          child: Text(value,
              textDirection: TextDirection.rtl,
              style: theme.textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.w600, fontFeatures: tabular, color: valueColor)),
        ),
      ]),
    );
  }
}

/// Lays out tiles in a responsive grid (LazyVGrid adaptive(minimum:) in SwiftUI).
class TileGrid extends StatelessWidget {
  const TileGrid({super.key, required this.children, this.minWidth = 170, this.spacing = 12});
  final List<Widget> children;
  final double minWidth;
  final double spacing;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final columns = ((c.maxWidth + spacing) / (minWidth + spacing)).floor().clamp(1, 6);
      final width = (c.maxWidth - spacing * (columns - 1)) / columns;
      return Wrap(spacing: spacing, runSpacing: spacing, children: [
        for (final w in children) SizedBox(width: width, child: w),
      ]);
    });
  }
}
