import 'package:flutter/material.dart';

class StaticLogoWidget extends StatelessWidget {
  final double width;

  const StaticLogoWidget({
    super.key,
    this.width = 250.0,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // The embedded AI generated logo
        ClipRRect(
          borderRadius: BorderRadius.circular(16.0),
          child: Image.asset(
            'assets/images/static_logo.png',
            width: width,
            fit: BoxFit.contain,
          ),
        ),
        const SizedBox(height: 16),
        // A fallback/complementary text rendering if you ever want the text separate from the icon
        const Text(
          'STATIC',
          style: TextStyle(
            fontSize: 32,
            fontWeight: FontWeight.w900,
            letterSpacing: 4.0,
            color: Colors.white, // Or a metallic grey: Color(0xFFB0BEC5)
            shadows: [
              Shadow(
                blurRadius: 10.0,
                color: Colors.blueAccent, // Subtle electric vibe
                offset: Offset(0, 0),
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        const Text(
          'KILL THE RESISTANCE',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            letterSpacing: 2.0,
            color: Colors.grey,
          ),
        ),
      ],
    );
  }
}
