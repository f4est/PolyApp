import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:intl/intl.dart';
import 'package:video_player/video_player.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'firebase_options.dart';

import 'api/api_client.dart';
import 'journal/journal_store.dart';
import 'journal/attendance_journal_page.dart';
import 'journal/grades_preset_journal_page.dart';
import 'widgets/brand_logo.dart';

const String apiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'http://localhost:8000',
);

const Color kBrandPrimary = Color(0xFF0F766E);
const Color kAccentSuccess = Color(0xFF16A34A);
const Color kAppBackground = Color(0xFFF4F7F2);
const Color kCardSurface = Color(0xFFFFFFFF);
const Color kSecondaryBackground = Color(0xFFE5EEE6);
const Color kPrimaryText = Color(0xFF1F2937);
const Color kSecondaryText = Color(0xFF4B5563);
const Color kMutedText = Color(0xFF9CA3AF);
const Color kError = Color(0xFFEF4444);
const Color kWarning = Color(0xFFF59E0B);
const Color kInfo = Color(0xFF0EA5E9);

enum DeviceCanvas { mobile, desktop, web }

const List<Map<String, String>> kNewsCategories = [
  {'id': 'news', 'label': '\u041d\u043e\u0432\u043e\u0441\u0442\u0438'},
  {'id': 'study', 'label': '\u0423\u0447\u0451\u0431\u0430'},
  {
    'id': 'announcements',
    'label': '\u041e\u0431\u044a\u044f\u0432\u043b\u0435\u043d\u0438\u044f',
  },
  {
    'id': 'events',
    'label':
        '\u041c\u0435\u0440\u043e\u043f\u0440\u0438\u044f\u0442\u0438\u044f',
  },
];

const Map<String, String> kReactionLabels = {
  'like': '\ud83d\udc4d \u041d\u0440\u0430\u0432\u0438\u0442\u0441\u044f',
  'cool': '\ud83d\udd25 \u041a\u0440\u0443\u0442\u043e',
  'useful': '\ud83d\udc4f \u041f\u043e\u043b\u0435\u0437\u043d\u043e',
  'discuss':
      '\ud83d\udcac \u041e\u0431\u0441\u0443\u0436\u0434\u0435\u043d\u0438\u0435',
};

const Map<String, String> kReactionEmoji = {
  'like': '\ud83d\udc4d',
  'cool': '\ud83d\udd25',
  'useful': '\ud83d\udc4f',
  'discuss': '\ud83d\udcac',
};

final FlutterLocalNotificationsPlugin _localNotifications =
    FlutterLocalNotificationsPlugin();
const AndroidNotificationChannel _defaultChannel = AndroidNotificationChannel(
  'general',
  'General',
  description: 'General notifications',
  importance: Importance.high,
);

Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  } catch (_) {}
}

Future<void> _initLocalNotifications() async {
  if (!kIsWeb) {
    await FirebaseMessaging.instance
        .setForegroundNotificationPresentationOptions(
          alert: true,
          badge: true,
          sound: true,
        );
    const initializationSettingsAndroid = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );
    const initializationSettingsDarwin = DarwinInitializationSettings();
    const initializationSettings = InitializationSettings(
      android: initializationSettingsAndroid,
      iOS: initializationSettingsDarwin,
      macOS: initializationSettingsDarwin,
    );
    await _localNotifications.initialize(initializationSettings);
    await _localNotifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(_defaultChannel);
  }
  FirebaseMessaging.onMessage.listen((message) {
    final notification = message.notification;
    if (notification == null) return;
    if (kIsWeb) return;
    _localNotifications.show(
      notification.hashCode,
      notification.title,
      notification.body,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'general',
          'General',
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(),
      ),
    );
  });
}

String humanizeError(Object error) {
  final isRu = appLocaleCode == 'ru';
  var raw = error.toString().replaceFirst('Exception: ', '').trim();
  if (error is ApiException) {
    raw = _extractApiDetail(error.body) ?? raw;
  } else {
    raw = _extractApiDetail(raw) ?? raw;
  }
  raw = raw.replaceFirst(RegExp(r'^ApiException\(\d+\):\s*'), '').trim();
  if (raw.startsWith('{') && raw.endsWith('}')) {
    raw = _extractApiDetail(raw) ?? raw;
  }
  if (raw.contains('Invalid credentials')) {
    return isRu
        ? '\u041d\u0435\u0432\u0435\u0440\u043d\u0430\u044f \u043f\u043e\u0447\u0442\u0430 \u0438\u043b\u0438 \u043f\u0430\u0440\u043e\u043b\u044c.'
        : 'Invalid email or password.';
  }
  if (raw.contains('Email already registered')) {
    return isRu
        ? '\u042d\u0442\u0430 \u043f\u043e\u0447\u0442\u0430 \u0443\u0436\u0435 \u0437\u0430\u0440\u0435\u0433\u0438\u0441\u0442\u0440\u0438\u0440\u043e\u0432\u0430\u043d\u0430.'
        : 'This email is already registered.';
  }
  if (raw.contains('Password must be at least')) {
    return isRu
        ? '\u041f\u0430\u0440\u043e\u043b\u044c \u0441\u043b\u0438\u0448\u043a\u043e\u043c \u043a\u043e\u0440\u043e\u0442\u043a\u0438\u0439.'
        : 'Password is too short.';
  }
  if (raw.contains('Password must include an uppercase')) {
    return isRu
        ? '\u0414\u043e\u0431\u0430\u0432\u044c\u0442\u0435 \u0437\u0430\u0433\u043b\u0430\u0432\u043d\u0443\u044e \u0431\u0443\u043a\u0432\u0443 \u0432 \u043f\u0430\u0440\u043e\u043b\u044c.'
        : 'Add at least one uppercase letter.';
  }
  if (raw.contains('Password must include a lowercase')) {
    return isRu
        ? '\u0414\u043e\u0431\u0430\u0432\u044c\u0442\u0435 \u0441\u0442\u0440\u043e\u0447\u043d\u0443\u044e \u0431\u0443\u043a\u0432\u0443 \u0432 \u043f\u0430\u0440\u043e\u043b\u044c.'
        : 'Add at least one lowercase letter.';
  }
  if (raw.contains('Password must include a number')) {
    return isRu
        ? '\u0414\u043e\u0431\u0430\u0432\u044c\u0442\u0435 \u0446\u0438\u0444\u0440\u0443 \u0432 \u043f\u0430\u0440\u043e\u043b\u044c.'
        : 'Add at least one number.';
  }
  if (raw.contains('Session expired')) {
    return isRu
        ? '\u0421\u0435\u0441\u0441\u0438\u044f \u0438\u0441\u0442\u0435\u043a\u043b\u0430. \u0412\u043e\u0439\u0434\u0438\u0442\u0435 \u0441\u043d\u043e\u0432\u0430.'
        : 'Session expired. Please sign in again.';
  }
  if (raw.contains('Insufficient role')) {
    return isRu
        ? '\u041d\u0435\u0434\u043e\u0441\u0442\u0430\u0442\u043e\u0447\u043d\u043e \u043f\u0440\u0430\u0432 \u0434\u043b\u044f \u044d\u0442\u043e\u0433\u043e \u0434\u0435\u0439\u0441\u0442\u0432\u0438\u044f.'
        : 'Your role does not allow this action.';
  }
  if (raw.isEmpty) {
    return isRu
        ? '\u041f\u0440\u043e\u0438\u0437\u043e\u0448\u043b\u0430 \u043e\u0448\u0438\u0431\u043a\u0430. \u041f\u043e\u043f\u0440\u043e\u0431\u0443\u0439\u0442\u0435 \u0435\u0449\u0435 \u0440\u0430\u0437.'
        : 'Something went wrong. Please try again.';
  }
  if (isRu &&
      (raw.contains('Failed to load notifications') ||
          raw.contains('notifications'))) {
    return 'Не удалось загрузить уведомления.';
  }
  if (!isRu &&
      (raw.contains('Failed to load notifications') ||
          raw.contains('notifications'))) {
    return 'Failed to load notifications.';
  }
  return raw;
}

String? _extractApiDetail(String input) {
  final text = input.trim();
  if (text.isEmpty) return null;
  final jsonStart = text.indexOf('{');
  final jsonText = jsonStart >= 0 ? text.substring(jsonStart) : text;
  try {
    final decoded = jsonDecode(jsonText);
    if (decoded is Map<String, dynamic>) {
      final detail = decoded['detail'];
      if (detail is String && detail.trim().isNotEmpty) return detail.trim();
      final message = decoded['message'];
      if (message is String && message.trim().isNotEmpty) return message.trim();
      final error = decoded['error'];
      if (error is String && error.trim().isNotEmpty) return error.trim();
    }
  } catch (_) {}
  return null;
}

class InlineNotice extends StatelessWidget {
  const InlineNotice({super.key, required this.message, this.isError = true});

  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final color = isError ? kError : kAccentSuccess;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(
            isError ? Icons.error_outline : Icons.check_circle_outline,
            color: color,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(message, style: TextStyle(color: color)),
          ),
        ],
      ),
    );
  }
}

String appLocaleCode = 'ru';

class AppLocalizations {
  AppLocalizations(this.locale);

  final Locale locale;

  static const supportedLocales = [Locale('ru'), Locale('en')];

  static const Map<String, Map<String, String>> _strings = {
    'ru': {
      'auth_title_login': '\u0412\u0445\u043e\u0434',
      'auth_title_register':
          '\u0420\u0435\u0433\u0438\u0441\u0442\u0440\u0430\u0446\u0438\u044f',
      'auth_subtitle_login':
          '\u0421 \u0432\u043e\u0437\u0432\u0440\u0430\u0449\u0435\u043d\u0438\u0435\u043c',
      'auth_subtitle_register':
          '\u0421\u043e\u0437\u0434\u0430\u0439\u0442\u0435 \u0441\u0442\u0443\u0434\u0435\u043d\u0447\u0435\u0441\u043a\u0438\u0439 \u0430\u043a\u043a\u0430\u0443\u043d\u0442',
      'full_name': '\u0424\u0418\u041e',
      'email': '\u041f\u043e\u0447\u0442\u0430',
      'password': '\u041f\u0430\u0440\u043e\u043b\u044c',
      'confirm_password':
          '\u041f\u043e\u0434\u0442\u0432\u0435\u0440\u0434\u0438\u0442\u0435 \u043f\u0430\u0440\u043e\u043b\u044c',
      'sign_in': '\u0412\u043e\u0439\u0442\u0438',
      'create_account':
          '\u0421\u043e\u0437\u0434\u0430\u0442\u044c \u0430\u043a\u043a\u0430\u0443\u043d\u0442',
      'have_account':
          '\u0423\u0436\u0435 \u0435\u0441\u0442\u044c \u0430\u043a\u043a\u0430\u0443\u043d\u0442',
      'create_new_account':
          '\u0421\u043e\u0437\u0434\u0430\u0442\u044c \u043d\u043e\u0432\u044b\u0439 \u0430\u043a\u043a\u0430\u0443\u043d\u0442',
      'forgot_password':
          '\u0417\u0430\u0431\u044b\u043b\u0438 \u043f\u0430\u0440\u043e\u043b\u044c?',
      'reset_password':
          '\u0412\u043e\u0441\u0441\u0442\u0430\u043d\u043e\u0432\u043b\u0435\u043d\u0438\u0435 \u043f\u0430\u0440\u043e\u043b\u044f',
      'reset_desc':
          '\u041c\u044b \u043e\u0442\u043f\u0440\u0430\u0432\u0438\u043c \u0441\u0441\u044b\u043b\u043a\u0443 \u0434\u043b\u044f \u0432\u043e\u0441\u0441\u0442\u0430\u043d\u043e\u0432\u043b\u0435\u043d\u0438\u044f \u043d\u0430 \u0432\u0430\u0448\u0443 \u043f\u043e\u0447\u0442\u0443.',
      'send_reset':
          '\u041e\u0442\u043f\u0440\u0430\u0432\u0438\u0442\u044c \u043f\u0438\u0441\u044c\u043c\u043e',
      'language': '\u042f\u0437\u044b\u043a',
      'language_ru': '\u0420\u0443\u0441\u0441\u043a\u0438\u0439',
      'language_en':
          '\u0410\u043d\u0433\u043b\u0438\u0439\u0441\u043a\u0438\u0439',
      'settings': '\u041d\u0430\u0441\u0442\u0440\u043e\u0439\u043a\u0438',
      'password_strength_weak':
          '\u0421\u043b\u0430\u0431\u044b\u0439 \u043f\u0430\u0440\u043e\u043b\u044c',
      'password_strength_medium':
          '\u0421\u0440\u0435\u0434\u043d\u0438\u0439 \u043f\u0430\u0440\u043e\u043b\u044c',
      'password_strength_strong':
          '\u041d\u0430\u0434\u0451\u0436\u043d\u044b\u0439 \u043f\u0430\u0440\u043e\u043b\u044c',
      'password_hint':
          '\u041c\u0438\u043d\u0438\u043c\u0443\u043c 8 \u0441\u0438\u043c\u0432\u043e\u043b\u043e\u0432, \u0431\u0443\u043a\u0432\u044b \u0438 \u0446\u0438\u0444\u0440\u044b',
      'passwords_mismatch':
          '\u041f\u0430\u0440\u043e\u043b\u0438 \u043d\u0435 \u0441\u043e\u0432\u043f\u0430\u0434\u0430\u044e\u0442',
      'email_required':
          '\u0412\u0432\u0435\u0434\u0438\u0442\u0435 \u043f\u043e\u0447\u0442\u0443',
      'password_required':
          '\u0412\u0432\u0435\u0434\u0438\u0442\u0435 \u043f\u0430\u0440\u043e\u043b\u044c',
      'name_required':
          '\u0412\u0432\u0435\u0434\u0438\u0442\u0435 \u0424\u0418\u041e',
      'auth_error':
          '\u041e\u0448\u0438\u0431\u043a\u0430 \u0432\u0445\u043e\u0434\u0430. \u041f\u0440\u043e\u0432\u0435\u0440\u044c\u0442\u0435 \u043f\u043e\u0447\u0442\u0443 \u0438 \u043f\u0430\u0440\u043e\u043b\u044c.',
      'reset_sent':
          '\u041f\u0438\u0441\u044c\u043c\u043e \u043e\u0442\u043f\u0440\u0430\u0432\u043b\u0435\u043d\u043e. \u041f\u0440\u043e\u0432\u0435\u0440\u044c\u0442\u0435 \u043f\u043e\u0447\u0442\u0443.',
      'profile_title': '\u041f\u0440\u043e\u0444\u0438\u043b\u044c',
      'save_profile': '\u0421\u043e\u0445\u0440\u0430\u043d\u0438\u0442\u044c',
      'profile_edit':
          '\u0420\u0435\u0434\u0430\u043a\u0442\u0438\u0440\u043e\u0432\u0430\u0442\u044c',
      'role_label': '\u0420\u043e\u043b\u044c',
      'contact_info': '\u041a\u043e\u043d\u0442\u0430\u043a\u0442\u044b',
      'account_info':
          '\u0414\u0430\u043d\u043d\u044b\u0435 \u0430\u043a\u043a\u0430\u0443\u043d\u0442\u0430',
      'preferences':
          '\u041f\u0440\u0435\u0434\u043f\u043e\u0447\u0442\u0435\u043d\u0438\u044f',
      'notifications':
          '\u0423\u0432\u0435\u0434\u043e\u043c\u043b\u0435\u043d\u0438\u044f',
      'schedule_updates':
          '\u041e\u0431\u043d\u043e\u0432\u043b\u0435\u043d\u0438\u044f \u0440\u0430\u0441\u043f\u0438\u0441\u0430\u043d\u0438\u044f',
      'request_updates':
          '\u041e\u0431\u043d\u043e\u0432\u043b\u0435\u043d\u0438\u044f \u0437\u0430\u044f\u0432\u043e\u043a',
      'security':
          '\u0411\u0435\u0437\u043e\u043f\u0430\u0441\u043d\u043e\u0441\u0442\u044c',
      'logout': '\u0412\u044b\u0439\u0442\u0438',
      'birth_date_label':
          '\u0414\u0430\u0442\u0430 \u0440\u043e\u0436\u0434\u0435\u043d\u0438\u044f (\u0413\u0413\u0413\u0413-\u041c\u041c-\u0414\u0414)',
      'group_label': '\u0413\u0440\u0443\u043f\u043f\u0430',
      'phone_label': '\u0422\u0435\u043b\u0435\u0444\u043e\u043d',
      'teacher_name_label':
          '\u0424\u0418\u041e \u043f\u0440\u0435\u043f\u043e\u0434\u0430\u0432\u0430\u0442\u0435\u043b\u044f',
      'profile_saved':
          '\u041f\u0440\u043e\u0444\u0438\u043b\u044c \u043e\u0431\u043d\u043e\u0432\u043b\u0451\u043d.',
      'birth_date_invalid':
          '\u0414\u0430\u0442\u0430 \u0440\u043e\u0436\u0434\u0435\u043d\u0438\u044f \u0434\u043e\u043b\u0436\u043d\u0430 \u0431\u044b\u0442\u044c \u0432 \u0444\u043e\u0440\u043c\u0430\u0442\u0435 \u0413\u0413\u0413\u0413-\u041c\u041c-\u0414\u0414.',
      'profile_stats_group': '\u0413\u0440\u0443\u043f\u043f\u0430',
      'profile_stats_role': '\u0420\u043e\u043b\u044c',
      'profile_stats_phone': '\u0422\u0435\u043b\u0435\u0444\u043e\u043d',
      'group_not_set':
          '\u041d\u0435 \u0443\u043a\u0430\u0437\u0430\u043d\u0430',
      'teacher_not_set':
          '\u041d\u0435 \u0443\u043a\u0430\u0437\u0430\u043d\u043e',
      'notifications_title':
          '\u0423\u0432\u0435\u0434\u043e\u043c\u043b\u0435\u043d\u0438\u044f',
      'notifications_empty':
          '\u041d\u0435\u0442 \u0443\u0432\u0435\u0434\u043e\u043c\u043b\u0435\u043d\u0438\u0439',
      'notifications_mark_read':
          '\u041e\u0442\u043c\u0435\u0442\u0438\u0442\u044c \u043a\u0430\u043a \u043f\u0440\u043e\u0447\u0438\u0442\u0430\u043d\u043d\u043e\u0435',
      'notifications_unread': '\u041d\u043e\u0432\u044b\u0435',
      'reset_password_action':
          '\u0421\u0431\u0440\u043e\u0441\u0438\u0442\u044c \u043f\u0430\u0440\u043e\u043b\u044c',
    },
    'en': {
      'auth_title_login': 'Sign in',
      'auth_title_register': 'Create account',
      'auth_subtitle_login': 'Welcome back',
      'auth_subtitle_register': 'Create a student account',
      'full_name': 'Full name',
      'email': 'Email',
      'password': 'Password',
      'confirm_password': 'Confirm password',
      'sign_in': 'Sign in',
      'create_account': 'Create account',
      'have_account': 'I already have an account',
      'create_new_account': 'Create a new account',
      'forgot_password': 'Forgot password?',
      'reset_password': 'Reset password',
      'reset_desc': 'We will send a password reset link to your email.',
      'send_reset': 'Send reset email',
      'language': 'Language',
      'language_ru': 'Russian',
      'language_en': 'English',
      'settings': 'Settings',
      'password_strength_weak': 'Weak password',
      'password_strength_medium': 'Medium password',
      'password_strength_strong': 'Strong password',
      'password_hint': 'At least 8 chars, letters and numbers',
      'passwords_mismatch': 'Passwords do not match',
      'email_required': 'Email is required',
      'password_required': 'Password is required',
      'name_required': 'Full name is required',
      'auth_error': 'Login failed. Check email and password.',
      'reset_sent': 'Reset email sent. Check your inbox.',
      'profile_title': 'Profile',
      'save_profile': 'Save',
      'profile_edit': 'Edit',
      'role_label': 'Role',
      'contact_info': 'Contact',
      'account_info': 'Account',
      'preferences': 'Preferences',
      'notifications': 'Notifications',
      'schedule_updates': 'Schedule updates',
      'request_updates': 'Request updates',
      'security': 'Security',
      'logout': 'Log out',
      'birth_date_label': 'Birth date (YYYY-MM-DD)',
      'group_label': 'Group',
      'phone_label': 'Phone',
      'teacher_name_label': 'Teacher name',
      'profile_saved': 'Profile updated.',
      'birth_date_invalid': 'Birth date must be in YYYY-MM-DD format.',
      'profile_stats_group': 'Group',
      'profile_stats_role': 'Role',
      'profile_stats_phone': 'Phone',
      'group_not_set': 'Not set',
      'teacher_not_set': 'Not set',
      'reset_password_action': 'Reset password',
      'notifications_title': 'Notifications',
      'notifications_empty': 'No notifications yet',
      'notifications_mark_read': 'Mark as read',
      'notifications_unread': 'New',
    },
  };

