import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class IMRTheme {
  // Core Palette defined in DESIGN.md
  static const Color background = Color(0xFF000000); 
  static const Color surfaceVeryDark = Color(0xFF0A0A0A);
  static const Color surfaceContainer = Color(0xFF131313); // Nested component backing
  
  static const Color primaryCyan = Color(0xFF00E5FF);
  static const Color pureWhite = Color(0xFFFFFFFF);
  
  // Used aggressively for high-contrast accessibility where nesting alone might fail under sun glare
  static final Color ghostBorder = const Color(0xFF44474C).withOpacity(0.15);

  static ThemeData get themeData {
    final baseTextTheme = ThemeData.dark().textTheme;
    
    // Space Grotesk for metrics/tech data, Inter for body reading
    final TextTheme imrTextTheme = baseTextTheme.copyWith(
      displayLarge: GoogleFonts.spaceGrotesk(fontSize: 56, color: pureWhite, fontWeight: FontWeight.w700),
      displayMedium: GoogleFonts.spaceGrotesk(fontSize: 40, color: pureWhite, fontWeight: FontWeight.w700),
      displaySmall: GoogleFonts.spaceGrotesk(fontSize: 32, color: pureWhite, fontWeight: FontWeight.w700),
      headlineMedium: GoogleFonts.spaceGrotesk(fontSize: 24, color: pureWhite, fontWeight: FontWeight.w600),
      headlineSmall: GoogleFonts.spaceGrotesk(fontSize: 20, color: pureWhite, fontWeight: FontWeight.w600),
      titleLarge: GoogleFonts.spaceGrotesk(fontSize: 18, color: pureWhite, fontWeight: FontWeight.w600),
      labelLarge: GoogleFonts.spaceGrotesk(fontSize: 14, color: pureWhite, letterSpacing: 1.2, fontWeight: FontWeight.w500),
      labelSmall: GoogleFonts.spaceGrotesk(fontSize: 11, color: pureWhite, letterSpacing: 1.2, fontWeight: FontWeight.w500),
      
      bodyLarge: GoogleFonts.inter(fontSize: 16, color: pureWhite),
      bodyMedium: GoogleFonts.inter(fontSize: 14, color: pureWhite),
      bodySmall: GoogleFonts.inter(fontSize: 12, color: pureWhite.withOpacity(0.7)),
    );

    return ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: background,
      primaryColor: primaryCyan,
      colorScheme: const ColorScheme.dark(
        primary: primaryCyan,
        onPrimary: background,
        surface: surfaceVeryDark,
        onSurface: pureWhite,
        shadow: Colors.transparent, // Nullify generic shadows
      ),
      textTheme: imrTextTheme,
      cardTheme: const CardThemeData(
        color: surfaceContainer,
        elevation: 0, // 'No-Line' and 'No-Shadow' rules
        margin: EdgeInsets.zero,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(8)),
          side: BorderSide.none,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primaryCyan,
          foregroundColor: background,
          elevation: 0,
          textStyle: GoogleFonts.spaceGrotesk(fontWeight: FontWeight.w600),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(6),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surfaceContainer,
        border: OutlineInputBorder(
          borderSide: BorderSide.none,
          borderRadius: BorderRadius.circular(6),
        ),
        enabledBorder: OutlineInputBorder(
          borderSide: BorderSide.none,
          borderRadius: BorderRadius.circular(6),
        ),
        focusedBorder: OutlineInputBorder(
          borderSide: BorderSide(color: primaryCyan, width: 2), // Aggressive active state
          borderRadius: BorderRadius.circular(6),
        ),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: background,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
    );
  }
}
