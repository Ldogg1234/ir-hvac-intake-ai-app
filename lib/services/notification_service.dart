import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';

class NotificationService {
  static final FirebaseMessaging _messaging = FirebaseMessaging.instance;

  static Future<void> initialize(GoRouter router) async {
    // Request permissions (iOS/Android 13+)
    NotificationSettings settings = await _messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );

    if (settings.authorizationStatus == AuthorizationStatus.authorized) {
      debugPrint('User granted notification permissions');
    }

    // Get the token (usually sent to backend to associate with tech email)
    String? token = await _messaging.getToken();
    debugPrint('FCM Token: $token');

    // Handle background messages that opened the app
    FirebaseMessaging.instance.getInitialMessage().then((RemoteMessage? message) {
      if (message != null) {
        _handleMessage(message, router);
      }
    });

    // Handle user interaction when app is in background but not terminated
    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      _handleMessage(message, router);
    });

    // Foreground messages (optional - usually just show a snackbar or update UI)
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      debugPrint('Received foreground message: ${message.notification?.title}');
    });
  }

  static void _handleMessage(RemoteMessage message, GoRouter router) {
    debugPrint('Handling notification interaction: ${message.data}');
    
    // Payload expected: { "type": "view_job", "leadId": "xyz..." }
    if (message.data['type'] == 'view_job' && message.data['leadId'] != null) {
      final leadId = message.data['leadId'];
      router.push('/job/$leadId');
    }
  }
}