  String t(String key) =>
      _strings[locale.languageCode]?[key] ?? _strings['en']![key] ?? key;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations) ??
        AppLocalizations(const Locale('ru'));
  }
}

class AppLocalizationsDelegate extends LocalizationsDelegate<AppLocalizations> {
  const AppLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) => AppLocalizations.supportedLocales.any(
    (l) => l.languageCode == locale.languageCode,
  );

  @override
  Future<AppLocalizations> load(Locale locale) async =>
      AppLocalizations(locale);

  @override
  bool shouldReload(covariant LocalizationsDelegate<AppLocalizations> old) =>
      false;
}

const List<String> kRequestTypes = [
  '\u0421\u043f\u0440\u0430\u0432\u043a\u0430 \u043d\u0430 \u043e\u043d\u0430\u0439',
  '\u0421\u043f\u0440\u0430\u0432\u043a\u0430 \u043d\u0430 \u0432\u043e\u0435\u043d\u043a\u043e\u043c\u0430\u0442',
  '\u0421\u043f\u0440\u0430\u0432\u043a\u0430 \u043f\u043e \u043c\u0435\u0441\u0442\u0443 \u0442\u0440\u0435\u0431\u043e\u0432\u0430\u043d\u0438\u044f',
  '\u041f\u0440\u0438\u043b\u043e\u0436\u0435\u043d\u0438\u0435 \u21162',
  '\u041f\u0440\u0438\u043b\u043e\u0436\u0435\u043d\u0438\u0435 \u21164',
  '\u041f\u0440\u0438\u043b\u043e\u0436\u0435\u043d\u0438\u0435 \u21166',
  '\u041f\u0440\u0438\u043b\u043e\u0436\u0435\u043d\u0438\u0435 \u211629',
  '\u041f\u0440\u0438\u043b\u043e\u0436\u0435\u043d\u0438\u0435 \u211631',
  '\u0421\u043f\u0440\u0430\u0432\u043a\u0430 \u0432 \u0448\u043a\u043e\u043b\u0443',
];

const List<String> kRequestStatuses = [
  '\u041e\u0442\u043f\u0440\u0430\u0432\u043b\u0435\u043d\u0430',
  '\u041d\u0430 \u0440\u0430\u0441\u0441\u043c\u043e\u0442\u0440\u0435\u043d\u0438\u0438',
  '\u041e\u0442\u043a\u043b\u043e\u043d\u0435\u043d\u0430',
  '\u0412 \u0440\u0430\u0431\u043e\u0442\u0435',
  '\u0413\u043e\u0442\u043e\u0432\u0430',
];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  } catch (_) {}
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
  await _initLocalNotifications();
  final state = AppState(apiBaseUrl);
  await state.init();
  await JournalStore.init();
  runApp(PolyApp(state: state));
}

class AppState extends ChangeNotifier {
  static const _tokenKey = 'auth_token';
  static const _userKey = 'auth_user';

  Map<String, dynamic> _userToJson(UserProfile user) {
    return {
      'id': user.id,
      'role': user.role,
      'full_name': user.fullName,
      'email': user.email,
      'phone': user.phone,
      'avatar_url': user.avatarUrl,
      'about': user.about,
      'student_group': user.studentGroup,
      'teacher_name': user.teacherName,
      'birth_date': user.birthDate?.toIso8601String(),
    };
  }

  Future<void> _persistAuth(AuthResponse response) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenKey, response.accessToken);
    await prefs.setString(_userKey, jsonEncode(_userToJson(response.user)));
  }

  Future<void> _clearAuth() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
    await prefs.remove(_userKey);
  }

  AppState(this.baseUrl) : _client = ApiClient(baseUrl: baseUrl);

  final String baseUrl;
  ApiClient _client;
  String? _token;
  UserProfile? _user;
  String? _deviceId;
  bool _isReady = false;
  Locale _locale = const Locale('ru');
  bool _pushReady = false;

  ApiClient get client => _client;
  String? get token => _token;
  UserProfile? get user => _user;
  bool get isAuthenticated => _token != null && _user != null;
  bool get isReady => _isReady;
  String? get deviceId => _deviceId;
  Locale get locale => _locale;

  String _platformLabel() {
    if (kIsWeb) return 'web';
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return 'android';
      case TargetPlatform.iOS:
        return 'ios';
      case TargetPlatform.macOS:
        return 'macos';
      case TargetPlatform.windows:
        return 'windows';
      case TargetPlatform.linux:
        return 'linux';
      default:
        return 'unknown';
    }
  }

  Future<void> _registerPushToken() async {
    if (!isAuthenticated) return;
    try {
      final messaging = FirebaseMessaging.instance;
      if (!kIsWeb) {
        await messaging.requestPermission(
          alert: true,
          badge: true,
          sound: true,
        );
      }
      final webVapidKey = const String.fromEnvironment('WEB_VAPID_KEY');
      final token = await messaging.getToken(
        vapidKey: kIsWeb && webVapidKey.isNotEmpty ? webVapidKey : null,
      );
      if (token == null || token.isEmpty) return;
      final prefs = await SharedPreferences.getInstance();
      final cached = prefs.getString('fcm_token');
      if (cached == token) return;
      await _client.registerDeviceToken(
        token: token,
        platform: _platformLabel(),
      );
      await prefs.setString('fcm_token', token);
    } catch (_) {}
  }

  Future<void> _setupPush() async {
    if (!isAuthenticated) return;
    await _registerPushToken();
    if (_pushReady) return;
    _pushReady = true;
    FirebaseMessaging.instance.onTokenRefresh.listen((token) async {
      if (!isAuthenticated || token.isEmpty) return;
      try {
        await _client.registerDeviceToken(
          token: token,
          platform: _platformLabel(),
        );
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('fcm_token', token);
      } catch (_) {}
    });
  }

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    var stored = prefs.getString('device_id');
    if (stored == null || stored.isEmpty) {
      stored = const Uuid().v4();
      await prefs.setString('device_id', stored);
    }
    _deviceId = stored;

    final storedLocale = prefs.getString('app_locale');
    if (storedLocale != null && storedLocale.isNotEmpty) {
      _locale = Locale(storedLocale);
      appLocaleCode = storedLocale;
    }
    final cachedToken = prefs.getString(_tokenKey);
    final cachedUser = prefs.getString(_userKey);
    if (cachedToken != null && cachedToken.isNotEmpty) {
      _token = cachedToken;
      _client = ApiClient(baseUrl: baseUrl, token: cachedToken);
      if (cachedUser != null && cachedUser.isNotEmpty) {
        try {
          _user = UserProfile.fromJson(
            jsonDecode(cachedUser) as Map<String, dynamic>,
          );
        } catch (_) {}
      }
      try {
        _user = await _client.me();
      } catch (_) {
        _token = null;
        _user = null;
        _client = ApiClient(baseUrl: baseUrl);
        await _clearAuth();
      }
    }

    if (isAuthenticated) {
      await _setupPush();
    }
    _isReady = true;
    notifyListeners();
  }

  Future<void> login({required String email, required String password}) async {
    final response = await _client.login(
      email: email,
      password: password,
      deviceId: _deviceId,
    );
    _setAuth(response);
  }

  Future<void> register({
    required String fullName,
    required String email,
    required String password,
  }) async {
    final response = await _client.register(
      fullName: fullName,
      email: email,
      password: password,
      deviceId: _deviceId,
    );
    _setAuth(response);
  }

  Future<void> setLocale(String code) async {
    _locale = Locale(code);
    appLocaleCode = code;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('app_locale', code);
    notifyListeners();
  }

  Future<void> logout() async {
    try {
      await _client.logout();
    } catch (_) {}
    _token = null;
    _user = null;
    _client = ApiClient(baseUrl: baseUrl);
    await _clearAuth();
    notifyListeners();
  }

  Future<UserProfile?> updateProfile(Map<String, dynamic> payload) async {
    final current = _user;
    if (current == null) return null;
    final updated = await _client.updateUser(current.id, payload);
    _user = updated;
    notifyListeners();
    return updated;
  }

  void _setAuth(AuthResponse response) {
    _token = response.accessToken;
    _user = response.user;
    _client = ApiClient(baseUrl: baseUrl, token: response.accessToken);
    _persistAuth(response);
    notifyListeners();
    unawaited(_setupPush());
  }
}

class AppStateScope extends InheritedNotifier<AppState> {
  const AppStateScope({
    super.key,
    required AppState notifier,
    required Widget child,
  }) : super(notifier: notifier, child: child);

  static AppState of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppStateScope>();
    if (scope == null) {
      throw StateError('AppStateScope not found');
    }
    return scope.notifier!;
  }
}

class PolyApp extends StatelessWidget {
  const PolyApp({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return AppStateScope(
      notifier: state,
      child: AnimatedBuilder(
        animation: state,
        builder: (context, _) => MaterialApp(
          title: 'PolyApp',
          debugShowCheckedModeBanner: false,
          locale: state.locale,
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: const [
            AppLocalizationsDelegate(),
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          builder: (context, child) {
            return Shortcuts(
              shortcuts: {
                LogicalKeySet(LogicalKeyboardKey.escape): const DismissIntent(),
              },
              child: Actions(
                actions: {
                  DismissIntent: CallbackAction<DismissIntent>(
                    onInvoke: (intent) {
                      Navigator.of(context, rootNavigator: true).maybePop();
                      return null;
                    },
                  ),
                },
                child: Focus(
                  autofocus: true,
                  child: child ?? const SizedBox.shrink(),
                ),
              ),
            );
          },
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: kBrandPrimary,
              primary: kBrandPrimary,
              secondary: const Color(0xFFB45309),
              surface: kCardSurface,
              background: kAppBackground,
              error: kError,
            ),
            useMaterial3: true,
            scaffoldBackgroundColor: kAppBackground,
            cardTheme: CardThemeData(
              color: kCardSurface,
              elevation: 0.8,
              shadowColor: Colors.black.withOpacity(0.05),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
            ),
            textTheme: GoogleFonts.manropeTextTheme().copyWith(
              bodyMedium: GoogleFonts.manrope(color: kPrimaryText),
              bodySmall: GoogleFonts.manrope(color: kSecondaryText),
              titleMedium: GoogleFonts.manrope(
                fontWeight: FontWeight.w700,
                color: kPrimaryText,
              ),
              titleLarge: GoogleFonts.manrope(
                fontWeight: FontWeight.w800,
                color: kPrimaryText,
              ),
            ),
            appBarTheme: AppBarTheme(
              backgroundColor: kAppBackground,
              foregroundColor: kPrimaryText,
              elevation: 0,
              titleTextStyle: GoogleFonts.manrope(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color: kPrimaryText,
              ),
            ),
            inputDecorationTheme: InputDecorationTheme(
              filled: true,
              fillColor: kSecondaryBackground,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide.none,
              ),
              hintStyle: GoogleFonts.manrope(color: kMutedText),
              labelStyle: GoogleFonts.manrope(color: kSecondaryText),
            ),
          ),
          home: AppGate(),
        ),
      ),
    );
  }
}

class AppGate extends StatelessWidget {
  const AppGate({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    if (!state.isReady) {
      return const SplashPage();
    }
    if (!state.isAuthenticated) {
      return const AuthPage();
    }
    final role = kRoles.firstWhere(
      (role) => role.id == state.user!.role,
      orElse: () => kRoles.first,
    );
    return RoleHomePage(role: role);
  }
}

class SplashPage extends StatelessWidget {
  const SplashPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF163A3A), Color(0xFFF6F5F1)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const BrandLogo(size: 96, animated: true),
              const SizedBox(height: 16),
              Text(
                'PolyApp',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                l10n.t('loading'),
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
              const SizedBox(height: 10),
              const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  color: Colors.white,
                  strokeWidth: 2.2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class AuthPage extends StatefulWidget {
  const AuthPage({super.key});

  @override
  State<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends State<AuthPage> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();
  final _nameController = TextEditingController();
  bool _isRegister = false;
  bool _isLoading = false;
  bool _showPassword = false;
  bool _showConfirm = false;
  String? _errorMessage;

  String _formatAuthError(Object error) {
    final message = error.toString().replaceFirst('Exception: ', '').trim();
    if (message.contains('Invalid credentials'))
      return 'Invalid email or password.';
    if (message.contains('Email already registered'))
      return 'Email already registered.';
    if (message.contains('Password must be at least'))
      return 'Password too short.';
    return message;
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _confirmController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  int _passwordScore(String value) {
    var score = 0;
    if (value.length >= 8) score++;
    if (RegExp(r'[A-Z]').hasMatch(value)) score++;
    if (RegExp(r'[a-z]').hasMatch(value)) score++;
    if (RegExp(r'[0-9]').hasMatch(value)) score++;
    if (RegExp(r'[!@#$%^&*(),.?":{}|<>_\-\/\[\]]').hasMatch(value)) score++;
    return score;
  }

  String _passwordHint(String value) {
    final l10n = AppLocalizations.of(context);
    final score = _passwordScore(value);
    if (score >= 5) return l10n.t('password_strength_strong');
    if (score >= 3) return l10n.t('password_strength_medium');
    if (value.isEmpty) return l10n.t('password_hint');
    return l10n.t('password_strength_weak');
  }

  String? _validatePassword(String? value) {
    final l10n = AppLocalizations.of(context);
    final text = value ?? '';
    if (text.isEmpty) return l10n.t('password_required');
    if (text.length < 8) return l10n.t('password_hint');
    final isRu = AppStateScope.of(context).locale.languageCode == 'ru';
    if (!RegExp(r'[A-Z]').hasMatch(text))
      return isRu
          ? '\u0414\u043e\u0431\u0430\u0432\u044c\u0442\u0435 \u0437\u0430\u0433\u043b\u0430\u0432\u043d\u0443\u044e \u0431\u0443\u043a\u0432\u0443.'
          : 'Add an uppercase letter.';
    if (!RegExp(r'[a-z]').hasMatch(text))
      return isRu
          ? '\u0414\u043e\u0431\u0430\u0432\u044c\u0442\u0435 \u0441\u0442\u0440\u043e\u0447\u043d\u0443\u044e \u0431\u0443\u043a\u0432\u0443.'
          : 'Add a lowercase letter.';
    if (!RegExp(r'[0-9]').hasMatch(text))
      return isRu
          ? '\u0414\u043e\u0431\u0430\u0432\u044c\u0442\u0435 \u0446\u0438\u0444\u0440\u0443.'
          : 'Add a number.';
    return null;
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    setState(() => _errorMessage = null);
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final state = AppStateScope.of(context);
    setState(() => _isLoading = true);
    try {
      if (_isRegister) {
        await state.register(
          fullName: _nameController.text.trim(),
          email: _emailController.text.trim(),
          password: _passwordController.text,
        );
      } else {
        await state.login(
          email: _emailController.text.trim(),
          password: _passwordController.text,
        );
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _errorMessage = humanizeError(error));
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _openReset() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const ResetPasswordPage()));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final password = _passwordController.text;
    final score = _passwordScore(password);

    return Scaffold(
      body: Stack(
        children: [
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFF163A3A), Color(0xFFF6F5F1)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
          ),
          Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(28),
                    child: Form(
                      key: _formKey,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              Container(
                                width: 58,
                                height: 58,
                                decoration: BoxDecoration(
                                  color: kSecondaryBackground,
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(
                                    color: kBrandPrimary.withValues(
                                      alpha: 0.15,
                                    ),
                                  ),
                                ),
                                child: const Center(child: BrandLogo(size: 42)),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'PolyApp',
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleLarge
                                          ?.copyWith(
                                            fontWeight: FontWeight.w700,
                                          ),
                                    ),
                                    Text(
                                      _isRegister
                                          ? l10n.t('auth_subtitle_register')
                                          : l10n.t('auth_subtitle_login'),
                                      style: TextStyle(color: kSecondaryText),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 20),
                          if (_isRegister)
                            TextFormField(
                              controller: _nameController,
                              textInputAction: TextInputAction.next,
                              decoration: InputDecoration(
                                labelText: l10n.t('full_name'),
                              ),
                              validator: (value) {
                                if (!_isRegister) return null;
                                if (value == null || value.trim().isEmpty)
                                  return l10n.t('name_required');
                                return null;
                              },
                              onFieldSubmitted: (_) =>
                                  FocusScope.of(context).nextFocus(),
                            ),
                          if (_isRegister) const SizedBox(height: 12),
                          TextFormField(
                            controller: _emailController,
                            keyboardType: TextInputType.emailAddress,
                            textInputAction: TextInputAction.next,
                            decoration: InputDecoration(
                              labelText: l10n.t('email'),
                            ),
                            validator: (value) {
                              if (value == null || value.trim().isEmpty)
                                return l10n.t('email_required');
                              if (!value.contains('@'))
                                return l10n.t('email_required');
                              return null;
                            },
                            onFieldSubmitted: (_) =>
                                FocusScope.of(context).nextFocus(),
                          ),
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: _passwordController,
                            obscureText: !_showPassword,
                            textInputAction: _isRegister
                                ? TextInputAction.next
                                : TextInputAction.done,
                            decoration: InputDecoration(
                              labelText: l10n.t('password'),
                              suffixIcon: IconButton(
                                onPressed: () => setState(
                                  () => _showPassword = !_showPassword,
                                ),
                                icon: Icon(
                                  _showPassword
                                      ? Icons.visibility_off
                                      : Icons.visibility,
                                ),
                              ),
                            ),
                            validator: _validatePassword,
                            onChanged: (_) => setState(() {}),
                          ),
                          if (_isRegister) ...[
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                for (int i = 0; i < 5; i++)
                                  Expanded(
                                    child: Container(
                                      margin: EdgeInsets.only(
                                        right: i == 4 ? 0 : 6,
                                      ),
                                      height: 6,
                                      decoration: BoxDecoration(
                                        color: i < score
                                            ? kAccentSuccess
                                            : kSecondaryBackground,
                                        borderRadius: BorderRadius.circular(20),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text(
                              _passwordHint(password),
                              style: TextStyle(
                                color: kSecondaryText,
                                fontSize: 12,
                              ),
                            ),
                            const SizedBox(height: 12),
                            TextFormField(
                              controller: _confirmController,
                              obscureText: !_showConfirm,
                              textInputAction: TextInputAction.done,
                              decoration: InputDecoration(
                                labelText: l10n.t('confirm_password'),
                                suffixIcon: IconButton(
                                  onPressed: () => setState(
                                    () => _showConfirm = !_showConfirm,
                                  ),
                                  icon: Icon(
                                    _showConfirm
                                        ? Icons.visibility_off
                                        : Icons.visibility,
                                  ),
                                ),
                              ),
                              validator: (value) {
                                if (!_isRegister) return null;
                                if (value == null || value.isEmpty)
                                  return 'Confirm your password';
                                if (value != _passwordController.text)
                                  return l10n.t('passwords_mismatch');
                                return null;
                              },
                              onFieldSubmitted: (_) => _submit(),
                            ),
                          ],
                          const SizedBox(height: 16),
                          if (_errorMessage != null)
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: kError.withOpacity(0.12),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Row(
                                children: [
                                  const Icon(
                                    Icons.error_outline,
                                    color: kError,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      _errorMessage!,
                                      style: const TextStyle(color: kError),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          const SizedBox(height: 12),
                          FilledButton(
                            onPressed: _isLoading ? null : _submit,
                            child: _isLoading
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : Text(
                                    _isRegister
                                        ? l10n.t('create_account')
                                        : l10n.t('sign_in'),
                                  ),
                          ),
                          const SizedBox(height: 12),
                          TextButton(
                            onPressed: _isLoading
                                ? null
                                : () => setState(
                                    () => _isRegister = !_isRegister,
                                  ),
                            child: Text(
                              _isRegister
                                  ? l10n.t('have_account')
                                  : l10n.t('create_new_account'),
                            ),
                          ),
                          if (!_isRegister)
                            TextButton(
                              onPressed: _isLoading ? null : _openReset,
                              child: Text(l10n.t('forgot_password')),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (_isLoading) const LoadingOverlay(),
        ],
      ),
    );
  }
}

class ResetPasswordPage extends StatefulWidget {
  const ResetPasswordPage({super.key});

  @override
  State<ResetPasswordPage> createState() => _ResetPasswordPageState();
}

class _ResetPasswordPageState extends State<ResetPasswordPage> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  bool _sending = false;
  String? _message;
  bool _success = false;

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    FocusScope.of(context).unfocus();
    setState(() {
      _message = null;
      _success = false;
    });
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _sending = true);
    final l10n = AppLocalizations.of(context);
    try {
      await FirebaseAuth.instance.sendPasswordResetEmail(
        email: _emailController.text.trim(),
      );
      if (!mounted) return;
      setState(() {
        _success = true;
        _message = l10n.t('reset_sent');
      });
    } on FirebaseAuthException catch (error) {
      if (!mounted) return;
      final msg = error.message ?? 'Reset failed.';
      setState(() {
        _success = false;
        _message = msg;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _success = false;
        _message = error.toString();
      });
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.t('reset_password'))),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(l10n.t('reset_desc'), style: TextStyle(color: kSecondaryText)),
          const SizedBox(height: 16),
          Form(
            key: _formKey,
            child: TextFormField(
              controller: _emailController,
              keyboardType: TextInputType.emailAddress,
              decoration: InputDecoration(labelText: l10n.t('email')),
              validator: (value) {
                if (value == null || value.trim().isEmpty)
                  return l10n.t('email_required');
                if (!value.contains('@')) return l10n.t('email_required');
                return null;
              },
            ),
          ),
          const SizedBox(height: 16),
          if (_message != null)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: (_success ? kAccentSuccess : kError).withOpacity(0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(
                    _success ? Icons.check_circle_outline : Icons.error_outline,
                    color: _success ? kAccentSuccess : kError,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _message!,
                      style: TextStyle(
                        color: _success ? kAccentSuccess : kError,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _sending ? null : _send,
            child: _sending
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(l10n.t('send_reset')),
          ),
        ],
      ),
    );
  }
}

class LoadingOverlay extends StatelessWidget {
  const LoadingOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black54,
      child: Center(
        child: const BrandLoadingIndicator(dark: true, logoSize: 88),
      ),
    );
  }
}

