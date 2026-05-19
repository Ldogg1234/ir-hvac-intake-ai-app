import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'firebase_options.dart';
import 'services/notification_service.dart';
import 'screens/report_draft_screen.dart';
import 'screens/admin_dashboard_screen.dart';
import 'screens/tech_home_screen.dart';
import 'screens/admin_report_review_screen.dart';
import 'screens/report_success_screen.dart';
import 'screens/admin_intake_screen.dart';
import 'screens/admin_estimate_builder_screen.dart';
import 'screens/admin_po_dashboard_screen.dart';
import 'screens/tech_login_screen.dart';
import 'screens/admin_pm_database_screen.dart';
import 'screens/voice_assistant_screen.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'ui/style/precision_theme.dart';
import 'ui/screens/intake_dashboard.dart';

import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:firebase_auth/firebase_auth.dart';

final ValueNotifier<bool> showGlobalFab = ValueNotifier<bool>(true);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  usePathUrlStrategy();
  
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    
    // Authenticate Anonymously to satisfy firestore.rules
    final auth = FirebaseAuth.instance;
    if (auth.currentUser == null) {
      await auth.signInAnonymously();
      debugPrint('Signed in anonymously for testing');
    }
  } catch (e) {
    debugPrint('Firebase initialization failed: $e');
  }
  
  runApp(const ProviderScope(child: IntakeApp()));

  if (kIsWeb) {
    Future.microtask(() async {
      try {
        await NotificationService.initialize(_router);
      } catch (e) {
        debugPrint('Web Notification initialization failed: $e');
      }
    });
  }
}

final GoRouter _router = GoRouter(
  initialLocation: '/',
  errorBuilder: (context, state) => Scaffold(
    body: Center(child: Text('Route not found: ${state.uri}')),
  ),
  routes: [
    GoRoute(
      path: '/',
      builder: (context, state) => const TechHomeScreen(),
    ),
    GoRoute(
      path: '/tech/login',
      builder: (context, state) => const TechLoginScreen(),
    ),
    GoRoute(
      path: '/tech',
      builder: (context, state) => const TechHomeScreen(),
    ),
    GoRoute(
      path: '/tech/voice',
      builder: (context, state) {
        final leadId = state.uri.queryParameters['leadId'];
        return VoiceAssistantScreen(leadId: leadId);
      },
    ),
    GoRoute(
      path: '/admin',
      builder: (context, state) => const AdminDashboardScreen(),
    ),
    GoRoute(
      path: '/dispatch',
      builder: (context, state) => const AdminDashboardScreen(),
    ),
    GoRoute(
      path: '/admin/intake',
      builder: (context, state) => const AdminIntakeScreen(),
    ),
    GoRoute(
      path: '/admin/po-workbench',
      builder: (context, state) => AdminPoDashboardScreen(),
    ),
    GoRoute(
      path: '/admin/pm-database',
      builder: (context, state) => const AdminPMDatabaseScreen(),
    ),
    GoRoute(
      path: '/job/:leadId',
      builder: (context, state) {
        final leadId = state.pathParameters['leadId'];
        return ReportDraftScreen(leadId: leadId);
      },
    ),
    GoRoute(
      path: '/admin/review/:leadId',
      builder: (context, state) {
        final leadId = state.pathParameters['leadId']!;
        return AdminReportReviewScreen(leadId: leadId);
      },
    ),
    GoRoute(
      path: '/admin/estimate/:leadId',
      builder: (context, state) {
        final leadId = state.pathParameters['leadId']!;
        return AdminEstimateBuilderScreen(leadId: leadId);
      },
    ),
    GoRoute(
      path: '/tech/success',
      builder: (context, state) {
        final reportUrl = state.uri.queryParameters['url'] ?? '';
        return ReportSuccessScreen(reportUrl: reportUrl);
      },
    ),
  ],
);

class IntakeApp extends StatelessWidget {
  const IntakeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'IRHVAC Command Center',
      routerConfig: _router,
      theme: PrecisionTheme.themeData,
    );
  }
}