class RoleDefinition {
  const RoleDefinition({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.features,
  });

  final String id;
  final String title;
  final String subtitle;
  final Color color;
  final List<FeatureDefinition> features;
}

class FeatureDefinition {
  const FeatureDefinition({
    required this.id,
    required this.title,
    required this.icon,
    required this.builder,
  });

  final String id;
  final String title;
  final IconData icon;
  final WidgetBuilder builder;
}

final List<RoleDefinition> kRoles = [
  RoleDefinition(
    id: 'smm',
    title: 'SMM',
    subtitle: 'News feed editor',
    color: const Color(0xFF0E5A6C),
    features: [
      FeatureDefinition(
        id: 'news',
        title: 'News feed',
        icon: Icons.dynamic_feed,
        builder: (context) => const NewsFeedPage(canEdit: true),
      ),
      FeatureDefinition(
        id: 'profile',
        title: 'Profile',
        icon: Icons.person,
        builder: (context) => const ProfilePage(),
      ),
    ],
  ),
  RoleDefinition(
    id: 'parent',
    title: 'Parent',
    subtitle: 'Attendance and grades',
    color: const Color(0xFF8A5A3B),
    features: [
      FeatureDefinition(
        id: 'attendance',
        title: 'Attendance',
        icon: Icons.fact_check,
        builder: (context) => const AttendancePage(),
      ),
      FeatureDefinition(
        id: 'grades',
        title: 'Grades',
        icon: Icons.grade,
        builder: (context) => const GradesPage(),
      ),
      FeatureDefinition(
        id: 'exams',
        title: 'Exam grades',
        icon: Icons.assignment_turned_in,
        builder: (context) => const ExamGradesPage(),
      ),
      FeatureDefinition(
        id: 'profile',
        title: 'Profile',
        icon: Icons.person,
        builder: (context) => const ProfilePage(),
      ),
    ],
  ),
  RoleDefinition(
    id: 'request_handler',
    title: 'Request handler',
    subtitle: 'Process student requests',
    color: const Color(0xFF31525B),
    features: [
      FeatureDefinition(
        id: 'requests',
        title: 'Requests',
        icon: Icons.receipt_long,
        builder: (context) => const RequestsPage(canProcess: true),
      ),
      FeatureDefinition(
        id: 'profile',
        title: 'Profile',
        icon: Icons.person,
        builder: (context) => const ProfilePage(),
      ),
    ],
  ),
  RoleDefinition(
    id: 'admin',
    title: 'Admin',
    subtitle: 'Full access',
    color: const Color(0xFF1C3F60),
    features: [
      FeatureDefinition(
        id: 'schedule',
        title: 'Schedule',
        icon: Icons.calendar_month,
        builder: (context) => const SchedulePage(),
      ),
      FeatureDefinition(
        id: 'attendance',
        title: 'Attendance',
        icon: Icons.fact_check,
        builder: (context) => const AttendancePage(),
      ),
      FeatureDefinition(
        id: 'grades',
        title: 'Grades',
        icon: Icons.grade,
        builder: (context) => const GradesPage(),
      ),
      FeatureDefinition(
        id: 'exams',
        title: 'Exam grades',
        icon: Icons.assignment_turned_in,
        builder: (context) => const ExamGradesPage(),
      ),
      FeatureDefinition(
        id: 'analytics',
        title: 'Analytics',
        icon: Icons.analytics_outlined,
        builder: (context) => const AnalyticsPage(),
      ),
      FeatureDefinition(
        id: 'news',
        title: 'News feed',
        icon: Icons.dynamic_feed,
        builder: (context) => const NewsFeedPage(canEdit: true),
      ),
      FeatureDefinition(
        id: 'requests',
        title: 'Requests',
        icon: Icons.receipt_long,
        builder: (context) => const RequestsPage(canProcess: true),
      ),
      FeatureDefinition(
        id: 'profile',
        title: 'Profile',
        icon: Icons.person,
        builder: (context) => const ProfilePage(),
      ),
    ],
  ),
  RoleDefinition(
    id: 'student',
    title: 'Student',
    subtitle: 'Schedule, news, requests',
    color: const Color(0xFF325C4A),
    features: [
      FeatureDefinition(
        id: 'schedule',
        title: 'Schedule',
        icon: Icons.calendar_today,
        builder: (context) => const SchedulePage(),
      ),
      FeatureDefinition(
        id: 'exams',
        title: 'Exam grades',
        icon: Icons.assignment_turned_in,
        builder: (context) => const ExamGradesPage(),
      ),
      FeatureDefinition(
        id: 'requests',
        title: 'Requests',
        icon: Icons.mail_outline,
        builder: (context) => const RequestsPage(canProcess: false),
      ),
      FeatureDefinition(
        id: 'news',
        title: 'News feed',
        icon: Icons.dynamic_feed,
        builder: (context) => const NewsFeedPage(canEdit: false),
      ),
      FeatureDefinition(
        id: 'profile',
        title: 'Profile',
        icon: Icons.person,
        builder: (context) => const ProfilePage(),
      ),
    ],
  ),
  RoleDefinition(
    id: 'teacher',
    title: 'Teacher',
    subtitle: 'Journals, feed and requests',
    color: const Color(0xFF6C3B2A),
    features: [
      FeatureDefinition(
        id: 'schedule',
        title: 'Schedule',
        icon: Icons.event_note,
        builder: (context) => const SchedulePage(),
      ),
      FeatureDefinition(
        id: 'attendance',
        title: 'Attendance',
        icon: Icons.fact_check,
        builder: (context) => const AttendancePage(),
      ),
      FeatureDefinition(
        id: 'grades',
        title: 'Grades',
        icon: Icons.grade,
        builder: (context) => const GradesPage(),
      ),
      FeatureDefinition(
        id: 'exams',
        title: 'Exam grades',
        icon: Icons.assignment_turned_in,
        builder: (context) => const ExamGradesPage(),
      ),
      FeatureDefinition(
        id: 'analytics',
        title: 'Analytics',
        icon: Icons.analytics_outlined,
        builder: (context) => const AnalyticsPage(),
      ),
      FeatureDefinition(
        id: 'news',
        title: 'News feed',
        icon: Icons.dynamic_feed,
        builder: (context) => const NewsFeedPage(canEdit: false),
      ),
      FeatureDefinition(
        id: 'requests',
        title: 'Requests',
        icon: Icons.receipt_long,
        builder: (context) => const RequestsPage(canProcess: true),
      ),
      FeatureDefinition(
        id: 'profile',
        title: 'Profile',
        icon: Icons.person,
        builder: (context) => const ProfilePage(),
      ),
    ],
  ),
];

class RoleHomePage extends StatefulWidget {
  const RoleHomePage({super.key, required this.role});

  final RoleDefinition role;

  @override
  State<RoleHomePage> createState() => _RoleHomePageState();
}

class _RoleHomePageState extends State<RoleHomePage> {
  int _index = 0;

  void _openNotifications() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const NotificationsPage()));
  }

  bool _isNativeDesktop() {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.linux;
  }

  DeviceCanvas _resolveCanvas(BoxConstraints constraints) {
    if (kIsWeb) {
      return DeviceCanvas.web;
    }
    if (_isNativeDesktop() && constraints.maxWidth >= 980) {
      return DeviceCanvas.desktop;
    }
    return DeviceCanvas.mobile;
  }

  List<_NavItem> _buildTabs() {
    final isRu = AppStateScope.of(context).locale.languageCode == 'ru';
    String t(String ru, String en) => isRu ? ru : en;
    final featureIds = widget.role.features
        .map((feature) => feature.id)
        .toSet();
    final items = <_NavItem>[
      _NavItem(
        t('Главная', 'Home'),
        Icons.home,
        (context) => HomePage(role: widget.role),
      ),
    ];
    if (featureIds.contains('schedule')) {
      items.add(
        _NavItem(
          t('Расписание', 'Schedule'),
          Icons.calendar_today,
          (context) => const SchedulePage(),
        ),
      );
    }
    if (featureIds.contains('grades') || featureIds.contains('attendance')) {
      items.add(
        _NavItem(
          t('Оценки', 'Grades'),
          Icons.grade,
          (context) => const GradesPage(),
        ),
      );
    }
    if (featureIds.contains('analytics')) {
      items.add(
        _NavItem(
          t('Аналитика', 'Analytics'),
          Icons.analytics_outlined,
          (context) => const AnalyticsPage(),
        ),
      );
    }
    if (featureIds.contains('requests')) {
      final canProcess =
          widget.role.id != 'student' && widget.role.id != 'parent';
      items.add(
        _NavItem(
          t('Заявки', 'Requests'),
          Icons.receipt_long,
          (context) => RequestsPage(canProcess: canProcess),
        ),
      );
    }
    items.add(
      _NavItem(
        t('Профиль', 'Profile'),
        Icons.person,
        (context) => const ProfilePage(),
      ),
    );
    return items;
  }

  Widget _buildAnimatedBody(List<_NavItem> tabs) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) {
        final offset = Tween<Offset>(
          begin: const Offset(0.04, 0),
          end: Offset.zero,
        ).animate(animation);
        return FadeTransition(
          opacity: animation,
          child: SlideTransition(position: offset, child: child),
        );
      },
      child: KeyedSubtree(
        key: ValueKey<int>(_index),
        child: tabs[_index].builder(context),
      ),
    );
  }

  Widget _buildDesktopShell(List<_NavItem> tabs, Color color, String title) {
    return Scaffold(
      body: Row(
        children: [
          Container(
            width: 280,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [color.withOpacity(0.24), const Color(0xFFD9E9D2)],
              ),
            ),
            child: SafeArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 18),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    child: Text(
                      widget.role.title,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    child: Text(
                      widget.role.subtitle,
                      style: TextStyle(color: kSecondaryText),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Expanded(
                    child: ListView.builder(
                      itemCount: tabs.length,
                      itemBuilder: (context, i) {
                        final selected = i == _index;
                        return Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          child: ListTile(
                            selected: selected,
                            selectedTileColor: Colors.white.withOpacity(0.75),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                            leading: Icon(
                              tabs[i].icon,
                              color: selected ? kBrandPrimary : kSecondaryText,
                            ),
                            title: Text(
                              tabs[i].title,
                              style: TextStyle(
                                fontWeight: selected
                                    ? FontWeight.w700
                                    : FontWeight.w600,
                                color: selected ? kPrimaryText : kSecondaryText,
                              ),
                            ),
                            onTap: () => setState(() => _index = i),
                          ),
                        );
                      },
                    ),
                  ),
                  const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 8,
                    ),
                    child: Row(
                      children: [
                        IconButton(
                          onPressed: _openNotifications,
                          icon: const Icon(Icons.notifications_none),
                          tooltip: 'Notifications',
                        ),
                        const Spacer(),
                        IconButton(
                          onPressed: () => AppStateScope.of(context).logout(),
                          icon: const Icon(Icons.logout),
                          tooltip: 'Logout',
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.fromLTRB(26, 22, 26, 18),
                  alignment: Alignment.centerLeft,
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                const Divider(height: 1),
                Expanded(child: _buildAnimatedBody(tabs)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWebShell(List<_NavItem> tabs, Color color, String title) {
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [color.withOpacity(0.22), kAppBackground],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
                child: Row(
                  children: [
                    Text(
                      widget.role.title,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(width: 20),
                    Expanded(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            for (int i = 0; i < tabs.length; i++)
                              Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: ChoiceChip(
                                  selected: _index == i,
                                  label: Text(tabs[i].title),
                                  onSelected: (_) => setState(() => _index = i),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: _openNotifications,
                      icon: const Icon(Icons.notifications_none),
                      tooltip: 'Notifications',
                    ),
                    IconButton(
                      onPressed: () => AppStateScope.of(context).logout(),
                      icon: const Icon(Icons.logout),
                      tooltip: 'Logout',
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1280),
                    child: Card(
                      margin: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                      clipBehavior: Clip.antiAlias,
                      child: Column(
                        children: [
                          Container(
                            width: double.infinity,
                            color: color.withOpacity(0.1),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 20,
                              vertical: 14,
                            ),
                            child: Text(
                              title,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ),
                          Expanded(child: _buildAnimatedBody(tabs)),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMobileShell(List<_NavItem> tabs, Color color, String title) {
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        backgroundColor: color.withOpacity(0.16),
        actions: [
          IconButton(
            onPressed: _openNotifications,
            icon: const Icon(Icons.notifications_none),
            tooltip: 'Notifications',
          ),
          IconButton(
            onPressed: () => AppStateScope.of(context).logout(),
            icon: const Icon(Icons.logout),
            tooltip: 'Logout',
          ),
        ],
      ),
      body: _buildAnimatedBody(tabs),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        destinations: [
          for (final feature in tabs)
            NavigationDestination(
              icon: Icon(feature.icon),
              label: feature.title,
            ),
        ],
        onDestinationSelected: (value) {
          setState(() => _index = value);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tabs = _buildTabs();
    final color = widget.role.color;
    final title = tabs[_index].title;
    return LayoutBuilder(
      builder: (context, constraints) {
        switch (_resolveCanvas(constraints)) {
          case DeviceCanvas.desktop:
            return _buildDesktopShell(tabs, color, title);
          case DeviceCanvas.web:
            return _buildWebShell(tabs, color, title);
          case DeviceCanvas.mobile:
            return _buildMobileShell(tabs, color, title);
        }
      },
    );
  }
}

class _NavItem {
  _NavItem(this.title, this.icon, this.builder);
  final String title;
  final IconData icon;
  final WidgetBuilder builder;
}

class _AccessGuard extends StatelessWidget {
  const _AccessGuard({
    required this.allowed,
    required this.role,
    required this.child,
    required this.pageName,
  });

  final Set<String> allowed;
  final String role;
  final Widget child;
  final String pageName;

  @override
  Widget build(BuildContext context) {
    if (!allowed.contains(role)) {
      return AccessDeniedPage(pageName: pageName);
    }
    return child;
  }
}

class SectionHeader extends StatelessWidget {
  const SectionHeader({super.key, required this.title, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          title,
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
        const Spacer(),
        if (trailing != null) trailing!,
      ],
    );
  }
}

class SchedulePage extends StatefulWidget {
  const SchedulePage({super.key});

  @override
  State<SchedulePage> createState() => _SchedulePageState();
}

class _SchedulePageState extends State<SchedulePage> {
  String? _noticeMessage;
  bool _noticeError = false;
  final _groupController = TextEditingController();
  final _teacherController = TextEditingController();
  ScheduleUpload? _latest;
  List<ScheduleLesson> _lessons = [];
  List<String> _groups = [];
  List<String> _teachers = [];
  bool _loading = false;
  bool _uploading = false;
  bool _initialized = false;
  late final List<DateTime> _dateRange;
  late DateTime _selectedDate;

  @override
  void initState() {
    super.initState();
    _dateRange = _buildDateRange();
    final today = DateUtils.dateOnly(DateTime.now());
    _selectedDate = _dateRange.firstWhere(
      (day) => DateUtils.isSameDay(day, today),
      orElse: () => _dateRange.isNotEmpty ? _dateRange.first : today,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _loadLatest();
    _loadGroups();
    _loadTeachers();
    _loadCachedSchedule();
    final user = AppStateScope.of(context).user;
    if (user != null && (user.role == 'student' || user.role == 'teacher')) {
      final hasValue =
          (user.role == 'student' &&
              (user.studentGroup ?? '').trim().isNotEmpty) ||
          (user.role == 'teacher' &&
              (user.teacherName ?? '').trim().isNotEmpty);
      if (hasValue) {
        _loadScheduleForMe();
      }
    }
    _initialized = true;
  }

  List<DateTime> _buildDateRange() {
    final today = DateUtils.dateOnly(DateTime.now());
    final start = today.subtract(const Duration(days: 5));
    final end = today.add(const Duration(days: 1));
    final items = <DateTime>[];
    for (int i = 0; i <= end.difference(start).inDays; i++) {
      final day = DateTime(start.year, start.month, start.day + i);
      if (_isWeekend(day) && !DateUtils.isSameDay(day, today)) continue;
      items.add(day);
    }
    return items;
  }

  bool _isWeekend(DateTime day) {
    return day.weekday == DateTime.saturday || day.weekday == DateTime.sunday;
  }

  String _lessonType(String lesson) {
    final lower = lesson.toLowerCase();
    if (lower.contains('lab') || lower.contains('\u043b\u0430\u0431'))
      return 'Lab';
    if (lower.contains('pract') ||
        lower.contains('\u043f\u0440\u0430\u043a\u0442'))
      return 'Practice';
    if (lower.contains('lec') || lower.contains('\u043b\u0435\u043a'))
      return 'Lecture';
    return 'Class';
  }

  Color _typeColor(String type) {
    switch (type) {
      case 'Lab':
        return kWarning;
      case 'Practice':
        return kInfo;
      case 'Lecture':
        return kBrandPrimary;
      default:
        return kSecondaryText;
    }
  }

  Future<void> _loadLatest() async {
    final client = AppStateScope.of(context).client;
    try {
      final latest = await client.latestSchedule();
      if (!mounted) return;
      setState(() => _latest = latest);
    } catch (_) {}
  }

  Future<void> _loadGroups() async {
    try {
      final groups = await AppStateScope.of(
        context,
      ).client.listScheduleGroups();
      if (!mounted) return;
      setState(() => _groups = groups);
    } catch (_) {}
  }

  Future<void> _loadTeachers() async {
    try {
      final teachers = await AppStateScope.of(
        context,
      ).client.listScheduleTeachers();
      if (!mounted) return;
      setState(() => _teachers = teachers);
    } catch (_) {}
  }

  Future<void> _uploadSchedule() async {
    if (_uploading) return;
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['docx'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;
    final bytes = file.bytes;
    if (bytes == null) {
      if (!mounted) return;
      setState(() {
        _noticeError = true;
        _noticeMessage = 'Не удалось прочитать файл.';
      });
      return;
    }
    setState(() => _uploading = true);
    try {
      final uploaded = await AppStateScope.of(
        context,
      ).client.uploadScheduleBytes(filename: file.name, bytes: bytes);
      if (!mounted) return;
      setState(() => _latest = uploaded);
      setState(() {
        _noticeError = false;
        _noticeMessage = 'Расписание загружено: ${uploaded.filename}';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _noticeError = true;
        _noticeMessage = humanizeError(error);
      });
    } finally {
      if (mounted) {
        setState(() => _uploading = false);
      }
    }
  }

  Future<void> _loadSchedule() async {
    final group = _groupController.text.trim();
    if (group.isEmpty) return;
    setState(() => _loading = true);
    try {
      final data = await AppStateScope.of(
        context,
      ).client.scheduleForGroup(group);
      if (!mounted) return;
      setState(() => _lessons = data);
      _saveCachedSchedule();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _noticeError = true;
        _noticeMessage =
            'Не удалось загрузить расписание: ${humanizeError(error)}';
      });
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _loadScheduleForMe() async {
    setState(() => _loading = true);
    try {
      final data = await AppStateScope.of(context).client.scheduleForMe();
      if (!mounted) return;
      setState(() => _lessons = data);
      _saveCachedSchedule();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _noticeError = true;
        _noticeMessage =
            'Не удалось загрузить расписание: ${humanizeError(error)}';
      });
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  String _cacheKey(UserProfile? user) {
    if (user == null) return 'schedule_cache_guest';
    if (user.role == 'student') {
      return 'schedule_cache_student_${user.studentGroup ?? 'none'}';
    }
    if (user.role == 'teacher') {
      return 'schedule_cache_teacher_${user.teacherName ?? 'none'}';
    }
    return 'schedule_cache_admin';
  }

  Future<void> _loadCachedSchedule() async {
    final prefs = await SharedPreferences.getInstance();
    final key = _cacheKey(AppStateScope.of(context).user);
    final raw = prefs.getString(key);
    if (raw == null || raw.isEmpty) return;
    try {
      final data = jsonDecode(raw) as List<dynamic>;
      final lessons = data
          .map((item) => ScheduleLesson.fromJson(item as Map<String, dynamic>))
          .toList();
      if (!mounted) return;
      setState(() => _lessons = lessons);
    } catch (_) {}
  }

  Future<void> _saveCachedSchedule() async {
    final prefs = await SharedPreferences.getInstance();
    final key = _cacheKey(AppStateScope.of(context).user);
    final payload = _lessons
        .map(
          (item) => {
            'shift': item.shift,
            'period': item.period,
            'time': item.time,
            'audience': item.audience,
            'lesson': item.lesson,
            'group_name': item.groupName,
          },
        )
        .toList();
    await prefs.setString(key, jsonEncode(payload));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final user = AppStateScope.of(context).user;
    final canUpload = user?.role == 'admin';
    final scheduleDate = _latest?.scheduleDate;
    final matchesDate =
        scheduleDate == null ||
        DateUtils.isSameDay(scheduleDate, _selectedDate);
    final visibleLessons = matchesDate ? _lessons : <ScheduleLesson>[];
    final isEmpty = visibleLessons.isEmpty;

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        if (_noticeMessage != null)
          InlineNotice(message: _noticeMessage!, isError: _noticeError),
        if (_noticeMessage != null) const SizedBox(height: 12),
        if (canUpload)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Admin tools',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: _uploading ? null : _uploadSchedule,
                    child: _uploading
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Upload DOCX'),
                  ),
                  if (_groups.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    const Text('Groups'),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final group in _groups.take(12))
                          ActionChip(
                            label: Text(group),
                            onPressed: () {
                              _groupController.text = group;
                              _loadSchedule();
                            },
                          ),
                      ],
                    ),
                  ],
                  if (_teachers.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    const Text('Teachers'),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final teacher in _teachers.take(12))
                          ActionChip(
                            label: Text(teacher),
                            onPressed: () {
                              _teacherController.text = teacher;
                              _loadScheduleForMe();
                            },
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        if (canUpload) const SizedBox(height: 16),
        SizedBox(
          height: 72,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: _dateRange.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (context, index) {
              final day = _dateRange[index];
              final isSelected = DateUtils.isSameDay(day, _selectedDate);
              final isToday = DateUtils.isSameDay(day, DateTime.now());
              return InkWell(
                onTap: () => setState(() => _selectedDate = day),
                child: Container(
                  width: 64,
                  decoration: BoxDecoration(
                    color: isSelected ? kBrandPrimary : kSecondaryBackground,
                    borderRadius: BorderRadius.circular(16),
                    border: isToday && !isSelected
                        ? Border.all(color: kBrandPrimary, width: 1.5)
                        : null,
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        DateFormat('EEE').format(day),
                        style: TextStyle(
                          color: isSelected ? Colors.white : kSecondaryText,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        DateFormat('dd').format(day),
                        style: TextStyle(
                          color: isSelected ? Colors.white : kPrimaryText,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 16),
        if (_loading) const Center(child: BrandLoadingIndicator()),
        if (!_loading && isEmpty)
          const Text('No lessons for this day')
        else if (!_loading)
          Column(
            children: [
              for (final lesson in visibleLessons)
                Card(
                  margin: const EdgeInsets.only(bottom: 12),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              lesson.time,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const Spacer(),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: _typeColor(
                                  _lessonType(lesson.lesson),
                                ).withOpacity(0.15),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                _lessonType(lesson.lesson),
                                style: TextStyle(
                                  color: _typeColor(_lessonType(lesson.lesson)),
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          lesson.lesson,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Room: ${lesson.audience}',
                          style: TextStyle(color: kSecondaryText),
                        ),
                        Text(
                          'Group: ${lesson.groupName}',
                          style: TextStyle(color: kSecondaryText),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
      ],
    );
  }
}

class AttendancePage extends StatelessWidget {
  const AttendancePage({super.key});

  @override
  Widget build(BuildContext context) {
    final role = AppStateScope.of(context).user?.role ?? '';
    final canEdit = role == 'teacher' || role == 'admin';
    return AttendanceJournalPage(
      canEdit: canEdit,
      client: AppStateScope.of(context).client,
    );
  }
}

class GradesPage extends StatelessWidget {
  const GradesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final role = AppStateScope.of(context).user?.role ?? '';
    final canEdit = role == 'teacher' || role == 'admin';
    return GradesPresetJournalPage(
      canEdit: canEdit,
      client: AppStateScope.of(context).client,
    );
  }
}

class ExamGradesPage extends StatefulWidget {
  const ExamGradesPage({super.key});

  @override
  State<ExamGradesPage> createState() => _ExamGradesPageState();
}

class _ExamGradesPageState extends State<ExamGradesPage> {
  String? _noticeMessage;
  bool _noticeError = false;
  final _groupController = TextEditingController();
  final _examController = TextEditingController();
  final DateFormat _dateFormat = DateFormat('dd.MM.yyyy HH:mm');
  Future<List<ExamGrade>>? _gradesFuture;
  Future<List<ExamUpload>>? _uploadsFuture;
  bool _initialized = false;
  bool _showUploads = false;

  bool get _canUpload {
    final role = AppStateScope.of(context).user?.role ?? '';
    return role == 'teacher' || role == 'admin';
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    final user = AppStateScope.of(context).user;
    _groupController.text = user?.studentGroup ?? '';
    _reload();
    _initialized = true;
  }

  @override
  void dispose() {
    _groupController.dispose();
    _examController.dispose();
    super.dispose();
  }

  void _reload() {
    final client = AppStateScope.of(context).client;
    final group = _groupController.text.trim();
    final exam = _examController.text.trim();
    setState(() {
      _gradesFuture = client.listExamGrades(
        groupName: group.isEmpty ? null : group,
        examName: exam.isEmpty ? null : exam,
      );
      if (_canUpload) {
        _uploadsFuture = client.listExamUploads(
          groupName: group.isEmpty ? null : group,
          examName: exam.isEmpty ? null : exam,
        );
      }
    });
  }

  Future<void> _openUploadDialog() async {
    final groupController = TextEditingController(
      text: _groupController.text.trim(),
    );
    final examController = TextEditingController(
      text: _examController.text.trim(),
    );
    List<int>? bytes;
    String? filename;

    await showDialog<void>(
      context: context,
      builder: (context) {
        bool uploading = false;
        return StatefulBuilder(
          builder: (context, setStateDialog) {
            return AlertDialog(
              title: const Text('Upload exam grades'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: groupController,
                    decoration: const InputDecoration(
                      labelText: 'Group',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => FocusScope.of(context).nextFocus(),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: examController,
                    decoration: const InputDecoration(
                      labelText: 'Exam name',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => FocusScope.of(context).nextFocus(),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(child: Text(filename ?? 'No file chosen')),
                      IconButton(
                        icon: const Icon(Icons.upload_file),
                        onPressed: uploading
                            ? null
                            : () async {
                                final result = await FilePicker.platform
                                    .pickFiles(
                                      type: FileType.custom,
                                      allowedExtensions: ['xlsx'],
                                      withData: true,
                                    );
                                if (result != null && result.files.isNotEmpty) {
                                  final file = result.files.first;
                                  setStateDialog(() {
                                    bytes = file.bytes;
                                    filename = file.name;
                                  });
                                }
                              },
                      ),
                    ],
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: uploading
                      ? null
                      : () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: uploading
                      ? null
                      : () async {
                          final group = groupController.text.trim();
                          final exam = examController.text.trim();
                          if (group.isEmpty ||
                              exam.isEmpty ||
                              bytes == null ||
                              filename == null) {
                            setState(() {
                              _noticeError = true;
                              _noticeMessage =
                                  'Заполните группу, название экзамена и выберите файл.';
                            });
                            return;
                          }
                          setStateDialog(() => uploading = true);
                          try {
                            final count = await AppStateScope.of(context).client
                                .uploadExamGradesBytes(
                                  groupName: group,
                                  examName: exam,
                                  filename: filename!,
                                  bytes: bytes!,
                                );
                            if (!mounted) return;
                            setState(() {
                              _noticeError = false;
                              _noticeMessage = 'Загружено оценок: $count';
                            });
                            _groupController.text = group;
                            _examController.text = exam;
                            _reload();
                            if (mounted) Navigator.of(context).pop();
                          } catch (error) {
                            if (!mounted) return;
                            setState(() {
                              _noticeError = true;
                              _noticeMessage = humanizeError(error);
                            });
                          } finally {
                            if (mounted)
                              setStateDialog(() => uploading = false);
                          }
                        },
                  child: uploading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Upload'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildGradesList() {
    final future = _gradesFuture;
    if (future == null) {
      return const SizedBox();
    }
    return FutureBuilder<List<ExamGrade>>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: BrandLoadingIndicator());
        }
        if (snapshot.hasError) {
          return Text('Failed to load exam grades: ${snapshot.error}');
        }
        final items = snapshot.data ?? [];
        if (items.isEmpty) {
          return const Text('No exam grades yet');
        }
        return Column(
          children: [
            for (final item in items)
              Card(
                margin: const EdgeInsets.only(bottom: 12),
                child: ListTile(
                  leading: const CircleAvatar(child: BrandLogo(size: 20)),
                  title: Text('${item.examName} (${item.groupName})'),
                  subtitle: Text(
                    '${item.studentName} - ${_dateFormat.format(item.createdAt)}',
                  ),
                  trailing: Text(
                    item.grade.toString(),
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Future<void> _editUpload(ExamUpload upload) async {
    final groupController = TextEditingController(text: upload.groupName);
    final examController = TextEditingController(text: upload.examName);
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit upload'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: groupController,
              decoration: const InputDecoration(
                labelText: 'Group',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => FocusScope.of(context).nextFocus(),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: examController,
              decoration: const InputDecoration(
                labelText: 'Exam name',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (result != true) return;
    try {
      await AppStateScope.of(context).client.updateExamUpload(
        upload.id,
        groupName: groupController.text.trim(),
        examName: examController.text.trim(),
      );
      if (!mounted) return;
      _reload();
      setState(() {
        _noticeError = false;
        _noticeMessage = 'Загрузка обновлена.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _noticeError = true;
        _noticeMessage = humanizeError(error);
      });
    }
  }

  Future<void> _deleteUpload(ExamUpload upload) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete upload?'),
        content: const Text('All grades from this upload will be deleted.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await AppStateScope.of(context).client.deleteExamUpload(upload.id);
      if (!mounted) return;
      _reload();
      setState(() {
        _noticeError = false;
        _noticeMessage = 'Загрузка удалена.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _noticeError = true;
        _noticeMessage = humanizeError(error);
      });
    }
  }

  Widget _buildUploadsList() {
    final future = _uploadsFuture;
    if (future == null) {
      return const SizedBox();
    }
    return FutureBuilder<List<ExamUpload>>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: BrandLoadingIndicator());
        }
        if (snapshot.hasError) {
          return Text('Failed to load uploads: ${snapshot.error}');
        }
        final items = snapshot.data ?? [];
        if (items.isEmpty) {
          return const Text('No uploads yet');
        }
        return Column(
          children: [
            for (final item in items)
              Card(
                margin: const EdgeInsets.only(bottom: 12),
                child: ListTile(
                  leading: const CircleAvatar(child: Icon(Icons.upload_file)),
                  title: Text('${item.examName} (${item.groupName})'),
                  subtitle: Text(
                    '${item.filename} - ${item.rowsCount} rows\n${_dateFormat.format(item.uploadedAt)}${item.teacherName == null ? '' : ' - ${item.teacherName}'}',
                  ),
                  trailing: _canUpload
                      ? PopupMenuButton<String>(
                          onSelected: (value) {
                            if (value == 'edit') {
                              _editUpload(item);
                            } else if (value == 'delete') {
                              _deleteUpload(item);
                            }
                          },
                          itemBuilder: (context) => [
                            const PopupMenuItem(
                              value: 'edit',
                              child: Text('Edit'),
                            ),
                            const PopupMenuItem(
                              value: 'delete',
                              child: Text('Delete'),
                            ),
                          ],
                        )
                      : null,
                ),
              ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return FeatureScaffold(
      title: 'Exam grades',
      subtitle: _canUpload
          ? 'Upload and review exam grades'
          : 'Your exam results',
      actionLabel: _canUpload ? 'Upload exam grades' : null,
      onAction: _canUpload ? _openUploadDialog : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  TextField(
                    controller: _groupController,
                    decoration: const InputDecoration(
                      labelText: 'Group',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => FocusScope.of(context).nextFocus(),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _examController,
                    decoration: const InputDecoration(
                      labelText: 'Exam name',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => FocusScope.of(context).nextFocus(),
                  ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton.icon(
                      onPressed: _reload,
                      icon: const Icon(Icons.search),
                      label: const Text('Filter'),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          if (_canUpload)
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => setState(() => _showUploads = false),
                    style: OutlinedButton.styleFrom(
                      backgroundColor: _showUploads
                          ? null
                          : Theme.of(
                              context,
                            ).colorScheme.primary.withOpacity(0.12),
                    ),
                    child: const Text('Grades'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => setState(() => _showUploads = true),
                    style: OutlinedButton.styleFrom(
                      backgroundColor: _showUploads
                          ? Theme.of(
                              context,
                            ).colorScheme.primary.withOpacity(0.12)
                          : null,
                    ),
                    child: const Text('Uploads'),
                  ),
                ),
              ],
            ),
          if (_canUpload) const SizedBox(height: 16),
          _showUploads ? _buildUploadsList() : _buildGradesList(),
        ],
      ),
    );
  }
}

class AnalyticsPage extends StatefulWidget {
  const AnalyticsPage({super.key});

  @override
  State<AnalyticsPage> createState() => _AnalyticsPageState();
}

class _AnalyticsPageState extends State<AnalyticsPage> {
  String? _noticeMessage;
  bool _noticeError = false;
  final _groupController = TextEditingController();
  int _tabIndex = 0;
  Future<List<GroupAnalytics>>? _groupsFuture;
  Future<List<AttendanceRecord>>? _attendanceFuture;
  Future<List<GradeRecord>>? _gradesFuture;
  Future<List<TeacherGroupAssignment>>? _assignmentsFuture;
  List<UserProfile> _teachers = [];
  bool _initialized = false;

  bool get _canManage {
    final role = AppStateScope.of(context).user?.role ?? '';
    return role == 'admin';
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _reload();
    _initialized = true;
  }

  @override
  void dispose() {
    _groupController.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final client = AppStateScope.of(context).client;
    final group = _groupController.text.trim();
    setState(() {
      _groupsFuture = client.listAnalyticsGroups();
      _attendanceFuture = client.listAnalyticsAttendance(
        groupName: group.isEmpty ? null : group,
      );
      _gradesFuture = client.listAnalyticsGrades(
        groupName: group.isEmpty ? null : group,
      );
      _assignmentsFuture = client.listTeacherAssignments(
        groupName: group.isEmpty ? null : group,
      );
    });
    if (_canManage) {
      try {
        _teachers = await client.listUsers(role: 'teacher');
      } catch (_) {}
    }
  }

  Future<void> _addAssignment() async {
    if (!_canManage) return;
    if (_teachers.isEmpty) {
      await _reload();
    }
    int? selectedId = _teachers.isNotEmpty ? _teachers.first.id : null;
    final groupController = TextEditingController(
      text: _groupController.text.trim(),
    );
    final subjectController = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add assignment'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<int>(
              value: selectedId,
              items: [
                for (final teacher in _teachers)
                  DropdownMenuItem(
                    value: teacher.id,
                    child: Text(teacher.fullName),
                  ),
              ],
              onChanged: (value) => selectedId = value,
              decoration: const InputDecoration(
                labelText: 'Teacher',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: groupController,
              decoration: const InputDecoration(
                labelText: 'Group',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => FocusScope.of(context).nextFocus(),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: subjectController,
              decoration: const InputDecoration(
                labelText: 'Subject',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => FocusScope.of(context).nextFocus(),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    if (ok != true || selectedId == null) return;
    try {
      await AppStateScope.of(context).client.createTeacherAssignment(
        teacherId: selectedId!,
        groupName: groupController.text.trim(),
        subject: subjectController.text.trim(),
      );
      if (!mounted) return;
      _reload();
      setState(() {
        _noticeError = false;
        _noticeMessage = 'Назначение добавлено.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _noticeError = true;
        _noticeMessage = humanizeError(error);
      });
    }
  }

  Future<void> _editAssignment(TeacherGroupAssignment item) async {
    if (!_canManage) return;
    final groupController = TextEditingController(text: item.groupName);
    final subjectController = TextEditingController(text: item.subject);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit assignment'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: groupController,
              decoration: const InputDecoration(
                labelText: 'Group',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => FocusScope.of(context).nextFocus(),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: subjectController,
              decoration: const InputDecoration(
                labelText: 'Subject',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => FocusScope.of(context).nextFocus(),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await AppStateScope.of(context).client.updateTeacherAssignment(
        item.id,
        groupName: groupController.text.trim(),
        subject: subjectController.text.trim(),
      );
      if (!mounted) return;
      _reload();
      setState(() {
        _noticeError = false;
        _noticeMessage = 'Назначение добавлено.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _noticeError = true;
        _noticeMessage = humanizeError(error);
      });
    }
  }

  Future<void> _deleteAssignment(TeacherGroupAssignment item) async {
    if (!_canManage) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete assignment?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await AppStateScope.of(context).client.deleteTeacherAssignment(item.id);
      if (!mounted) return;
      _reload();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _noticeError = true;
        _noticeMessage = humanizeError(error);
      });
    }
  }

  Widget _buildTabs() {
    final tabs = [
      'Groups',
      'Attendance',
      'Grades',
      if (_canManage) 'Assignments',
    ];
    return Row(
      children: [
        for (int i = 0; i < tabs.length; i++)
          Expanded(
            child: OutlinedButton(
              onPressed: () => setState(() => _tabIndex = i),
              style: OutlinedButton.styleFrom(
                backgroundColor: _tabIndex == i
                    ? Theme.of(context).colorScheme.primary.withOpacity(0.12)
                    : null,
              ),
              child: Text(tabs[i]),
            ),
          ),
      ],
    );
  }

  Widget _buildGroups() {
    final future = _groupsFuture;
    if (future == null) return const SizedBox();
    return FutureBuilder<List<GroupAnalytics>>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: BrandLoadingIndicator());
        }
        if (snapshot.hasError) {
          return Text('Failed to load groups: ${snapshot.error}');
        }
        final items = snapshot.data ?? [];
        if (items.isEmpty) {
          return const Text('No groups');
        }
        return Column(
          children: [
            for (final item in items)
              Card(
                margin: const EdgeInsets.only(bottom: 12),
                child: ListTile(
                  title: Text(item.groupName),
                  subtitle: Text(
                    'Subjects: ${item.subjects.isEmpty ? "-" : item.subjects.join(", ")}\nTeachers: ${item.teachers.isEmpty ? "-" : item.teachers.join(", ")}',
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _buildAttendance() {
    final future = _attendanceFuture;
    if (future == null) return const SizedBox();
    return FutureBuilder<List<AttendanceRecord>>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: BrandLoadingIndicator());
        }
        if (snapshot.hasError) {
          return Text('Failed to load attendance: ${snapshot.error}');
        }
        final items = snapshot.data ?? [];
        if (items.isEmpty) {
          return const Text('No attendance records');
        }
        return Column(
          children: [
            for (final item in items)
              Card(
                margin: const EdgeInsets.only(bottom: 12),
                child: ListTile(
                  title: Text('${item.studentName} (${item.groupName})'),
                  subtitle: Text(
                    '${DateFormat('dd.MM.yyyy').format(item.classDate)}',
                  ),
                  trailing: Icon(
                    item.present ? Icons.check_circle : Icons.cancel,
                    color: item.present ? Colors.green : Colors.red,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _buildGrades() {
    final future = _gradesFuture;
    if (future == null) return const SizedBox();
    return FutureBuilder<List<GradeRecord>>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: BrandLoadingIndicator());
        }
        if (snapshot.hasError) {
          return Text('Failed to load grades: ${snapshot.error}');
        }
        final items = snapshot.data ?? [];
        if (items.isEmpty) {
          return const Text('No grade records');
        }
        return Column(
          children: [
            for (final item in items)
              Card(
                margin: const EdgeInsets.only(bottom: 12),
                child: ListTile(
                  title: Text('${item.studentName} (${item.groupName})'),
                  subtitle: Text(
                    DateFormat('dd.MM.yyyy').format(item.classDate),
                  ),
                  trailing: Text(
                    item.grade.toString(),
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _buildAssignments() {
    final future = _assignmentsFuture;
    if (future == null) return const SizedBox();
    return FutureBuilder<List<TeacherGroupAssignment>>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: BrandLoadingIndicator());
        }
        if (snapshot.hasError) {
          return Text('Failed to load assignments: ${snapshot.error}');
        }
        final items = snapshot.data ?? [];
        if (items.isEmpty) {
          return const Text('No assignments');
        }
        return Column(
          children: [
            for (final item in items)
              Card(
                margin: const EdgeInsets.only(bottom: 12),
                child: ListTile(
                  title: Text('${item.subject} ? ${item.groupName}'),
                  subtitle: Text(item.teacherName),
                  trailing: _canManage
                      ? PopupMenuButton<String>(
                          onSelected: (value) {
                            if (value == 'edit') {
                              _editAssignment(item);
                            } else if (value == 'delete') {
                              _deleteAssignment(item);
                            }
                          },
                          itemBuilder: (context) => [
                            const PopupMenuItem(
                              value: 'edit',
                              child: Text('Edit'),
                            ),
                            const PopupMenuItem(
                              value: 'delete',
                              child: Text('Delete'),
                            ),
                          ],
                        )
                      : null,
                ),
              ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return FeatureScaffold(
      title: 'Analytics',
      subtitle: _canManage ? 'All groups overview' : 'Your groups overview',
      actionLabel: _canManage && _tabIndex == 3 ? 'Add assignment' : null,
      onAction: _canManage && _tabIndex == 3 ? _addAssignment : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  TextField(
                    controller: _groupController,
                    decoration: const InputDecoration(
                      labelText: 'Group filter',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton.icon(
                      onPressed: _reload,
                      icon: const Icon(Icons.search),
                      label: const Text('Apply'),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          _buildTabs(),
          const SizedBox(height: 16),
          if (_tabIndex == 0) _buildGroups(),
          if (_tabIndex == 1) _buildAttendance(),
          if (_tabIndex == 2) _buildGrades(),
          if (_canManage && _tabIndex == 3) _buildAssignments(),
        ],
      ),
    );
  }
}

class RequestsPage extends StatefulWidget {
  const RequestsPage({super.key, required this.canProcess});

  final bool canProcess;

  @override
  State<RequestsPage> createState() => _RequestsPageState();
}

class _RequestsPageState extends State<RequestsPage> {
  String? _noticeMessage;
  bool _noticeError = false;

  final DateFormat _requestDateFormat = DateFormat('dd.MM.yyyy HH:mm');
  late Future<List<RequestTicket>> _requestsFuture;
  bool _initialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _requestsFuture = AppStateScope.of(context).client.listRequests();
    _initialized = true;
  }

  Future<void> _refresh() async {
    setState(() {
      _requestsFuture = AppStateScope.of(context).client.listRequests();
    });
  }

  Future<void> _createRequest() async {
    final created = await Navigator.of(context).push<RequestTicket>(
      MaterialPageRoute(builder: (_) => RequestComposePage()),
    );
    if (created == null) return;
    setState(() {
      _requestsFuture = AppStateScope.of(context).client.listRequests();
    });
  }

  @override
  Widget build(BuildContext context) {
    return FeatureScaffold(
      title: 'Requests',
      subtitle: widget.canProcess
          ? 'Review and process requests'
          : 'Submit a request',
      actionLabel: widget.canProcess ? null : 'New request',
      onAction: widget.canProcess ? null : _createRequest,
      child: FutureBuilder<List<RequestTicket>>(
        future: _requestsFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: BrandLoadingIndicator());
          }
          if (snapshot.hasError) {
            return Text('Failed to load requests: ${snapshot.error}');
          }
          final items = snapshot.data ?? [];
          if (items.isEmpty) {
            return const Text('No requests yet');
          }
          return Column(
            children: [
              for (final item in items)
                Card(
                  margin: const EdgeInsets.only(bottom: 12),
                  child: ListTile(
                    leading: const CircleAvatar(child: Icon(Icons.description)),
                    title: Text(item.requestType),
                    subtitle: Text(
                      '\u0421\u0442\u0430\u0442\u0443\u0441: ${item.status}\n${item.studentName} - ${_requestDateFormat.format(item.createdAt)}',
                    ),
                    trailing: widget.canProcess
                        ? IconButton(
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () async {
                              final ok = await showDialog<bool>(
                                context: context,
                                builder: (_) => AlertDialog(
                                  title: const Text('Delete request?'),
                                  content: const Text(
                                    'This will remove it for the student too.',
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () =>
                                          Navigator.pop(context, false),
                                      child: const Text('Cancel'),
                                    ),
                                    FilledButton(
                                      onPressed: () =>
                                          Navigator.pop(context, true),
                                      child: const Text('Delete'),
                                    ),
                                  ],
                                ),
                              );
                              if (ok != true) return;
                              try {
                                await AppStateScope.of(
                                  context,
                                ).client.deleteRequest(item.id);
                                if (!mounted) return;
                                setState(() {
                                  _requestsFuture = AppStateScope.of(
                                    context,
                                  ).client.listRequests();
                                });
                              } catch (error) {
                                if (!mounted) return;
                                setState(() {
                                  _noticeError = true;
                                  _noticeMessage = humanizeError(error);
                                });
                              }
                            },
                          )
                        : null,
                    onTap: () async {
                      final canProcess = widget.canProcess;
                      final updated = await Navigator.of(context)
                          .push<RequestTicket>(
                            MaterialPageRoute(
                              builder: (_) => RequestDetailPage(
                                ticket: item,
                                canProcess: canProcess,
                              ),
                            ),
                          );
                      setState(() {
                        _requestsFuture = AppStateScope.of(
                          context,
                        ).client.listRequests();
                      });
                    },
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class RequestComposePage extends StatefulWidget {
  const RequestComposePage({super.key});

  @override
  State<RequestComposePage> createState() => _RequestComposePageState();
}

class _RequestComposePageState extends State<RequestComposePage> {
  String? _noticeMessage;
  bool _noticeError = false;
  final _detailsController = TextEditingController();
  String? _selectedType;
  bool _sending = false;

  bool _profileComplete(UserProfile? user) {
    return user != null &&
        (user.fullName).trim().isNotEmpty &&
        (user.phone ?? '').trim().isNotEmpty &&
        (user.studentGroup ?? '').trim().isNotEmpty &&
        (user.birthDate != null);
  }

  Future<void> _submit() async {
    final state = AppStateScope.of(context);
    final user = state.user;
    if (!_profileComplete(user)) {
      setState(() {
        _noticeError = true;
        _noticeMessage =
            'Заполните профиль: ФИО, телефон, дату рождения и группу.';
      });
      return;
    }
    final type = _selectedType;
    if (type == null) {
      setState(() {
        _noticeError = true;
        _noticeMessage = 'Выберите тип справки.';
      });
      return;
    }
    setState(() => _sending = true);
    try {
      final ticket = await state.client.createRequest(
        requestType: type,
        details: _detailsController.text.trim().isEmpty
            ? null
            : _detailsController.text.trim(),
      );
      if (!mounted) return;
      Navigator.of(context).pop(ticket);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _noticeError = true;
        _noticeMessage = humanizeError(error);
      });
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  void dispose() {
    _detailsController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('New request')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          DropdownButtonFormField<String>(
            value: _selectedType,
            items: [
              for (final type in kRequestTypes)
                DropdownMenuItem(value: type, child: Text(type)),
            ],
            onChanged: (value) => setState(() => _selectedType = value),
            decoration: const InputDecoration(labelText: 'Request type'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _detailsController,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: 'Description (optional)',
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _sending ? null : _submit,
            child: _sending
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Send request'),
          ),
        ],
      ),
    );
  }
}

class RequestDetailPage extends StatefulWidget {
  const RequestDetailPage({
    super.key,
    required this.ticket,
    required this.canProcess,
  });

  final RequestTicket ticket;
  final bool canProcess;

  @override
  State<RequestDetailPage> createState() => _RequestDetailPageState();
}

class _RequestDetailPageState extends State<RequestDetailPage> {
  String? _noticeMessage;
  bool _noticeError = false;
  late RequestTicket _ticket;
  String? _status;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _ticket = widget.ticket;
    _status = kRequestStatuses.contains(_ticket.status)
        ? _ticket.status
        : kRequestStatuses.first;
  }

  Future<void> _save() async {
    if (!widget.canProcess) return;
    setState(() => _saving = true);
    try {
      final updated = await AppStateScope.of(
        context,
      ).client.updateRequest(_ticket.id, status: _status);
      if (!mounted) return;
      setState(() => _ticket = updated);
      setState(() {
        _noticeError = false;
        _noticeMessage = 'Заявка обновлена.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _noticeError = true;
        _noticeMessage = humanizeError(error);
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Request')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Card(
            child: ListTile(
              title: Text(_ticket.requestType),
              subtitle: Text(
                "${_ticket.studentName}\n"
                "${DateFormat("dd.MM.yyyy HH:mm").format(_ticket.createdAt)}\n"
                "Status: ${_ticket.status}",
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (widget.canProcess) ...[
            DropdownButtonFormField<String>(
              value: kRequestStatuses.contains(_status)
                  ? _status
                  : kRequestStatuses.first,
              items: [
                for (final status in kRequestStatuses)
                  DropdownMenuItem(value: status, child: Text(status)),
              ],
              onChanged: (value) => setState(() => _status = value),
              decoration: const InputDecoration(labelText: 'Status'),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Save'),
            ),
          ],
        ],
      ),
    );
  }
}

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  String? _noticeMessage;
  bool _noticeError = false;
  final _fullNameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _birthController = TextEditingController();
  final _groupController = TextEditingController();
  final _teacherController = TextEditingController();
  final _scrollController = ScrollController();
  bool _initialized = false;
  bool _prefsLoaded = false;
  bool _notifySchedule = true;
  bool _notifyRequests = true;

  @override
  void dispose() {
    _fullNameController.dispose();
    _phoneController.dispose();
    _birthController.dispose();
    _groupController.dispose();
    _teacherController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_prefsLoaded) {
      _loadPrefs();
    }
    if (_initialized) return;
    final user = AppStateScope.of(context).user;
    _fullNameController.text = user?.fullName ?? '';
    _phoneController.text = user?.phone ?? '';
    _birthController.text = user?.birthDate == null
        ? ''
        : DateFormat('yyyy-MM-dd').format(user!.birthDate!);
    _groupController.text = user?.studentGroup ?? '';
    _teacherController.text = user?.teacherName ?? '';
    _initialized = true;
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _notifySchedule = prefs.getBool('pref_notify_schedule') ?? true;
      _notifyRequests = prefs.getBool('pref_notify_requests') ?? true;
      _prefsLoaded = true;
    });
  }

  Future<void> _savePref(String key, bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, value);
  }

  void _scrollTo(double offset) {
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(
      offset,
      duration: const Duration(milliseconds: 450),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _saveProfile() async {
    final state = AppStateScope.of(context);
    final user = state.user;
    if (user == null) return;
    final payload = <String, dynamic>{};
    if (_fullNameController.text.trim().isNotEmpty) {
      payload['full_name'] = _fullNameController.text.trim();
    }
    if (_phoneController.text.trim().isNotEmpty) {
      payload['phone'] = _phoneController.text.trim();
    }
    if (_birthController.text.trim().isNotEmpty) {
      final birth = _birthController.text.trim();
      final birthOk = RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(birth);
      if (!birthOk) {
        setState(() {
          _noticeError = true;
          _noticeMessage = AppLocalizations.of(context).t('birth_date_invalid');
        });
        return;
      }
      payload['birth_date'] = birth;
    }
    if (_groupController.text.trim().isNotEmpty) {
      payload['student_group'] = _groupController.text.trim();
    }
    if (user.role == 'teacher' && _teacherController.text.trim().isNotEmpty) {
      payload['teacher_name'] = _teacherController.text.trim();
    }
    if (payload.isEmpty) return;
    try {
      await state.updateProfile(payload);
      if (!mounted) return;
      setState(() {
        _noticeError = false;
        _noticeMessage = AppLocalizations.of(context).t('profile_saved');
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _noticeError = true;
        _noticeMessage = humanizeError(error);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final user = AppStateScope.of(context).user;
    final roleLabel = user?.role ?? l10n.t('role_label');
    final displayName = (user?.fullName.isNotEmpty ?? false)
        ? user!.fullName
        : l10n.t('full_name');
    final subtitle = user?.role == 'teacher'
        ? ((user?.teacherName?.isNotEmpty ?? false)
              ? user!.teacherName!
              : l10n.t('teacher_not_set'))
        : ((user?.studentGroup?.isNotEmpty ?? false)
              ? user!.studentGroup!
              : l10n.t('group_not_set'));
    final phoneValue = (user?.phone?.isNotEmpty ?? false)
        ? user!.phone!
        : l10n.t('group_not_set');
    final initials = (user?.fullName.isNotEmpty ?? false)
        ? user!.fullName
              .split(' ')
              .map((e) => e.isNotEmpty ? e[0] : '')
              .take(2)
              .join()
              .toUpperCase()
        : 'PA';

    return ListView(
      controller: _scrollController,
      padding: EdgeInsets.zero,
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(20, 28, 20, 28),
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [kBrandPrimary, kInfo],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.vertical(bottom: Radius.circular(32)),
          ),
          child: Column(
            children: [
              CircleAvatar(
                radius: 40,
                backgroundColor: Colors.white.withOpacity(0.2),
                child: Text(
                  initials,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                displayName,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                subtitle,
                style: TextStyle(color: Colors.white.withOpacity(0.85)),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                alignment: WrapAlignment.center,
                children: [
                  _ProfileActionButton(
                    label: l10n.t('profile_edit'),
                    icon: Icons.edit,
                    onPressed: () => _scrollTo(320),
                  ),
                  _ProfileActionButton(
                    label: l10n.t('save_profile'),
                    icon: Icons.check_circle_outline,
                    isPrimary: true,
                    onPressed: _saveProfile,
                  ),
                ],
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Column(
            children: [
              if (_noticeMessage != null)
                InlineNotice(message: _noticeMessage!, isError: _noticeError),
              if (_noticeMessage != null) const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: kCardSurface,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.06),
                      blurRadius: 16,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: _ProfileStat(
                        label: l10n.t('profile_stats_group'),
                        value: subtitle,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _ProfileStat(
                        label: l10n.t('profile_stats_role'),
                        value: roleLabel,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _ProfileStat(
                        label: l10n.t('profile_stats_phone'),
                        value: phoneValue,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              _ProfileSectionCard(
                title: l10n.t('account_info'),
                child: Column(
                  children: [
                    TextField(
                      controller: _fullNameController,
                      decoration: InputDecoration(
                        labelText: l10n.t('full_name'),
                      ),
                      onSubmitted: (_) => FocusScope.of(context).nextFocus(),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _phoneController,
                      decoration: InputDecoration(
                        labelText: l10n.t('phone_label'),
                      ),
                      keyboardType: TextInputType.phone,
                      onSubmitted: (_) => FocusScope.of(context).nextFocus(),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _birthController,
                      decoration: InputDecoration(
                        labelText: l10n.t('birth_date_label'),
                      ),
                      onSubmitted: (_) => FocusScope.of(context).nextFocus(),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _groupController,
                      decoration: InputDecoration(
                        labelText: l10n.t('group_label'),
                      ),
                      onSubmitted: (_) => FocusScope.of(context).nextFocus(),
                    ),
                    if (user?.role == 'teacher') ...[
                      const SizedBox(height: 12),
                      TextField(
                        controller: _teacherController,
                        decoration: InputDecoration(
                          labelText: l10n.t('teacher_name_label'),
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: _saveProfile,
                        child: Text(l10n.t('save_profile')),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              _ProfileSectionCard(
                title: l10n.t('preferences'),
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.language),
                      title: Text(l10n.t('language')),
                      trailing: DropdownButton<String>(
                        value: AppStateScope.of(context).locale.languageCode,
                        items: [
                          DropdownMenuItem(
                            value: 'ru',
                            child: Text(l10n.t('language_ru')),
                          ),
                          DropdownMenuItem(
                            value: 'en',
                            child: Text(l10n.t('language_en')),
                          ),
                        ],
                        onChanged: (value) async {
                          if (value != null) {
                            await AppStateScope.of(context).setLocale(value);
                          }
                        },
                      ),
                    ),
                    const Divider(height: 1),
                    SwitchListTile(
                      value: _notifySchedule,
                      onChanged: (value) {
                        setState(() => _notifySchedule = value);
                        _savePref('pref_notify_schedule', value);
                      },
                      title: Text(l10n.t('schedule_updates')),
                    ),
                    const Divider(height: 1),
                    SwitchListTile(
                      value: _notifyRequests,
                      onChanged: (value) {
                        setState(() => _notifyRequests = value);
                        _savePref('pref_notify_requests', value);
                      },
                      title: Text(l10n.t('request_updates')),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              _ProfileSectionCard(
                title: l10n.t('security'),
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.lock_reset),
                      title: Text(l10n.t('reset_password_action')),
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const ResetPasswordPage(),
                          ),
                        );
                      },
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.logout),
                      title: Text(l10n.t('logout')),
                      onTap: () => AppStateScope.of(context).logout(),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ],
    );
  }
}

class _ProfileActionButton extends StatelessWidget {
  const _ProfileActionButton({
    required this.label,
    required this.icon,
    required this.onPressed,
    this.isPrimary = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;
  final bool isPrimary;

  @override
  Widget build(BuildContext context) {
    return isPrimary
        ? FilledButton.icon(
            onPressed: onPressed,
            icon: Icon(icon),
            label: Text(label),
          )
        : OutlinedButton.icon(
            onPressed: onPressed,
            icon: Icon(icon),
            label: Text(label),
          );
  }
}

class _ProfileStat extends StatelessWidget {
  const _ProfileStat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
        ),
        const SizedBox(height: 4),
        Text(label, style: TextStyle(color: kSecondaryText, fontSize: 12)),
      ],
    );
  }
}

class _ProfileSectionCard extends StatelessWidget {
  const _ProfileSectionCard({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: kCardSurface,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 14,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

class NotificationsPage extends StatefulWidget {
  const NotificationsPage({super.key});

  @override
  State<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends State<NotificationsPage> {
  late Future<List<AppNotification>> _future;
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _future = _load();
    _initialized = true;
  }

  Future<List<AppNotification>> _load() async {
    return AppStateScope.of(context).client.listNotifications();
  }

  Future<void> _refresh() async {
    setState(() => _future = _load());
    await _future;
  }

  Future<void> _markRead(AppNotification notification) async {
    if (notification.isRead) return;
    try {
      await AppStateScope.of(
        context,
      ).client.markNotificationRead(notification.id);
      if (!mounted) return;
      await _refresh();
    } catch (_) {}
  }

  String _notificationBody(AppNotification item) {
    final body = item.body.trim();
    if (body.isNotEmpty &&
        !body.startsWith('ApiException') &&
        !body.startsWith('{')) {
      return body;
    }
    final data = item.data ?? {};
    final type = (data['type'] ?? '').toString();
    if (type == 'exam_grades') {
      final group = (data['group'] ?? '').toString().trim();
      final exam = (data['exam'] ?? '').toString().trim();
      if (appLocaleCode == 'ru') {
        if (group.isNotEmpty && exam.isNotEmpty) {
          return 'Появились оценки по экзамену "$exam" для группы $group.';
        }
        return 'Появились новые экзаменационные оценки.';
      }
      if (group.isNotEmpty && exam.isNotEmpty) {
        return 'New grades for "$exam" in group $group.';
      }
      return 'New exam grades are available.';
    }
    final fromBody = humanizeError(item.body);
    if (fromBody != item.body && fromBody.trim().isNotEmpty) {
      return fromBody;
    }
    return appLocaleCode == 'ru'
        ? 'Откройте уведомление для подробностей.'
        : 'Open this notification for details.';
  }

  String _notificationTitle(AppNotification item) {
    final title = item.title.trim();
    if (title.isNotEmpty &&
        !title.startsWith('{') &&
        !title.startsWith('ApiException')) {
      return title;
    }
    final type = (item.data?['type'] ?? '').toString();
    if (type == 'exam_grades') {
      return appLocaleCode == 'ru' ? 'Обновление оценок' : 'Grades update';
    }
    return appLocaleCode == 'ru' ? 'Уведомление' : 'Notification';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final dateFormat = DateFormat('dd.MM.yyyy HH:mm');
    return Scaffold(
      appBar: AppBar(title: Text(l10n.t('notifications_title'))),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: FutureBuilder<List<AppNotification>>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: BrandLoadingIndicator());
            }
            if (snapshot.hasError) {
              final message = humanizeError(snapshot.error ?? '');
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: InlineNotice(message: message, isError: true),
                ),
              );
            }
            final items = snapshot.data ?? [];
            if (items.isEmpty) {
              return Center(child: Text(l10n.t('notifications_empty')));
            }
            return ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: items.length,
              separatorBuilder: (_, __) => const SizedBox(height: 12),
              itemBuilder: (context, index) {
                final item = items[index];
                return GestureDetector(
                  onTap: () => _markRead(item),
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: item.isRead ? kCardSurface : kSecondaryBackground,
                      borderRadius: BorderRadius.circular(16),
                      border: item.isRead
                          ? null
                          : Border.all(color: kBrandPrimary.withOpacity(0.3)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                _notificationTitle(item),
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            if (!item.isRead)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: kBrandPrimary.withOpacity(0.12),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(
                                  l10n.t('notifications_unread'),
                                  style: TextStyle(
                                    color: kBrandPrimary,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(_notificationBody(item)),
                        const SizedBox(height: 8),
                        Text(
                          dateFormat.format(item.createdAt),
                          style: TextStyle(color: kSecondaryText, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class FeatureScaffold extends StatelessWidget {
  const FeatureScaffold({
    super.key,
    required this.title,
    required this.subtitle,
    required this.child,
    this.actionLabel,
    this.onAction,
    this.bodyScrollable = true,
  });

  final String title;
  final String subtitle;
  final String? actionLabel;
  final VoidCallback? onAction;
  final Widget child;
  final bool bodyScrollable;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth >= 1200
            ? 1140.0
            : constraints.maxWidth >= 900
            ? 980.0
            : double.infinity;
        final horizontal = constraints.maxWidth >= 900 ? 24.0 : 16.0;
        return Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFFF4F7F2), Color(0xFFEAF0E4)],
            ),
          ),
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxWidth),
              child: bodyScrollable
                  ? ListView(
                      padding: EdgeInsets.fromLTRB(
                        horizontal,
                        20,
                        horizontal,
                        24,
                      ),
                      children: [
                        SectionHeader(
                          title: title,
                          trailing: actionLabel == null
                              ? null
                              : FilledButton(
                                  onPressed: onAction,
                                  child: Text(actionLabel!),
                                ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          subtitle,
                          style: TextStyle(color: Colors.grey.shade700),
                        ),
                        const SizedBox(height: 20),
                        child,
                      ],
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: EdgeInsets.fromLTRB(
                            horizontal,
                            20,
                            horizontal,
                            0,
                          ),
                          child: SectionHeader(
                            title: title,
                            trailing: actionLabel == null
                                ? null
                                : FilledButton(
                                    onPressed: onAction,
                                    child: Text(actionLabel!),
                                  ),
                          ),
                        ),
                        Padding(
                          padding: EdgeInsets.fromLTRB(
                            horizontal,
                            6,
                            horizontal,
                            0,
                          ),
                          child: Text(
                            subtitle,
                            style: TextStyle(color: Colors.grey.shade700),
                          ),
                        ),
                        const SizedBox(height: 20),
                        Expanded(
                          child: Padding(
                            padding: EdgeInsets.fromLTRB(
                              horizontal,
                              0,
                              horizontal,
                              24,
                            ),
                            child: child,
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        );
      },
    );
  }
}

class HomePage extends StatelessWidget {
  const HomePage({super.key, required this.role});

  final RoleDefinition role;

  void _openFeature(BuildContext context, FeatureDefinition action) {
    final isRu = AppStateScope.of(context).locale.languageCode == 'ru';
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (routeContext) => _FeatureStandalonePage(
          title: _featureTitle(action.id, action.title, isRu),
          child: action.builder(routeContext),
          accent: role.color,
        ),
      ),
    );
  }

  FeatureDefinition? _findFeature(String id) {
    for (final feature in role.features) {
      if (feature.id == id) return feature;
    }
    return null;
  }

  String _actionHint(String id, bool isRu) {
    if (!isRu) {
      switch (id) {
        case 'schedule':
          return 'Classes and rooms';
        case 'attendance':
          return 'Attendance journal';
        case 'grades':
          return 'Grades journal';
        case 'analytics':
          return 'Performance insights';
        case 'news':
          return 'News feed';
        case 'requests':
          return 'Request queue';
        case 'exams':
          return 'Exam results';
        case 'profile':
          return 'Personal settings';
      }
      return 'Open section';
    }
    switch (id) {
      case 'schedule':
        return 'Пары и аудитории';
      case 'attendance':
        return 'Журнал посещений';
      case 'grades':
        return 'Журнал оценок';
      case 'analytics':
        return 'Аналитика успеваемости';
      case 'news':
        return 'Лента новостей';
      case 'requests':
        return 'Очередь заявок';
      case 'exams':
        return 'Экзаменационные оценки';
      case 'profile':
        return 'Настройки профиля';
    }
    return 'Открыть раздел';
  }

  String _featureTitle(String id, String fallback, bool isRu) {
    if (!isRu) return fallback;
    switch (id) {
      case 'schedule':
        return 'Расписание';
      case 'attendance':
        return 'Посещаемость';
      case 'grades':
        return 'Оценки';
      case 'analytics':
        return 'Аналитика';
      case 'news':
        return 'Новости';
      case 'requests':
        return 'Заявки';
      case 'exams':
        return 'Экзамены';
      case 'profile':
        return 'Профиль';
    }
    return fallback;
  }

  String _roleName(bool isRu) {
    if (!isRu) return role.title;
    switch (role.id) {
      case 'admin':
        return 'Администратор';
      case 'teacher':
        return 'Преподаватель';
      case 'student':
        return 'Студент';
      case 'parent':
        return 'Родитель';
      case 'smm':
        return 'SMM';
      case 'request_handler':
        return 'Обработчик заявок';
    }
    return role.title;
  }

  IconData _roleIcon(String roleId) {
    switch (roleId) {
      case 'admin':
        return Icons.shield_outlined;
      case 'teacher':
        return Icons.co_present_outlined;
      case 'student':
        return Icons.school_outlined;
      case 'parent':
        return Icons.family_restroom_outlined;
      case 'smm':
        return Icons.campaign_outlined;
      case 'request_handler':
        return Icons.assignment_turned_in_outlined;
      default:
        return Icons.dashboard_outlined;
    }
  }

  String _homeTitle(bool isRu) => isRu ? 'Главная' : 'Home';

  String _homeSubtitle(bool isRu, String roleId) {
    if (!isRu) {
      switch (roleId) {
        case 'admin':
          return 'System health, operations and full platform control.';
        case 'teacher':
          return 'Lessons, journals and student performance in one place.';
        case 'student':
          return 'Your schedule, grades and requests for today.';
        case 'parent':
          return 'Track attendance and progress with minimal noise.';
        case 'smm':
          return 'Create content and manage feed communication.';
        case 'request_handler':
          return 'Queue handling and student request processing.';
      }
      return 'Your daily workspace.';
    }
    switch (roleId) {
      case 'admin':
        return 'Контроль системы, процессов и ключевых разделов.';
      case 'teacher':
        return 'Занятия, журналы и успеваемость в одном месте.';
      case 'student':
        return 'Ваше расписание, оценки и заявки на сегодня.';
      case 'parent':
        return 'Отслеживание посещаемости и прогресса без лишнего.';
      case 'smm':
        return 'Публикации и управление коммуникацией в ленте.';
      case 'request_handler':
        return 'Обработка очереди и заявок студентов.';
    }
    return 'Ваше рабочее пространство на день.';
  }

  List<_HomeFocus> _focusByRole(bool isRu) {
    switch (role.id) {
      case 'admin':
        return [
          _HomeFocus(
            icon: Icons.account_tree_outlined,
            title: isRu ? 'Структура групп' : 'Group structure',
            description: isRu
                ? 'Проверьте распределение преподавателей по группам.'
                : 'Review teacher-to-group assignments.',
          ),
          _HomeFocus(
            icon: Icons.receipt_long_outlined,
            title: isRu ? 'Заявки' : 'Requests',
            description: isRu
                ? 'Убедитесь, что нет “зависших” обращений.'
                : 'Check that no student requests are stalled.',
          ),
          _HomeFocus(
            icon: Icons.analytics_outlined,
            title: isRu ? 'Аналитика' : 'Analytics',
            description: isRu
                ? 'Сверьте посещаемость и динамику оценок.'
                : 'Review attendance and grade trends.',
          ),
        ];
      case 'teacher':
        return [
          _HomeFocus(
            icon: Icons.event_note_outlined,
            title: isRu ? 'Расписание' : 'Schedule',
            description: isRu
                ? 'Сверьте занятия и аудитории перед парой.'
                : 'Check today classes and room details.',
          ),
          _HomeFocus(
            icon: Icons.fact_check_outlined,
            title: isRu ? 'Посещаемость' : 'Attendance',
            description: isRu
                ? 'Отметьте присутствующих в журнале.'
                : 'Mark students in attendance journal.',
          ),
          _HomeFocus(
            icon: Icons.assignment_turned_in_outlined,
            title: isRu ? 'Экзамены' : 'Exams',
            description: isRu
                ? 'Загрузите свежие результаты группы.'
                : 'Upload latest exam results for groups.',
          ),
        ];
      case 'student':
        return [
          _HomeFocus(
            icon: Icons.schedule_outlined,
            title: isRu ? 'Сегодняшние пары' : 'Today classes',
            description: isRu
                ? 'Откройте расписание и проверьте время.'
                : 'Open your schedule and verify timing.',
          ),
          _HomeFocus(
            icon: Icons.grade_outlined,
            title: isRu ? 'Оценки' : 'Grades',
            description: isRu
                ? 'Проверьте обновления по предметам.'
                : 'Review latest performance updates.',
          ),
          _HomeFocus(
            icon: Icons.mail_outline,
            title: isRu ? 'Заявки' : 'Requests',
            description: isRu
                ? 'Следите за статусом поданных справок.'
                : 'Track statuses of your submitted requests.',
          ),
        ];
      case 'parent':
        return [
          _HomeFocus(
            icon: Icons.fact_check_outlined,
            title: isRu ? 'Посещаемость' : 'Attendance',
            description: isRu
                ? 'Проверьте посещаемость ребёнка за неделю.'
                : 'Review this week attendance summary.',
          ),
          _HomeFocus(
            icon: Icons.workspace_premium_outlined,
            title: isRu ? 'Успеваемость' : 'Performance',
            description: isRu
                ? 'Сверьте оценки и динамику успеваемости.'
                : 'Check grades and performance dynamics.',
          ),
          _HomeFocus(
            icon: Icons.assignment_turned_in_outlined,
            title: isRu ? 'Экзамены' : 'Exams',
            description: isRu
                ? 'Проверьте доступные результаты экзаменов.'
                : 'Check available exam results.',
          ),
        ];
      case 'smm':
        return [
          _HomeFocus(
            icon: Icons.dynamic_feed_outlined,
            title: isRu ? 'Лента' : 'Feed',
            description: isRu
                ? 'Подготовьте важные публикации на сегодня.'
                : 'Prepare today priority posts.',
          ),
          _HomeFocus(
            icon: Icons.push_pin_outlined,
            title: isRu ? 'Закрепления' : 'Pinned posts',
            description: isRu
                ? 'Актуализируйте закреплённые объявления.'
                : 'Update pinned announcements.',
          ),
          _HomeFocus(
            icon: Icons.forum_outlined,
            title: isRu ? 'Обратная связь' : 'Feedback',
            description: isRu
                ? 'Проверьте реакции и комментарии.'
                : 'Check reactions and comments.',
          ),
        ];
      case 'request_handler':
        return [
          _HomeFocus(
            icon: Icons.inbox_outlined,
            title: isRu ? 'Новые обращения' : 'New requests',
            description: isRu
                ? 'Начните с заявок со статусом “Отправлена”.'
                : 'Start with requests in "Submitted" status.',
          ),
          _HomeFocus(
            icon: Icons.rule_outlined,
            title: isRu ? 'Проверка данных' : 'Validation',
            description: isRu
                ? 'Проверьте корректность деталей заявок.'
                : 'Validate details and attached info.',
          ),
          _HomeFocus(
            icon: Icons.done_all_outlined,
            title: isRu ? 'Завершение' : 'Completion',
            description: isRu
                ? 'Обновляйте статусы после обработки.'
                : 'Update status immediately after processing.',
          ),
        ];
      default:
        return [
          _HomeFocus(
            icon: Icons.dashboard_outlined,
            title: isRu ? 'Рабочий день' : 'Workday',
            description: isRu
                ? 'Откройте ключевые разделы и начните работу.'
                : 'Open key sections and start your day.',
          ),
        ];
    }
  }

  List<String> _tipsByRole(bool isRu) {
    switch (role.id) {
      case 'admin':
        return isRu
            ? [
                'Периодически проверяйте список ролей и доступов.',
                'Синхронизируйте назначения преподавателей по группам.',
                'Держите новости и служебные объявления актуальными.',
              ]
            : [
                'Review role and access matrix regularly.',
                'Keep teacher-group assignments synchronized.',
                'Maintain up-to-date news and service announcements.',
              ];
      case 'teacher':
        return isRu
            ? [
                'Отмечайте посещаемость сразу после занятия.',
                'Вносите оценки в тот же день для точной аналитики.',
                'Проверяйте закреплённые новости для группы.',
              ]
            : [
                'Mark attendance right after each lesson.',
                'Enter grades the same day for accurate analytics.',
                'Check pinned feed posts relevant for your groups.',
              ];
      case 'student':
        return isRu
            ? [
                'Проверяйте расписание утром и перед второй сменой.',
                'Следите за статусами заявок, чтобы не пропустить готовые документы.',
                'Подписывайтесь на обновления новостей колледжа.',
              ]
            : [
                'Check schedule in the morning and before second shift.',
                'Track request statuses to collect documents on time.',
                'Keep up with college news updates.',
              ];
      case 'parent':
        return isRu
            ? [
                'Раз в неделю просматривайте сводку посещаемости.',
                'Отслеживайте экзаменационные оценки и изменения.',
                'Проверяйте профиль и контактные данные.',
              ]
            : [
                'Review attendance summary once a week.',
                'Track exam grades and changes.',
                'Keep profile and contact data up to date.',
              ];
      case 'smm':
        return isRu
            ? [
                'Публикуйте ключевые новости в начале дня.',
                'Используйте закрепления для срочных объявлений.',
                'Отвечайте на вопросы в комментариях оперативно.',
              ]
            : [
                'Publish key updates early in the day.',
                'Use pinned posts for urgent announcements.',
                'Respond to feed comments quickly.',
              ];
      case 'request_handler':
        return isRu
            ? [
                'Фильтруйте очередь по статусам и приоритету.',
                'Обновляйте заявки на каждом этапе обработки.',
                'Держите шаблоны ответов под рукой.',
              ]
            : [
                'Sort queue by status and priority.',
                'Update requests at each processing stage.',
                'Keep response templates ready.',
              ];
      default:
        return isRu
            ? ['Планируйте рабочий день с главного экрана.']
            : ['Plan your day from the home dashboard.'];
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = AppStateScope.of(context).user;
    final client = AppStateScope.of(context).client;
    final isRu = AppStateScope.of(context).locale.languageCode == 'ru';
    final quickActions = role.features.take(6).toList();
    final newsFeature = _findFeature('news');
    final attendanceFeature = _findFeature('attendance');
    final focusItems = _focusByRole(isRu);
    final tips = _tipsByRole(isRu);
    final width = MediaQuery.of(context).size.width;
    final today = DateFormat(
      isRu ? 'd MMMM, EEEE' : 'EEEE, MMMM d',
      isRu ? 'ru' : 'en',
    ).format(DateTime.now());
    final crossAxisCount = width < 620
        ? 2
        : width < 1000
        ? 3
        : 4;
    final ratio = width < 620 ? 1.05 : 1.42;
    return FeatureScaffold(
      title: _homeTitle(isRu),
      subtitle: _homeSubtitle(isRu, role.id),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  role.color.withOpacity(0.25),
                  Color.lerp(role.color, Colors.white, 0.8) ?? Colors.white,
                ],
              ),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: role.color.withOpacity(0.25)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    CircleAvatar(
                      radius: 28,
                      backgroundColor: role.color.withOpacity(0.18),
                      child: Icon(_roleIcon(role.id), color: role.color),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            isRu
                                ? 'Здравствуйте, ${user?.fullName ?? _roleName(isRu)}'
                                : 'Hello, ${user?.fullName ?? _roleName(isRu)}',
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w800),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            isRu
                                ? 'Роль: ${_roleName(isRu)}. Рабочие разделы ниже.'
                                : 'Role: ${_roleName(isRu)}. Key sections are below.',
                            style: TextStyle(color: kSecondaryText),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    _HomeMetricChip(
                      icon: Icons.calendar_today_outlined,
                      accent: role.color,
                      label: today,
                    ),
                    _HomeMetricChip(
                      icon: Icons.dashboard_outlined,
                      accent: role.color,
                      label: isRu
                          ? 'Разделов: ${role.features.length}'
                          : 'Sections: ${role.features.length}',
                    ),
                    if (newsFeature != null)
                      _HomeMetricChip(
                        icon: Icons.dynamic_feed_outlined,
                        accent: role.color,
                        label: isRu ? 'Лента доступна' : 'Feed available',
                      ),
                    if (attendanceFeature != null)
                      _HomeMetricChip(
                        icon: Icons.fact_check_outlined,
                        accent: role.color,
                        label: isRu ? 'Журнал посещений' : 'Attendance journal',
                      ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 22),
          SectionHeader(title: isRu ? 'Быстрые действия' : 'Quick actions'),
          const SizedBox(height: 12),
          GridView.count(
            crossAxisCount: crossAxisCount,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            childAspectRatio: ratio,
            children: [
              for (final action in quickActions)
                InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: () => _openFeature(context, action),
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          kSecondaryBackground,
                          Colors.white.withOpacity(0.9),
                        ],
                      ),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: role.color.withOpacity(0.12)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            CircleAvatar(
                              backgroundColor: role.color.withOpacity(0.15),
                              foregroundColor: role.color,
                              child: Icon(action.icon),
                            ),
                            const Spacer(),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: role.color.withOpacity(0.09),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                isRu ? 'Перейти' : 'Open',
                                style: TextStyle(
                                  color: role.color,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 11,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        Text(
                          _featureTitle(action.id, action.title, isRu),
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _actionHint(action.id, isRu),
                          style: TextStyle(color: kSecondaryText),
                        ),
                        const Spacer(),
                        Align(
                          alignment: Alignment.bottomRight,
                          child: Icon(
                            Icons.arrow_forward_rounded,
                            color: role.color.withOpacity(0.7),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
          if (newsFeature != null || attendanceFeature != null) ...[
            const SizedBox(height: 24),
            SectionHeader(
              title: isRu
                  ? 'Лента новостей и журнал посещений'
                  : 'News feed and attendance journal',
            ),
            const SizedBox(height: 12),
            if (width < 980)
              Column(
                children: [
                  if (newsFeature != null)
                    _HomeNewsPreview(
                      client: client,
                      accent: role.color,
                      isRu: isRu,
                      onOpen: () => _openFeature(context, newsFeature),
                    ),
                  if (newsFeature != null && attendanceFeature != null)
                    const SizedBox(height: 12),
                  if (attendanceFeature != null)
                    _HomeAttendancePreview(
                      client: client,
                      accent: role.color,
                      isRu: isRu,
                      onOpen: () => _openFeature(context, attendanceFeature),
                    ),
                ],
              )
            else
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (newsFeature != null)
                    Expanded(
                      child: _HomeNewsPreview(
                        client: client,
                        accent: role.color,
                        isRu: isRu,
                        onOpen: () => _openFeature(context, newsFeature),
                      ),
                    ),
                  if (newsFeature != null && attendanceFeature != null)
                    const SizedBox(width: 12),
                  if (attendanceFeature != null)
                    Expanded(
                      child: _HomeAttendancePreview(
                        client: client,
                        accent: role.color,
                        isRu: isRu,
                        onOpen: () => _openFeature(context, attendanceFeature),
                      ),
                    ),
                ],
              ),
          ],
          const SizedBox(height: 24),
          SectionHeader(title: isRu ? 'Фокус на сегодня' : 'Today focus'),
          const SizedBox(height: 12),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: focusItems.length,
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: width < 760 ? 1 : 3,
              childAspectRatio: width < 760 ? 3.2 : 1.65,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
            ),
            itemBuilder: (context, index) {
              final item = focusItems[index];
              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(item.icon, color: role.color),
                      const SizedBox(height: 10),
                      Text(
                        item.title,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        item.description,
                        style: TextStyle(color: kSecondaryText),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 24),
          SectionHeader(title: isRu ? 'Рекомендации' : 'Recommendations'),
          const SizedBox(height: 12),
          Card(
            child: Column(
              children: [
                for (int i = 0; i < tips.length; i++) ...[
                  ListTile(
                    leading: Icon(
                      Icons.check_circle_outline,
                      color: role.color,
                    ),
                    title: Text(tips[i]),
                  ),
                  if (i != tips.length - 1) const Divider(height: 1),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HomeMetricChip extends StatelessWidget {
  const _HomeMetricChip({
    required this.icon,
    required this.accent,
    required this.label,
  });

  final IconData icon;
  final Color accent;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.75),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: accent.withOpacity(0.2)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: accent),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _HomeFocus {
  const _HomeFocus({
    required this.icon,
    required this.title,
    required this.description,
  });

  final IconData icon;
  final String title;
  final String description;
}

class _FeatureStandalonePage extends StatelessWidget {
  const _FeatureStandalonePage({
    required this.title,
    required this.child,
    required this.accent,
  });

  final String title;
  final Widget child;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        backgroundColor: accent.withOpacity(0.14),
      ),
      body: SafeArea(child: child),
    );
  }
}

class _HomeNewsPreview extends StatefulWidget {
  const _HomeNewsPreview({
    required this.client,
    required this.accent,
    required this.isRu,
    required this.onOpen,
  });

  final ApiClient client;
  final Color accent;
  final bool isRu;
  final VoidCallback onOpen;

  @override
  State<_HomeNewsPreview> createState() => _HomeNewsPreviewState();
}

class _HomeNewsPreviewState extends State<_HomeNewsPreview> {
  bool _initialized = false;
  bool _loading = false;
  List<NewsPost> _items = [];
  String? _error;
  final DateFormat _format = DateFormat('dd.MM HH:mm');

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items = await widget.client.listNews(
        limit: 3,
        offset: 0,
        category: 'news',
      );
      if (!mounted) return;
      setState(() => _items = items);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = humanizeError(error));
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.dynamic_feed_outlined, color: widget.accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.isRu ? 'Лента новостей' : 'News feed',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: widget.onOpen,
                  child: Text(widget.isRu ? 'Открыть' : 'Open'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 18),
                child: Center(
                  child: BrandLoadingIndicator(logoSize: 48, spacing: 8),
                ),
              )
            else if (_error != null)
              InlineNotice(message: _error!, isError: true)
            else if (_items.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Text(
                  widget.isRu ? 'Пока нет публикаций.' : 'No posts yet.',
                  style: TextStyle(color: kSecondaryText),
                ),
              )
            else
              Column(
                children: [
                  for (int i = 0; i < _items.length; i++) ...[
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: CircleAvatar(
                        backgroundColor: widget.accent.withOpacity(0.12),
                        child: Icon(
                          Icons.article_outlined,
                          color: widget.accent,
                        ),
                      ),
                      title: Text(
                        _items[i].title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '${_items[i].authorName} • ${_format.format(_items[i].createdAt)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: widget.onOpen,
                    ),
                    if (i != _items.length - 1) const Divider(height: 1),
                  ],
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _HomeAttendancePreview extends StatefulWidget {
  const _HomeAttendancePreview({
    required this.client,
    required this.accent,
    required this.isRu,
    required this.onOpen,
  });

  final ApiClient client;
  final Color accent;
  final bool isRu;
  final VoidCallback onOpen;

  @override
  State<_HomeAttendancePreview> createState() => _HomeAttendancePreviewState();
}

class _HomeAttendancePreviewState extends State<_HomeAttendancePreview> {
  bool _initialized = false;
  bool _loading = false;
  List<AttendanceSummary> _items = [];
  String? _error;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items = await widget.client.attendanceSummary();
      if (!mounted) return;
      setState(() => _items = items);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = humanizeError(error));
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.fact_check_outlined, color: widget.accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.isRu ? 'Журнал посещений' : 'Attendance journal',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: widget.onOpen,
                  child: Text(widget.isRu ? 'Открыть' : 'Open'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 18),
                child: Center(
                  child: BrandLoadingIndicator(logoSize: 48, spacing: 8),
                ),
              )
            else if (_error != null)
              InlineNotice(message: _error!, isError: true)
            else if (_items.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Text(
                  widget.isRu
                      ? 'Нет данных по посещаемости.'
                      : 'No attendance data.',
                  style: TextStyle(color: kSecondaryText),
                ),
              )
            else
              Column(
                children: [
                  for (int i = 0; i < _items.length && i < 3; i++) ...[
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: CircleAvatar(
                        backgroundColor: widget.accent.withOpacity(0.12),
                        child: Icon(Icons.group_outlined, color: widget.accent),
                      ),
                      title: Text(_items[i].groupName),
                      subtitle: Text(
                        widget.isRu
                            ? 'Присутствие: ${_items[i].presentCount}/${_items[i].totalCount}'
                            : 'Presence: ${_items[i].presentCount}/${_items[i].totalCount}',
                      ),
                      onTap: widget.onOpen,
                    ),
                    if (i != _items.length - 1 && i < 2)
                      const Divider(height: 1),
                  ],
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class AccessDeniedPage extends StatelessWidget {
  const AccessDeniedPage({super.key, required this.pageName});

  final String pageName;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Card(
        margin: const EdgeInsets.all(24),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.lock_outline, size: 48, color: kMutedText),
              const SizedBox(height: 12),
              Text(
                'Access denied',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                'You do not have access to $pageName.',
                style: TextStyle(color: kSecondaryText),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class NewsFeedPage extends StatefulWidget {
  const NewsFeedPage({super.key, required this.canEdit});

  final bool canEdit;

  @override
  State<NewsFeedPage> createState() => _NewsFeedPageState();
}

class _NewsFeedPageState extends State<NewsFeedPage> {
  String? _noticeMessage;
  bool _noticeError = false;
  static const int _pageSize = 20;
  final _scrollController = ScrollController();
  final List<NewsPost> _posts = [];
  bool _loading = false;
  bool _loadingMore = false;
  bool _hasMore = true;
  int _offset = 0;
  String _selectedCategory = 'news';
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_handleScroll);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    _loadInitial();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _handleScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      _loadMore();
    }
  }

  Future<void> _loadInitial() async {
    setState(() => _loading = true);
    try {
      final data = await AppStateScope.of(context).client.listNews(
        offset: 0,
        limit: _pageSize,
        category: _selectedCategory,
      );
      if (!mounted) return;
      setState(() {
        _posts
          ..clear()
          ..addAll(data);
        _offset = data.length;
        _hasMore = data.length == _pageSize;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _noticeError = true;
        _noticeMessage =
            '\u041d\u0435 \u0443\u0434\u0430\u043b\u043e\u0441\u044c \u0437\u0430\u0433\u0440\u0443\u0437\u0438\u0442\u044c \u043b\u0435\u043d\u0442\u0443: ${humanizeError(error)}';
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);
    try {
      final data = await AppStateScope.of(context).client.listNews(
        offset: _offset,
        limit: _pageSize,
        category: _selectedCategory,
      );
      if (!mounted) return;
      setState(() {
        _posts.addAll(data);
        _offset += data.length;
        _hasMore = data.length == _pageSize;
      });
    } catch (_) {
      if (!mounted) return;
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  Future<void> _refresh() async {
    await _loadInitial();
  }

  void _selectCategory(String id) {
    if (_selectedCategory == id) return;
    setState(() {
      _selectedCategory = id;
      _posts.clear();
      _offset = 0;
      _hasMore = true;
    });
    _loadInitial();
  }

  Future<void> _react(NewsPost post, String reaction) async {
    final index = _posts.indexWhere((item) => item.id == post.id);
    if (index == -1) return;
    final prev = _posts[index];
    final current = prev.myReaction;
    final nextReaction = current == reaction ? null : reaction;
    final updatedCounts = Map<String, int>.from(prev.reactionCounts);
    if (current != null) {
      updatedCounts[current] = (updatedCounts[current] ?? 1) - 1;
      if (updatedCounts[current]! <= 0) {
        updatedCounts.remove(current);
      }
    }
    if (nextReaction != null) {
      updatedCounts[nextReaction] = (updatedCounts[nextReaction] ?? 0) + 1;
    }
    final nextLiked = nextReaction != null;
    setState(() {
      _posts[index] = prev.copyWith(
        myReaction: nextReaction,
        likedByMe: nextLiked,
        reactionCounts: updatedCounts,
        likesCount: updatedCounts.values.fold<int>(0, (a, b) => a + b),
      );
    });
    try {
      final result = await AppStateScope.of(context).client.toggleNewsLike(
        post.id,
        like: nextReaction != null,
        reaction: reaction,
      );
      if (!mounted) return;
      setState(() {
        _posts[index] = _posts[index].copyWith(
          likedByMe: result.liked,
          likesCount: result.likesCount,
          reactionCounts: result.reactionCounts,
          myReaction: result.myReaction,
        );
      });
    } catch (_) {}
  }

  Future<void> _share(NewsPost post) async {
    try {
      final count = await AppStateScope.of(context).client.shareNews(post.id);
      final index = _posts.indexWhere((item) => item.id == post.id);
      if (!mounted || index == -1) return;
      setState(() => _posts[index] = _posts[index].copyWith(shareCount: count));
    } catch (_) {}
  }

  Future<void> _openDetail(NewsPost post) async {
    final result = await Navigator.of(context).push<NewsPost>(
      MaterialPageRoute(
        builder: (_) => NewsPostDetailPage(post: post, canEdit: widget.canEdit),
      ),
    );
    if (result == null) return;
    final index = _posts.indexWhere((item) => item.id == result.id);
    if (index == -1) return;
    setState(() => _posts[index] = result);
  }

  Future<void> _deletePost(NewsPost post) async {
    if (!widget.canEdit) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete post'),
        content: const Text('Delete this post?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await AppStateScope.of(context).client.deleteNewsPost(post.id);
      if (!mounted) return;
      setState(() => _posts.removeWhere((item) => item.id == post.id));
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _noticeError = true;
        _noticeMessage = humanizeError(error);
      });
    }
  }

  Future<void> _openCompose() async {
    final created = await Navigator.of(
      context,
    ).push<bool>(MaterialPageRoute(builder: (_) => const NewsComposePage()));
    if (created == true) {
      _refresh();
    }
  }

  void _openReactionPicker(NewsPost post) {
    showModalBottomSheet<void>(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              for (final entry in kReactionLabels.entries)
                ListTile(
                  leading: Text(kReactionEmoji[entry.key] ?? ''),
                  title: Text(entry.value),
                  trailing: post.myReaction == entry.key
                      ? const Icon(Icons.check_circle, color: kBrandPrimary)
                      : null,
                  onTap: () {
                    Navigator.pop(context);
                    _react(post, entry.key);
                  },
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  Widget _buildReactionCounts(NewsPost post) {
    if (post.reactionCounts.isEmpty) {
      return const SizedBox.shrink();
    }
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: post.reactionCounts.entries.map((entry) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: kSecondaryBackground,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text('${kReactionEmoji[entry.key] ?? ''} ${entry.value}'),
        );
      }).toList(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FeatureScaffold(
      title: 'News feed',
      subtitle:
          '\u041b\u0435\u043d\u0442\u0430 \u0438 \u0441\u043e\u0431\u044b\u0442\u0438\u044f \u043a\u0430\u043c\u043f\u0443\u0441\u0430',
      actionLabel: widget.canEdit
          ? '\u0421\u043e\u0437\u0434\u0430\u0442\u044c \u043f\u043e\u0441\u0442'
          : null,
      onAction: widget.canEdit ? _openCompose : null,
      bodyScrollable: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 44,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemBuilder: (context, index) {
                final category = kNewsCategories[index];
                final selected = _selectedCategory == category['id'];
                return ChoiceChip(
                  label: Text(category['label'] ?? ''),
                  selected: selected,
                  onSelected: (_) => _selectCategory(category['id'] ?? 'news'),
                );
              },
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemCount: kNewsCategories.length,
            ),
          ),
          const SizedBox(height: 12),
          if (_noticeMessage != null)
            InlineNotice(message: _noticeMessage!, isError: _noticeError),
          if (_noticeMessage != null) const SizedBox(height: 12),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _refresh,
              child: _loading && _posts.isEmpty
                  ? const Center(child: BrandLoadingIndicator())
                  : ListView.builder(
                      controller: _scrollController,
                      itemCount: _posts.length + (_loadingMore ? 1 : 0),
                      itemBuilder: (context, index) {
                        if (index >= _posts.length) {
                          return const Padding(
                            padding: EdgeInsets.symmetric(vertical: 16),
                            child: Center(
                              child: BrandLoadingIndicator(
                                logoSize: 44,
                                spacing: 8,
                              ),
                            ),
                          );
                        }
                        final post = _posts[index];
                        return Container(
                          margin: const EdgeInsets.only(bottom: 16),
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [
                                kBrandPrimary.withOpacity(0.25),
                                kInfo.withOpacity(0.25),
                              ],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                            borderRadius: BorderRadius.circular(24),
                          ),
                          child: Container(
                            margin: const EdgeInsets.all(1.2),
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.92),
                              borderRadius: BorderRadius.circular(22),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withOpacity(0.06),
                                  blurRadius: 16,
                                  offset: const Offset(0, 8),
                                ),
                              ],
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    CircleAvatar(
                                      backgroundColor: kSecondaryBackground,
                                      child: Text(
                                        post.authorName.isEmpty
                                            ? '?'
                                            : post.authorName[0].toUpperCase(),
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            post.authorName,
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                          Text(
                                            DateFormat(
                                              'dd.MM.yyyy HH:mm',
                                            ).format(post.createdAt),
                                            style: TextStyle(
                                              color: kSecondaryText,
                                              fontSize: 12,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    if (post.pinned)
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 4,
                                        ),
                                        decoration: BoxDecoration(
                                          color: kBrandPrimary.withOpacity(
                                            0.12,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                        ),
                                        child: Text(
                                          '\u0417\u0430\u043a\u0440\u0435\u043f\u043b\u0435\u043d\u043e',
                                          style: TextStyle(
                                            color: kBrandPrimary,
                                            fontSize: 12,
                                          ),
                                        ),
                                      ),
                                    if (widget.canEdit)
                                      IconButton(
                                        onPressed: () => _deletePost(post),
                                        icon: const Icon(Icons.delete_outline),
                                      ),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                Wrap(
                                  spacing: 8,
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 10,
                                        vertical: 4,
                                      ),
                                      decoration: BoxDecoration(
                                        color: kSecondaryBackground,
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: Text(
                                        (kNewsCategories.firstWhere(
                                              (c) => c['id'] == post.category,
                                              orElse: () =>
                                                  kNewsCategories.first,
                                            )['label']) ??
                                            '',
                                        style: const TextStyle(fontSize: 12),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 10),
                                Text(
                                  post.title,
                                  style: Theme.of(context).textTheme.titleMedium
                                      ?.copyWith(fontWeight: FontWeight.w700),
                                ),
                                const SizedBox(height: 6),
                                Text(post.body),
                                if (post.media.isNotEmpty) ...[
                                  const SizedBox(height: 12),
                                  SizedBox(
                                    height: 160,
                                    child: ListView.separated(
                                      scrollDirection: Axis.horizontal,
                                      itemCount: post.media.length,
                                      separatorBuilder: (_, __) =>
                                          const SizedBox(width: 12),
                                      itemBuilder: (context, mediaIndex) {
                                        final media = post.media[mediaIndex];
                                        final url = _resolveMediaUrl(media.url);
                                        if (_isVideo(media)) {
                                          return GestureDetector(
                                            onTap: () => _openMediaViewer(
                                              post.media,
                                              mediaIndex,
                                            ),
                                            child: SizedBox(
                                              width: 220,
                                              child: NewsVideoPreview(url: url),
                                            ),
                                          );
                                        }
                                        return GestureDetector(
                                          onTap: () => _openMediaViewer(
                                            post.media,
                                            mediaIndex,
                                          ),
                                          child: ClipRRect(
                                            borderRadius: BorderRadius.circular(
                                              16,
                                            ),
                                            child: Image.network(
                                              url,
                                              width: 220,
                                              height: 160,
                                              fit: BoxFit.cover,
                                              loadingBuilder:
                                                  (context, child, progress) {
                                                    if (progress == null)
                                                      return child;
                                                    return Container(
                                                      width: 220,
                                                      height: 160,
                                                      color:
                                                          kSecondaryBackground,
                                                      child: const Center(
                                                        child:
                                                            BrandLoadingIndicator(
                                                              logoSize: 40,
                                                              spacing: 8,
                                                            ),
                                                      ),
                                                    );
                                                  },
                                            ),
                                          ),
                                        );
                                      },
                                    ),
                                  ),
                                ],
                                const SizedBox(height: 12),
                                _buildReactionCounts(post),
                                const SizedBox(height: 12),
                                Row(
                                  children: [
                                    TextButton.icon(
                                      onPressed: () =>
                                          _openReactionPicker(post),
                                      icon: Text(
                                        kReactionEmoji[post.myReaction ??
                                                'like'] ??
                                            '\ud83d\udc4d',
                                      ),
                                      label: Text(
                                        post.myReaction == null
                                            ? '\u0420\u0435\u0430\u043a\u0446\u0438\u044f'
                                            : (kReactionLabels[post
                                                      .myReaction] ??
                                                  '\u0420\u0435\u0430\u043a\u0446\u0438\u044f'),
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    IconButton(
                                      onPressed: () => _openDetail(post),
                                      icon: const Icon(
                                        Icons.chat_bubble_outline,
                                      ),
                                    ),
                                    Text('${post.commentsCount}'),
                                    const Spacer(),
                                    TextButton.icon(
                                      onPressed: () => _share(post),
                                      icon: const Icon(Icons.share),
                                      label: Text('${post.shareCount}'),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }

  void _openMediaViewer(List<NewsMedia> media, int startIndex) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MediaViewerPage(media: media, initialIndex: startIndex),
      ),
    );
  }
}

class NewsComposePage extends StatefulWidget {
  const NewsComposePage({super.key});

  @override
  State<NewsComposePage> createState() => _NewsComposePageState();
}

class _NewsComposePageState extends State<NewsComposePage> {
  String? _noticeMessage;
  bool _noticeError = false;
  final _titleController = TextEditingController();
  final _bodyController = TextEditingController();
  final List<NewsMediaUpload> _media = [];
  String _category = 'news';
  bool _pinned = false;
  bool _submitting = false;

  @override
  void dispose() {
    _titleController.dispose();
    _bodyController.dispose();
    super.dispose();
  }

  Future<void> _pickMedia() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      withData: true,
      type: FileType.any,
    );
    if (result == null) return;
    final uploads = <NewsMediaUpload>[];
    for (final file in result.files) {
      if (file.bytes == null) continue;
      uploads.add(NewsMediaUpload(filename: file.name, bytes: file.bytes!));
    }
    setState(() => _media.addAll(uploads));
  }

  Future<void> _submit() async {
    if (_titleController.text.trim().isEmpty &&
        _bodyController.text.trim().isEmpty) {
      setState(() {
        _noticeError = true;
        _noticeMessage = 'Добавьте заголовок или описание.';
      });
      return;
    }
    setState(() => _submitting = true);
    try {
      await AppStateScope.of(context).client.createNews(
        title: _titleController.text.trim(),
        body: _bodyController.text.trim(),
        category: _category,
        pinned: _pinned,
        media: _media,
      );
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _noticeError = true;
        _noticeMessage = humanizeError(error);
      });
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          '\u0421\u043e\u0437\u0434\u0430\u0442\u044c \u043f\u043e\u0441\u0442',
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          TextField(
            controller: _titleController,
            decoration: const InputDecoration(
              labelText:
                  '\u0417\u0430\u0433\u043e\u043b\u043e\u0432\u043e\u043a',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _bodyController,
            maxLines: 6,
            decoration: const InputDecoration(
              labelText: '\u041e\u043f\u0438\u0441\u0430\u043d\u0438\u0435',
            ),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            value: _category,
            items: [
              for (final item in kNewsCategories)
                DropdownMenuItem(
                  value: item['id'],
                  child: Text(item['label'] ?? ''),
                ),
            ],
            onChanged: (value) {
              if (value != null) setState(() => _category = value);
            },
            decoration: const InputDecoration(labelText: 'Category'),
          ),
          const SizedBox(height: 12),
          SwitchListTile(
            value: _pinned,
            onChanged: (value) => setState(() => _pinned = value),
            title: const Text('Pin post'),
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: _pickMedia,
            icon: const Icon(Icons.attach_file),
            label: const Text(
              '\u0414\u043e\u0431\u0430\u0432\u0438\u0442\u044c \u0444\u0430\u0439\u043b\u044b',
            ),
          ),
          if (_media.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (int i = 0; i < _media.length; i++)
                  Chip(
                    label: Text(_media[i].filename),
                    onDeleted: () => setState(() => _media.removeAt(i)),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _submitting ? null : _submit,
            child: _submitting
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text(
                    '\u041e\u043f\u0443\u0431\u043b\u0438\u043a\u043e\u0432\u0430\u0442\u044c',
                  ),
          ),
        ],
      ),
    );
  }
}

class NewsPostDetailPage extends StatefulWidget {
  const NewsPostDetailPage({
    super.key,
    required this.post,
    required this.canEdit,
  });

  final NewsPost post;
  final bool canEdit;

  @override
  State<NewsPostDetailPage> createState() => _NewsPostDetailPageState();
}

class _NewsPostDetailPageState extends State<NewsPostDetailPage> {
  String? _noticeMessage;
  bool _noticeError = false;
  late NewsPost _post;
  final _commentController = TextEditingController();
  bool _loading = false;
  bool _sending = false;
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    _post = widget.post;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    _load();
  }

  @override
  void dispose() {
    _commentController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final latest = await AppStateScope.of(
        context,
      ).client.getNewsPost(_post.id);
      if (!mounted) return;
      setState(() => _post = latest);
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _react(String reaction) async {
    final current = _post.myReaction;
    final nextReaction = current == reaction ? null : reaction;
    final updatedCounts = Map<String, int>.from(_post.reactionCounts);
    if (current != null) {
      updatedCounts[current] = (updatedCounts[current] ?? 1) - 1;
      if (updatedCounts[current]! <= 0) {
        updatedCounts.remove(current);
      }
    }
    if (nextReaction != null) {
      updatedCounts[nextReaction] = (updatedCounts[nextReaction] ?? 0) + 1;
    }
    setState(() {
      _post = _post.copyWith(
        myReaction: nextReaction,
        likedByMe: nextReaction != null,
        reactionCounts: updatedCounts,
        likesCount: updatedCounts.values.fold<int>(0, (a, b) => a + b),
      );
    });
    try {
      final result = await AppStateScope.of(context).client.toggleNewsLike(
        _post.id,
        like: nextReaction != null,
        reaction: reaction,
      );
      if (!mounted) return;
      setState(() {
        _post = _post.copyWith(
          likedByMe: result.liked,
          likesCount: result.likesCount,
          reactionCounts: result.reactionCounts,
          myReaction: result.myReaction,
        );
      });
    } catch (_) {}
  }

  void _openReactionPicker() {
    showModalBottomSheet<void>(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              for (final entry in kReactionLabels.entries)
                ListTile(
                  leading: Text(kReactionEmoji[entry.key] ?? ''),
                  title: Text(entry.value),
                  trailing: _post.myReaction == entry.key
                      ? const Icon(Icons.check_circle, color: kBrandPrimary)
                      : null,
                  onTap: () {
                    Navigator.pop(context);
                    _react(entry.key);
                  },
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  Widget _buildReactionCounts() {
    if (_post.reactionCounts.isEmpty) {
      return const SizedBox.shrink();
    }
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: _post.reactionCounts.entries.map((entry) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: kSecondaryBackground,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text('${kReactionEmoji[entry.key] ?? ''} ${entry.value}'),
        );
      }).toList(),
    );
  }

  Future<void> _share() async {
    try {
      final count = await AppStateScope.of(context).client.shareNews(_post.id);
      if (!mounted) return;
      setState(() => _post = _post.copyWith(shareCount: count));
    } catch (_) {}
  }

  Future<void> _addComment() async {
    final text = _commentController.text.trim();
    if (text.isEmpty) return;
    setState(() => _sending = true);
    try {
      final comment = await AppStateScope.of(
        context,
      ).client.addNewsComment(_post.id, text);
      if (!mounted) return;
      setState(() {
        _post = _post.copyWith(
          comments: [..._post.comments, comment],
          commentsCount: _post.commentsCount + 1,
        );
        _commentController.clear();
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _noticeError = true;
        _noticeMessage = humanizeError(error);
      });
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _deleteComment(NewsComment comment) async {
    if (!widget.canEdit) return;
    try {
      await AppStateScope.of(
        context,
      ).client.deleteNewsComment(postId: _post.id, commentId: comment.id);
      if (!mounted) return;
      setState(() {
        _post = _post.copyWith(
          comments: _post.comments
              .where((item) => item.id != comment.id)
              .toList(),
          commentsCount: _post.commentsCount > 0 ? _post.commentsCount - 1 : 0,
        );
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _noticeError = true;
        _noticeMessage = humanizeError(error);
      });
    }
  }

  Future<void> _deletePost() async {
    if (!widget.canEdit) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete post'),
        content: const Text('Delete this post?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await AppStateScope.of(context).client.deleteNewsPost(_post.id);
      if (!mounted) return;
      Navigator.pop(context);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _noticeError = true;
        _noticeMessage = humanizeError(error);
      });
    }
  }

  Future<void> _togglePinned() async {
    if (!widget.canEdit) return;
    try {
      final updated = await AppStateScope.of(
        context,
      ).client.updateNewsPost(_post.id, pinned: !_post.pinned);
      if (!mounted) return;
      setState(() => _post = updated);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Post'),
        actions: [
          if (widget.canEdit)
            IconButton(
              onPressed: _togglePinned,
              icon: Icon(
                _post.pinned ? Icons.push_pin : Icons.push_pin_outlined,
              ),
            ),
          if (widget.canEdit)
            IconButton(
              onPressed: _deletePost,
              icon: const Icon(Icons.delete_outline),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: BrandLoadingIndicator())
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                if (_noticeMessage != null)
                  InlineNotice(message: _noticeMessage!, isError: _noticeError),
                if (_noticeMessage != null) const SizedBox(height: 12),
                Text(
                  _post.title,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 6),
                Text(_post.body),
                const SizedBox(height: 12),
                if (_post.media.isNotEmpty)
                  SizedBox(
                    height: 220,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: _post.media.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 12),
                      itemBuilder: (context, index) {
                        final media = _post.media[index];
                        final url = _resolveMediaUrl(media.url);
                        if (_isVideo(media)) {
                          return GestureDetector(
                            onTap: () => _openMediaViewer(_post.media, index),
                            child: SizedBox(
                              width: 280,
                              child: NewsVideoPreview(url: url),
                            ),
                          );
                        }
                        return GestureDetector(
                          onTap: () => _openMediaViewer(_post.media, index),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(16),
                            child: Image.network(
                              url,
                              width: 280,
                              height: 220,
                              fit: BoxFit.cover,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                const SizedBox(height: 12),
                _buildReactionCounts(),
                const SizedBox(height: 12),
                Row(
                  children: [
                    TextButton.icon(
                      onPressed: _openReactionPicker,
                      icon: Text(
                        kReactionEmoji[_post.myReaction ?? 'like'] ??
                            '\ud83d\udc4d',
                      ),
                      label: Text(
                        _post.myReaction == null
                            ? '\u0420\u0435\u0430\u043a\u0446\u0438\u044f'
                            : (kReactionLabels[_post.myReaction] ??
                                  '\u0420\u0435\u0430\u043a\u0446\u0438\u044f'),
                      ),
                    ),
                    const Spacer(),
                    TextButton.icon(
                      onPressed: _share,
                      icon: const Icon(Icons.share),
                      label: Text('${_post.shareCount}'),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                Text(
                  'Comments',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                for (final comment in _post.comments)
                  Card(
                    child: ListTile(
                      title: Text(comment.userName),
                      subtitle: Text(comment.text),
                      trailing: widget.canEdit
                          ? IconButton(
                              onPressed: () => _deleteComment(comment),
                              icon: const Icon(Icons.delete_outline),
                            )
                          : null,
                    ),
                  ),
                const SizedBox(height: 12),
                TextField(
                  controller: _commentController,
                  decoration: const InputDecoration(labelText: 'Add a comment'),
                ),
                const SizedBox(height: 8),
                FilledButton(
                  onPressed: _sending ? null : _addComment,
                  child: _sending
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Send'),
                ),
              ],
            ),
    );
  }

  void _openMediaViewer(List<NewsMedia> media, int startIndex) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MediaViewerPage(media: media, initialIndex: startIndex),
      ),
    );
  }
}

class NewsVideoPreview extends StatefulWidget {
  const NewsVideoPreview({super.key, required this.url});

  final String url;

  @override
  State<NewsVideoPreview> createState() => _NewsVideoPreviewState();
}

class _NewsVideoPreviewState extends State<NewsVideoPreview> {
  VideoPlayerController? _controller;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.networkUrl(Uri.parse(widget.url))
      ..setLooping(true)
      ..setVolume(0)
      ..initialize().then((_) {
        if (mounted) setState(() => _ready = true);
      });
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready || _controller == null) {
      return Container(
        decoration: BoxDecoration(
          color: kSecondaryBackground,
          borderRadius: BorderRadius.circular(16),
        ),
        child: const Center(
          child: Icon(Icons.play_circle_outline, size: 48, color: kMutedText),
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Stack(
        fit: StackFit.expand,
        children: [
          VideoPlayer(_controller!),
          const Align(
            alignment: Alignment.center,
            child: Icon(
              Icons.play_circle_outline,
              size: 48,
              color: Colors.white70,
            ),
          ),
        ],
      ),
    );
  }
}

class MediaViewerPage extends StatefulWidget {
  const MediaViewerPage({
    super.key,
    required this.media,
    required this.initialIndex,
  });

  final List<NewsMedia> media;
  final int initialIndex;

  @override
  State<MediaViewerPage> createState() => _MediaViewerPageState();
}

class _MediaViewerPageState extends State<MediaViewerPage> {
  late PageController _pageController;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: widget.initialIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(),
      body: PageView.builder(
        controller: _pageController,
        itemCount: widget.media.length,
        itemBuilder: (context, index) {
          final media = widget.media[index];
          final url = _resolveMediaUrl(media.url);
          if (_isVideo(media)) {
            return Center(child: _VideoPlayerFull(url: url));
          }
          return InteractiveViewer(
            child: Center(child: Image.network(url, fit: BoxFit.contain)),
          );
        },
      ),
    );
  }
}

class _VideoPlayerFull extends StatefulWidget {
  const _VideoPlayerFull({required this.url});

  final String url;

  @override
  State<_VideoPlayerFull> createState() => _VideoPlayerFullState();
}

class _VideoPlayerFullState extends State<_VideoPlayerFull> {
  VideoPlayerController? _controller;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.networkUrl(Uri.parse(widget.url))
      ..initialize().then((_) {
        if (mounted) setState(() => _ready = true);
      });
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready || _controller == null) {
      return const Center(child: BrandLoadingIndicator());
    }
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        AspectRatio(
          aspectRatio: _controller!.value.aspectRatio,
          child: VideoPlayer(_controller!),
        ),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              onPressed: () {
                if (_controller!.value.isPlaying) {
                  _controller!.pause();
                } else {
                  _controller!.play();
                }
                setState(() {});
              },
              icon: Icon(
                _controller!.value.isPlaying
                    ? Icons.pause_circle
                    : Icons.play_circle,
                size: 36,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

bool _isVideo(NewsMedia media) {
  final mime = media.mimeType ?? '';
  if (mime.startsWith('video')) return true;
  final type = media.mediaType.toLowerCase();
  return type.contains('video');
}

String _resolveMediaUrl(String url) {
  if (url.startsWith('http://') || url.startsWith('https://')) return url;
  return '$apiBaseUrl$url';
}
