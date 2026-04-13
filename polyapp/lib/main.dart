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
import 'package:url_launcher/url_launcher.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'firebase_options.dart';

import 'api/api_client.dart';
import 'journal/journal_store.dart';
import 'journal/attendance_journal_page.dart';
import 'journal/grades_preset_journal_page.dart';
import 'makeup/makeup_pages.dart';
import 'analytics/analytics_workspace_page.dart';
import 'widgets/brand_logo.dart';
import 'i18n/ui_text.dart';

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
const double kNewsMediaMaxWidth = 680;
const double kNewsMediaMaxHeight = 320;

enum DeviceCanvas { mobile, desktop, web }

bool _isDesktopLikeCanvas() {
  if (kIsWeb) return true;
  return defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.linux;
}

Future<T?> pushAdaptivePage<T>(
  BuildContext context,
  Widget child, {
  double width = 1100,
  double height = 780,
  bool barrierDismissible = false,
}) {
  if (!_isDesktopLikeCanvas()) {
    return Navigator.of(
      context,
    ).push<T>(MaterialPageRoute(builder: (_) => child));
  }
  return showDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    builder: (_) => Dialog(
      insetPadding: const EdgeInsets.all(20),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: SizedBox(width: width, height: height, child: child),
      ),
    ),
  );
}

String publicNewsShareLink(BuildContext context, int postId) {
  final rawBase = AppStateScope.of(context).baseUrl.trim();
  final normalized = rawBase.endsWith('/api')
      ? rawBase.substring(0, rawBase.length - 4)
      : rawBase;
  return '$normalized/news/public/$postId';
}

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
  'like': '\u041d\u0440\u0430\u0432\u0438\u0442\u0441\u044f',
  'cool': '\u041a\u0440\u0443\u0442\u043e',
  'useful': '\u041f\u043e\u043b\u0435\u0437\u043d\u043e',
  'discuss': '\u041e\u0431\u0441\u0443\u0436\u0434\u0435\u043d\u0438\u0435',
};

const Map<String, String> kReactionEmoji = {
  'like': '\ud83d\udc4d',
  'cool': '\ud83d\udd25',
  'useful': '\ud83d\udc4f',
  'discuss': '\ud83d\udcac',
};

final RegExp _newsInlineMediaTokenPattern = RegExp(
  r'\{\{media:(\d+)\}\}',
  caseSensitive: false,
);
final RegExp _newsMarkdownImagePattern = RegExp(r'!\[[^\]]*\]\(([^)]+)\)');

Set<int> _newsReferencedMediaIndices(String body, int mediaCount) {
  final used = <int>{};
  for (final match in _newsInlineMediaTokenPattern.allMatches(body)) {
    final token = int.tryParse(match.group(1) ?? '');
    if (token == null) continue;
    final index = token - 1;
    if (index >= 0 && index < mediaCount) {
      used.add(index);
    }
  }
  return used;
}

List<int> _newsRemainingMediaIndices(String body, List<NewsMedia> media) {
  if (media.isEmpty) return const [];
  final used = _newsReferencedMediaIndices(body, media.length);
  final markdownUrls = _newsMarkdownImagePattern
      .allMatches(body)
      .map((m) => (m.group(1) ?? '').trim())
      .where((url) => url.isNotEmpty)
      .toSet();
  if (markdownUrls.isNotEmpty) {
    for (int i = 0; i < media.length; i++) {
      final mediaUrl = media[i].url.trim();
      if (mediaUrl.isEmpty) continue;
      final resolvedMediaUrl = _resolveMediaUrl(mediaUrl);
      final matchesMarkdown = markdownUrls.any((rawUrl) {
        final resolvedRawUrl = _resolveMediaUrl(rawUrl);
        return rawUrl == mediaUrl ||
            rawUrl == resolvedMediaUrl ||
            resolvedRawUrl == mediaUrl ||
            resolvedRawUrl == resolvedMediaUrl;
      });
      if (matchesMarkdown) {
        used.add(i);
      }
    }
  }
  final remaining = <int>[];
  for (int i = 0; i < media.length; i++) {
    if (!used.contains(i)) {
      remaining.add(i);
    }
  }
  return remaining;
}

String _newsPreviewText(String body) {
  var text = body.replaceAll(_newsInlineMediaTokenPattern, '');
  text = text.replaceAll(_newsMarkdownImagePattern, '');
  text = text.replaceAll(RegExp(r'[ \t]+'), ' ');
  text = text.replaceAll(RegExp(r'\n{2,}'), '\n');
  return text.trim();
}

NewsMedia? _firstImageMedia(List<NewsMedia> media) {
  for (final item in media) {
    if (_isImage(item)) return item;
  }
  return null;
}

String? _firstMarkdownImageUrl(String body) {
  for (final match in _newsMarkdownImagePattern.allMatches(body)) {
    final url = (match.group(1) ?? '').trim();
    if (url.isNotEmpty) {
      return _resolveMediaUrl(url);
    }
  }
  return null;
}

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
  if (raw.contains('Invalid argument (string): Contains invalid characters')) {
    return isRu
        ? 'Некорректная ссылка на файл. Обновите страницу и попробуйте снова.'
        : 'Invalid file link. Refresh and try again.';
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
  if (raw.contains('pending admin approval') ||
      raw.contains('pending approval')) {
    return isRu
        ? 'Аккаунт создан и ожидает подтверждения администратором.'
        : 'Account created and waiting for admin approval.';
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
  if (raw.contains('Failed to fetch') || raw.contains('ClientException')) {
    return isRu
        ? 'Сервер недоступен. Проверьте API_BASE_URL и CORS (пример: http://<IP_компьютера>:8000 для телефона).'
        : 'Server is unavailable. Check API_BASE_URL and CORS (example: http://<your-pc-ip>:8000 for phone).';
  }
  return raw;
}

String? _extractApiDetail(String input) {
  final text = input.trim();
  if (text.isEmpty) return null;
  final jsonStart = text.indexOf('{');
  final jsonText = jsonStart >= 0 ? text.substring(jsonStart) : text;
  String normalized = jsonText;
  if (normalized.contains(r'\"') || normalized.contains(r'\/')) {
    normalized = normalized
        .replaceAll(r'\"', '"')
        .replaceAll(r'\/', '/')
        .replaceAll(r'\\n', '\n')
        .replaceAll(r'\\t', '\t')
        .replaceAll(r'\\r', '\r');
  }
  try {
    dynamic decoded = jsonDecode(normalized);
    if (decoded is String) {
      decoded = jsonDecode(decoded);
    }
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
        color: color.withValues(alpha: 0.12),
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

  static const supportedLocales = [
    Locale('ru'),
    Locale('en'),
    Locale('kk'),
    Locale('fr'),
    Locale('de'),
    Locale('hi'),
    Locale('zh'),
  ];

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
      'language_kk': '\u041a\u0430\u0437\u0430\u0445\u0441\u043a\u0438\u0439',
      'language_fr':
          '\u0424\u0440\u0430\u043d\u0446\u0443\u0437\u0441\u043a\u0438\u0439',
      'language_de': '\u041d\u0435\u043c\u0435\u0446\u043a\u0438\u0439',
      'language_hi': '\u0425\u0438\u043d\u0434\u0438',
      'language_zh': '\u041a\u0438\u0442\u0430\u0439\u0441\u043a\u0438\u0439',
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
      'notifications_read_action':
          '\u041f\u0440\u043e\u0447\u0438\u0442\u0430\u0442\u044c',
      'notifications_delete': '\u0423\u0434\u0430\u043b\u0438\u0442\u044c',
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
      'language_kk': 'Kazakh',
      'language_fr': 'French',
      'language_de': 'German',
      'language_hi': 'Hindi',
      'language_zh': 'Chinese',
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
      'notifications_read_action': 'Read',
      'notifications_delete': 'Delete',
      'notifications_unread': 'New',
    },
    'kk': {
      'auth_title_login': '\u041a\u0456\u0440\u0443',
      'auth_title_register': '\u0422\u0456\u0440\u043a\u0435\u043b\u0443',
      'auth_subtitle_login':
          '\u049a\u0430\u0439\u0442\u0430 \u043a\u0435\u043b\u0434\u0456\u04a3\u0456\u0437',
      'auth_subtitle_register':
          '\u0421\u0442\u0443\u0434\u0435\u043d\u0442 \u0430\u043a\u043a\u0430\u0443\u043d\u0442\u044b\u043d \u0436\u0430\u0441\u0430\u04a3\u044b\u0437',
      'full_name':
          '\u0422\u043e\u043b\u044b\u049b \u0430\u0442\u044b-\u0436\u04e9\u043d\u0456',
      'email': 'Email',
      'password': '\u049a\u04b1\u043f\u0438\u044f \u0441\u04e9\u0437',
      'confirm_password':
          '\u049a\u04b1\u043f\u0438\u044f \u0441\u04e9\u0437\u0434\u0456 \u0440\u0430\u0441\u0442\u0430\u04a3\u044b\u0437',
      'sign_in': '\u041a\u0456\u0440\u0443',
      'create_account':
          '\u0410\u043a\u043a\u0430\u0443\u043d\u0442 \u0436\u0430\u0441\u0430\u0443',
      'have_account':
          '\u041c\u0435\u043d\u0434\u0435 \u0430\u043a\u043a\u0430\u0443\u043d\u0442 \u0431\u0430\u0440',
      'create_new_account':
          '\u0416\u0430\u04a3\u0430 \u0430\u043a\u043a\u0430\u0443\u043d\u0442 \u0436\u0430\u0441\u0430\u0443',
      'forgot_password':
          '\u049a\u04b1\u043f\u0438\u044f \u0441\u04e9\u0437\u0434\u0456 \u04b1\u043c\u044b\u0442\u0442\u044b\u04a3\u044b\u0437 \u0431\u0430?',
      'reset_password':
          '\u049a\u04b1\u043f\u0438\u044f \u0441\u04e9\u0437\u0434\u0456 \u049b\u0430\u0439\u0442\u0430 \u043e\u0440\u043d\u0430\u0442\u0443',
      'reset_desc':
          'Email \u043f\u043e\u0448\u0442\u0430\u04a3\u044b\u0437\u0493\u0430 \u049b\u0430\u043b\u043f\u044b\u043d\u0430 \u043a\u0435\u043b\u0442\u0456\u0440\u0443 \u0441\u0456\u043b\u0442\u0435\u043c\u0435\u0441\u0456\u043d \u0436\u0456\u0431\u0435\u0440\u0435\u043c\u0456\u0437.',
      'send_reset':
          '\u049a\u0430\u043b\u043f\u044b\u043d\u0430 \u043a\u0435\u043b\u0442\u0456\u0440\u0443 \u0445\u0430\u0442\u044b\u043d \u0436\u0456\u0431\u0435\u0440\u0443',
      'language': '\u0422\u0456\u043b',
      'language_ru': '\u041e\u0440\u044b\u0441 \u0442\u0456\u043b\u0456',
      'language_en':
          '\u0410\u0493\u044b\u043b\u0448\u044b\u043d \u0442\u0456\u043b\u0456',
      'language_kk': '\u049a\u0430\u0437\u0430\u049b \u0442\u0456\u043b\u0456',
      'language_fr':
          '\u0424\u0440\u0430\u043d\u0446\u0443\u0437 \u0442\u0456\u043b\u0456',
      'language_de': '\u041d\u0435\u043c\u0456\u0441 \u0442\u0456\u043b\u0456',
      'language_hi': '\u0425\u0438\u043d\u0434\u0438',
      'language_zh': '\u049a\u044b\u0442\u0430\u0439 \u0442\u0456\u043b\u0456',
      'settings': '\u0411\u0430\u043f\u0442\u0430\u0443\u043b\u0430\u0440',
      'password_strength_weak':
          '\u04d8\u043b\u0441\u0456\u0437 \u049b\u04b1\u043f\u0438\u044f \u0441\u04e9\u0437',
      'password_strength_medium':
          '\u041e\u0440\u0442\u0430\u0448\u0430 \u049b\u04b1\u043f\u0438\u044f \u0441\u04e9\u0437',
      'password_strength_strong':
          '\u041a\u04af\u0448\u0442\u0456 \u049b\u04b1\u043f\u0438\u044f \u0441\u04e9\u0437',
      'password_hint':
          '\u041a\u0435\u043c\u0456\u043d\u0434\u0435 8 \u0431\u0435\u043b\u0433\u0456, \u04d9\u0440\u0456\u043f\u0442\u0435\u0440 \u043c\u0435\u043d \u0441\u0430\u043d\u0434\u0430\u0440',
      'passwords_mismatch':
          '\u049a\u04b1\u043f\u0438\u044f \u0441\u04e9\u0437\u0434\u0435\u0440 \u0441\u04d9\u0439\u043a\u0435\u0441 \u0435\u043c\u0435\u0441',
      'email_required':
          'Email \u043c\u0456\u043d\u0434\u0435\u0442\u0442\u0456',
      'password_required':
          '\u049a\u04b1\u043f\u0438\u044f \u0441\u04e9\u0437 \u043c\u0456\u043d\u0434\u0435\u0442\u0442\u0456',
      'name_required':
          '\u0422\u043e\u043b\u044b\u049b \u0430\u0442\u044b-\u0436\u04e9\u043d\u0456 \u043c\u0456\u043d\u0434\u0435\u0442\u0442\u0456',
      'auth_error':
          '\u041a\u0456\u0440\u0443 \u0441\u04d9\u0442\u0441\u0456\u0437. Email \u043c\u0435\u043d \u049b\u04b1\u043f\u0438\u044f \u0441\u04e9\u0437\u0434\u0456 \u0442\u0435\u043a\u0441\u0435\u0440\u0456\u04a3\u0456\u0437.',
      'reset_sent':
          '\u049a\u0430\u043b\u043f\u044b\u043d\u0430 \u043a\u0435\u043b\u0442\u0456\u0440\u0443 \u0445\u0430\u0442\u044b \u0436\u0456\u0431\u0435\u0440\u0456\u043b\u0434\u0456.',
      'profile_title': '\u041f\u0440\u043e\u0444\u0438\u043b\u044c',
      'save_profile': '\u0421\u0430\u049b\u0442\u0430\u0443',
      'profile_edit': '\u04e8\u04a3\u0434\u0435\u0443',
      'role_label': '\u0420\u04e9\u043b',
      'contact_info': '\u0411\u0430\u0439\u043b\u0430\u043d\u044b\u0441',
      'account_info': '\u0410\u043a\u043a\u0430\u0443\u043d\u0442',
      'preferences': '\u049b\u0430\u043b\u0430\u0443\u043b\u0430\u0440',
      'notifications':
          '\u0425\u0430\u0431\u0430\u0440\u043b\u0430\u043c\u0430\u043b\u0430\u0440',
      'schedule_updates':
          '\u041a\u0435\u0441\u0442\u0435 \u0436\u0430\u04a3\u0430\u0440\u0442\u0443\u043b\u0430\u0440\u044b',
      'request_updates':
          '\u04e8\u0442\u0456\u043d\u0456\u0448 \u0436\u0430\u04a3\u0430\u0440\u0442\u0443\u043b\u0430\u0440\u044b',
      'security':
          '\u049a\u0430\u0443\u0456\u043f\u0441\u0456\u0437\u0434\u0456\u043a',
      'logout': '\u0428\u044b\u0493\u0443',
      'birth_date_label':
          '\u0422\u0443\u0493\u0430\u043d \u043a\u04af\u043d\u0456 (YYYY-MM-DD)',
      'group_label': '\u0422\u043e\u043f',
      'phone_label': '\u0422\u0435\u043b\u0435\u0444\u043e\u043d',
      'teacher_name_label':
          '\u041e\u049b\u044b\u0442\u0443\u0448\u044b \u0430\u0442\u044b-\u0436\u04e9\u043d\u0456',
      'profile_saved':
          '\u041f\u0440\u043e\u0444\u0438\u043b\u044c \u0436\u0430\u04a3\u0430\u0440\u0442\u044b\u043b\u0434\u044b.',
      'birth_date_invalid':
          '\u0422\u0443\u0493\u0430\u043d \u043a\u04af\u043d\u0456 YYYY-MM-DD \u0444\u043e\u0440\u043c\u0430\u0442\u044b\u043d\u0434\u0430 \u0431\u043e\u043b\u0443\u044b \u043a\u0435\u0440\u0435\u043a.',
      'profile_stats_group': '\u0422\u043e\u043f',
      'profile_stats_role': '\u0420\u04e9\u043b',
      'profile_stats_phone': '\u0422\u0435\u043b\u0435\u0444\u043e\u043d',
      'group_not_set':
          '\u041a\u04e9\u0440\u0441\u0435\u0442\u0456\u043b\u043c\u0435\u0433\u0435\u043d',
      'teacher_not_set':
          '\u041a\u04e9\u0440\u0441\u0435\u0442\u0456\u043b\u043c\u0435\u0433\u0435\u043d',
      'reset_password_action':
          '\u049a\u04b1\u043f\u0438\u044f \u0441\u04e9\u0437\u0434\u0456 \u049b\u0430\u0439\u0442\u0430 \u043e\u0440\u043d\u0430\u0442\u0443',
      'notifications_title':
          '\u0425\u0430\u0431\u0430\u0440\u043b\u0430\u043c\u0430\u043b\u0430\u0440',
      'notifications_empty':
          '\u04d8\u0437\u0456\u0440\u0433\u0435 \u0445\u0430\u0431\u0430\u0440\u043b\u0430\u043c\u0430 \u0436\u043e\u049b',
      'notifications_mark_read':
          '\u041e\u049b\u044b\u043b\u0493\u0430\u043d \u0434\u0435\u043f \u0431\u0435\u043b\u0433\u0456\u043b\u0435\u0443',
      'notifications_read_action': '\u041e\u049b\u0443',
      'notifications_delete': '\u04e8\u0448\u0456\u0440\u0443',
      'notifications_unread': '\u0416\u0430\u04a3\u0430',
    },
    'fr': {
      'auth_title_login': 'Connexion',
      'auth_title_register': 'Creer un compte',
      'auth_subtitle_login': 'Bon retour',
      'auth_subtitle_register': 'Creez un compte etudiant',
      'full_name': 'Nom complet',
      'email': 'E-mail',
      'password': 'Mot de passe',
      'confirm_password': 'Confirmer le mot de passe',
      'sign_in': 'Se connecter',
      'create_account': 'Creer un compte',
      'have_account': 'J ai deja un compte',
      'create_new_account': 'Creer un nouveau compte',
      'forgot_password': 'Mot de passe oublie ?',
      'reset_password': 'Reinitialiser le mot de passe',
      'reset_desc':
          'Nous enverrons un lien de reinitialisation a votre e-mail.',
      'send_reset': 'Envoyer l e-mail de reinitialisation',
      'language': 'Langue',
      'language_ru': 'Russe',
      'language_en': 'Anglais',
      'language_kk': 'Kazakh',
      'language_fr': 'Francais',
      'language_de': 'Allemand',
      'language_hi': 'Hindi',
      'language_zh': 'Chinois',
      'settings': 'Parametres',
      'password_strength_weak': 'Mot de passe faible',
      'password_strength_medium': 'Mot de passe moyen',
      'password_strength_strong': 'Mot de passe fort',
      'password_hint': 'Au moins 8 caracteres, lettres et chiffres',
      'passwords_mismatch': 'Les mots de passe ne correspondent pas',
      'email_required': 'L e-mail est requis',
      'password_required': 'Le mot de passe est requis',
      'name_required': 'Le nom complet est requis',
      'auth_error': 'Echec de connexion. Verifiez l e-mail et le mot de passe.',
      'reset_sent':
          'E-mail de reinitialisation envoye. Verifiez votre boite de reception.',
      'profile_title': 'Profil',
      'save_profile': 'Enregistrer',
      'profile_edit': 'Modifier',
      'role_label': 'Role',
      'contact_info': 'Contact',
      'account_info': 'Compte',
      'preferences': 'Preferences',
      'notifications': 'Notifications',
      'schedule_updates': 'Mises a jour de l emploi du temps',
      'request_updates': 'Mises a jour des demandes',
      'security': 'Securite',
      'logout': 'Se deconnecter',
      'birth_date_label': 'Date de naissance (YYYY-MM-DD)',
      'group_label': 'Groupe',
      'phone_label': 'Telephone',
      'teacher_name_label': 'Nom de l enseignant',
      'profile_saved': 'Profil mis a jour.',
      'birth_date_invalid':
          'La date de naissance doit etre au format YYYY-MM-DD.',
      'profile_stats_group': 'Groupe',
      'profile_stats_role': 'Role',
      'profile_stats_phone': 'Telephone',
      'group_not_set': 'Non defini',
      'teacher_not_set': 'Non defini',
      'reset_password_action': 'Reinitialiser le mot de passe',
      'notifications_title': 'Notifications',
      'notifications_empty': 'Aucune notification pour le moment',
      'notifications_mark_read': 'Marquer comme lu',
      'notifications_read_action': 'Lire',
      'notifications_delete': 'Supprimer',
      'notifications_unread': 'Nouveau',
    },
    'de': {
      'auth_title_login': 'Anmelden',
      'auth_title_register': 'Konto erstellen',
      'auth_subtitle_login': 'Willkommen zuruck',
      'auth_subtitle_register': 'Erstelle ein Studenten-Konto',
      'full_name': 'Vollstandiger Name',
      'email': 'E-Mail',
      'password': 'Passwort',
      'confirm_password': 'Passwort bestatigen',
      'sign_in': 'Anmelden',
      'create_account': 'Konto erstellen',
      'have_account': 'Ich habe bereits ein Konto',
      'create_new_account': 'Neues Konto erstellen',
      'forgot_password': 'Passwort vergessen?',
      'reset_password': 'Passwort zurucksetzen',
      'reset_desc': 'Wir senden einen Link zum Zurucksetzen an deine E-Mail.',
      'send_reset': 'Zurucksetzungs-E-Mail senden',
      'language': 'Sprache',
      'language_ru': 'Russisch',
      'language_en': 'Englisch',
      'language_kk': 'Kasachisch',
      'language_fr': 'Franzosisch',
      'language_de': 'Deutsch',
      'language_hi': 'Hindi',
      'language_zh': 'Chinesisch',
      'settings': 'Einstellungen',
      'password_strength_weak': 'Schwaches Passwort',
      'password_strength_medium': 'Mittleres Passwort',
      'password_strength_strong': 'Starkes Passwort',
      'password_hint': 'Mindestens 8 Zeichen, Buchstaben und Zahlen',
      'passwords_mismatch': 'Passworter stimmen nicht uberein',
      'email_required': 'E-Mail ist erforderlich',
      'password_required': 'Passwort ist erforderlich',
      'name_required': 'Vollstandiger Name ist erforderlich',
      'auth_error': 'Anmeldung fehlgeschlagen. E-Mail und Passwort prufen.',
      'reset_sent': 'Zurucksetzungs-E-Mail gesendet. Posteingang prufen.',
      'profile_title': 'Profil',
      'save_profile': 'Speichern',
      'profile_edit': 'Bearbeiten',
      'role_label': 'Rolle',
      'contact_info': 'Kontakt',
      'account_info': 'Konto',
      'preferences': 'Einstellungen',
      'notifications': 'Benachrichtigungen',
      'schedule_updates': 'Stundenplan-Updates',
      'request_updates': 'Anfrage-Updates',
      'security': 'Sicherheit',
      'logout': 'Abmelden',
      'birth_date_label': 'Geburtsdatum (YYYY-MM-DD)',
      'group_label': 'Gruppe',
      'phone_label': 'Telefon',
      'teacher_name_label': 'Name des Lehrers',
      'profile_saved': 'Profil aktualisiert.',
      'birth_date_invalid': 'Geburtsdatum muss im Format YYYY-MM-DD sein.',
      'profile_stats_group': 'Gruppe',
      'profile_stats_role': 'Rolle',
      'profile_stats_phone': 'Telefon',
      'group_not_set': 'Nicht gesetzt',
      'teacher_not_set': 'Nicht gesetzt',
      'reset_password_action': 'Passwort zurucksetzen',
      'notifications_title': 'Benachrichtigungen',
      'notifications_empty': 'Noch keine Benachrichtigungen',
      'notifications_mark_read': 'Als gelesen markieren',
      'notifications_read_action': 'Lesen',
      'notifications_delete': 'Loschen',
      'notifications_unread': 'Neu',
    },
    'hi': {
      'auth_title_login': '\u0932\u0949\u0917 \u0907\u0928',
      'auth_title_register':
          '\u0916\u093e\u0924\u093e \u092c\u0928\u093e\u090f\u0902',
      'auth_subtitle_login':
          '\u0935\u093e\u092a\u0938 \u0938\u094d\u0935\u093e\u0917\u0924 \u0939\u0948',
      'auth_subtitle_register':
          '\u090f\u0915 \u091b\u093e\u0924\u094d\u0930 \u0916\u093e\u0924\u093e \u092c\u0928\u093e\u090f\u0902',
      'full_name': '\u092a\u0942\u0930\u093e \u0928\u093e\u092e',
      'email': '\u0908\u092e\u0947\u0932',
      'password': '\u092a\u093e\u0938\u0935\u0930\u094d\u0921',
      'confirm_password':
          '\u092a\u093e\u0938\u0935\u0930\u094d\u0921 \u0915\u0940 \u092a\u0941\u0937\u094d\u091f\u093f \u0915\u0930\u0947\u0902',
      'sign_in': '\u0932\u0949\u0917 \u0907\u0928',
      'create_account':
          '\u0916\u093e\u0924\u093e \u092c\u0928\u093e\u090f\u0902',
      'have_account':
          '\u092e\u0947\u0930\u0947 \u092a\u093e\u0938 \u092a\u0939\u0932\u0947 \u0938\u0947 \u0916\u093e\u0924\u093e \u0939\u0948',
      'create_new_account':
          '\u0928\u092f\u093e \u0916\u093e\u0924\u093e \u092c\u0928\u093e\u090f\u0902',
      'forgot_password':
          '\u092a\u093e\u0938\u0935\u0930\u094d\u0921 \u092d\u0942\u0932 \u0917\u090f?',
      'reset_password':
          '\u092a\u093e\u0938\u0935\u0930\u094d\u0921 \u0930\u0940\u0938\u0947\u091f \u0915\u0930\u0947\u0902',
      'reset_desc':
          '\u0939\u092e \u0906\u092a\u0915\u0947 \u0908\u092e\u0947\u0932 \u092a\u0930 \u092a\u093e\u0938\u0935\u0930\u094d\u0921 \u0930\u0940\u0938\u0947\u091f \u0932\u093f\u0902\u0915 \u092d\u0947\u091c\u0947\u0902\u0917\u0947\u0964',
      'send_reset':
          '\u0930\u0940\u0938\u0947\u091f \u0908\u092e\u0947\u0932 \u092d\u0947\u091c\u0947\u0902',
      'language': '\u092d\u093e\u0937\u093e',
      'language_ru': '\u0930\u0942\u0938\u0940',
      'language_en': '\u0905\u0902\u0917\u094d\u0930\u0947\u091c\u093c\u0940',
      'language_kk': '\u0915\u091c\u093c\u093e\u0916',
      'language_fr': '\u092b\u093c\u094d\u0930\u0947\u0902\u091a',
      'language_de': '\u091c\u0930\u094d\u092e\u0928',
      'language_hi': '\u0939\u093f\u0902\u0926\u0940',
      'language_zh': '\u091a\u0940\u0928\u0940',
      'settings': '\u0938\u0947\u091f\u093f\u0902\u0917\u094d\u0938',
      'password_strength_weak':
          '\u0915\u092e\u091c\u094b\u0930 \u092a\u093e\u0938\u0935\u0930\u094d\u0921',
      'password_strength_medium':
          '\u092e\u0927\u094d\u092f\u092e \u092a\u093e\u0938\u0935\u0930\u094d\u0921',
      'password_strength_strong':
          '\u092e\u091c\u092c\u0942\u0924 \u092a\u093e\u0938\u0935\u0930\u094d\u0921',
      'password_hint':
          '\u0915\u092e \u0938\u0947 \u0915\u092e 8 \u0905\u0915\u094d\u0937\u0930, \u0905\u0915\u094d\u0937\u0930 \u0914\u0930 \u0905\u0902\u0915',
      'passwords_mismatch':
          '\u092a\u093e\u0938\u0935\u0930\u094d\u0921 \u092e\u0947\u0932 \u0928\u0939\u0940\u0902 \u0916\u093e\u0924\u0947',
      'email_required':
          '\u0908\u092e\u0947\u0932 \u0906\u0935\u0936\u094d\u092f\u0915 \u0939\u0948',
      'password_required':
          '\u092a\u093e\u0938\u0935\u0930\u094d\u0921 \u0906\u0935\u0936\u094d\u092f\u0915 \u0939\u0948',
      'name_required':
          '\u092a\u0942\u0930\u093e \u0928\u093e\u092e \u0906\u0935\u0936\u094d\u092f\u0915 \u0939\u0948',
      'auth_error':
          '\u0932\u0949\u0917 \u0907\u0928 \u0935\u093f\u092b\u0932 \u0930\u0939\u093e\u0964 \u0908\u092e\u0947\u0932 \u0914\u0930 \u092a\u093e\u0938\u0935\u0930\u094d\u0921 \u091c\u093e\u0902\u091a\u0947\u0902\u0964',
      'reset_sent':
          '\u0930\u0940\u0938\u0947\u091f \u0908\u092e\u0947\u0932 \u092d\u0947\u091c \u0926\u0940 \u0917\u0908\u0964',
      'profile_title': '\u092a\u094d\u0930\u094b\u092b\u093e\u0907\u0932',
      'save_profile': '\u0938\u0947\u0935 \u0915\u0930\u0947\u0902',
      'profile_edit':
          '\u0938\u0902\u092a\u093e\u0926\u093f\u0924 \u0915\u0930\u0947\u0902',
      'role_label': '\u092d\u0942\u092e\u093f\u0915\u093e',
      'contact_info': '\u0938\u0902\u092a\u0930\u094d\u0915',
      'account_info': '\u0916\u093e\u0924\u093e',
      'preferences': '\u092a\u0938\u0902\u0926\u0947\u0902',
      'notifications': '\u0938\u0942\u091a\u0928\u093e\u090f\u0902',
      'schedule_updates':
          '\u0938\u092e\u092f\u0938\u093e\u0930\u0923\u0940 \u0905\u092a\u0921\u0947\u091f',
      'request_updates':
          '\u0905\u0928\u0941\u0930\u094b\u0927 \u0905\u092a\u0921\u0947\u091f',
      'security': '\u0938\u0941\u0930\u0915\u094d\u0937\u093e',
      'logout': '\u0932\u0949\u0917 \u0906\u0909\u091f',
      'birth_date_label':
          '\u091c\u0928\u094d\u092e \u0924\u093f\u0925\u093f (YYYY-MM-DD)',
      'group_label': '\u0917\u094d\u0930\u0941\u092a',
      'phone_label': '\u092b\u094b\u0928',
      'teacher_name_label':
          '\u0936\u093f\u0915\u094d\u0937\u0915 \u0915\u093e \u0928\u093e\u092e',
      'profile_saved':
          '\u092a\u094d\u0930\u094b\u092b\u093e\u0907\u0932 \u0905\u092a\u0921\u0947\u091f \u0939\u094b \u0917\u0908\u0964',
      'birth_date_invalid':
          '\u091c\u0928\u094d\u092e \u0924\u093f\u0925\u093f YYYY-MM-DD \u092b\u0949\u0930\u094d\u092e\u0948\u091f \u092e\u0947\u0902 \u0939\u094b\u0928\u0940 \u091a\u093e\u0939\u093f\u090f\u0964',
      'profile_stats_group': '\u0917\u094d\u0930\u0941\u092a',
      'profile_stats_role': '\u092d\u0942\u092e\u093f\u0915\u093e',
      'profile_stats_phone': '\u092b\u094b\u0928',
      'group_not_set': '\u0938\u0947\u091f \u0928\u0939\u0940\u0902',
      'teacher_not_set': '\u0938\u0947\u091f \u0928\u0939\u0940\u0902',
      'reset_password_action':
          '\u092a\u093e\u0938\u0935\u0930\u094d\u0921 \u0930\u0940\u0938\u0947\u091f \u0915\u0930\u0947\u0902',
      'notifications_title': '\u0938\u0942\u091a\u0928\u093e\u090f\u0902',
      'notifications_empty':
          '\u0905\u092d\u0940 \u0915\u094b\u0908 \u0938\u0942\u091a\u0928\u093e \u0928\u0939\u0940\u0902 \u0939\u0948',
      'notifications_mark_read':
          '\u092a\u0922\u093c\u093e \u0939\u0941\u0906 \u091a\u093f\u0939\u094d\u0928\u093f\u0924 \u0915\u0930\u0947\u0902',
      'notifications_read_action': '\u092a\u0922\u093c\u0947\u0902',
      'notifications_delete': '\u0939\u091f\u093e\u090f\u0902',
      'notifications_unread': '\u0928\u092f\u093e',
    },
    'zh': {
      'auth_title_login': '\u767b\u5f55',
      'auth_title_register': '\u521b\u5efa\u8d26\u53f7',
      'auth_subtitle_login': '\u6b22\u8fce\u56de\u6765',
      'auth_subtitle_register': '\u521b\u5efa\u5b66\u751f\u8d26\u53f7',
      'full_name': '\u59d3\u540d',
      'email': '\u90ae\u7bb1',
      'password': '\u5bc6\u7801',
      'confirm_password': '\u786e\u8ba4\u5bc6\u7801',
      'sign_in': '\u767b\u5f55',
      'create_account': '\u521b\u5efa\u8d26\u53f7',
      'have_account': '\u6211\u5df2\u7ecf\u6709\u8d26\u53f7',
      'create_new_account': '\u521b\u5efa\u65b0\u8d26\u53f7',
      'forgot_password': '\u5fd8\u8bb0\u5bc6\u7801\uff1f',
      'reset_password': '\u91cd\u7f6e\u5bc6\u7801',
      'reset_desc':
          '\u6211\u4eec\u4f1a\u5411\u60a8\u7684\u90ae\u7bb1\u53d1\u9001\u5bc6\u7801\u91cd\u7f6e\u94fe\u63a5\u3002',
      'send_reset': '\u53d1\u9001\u91cd\u7f6e\u90ae\u4ef6',
      'language': '\u8bed\u8a00',
      'language_ru': '\u4fc4\u8bed',
      'language_en': '\u82f1\u8bed',
      'language_kk': '\u54c8\u8428\u514b\u8bed',
      'language_fr': '\u6cd5\u8bed',
      'language_de': '\u5fb7\u8bed',
      'language_hi': '\u5370\u5730\u8bed',
      'language_zh': '\u4e2d\u6587',
      'settings': '\u8bbe\u7f6e',
      'password_strength_weak': '\u5bc6\u7801\u5f31',
      'password_strength_medium': '\u5bc6\u7801\u4e2d\u7b49',
      'password_strength_strong': '\u5bc6\u7801\u5f3a',
      'password_hint':
          '\u81f3\u5c11 8 \u4e2a\u5b57\u7b26\uff0c\u5305\u542b\u5b57\u6bcd\u548c\u6570\u5b57',
      'passwords_mismatch': '\u5bc6\u7801\u4e0d\u5339\u914d',
      'email_required': '\u90ae\u7bb1\u4e3a\u5fc5\u586b\u9879',
      'password_required': '\u5bc6\u7801\u4e3a\u5fc5\u586b\u9879',
      'name_required': '\u59d3\u540d\u4e3a\u5fc5\u586b\u9879',
      'auth_error':
          '\u767b\u5f55\u5931\u8d25\uff0c\u8bf7\u68c0\u67e5\u90ae\u7bb1\u548c\u5bc6\u7801\u3002',
      'reset_sent':
          '\u5df2\u53d1\u9001\u91cd\u7f6e\u90ae\u4ef6\uff0c\u8bf7\u67e5\u6536\u3002',
      'profile_title': '\u4e2a\u4eba\u8d44\u6599',
      'save_profile': '\u4fdd\u5b58',
      'profile_edit': '\u7f16\u8f91',
      'role_label': '\u89d2\u8272',
      'contact_info': '\u8054\u7cfb\u65b9\u5f0f',
      'account_info': '\u8d26\u53f7',
      'preferences': '\u504f\u597d',
      'notifications': '\u901a\u77e5',
      'schedule_updates': '\u8bfe\u8868\u66f4\u65b0',
      'request_updates': '\u7533\u8bf7\u66f4\u65b0',
      'security': '\u5b89\u5168',
      'logout': '\u9000\u51fa\u767b\u5f55',
      'birth_date_label': '\u51fa\u751f\u65e5\u671f (YYYY-MM-DD)',
      'group_label': '\u5c0f\u7ec4',
      'phone_label': '\u7535\u8bdd',
      'teacher_name_label': '\u6559\u5e08\u59d3\u540d',
      'profile_saved': '\u4e2a\u4eba\u8d44\u6599\u5df2\u66f4\u65b0\u3002',
      'birth_date_invalid':
          '\u51fa\u751f\u65e5\u671f\u5fc5\u987b\u4e3a YYYY-MM-DD \u683c\u5f0f\u3002',
      'profile_stats_group': '\u5c0f\u7ec4',
      'profile_stats_role': '\u89d2\u8272',
      'profile_stats_phone': '\u7535\u8bdd',
      'group_not_set': '\u672a\u8bbe\u7f6e',
      'teacher_not_set': '\u672a\u8bbe\u7f6e',
      'reset_password_action': '\u91cd\u7f6e\u5bc6\u7801',
      'notifications_title': '\u901a\u77e5',
      'notifications_empty': '\u6682\u65e0\u901a\u77e5',
      'notifications_mark_read': '\u6807\u8bb0\u4e3a\u5df2\u8bfb',
      'notifications_read_action': '\u5df2\u8bfb',
      'notifications_delete': '\u5220\u9664',
      'notifications_unread': '\u65b0',
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

const String kTeacherGroupRequestType =
    '\u0417\u0430\u043f\u0440\u043e\u0441 \u043d\u0430 \u043f\u0440\u0435\u043f\u043e\u0434\u0430\u0432\u0430\u043d\u0438\u0435 \u0433\u0440\u0443\u043f\u043f\u044b';

const List<String> kRequestStatuses = [
  '\u041e\u0442\u043f\u0440\u0430\u0432\u043b\u0435\u043d\u0430',
  '\u041d\u0430 \u0440\u0430\u0441\u0441\u043c\u043e\u0442\u0440\u0435\u043d\u0438\u0438',
  '\u041e\u0442\u043a\u043b\u043e\u043d\u0435\u043d\u0430',
  '\u0412 \u0440\u0430\u0431\u043e\u0442\u0435',
  '\u0413\u043e\u0442\u043e\u0432\u0430',
];

String _resolvedApiBaseUrl() {
  final trimmed = apiBaseUrl.trim();
  final uri = Uri.tryParse(trimmed);
  if (uri == null) {
    return trimmed;
  }
  final isLocalhost = uri.host == 'localhost' || uri.host == '127.0.0.1';
  if (!kIsWeb &&
      defaultTargetPlatform == TargetPlatform.android &&
      isLocalhost) {
    final mapped = uri.replace(host: '10.0.2.2');
    return mapped.toString().replaceFirst(RegExp(r'/+$'), '');
  }
  return trimmed.replaceFirst(RegExp(r'/+$'), '');
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  } catch (_) {}
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
  await _initLocalNotifications();
  final state = AppState(_resolvedApiBaseUrl());
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
      'notify_schedule': user.notifySchedule,
      'notify_requests': user.notifyRequests,
      'student_group': user.studentGroup,
      'teacher_name': user.teacherName,
      'child_full_name': user.childFullName,
      'parent_student_id': user.parentStudentId,
      'admin_permissions': user.adminPermissions,
      'is_approved': user.isApproved,
      'approved_at': user.approvedAt?.toIso8601String(),
      'approved_by': user.approvedBy,
      'created_at': user.createdAt?.toIso8601String(),
      'updated_at': user.updatedAt?.toIso8601String(),
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
  int? _clockDriftSeconds;

  ApiClient get client => _client;
  String? get token => _token;
  UserProfile? get user => _user;
  bool get isAuthenticated => _token != null && _user != null;
  bool get isReady => _isReady;
  String? get deviceId => _deviceId;
  Locale get locale => _locale;
  int? get clockDriftSeconds => _clockDriftSeconds;

  Future<void> _syncDeviceClock() async {
    try {
      final data = await _client.syncDeviceTime();
      final drift = data['drift_seconds'];
      if (drift is num) {
        _clockDriftSeconds = drift.toInt();
      }
    } catch (_) {}
  }

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
      await _syncDeviceClock();
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

  Future<bool> register({
    required String fullName,
    required String email,
    required String password,
    required String role,
    String? studentGroup,
    String? teacherName,
    String? childFullName,
    int? parentStudentId,
  }) async {
    final response = await _client.register(
      fullName: fullName,
      email: email,
      password: password,
      role: role,
      studentGroup: studentGroup,
      teacherName: teacherName,
      childFullName: childFullName,
      parentStudentId: parentStudentId,
      deviceId: _deviceId,
    );
    if (response.auth != null) {
      _setAuth(response.auth!);
      return true;
    }
    return false;
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
    if (_token != null) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_userKey, jsonEncode(_userToJson(updated)));
    }
    notifyListeners();
    return updated;
  }

  void _setAuth(AuthResponse response) {
    _token = response.accessToken;
    _user = response.user;
    _client = ApiClient(baseUrl: baseUrl, token: response.accessToken);
    _persistAuth(response);
    notifyListeners();
    unawaited(_syncDeviceClock());
    unawaited(_setupPush());
  }
}

class AppStateScope extends InheritedNotifier<AppState> {
  const AppStateScope({
    super.key,
    required AppState super.notifier,
    required super.child,
  });

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
              error: kError,
            ),
            useMaterial3: true,
            scaffoldBackgroundColor: kAppBackground,
            cardTheme: CardThemeData(
              color: kCardSurface,
              elevation: 0.8,
              shadowColor: Colors.black.withValues(alpha: 0.05),
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
  final _groupController = TextEditingController();
  final _teacherNameController = TextEditingController();
  final _childNameController = TextEditingController();
  bool _isRegister = false;
  bool _isLoading = false;
  bool _showPassword = false;
  bool _showConfirm = false;
  String? _errorMessage;
  String? _noticeMessage;
  String _registerRole = 'student';

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _confirmController.dispose();
    _nameController.dispose();
    _groupController.dispose();
    _teacherNameController.dispose();
    _childNameController.dispose();
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
    final localeCode = AppStateScope.of(context).locale.languageCode;
    final isRu = localeCode == 'ru';
    if (!RegExp(r'[A-Z]').hasMatch(text)) {
      return isRu
          ? '\u0414\u043e\u0431\u0430\u0432\u044c\u0442\u0435 \u0437\u0430\u0433\u043b\u0430\u0432\u043d\u0443\u044e \u0431\u0443\u043a\u0432\u0443.'
          : 'Add an uppercase letter.';
    }
    if (!RegExp(r'[a-z]').hasMatch(text)) {
      return isRu
          ? '\u0414\u043e\u0431\u0430\u0432\u044c\u0442\u0435 \u0441\u0442\u0440\u043e\u0447\u043d\u0443\u044e \u0431\u0443\u043a\u0432\u0443.'
          : 'Add a lowercase letter.';
    }
    if (!RegExp(r'[0-9]').hasMatch(text)) {
      return isRu
          ? '\u0414\u043e\u0431\u0430\u0432\u044c\u0442\u0435 \u0446\u0438\u0444\u0440\u0443.'
          : 'Add a number.';
    }
    return null;
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    setState(() {
      _errorMessage = null;
      _noticeMessage = null;
    });
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final state = AppStateScope.of(context);
    setState(() => _isLoading = true);
    try {
      if (_isRegister) {
        final authed = await state.register(
          fullName: _nameController.text.trim(),
          email: _emailController.text.trim(),
          password: _passwordController.text,
          role: _registerRole,
          studentGroup: _registerRole == 'student'
              ? _groupController.text.trim()
              : null,
          teacherName: _registerRole == 'teacher'
              ? _teacherNameController.text.trim()
              : null,
          childFullName: _registerRole == 'parent'
              ? _childNameController.text.trim()
              : null,
        );
        if (!authed && mounted) {
          setState(() {
            _noticeMessage =
                AppStateScope.of(context).locale.languageCode == 'ru'
                ? 'Аккаунт создан. Ожидайте подтверждения администратора.'
                : 'Account created. Wait for admin approval.';
            _isRegister = false;
          });
        }
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
    pushAdaptivePage<void>(
      context,
      ResetPasswordPage(initialEmail: _emailController.text.trim()),
    );
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
                                if (value == null || value.trim().isEmpty) {
                                  return l10n.t('name_required');
                                }
                                return null;
                              },
                              onFieldSubmitted: (_) =>
                                  FocusScope.of(context).nextFocus(),
                            ),
                          if (_isRegister) const SizedBox(height: 12),
                          if (_isRegister)
                            DropdownButtonFormField<String>(
                              initialValue: _registerRole,
                              decoration: InputDecoration(
                                labelText:
                                    AppStateScope.of(
                                          context,
                                        ).locale.languageCode ==
                                        'ru'
                                    ? 'Роль'
                                    : 'Role',
                              ),
                              items: [
                                DropdownMenuItem(
                                  value: 'student',
                                  child: Text(
                                    AppStateScope.of(
                                              context,
                                            ).locale.languageCode ==
                                            'ru'
                                        ? 'Студент'
                                        : 'Student',
                                  ),
                                ),
                                DropdownMenuItem(
                                  value: 'teacher',
                                  child: Text(
                                    AppStateScope.of(
                                              context,
                                            ).locale.languageCode ==
                                            'ru'
                                        ? 'Преподаватель'
                                        : 'Teacher',
                                  ),
                                ),
                                DropdownMenuItem(
                                  value: 'parent',
                                  child: Text(
                                    AppStateScope.of(
                                              context,
                                            ).locale.languageCode ==
                                            'ru'
                                        ? 'Родитель'
                                        : 'Parent',
                                  ),
                                ),
                              ],
                              onChanged: (value) {
                                if (value == null) return;
                                setState(() => _registerRole = value);
                              },
                            ),
                          if (_isRegister) const SizedBox(height: 12),
                          if (_isRegister && _registerRole == 'student')
                            TextFormField(
                              controller: _groupController,
                              textInputAction: TextInputAction.next,
                              decoration: InputDecoration(
                                labelText:
                                    AppStateScope.of(
                                          context,
                                        ).locale.languageCode ==
                                        'ru'
                                    ? 'Группа'
                                    : 'Group',
                              ),
                              validator: (value) {
                                if (!_isRegister ||
                                    _registerRole != 'student') {
                                  return null;
                                }
                                if (value == null || value.trim().isEmpty) {
                                  return AppStateScope.of(
                                            context,
                                          ).locale.languageCode ==
                                          'ru'
                                      ? 'Укажите группу.'
                                      : 'Group is required.';
                                }
                                return null;
                              },
                              onFieldSubmitted: (_) =>
                                  FocusScope.of(context).nextFocus(),
                            ),
                          if (_isRegister && _registerRole == 'student')
                            const SizedBox(height: 12),
                          if (_isRegister && _registerRole == 'teacher')
                            TextFormField(
                              controller: _teacherNameController,
                              textInputAction: TextInputAction.next,
                              decoration: InputDecoration(
                                labelText:
                                    AppStateScope.of(
                                          context,
                                        ).locale.languageCode ==
                                        'ru'
                                    ? 'ФИО преподавателя (для журнала)'
                                    : 'Teacher name (for journal)',
                              ),
                              validator: (value) {
                                if (!_isRegister ||
                                    _registerRole != 'teacher') {
                                  return null;
                                }
                                if (value == null || value.trim().isEmpty) {
                                  return AppStateScope.of(
                                            context,
                                          ).locale.languageCode ==
                                          'ru'
                                      ? 'Укажите ФИО преподавателя.'
                                      : 'Teacher name is required.';
                                }
                                return null;
                              },
                              onFieldSubmitted: (_) =>
                                  FocusScope.of(context).nextFocus(),
                            ),
                          if (_isRegister && _registerRole == 'teacher')
                            const SizedBox(height: 12),
                          if (_isRegister && _registerRole == 'parent')
                            TextFormField(
                              controller: _childNameController,
                              textInputAction: TextInputAction.next,
                              decoration: InputDecoration(
                                labelText:
                                    AppStateScope.of(
                                          context,
                                        ).locale.languageCode ==
                                        'ru'
                                    ? 'ФИО ребёнка'
                                    : 'Child full name',
                              ),
                              validator: (value) {
                                if (!_isRegister || _registerRole != 'parent') {
                                  return null;
                                }
                                if (value == null || value.trim().isEmpty) {
                                  return AppStateScope.of(
                                            context,
                                          ).locale.languageCode ==
                                          'ru'
                                      ? 'Укажите ФИО ребёнка.'
                                      : 'Child full name is required.';
                                }
                                return null;
                              },
                              onFieldSubmitted: (_) =>
                                  FocusScope.of(context).nextFocus(),
                            ),
                          if (_isRegister && _registerRole == 'parent')
                            const SizedBox(height: 12),
                          TextFormField(
                            controller: _emailController,
                            keyboardType: TextInputType.emailAddress,
                            textInputAction: TextInputAction.next,
                            decoration: InputDecoration(
                              labelText: l10n.t('email'),
                            ),
                            validator: (value) {
                              if (value == null || value.trim().isEmpty) {
                                return l10n.t('email_required');
                              }
                              if (!value.contains('@')) {
                                return l10n.t('email_required');
                              }
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
                            onFieldSubmitted: (_) {
                              if (_isRegister) {
                                FocusScope.of(context).nextFocus();
                                return;
                              }
                              _submit();
                            },
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
                                if (value == null || value.isEmpty) {
                                  return 'Confirm your password';
                                }
                                if (value != _passwordController.text) {
                                  return l10n.t('passwords_mismatch');
                                }
                                return null;
                              },
                              onFieldSubmitted: (_) => _submit(),
                            ),
                          ],
                          const SizedBox(height: 16),
                          if (_noticeMessage != null)
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: kAccentSuccess.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Row(
                                children: [
                                  const Icon(
                                    Icons.check_circle_outline,
                                    color: kAccentSuccess,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      _noticeMessage!,
                                      style: const TextStyle(
                                        color: kAccentSuccess,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          if (_noticeMessage != null)
                            const SizedBox(height: 12),
                          if (_errorMessage != null)
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: kError.withValues(alpha: 0.12),
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
  const ResetPasswordPage({super.key, this.initialEmail});

  final String? initialEmail;

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
  void initState() {
    super.initState();
    final initial = widget.initialEmail?.trim() ?? '';
    if (initial.isNotEmpty) {
      _emailController.text = initial;
    }
  }

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
    final email = _emailController.text.trim();
    try {
      final exists = await AppStateScope.of(
        context,
      ).client.checkEmailRegistered(email);
      if (!exists) {
        if (!mounted) return;
        setState(() {
          _success = false;
          _message = AppStateScope.of(context).locale.languageCode == 'ru'
              ? 'Аккаунт с такой почтой не найден.'
              : 'No account is registered with this email.';
        });
        return;
      }
      await FirebaseAuth.instance.sendPasswordResetEmail(email: email);
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
          const SizedBox(height: 8),
          Text(
            AppStateScope.of(context).locale.languageCode == 'ru'
                ? 'Введите почту, привязанную к вашему аккаунту.'
                : 'Enter the email linked to your account.',
            style: TextStyle(color: kSecondaryText, fontSize: 12),
          ),
          const SizedBox(height: 16),
          Form(
            key: _formKey,
            child: TextFormField(
              controller: _emailController,
              keyboardType: TextInputType.emailAddress,
              decoration: InputDecoration(labelText: l10n.t('email')),
              validator: (value) {
                if (value == null || value.trim().isEmpty) {
                  return l10n.t('email_required');
                }
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
                color: (_success ? kAccentSuccess : kError).withValues(
                  alpha: 0.12,
                ),
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

Widget _buildMakeupFeaturePage(BuildContext context) {
  final state = AppStateScope.of(context);
  final user = state.user;
  if (user == null) return const SizedBox.shrink();
  return MakeupWorkspacePage(
    client: state.client,
    currentUser: user,
    locale: state.locale,
    baseUrl: state.baseUrl,
    errorText: humanizeError,
  );
}

Widget _buildAdminFeaturePage(BuildContext context) {
  final state = AppStateScope.of(context);
  final user = state.user;
  if (user == null) return const SizedBox.shrink();
  return AdminWorkspacePage(
    client: state.client,
    currentUser: user,
    locale: state.locale,
    baseUrl: state.baseUrl,
    errorText: humanizeError,
  );
}

Widget _buildAnalyticsFeaturePage(BuildContext context) {
  final state = AppStateScope.of(context);
  final user = state.user;
  if (user == null) return const SizedBox.shrink();
  return AnalyticsWorkspacePage(
    client: state.client,
    currentUser: user,
    locale: state.locale,
    errorText: humanizeError,
  );
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
        id: 'admin_panel',
        title: 'Admin panel',
        icon: Icons.admin_panel_settings_outlined,
        builder: _buildAdminFeaturePage,
      ),
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
        builder: _buildAnalyticsFeaturePage,
      ),
      FeatureDefinition(
        id: 'news',
        title: 'News feed',
        icon: Icons.dynamic_feed,
        builder: (context) => const NewsFeedPage(canEdit: true),
      ),
      FeatureDefinition(
        id: 'makeup',
        title: 'Makeups',
        icon: Icons.assignment_late_outlined,
        builder: _buildMakeupFeaturePage,
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
        id: 'makeup',
        title: 'Makeups',
        icon: Icons.assignment_late_outlined,
        builder: _buildMakeupFeaturePage,
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
    subtitle: 'Journals and feed',
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
        builder: _buildAnalyticsFeaturePage,
      ),
      FeatureDefinition(
        id: 'news',
        title: 'News feed',
        icon: Icons.dynamic_feed,
        builder: (context) => const NewsFeedPage(canEdit: false),
      ),
      FeatureDefinition(
        id: 'makeup',
        title: 'Makeups',
        icon: Icons.assignment_late_outlined,
        builder: _buildMakeupFeaturePage,
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
  int _unreadNotifications = 0;
  int _totalNotifications = 0;
  Timer? _notificationsTimer;
  static const List<String> _navFeatureOrder = <String>[
    'news',
    'schedule',
    'grades',
    'attendance',
    'analytics',
    'exams',
    'makeup',
    'requests',
    'admin_panel',
    'profile',
  ];

  @override
  void initState() {
    super.initState();
    _restoreTab();
    _refreshUnreadNotifications();
    _notificationsTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!mounted) return;
      _refreshUnreadNotifications();
    });
  }

  @override
  void dispose() {
    _notificationsTimer?.cancel();
    super.dispose();
  }

  String _tabKey() => 'home_tab_${widget.role.id}';

  Future<void> _restoreTab() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getInt(_tabKey());
    if (!mounted) return;
    setState(() {
      if (saved != null && saved >= 0) {
        _index = saved;
      }
    });
  }

  Future<void> _saveTab(int value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_tabKey(), value);
  }

  void _setIndex(int value) {
    if (_index == value) return;
    setState(() => _index = value);
    _saveTab(value);
  }

  void _openFeatureById(String featureId) {
    final tabs = _buildTabs();
    final target = tabs.indexWhere((item) => item.id == featureId);
    if (target >= 0) {
      _setIndex(target);
    }
  }

  Future<void> _openNotifications() async {
    await pushAdaptivePage<void>(context, const NotificationsPage());
    if (!mounted) return;
    await _refreshUnreadNotifications();
  }

  Future<void> _refreshUnreadNotifications() async {
    try {
      final rows = await AppStateScope.of(
        context,
      ).client.listNotifications(limit: 50);
      if (!mounted) return;
      setState(() {
        _totalNotifications = rows.length;
        _unreadNotifications = rows.where((item) => !item.isRead).length;
      });
    } catch (_) {}
  }

  Widget _buildNotificationButton() {
    final visibleCount = _unreadNotifications > 0
        ? _unreadNotifications
        : _totalNotifications;
    final icon = IconButton(
      onPressed: _openNotifications,
      icon: const Icon(Icons.notifications_none),
      tooltip: translateEnglishUi(
        AppStateScope.of(context).locale.languageCode,
        'Notifications',
      ),
    );
    if (visibleCount <= 0) {
      return icon;
    }
    return Stack(
      clipBehavior: Clip.none,
      children: [
        icon,
        Positioned(
          right: 6,
          top: 6,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
            decoration: BoxDecoration(
              color: Colors.red,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              visibleCount > 99 ? '99+' : '$visibleCount',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 10,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ],
    );
  }

  bool _isNativeDesktop() {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.linux;
  }

  DeviceCanvas _resolveCanvas() {
    if (kIsWeb) {
      return DeviceCanvas.web;
    }
    if (_isNativeDesktop()) {
      return DeviceCanvas.desktop;
    }
    return DeviceCanvas.mobile;
  }

  String _localizedFeatureTitle(FeatureDefinition feature, String localeCode) {
    switch (feature.id) {
      case 'schedule':
        return trTextByCode(localeCode, 'Расписание', 'Schedule');
      case 'attendance':
        return trTextByCode(localeCode, 'Посещаемость', 'Attendance');
      case 'grades':
        return trTextByCode(localeCode, 'Оценки', 'Grades');
      case 'analytics':
        return trTextByCode(localeCode, 'Аналитика', 'Analytics');
      case 'news':
        return trTextByCode(localeCode, 'Лента новостей', 'News feed');
      case 'requests':
        return trTextByCode(localeCode, 'Заявки', 'Requests');
      case 'makeup':
        return trTextByCode(localeCode, 'Отработки', 'Makeups');
      case 'admin_panel':
        return trTextByCode(localeCode, 'Админ панель', 'Admin panel');
      case 'exams':
        return trTextByCode(localeCode, 'Экзамены', 'Exam grades');
      case 'profile':
        return trTextByCode(localeCode, 'Профиль', 'Profile');
      default:
        return translateEnglishUi(localeCode, feature.title);
    }
  }

  int _featureOrderRank(String id) {
    final idx = _navFeatureOrder.indexOf(id);
    if (idx >= 0) {
      return idx;
    }
    return _navFeatureOrder.length + 100;
  }

  bool _adminCanAccessFeature(UserProfile? user, String featureId) {
    if ((user?.role ?? '') != 'admin') {
      return true;
    }
    final permissions = user?.adminPermissions ?? const <String>[];
    if (permissions.isEmpty || permissions.contains('all')) {
      return true;
    }
    final permissionSet = permissions.map((item) => item.trim()).toSet();
    bool has(String code) => permissionSet.contains(code);
    switch (featureId) {
      case 'admin_panel':
        return has('users_manage') ||
            has('departments_manage') ||
            has('academic_manage') ||
            has('schedule_manage') ||
            has('analytics_view');
      case 'schedule':
        return has('schedule_manage');
      case 'attendance':
      case 'grades':
      case 'exams':
      case 'makeup':
      case 'requests':
      case 'news':
        return has('academic_manage');
      case 'analytics':
        return has('analytics_view');
      case 'profile':
      case 'home':
        return true;
      default:
        return true;
    }
  }

  List<_NavItem> _buildTabs() {
    final localeCode = AppStateScope.of(context).locale.languageCode;
    final currentUser = AppStateScope.of(context).user;
    String t(String ru, String en) => trTextByCode(localeCode, ru, en);
    final added = <String>{};
    final sortedFeatures = [...widget.role.features]
      ..sort((a, b) {
        final rankA = _featureOrderRank(a.id);
        final rankB = _featureOrderRank(b.id);
        if (rankA != rankB) {
          return rankA.compareTo(rankB);
        }
        return a.id.compareTo(b.id);
      });
    final items = <_NavItem>[
      _NavItem(
        id: 'home',
        t('Главная', 'Home'),
        Icons.home,
        (context) => HomeDashboardPage(
          role: widget.role,
          onOpenFeature: _openFeatureById,
        ),
      ),
    ];
    for (final feature in sortedFeatures) {
      if (!added.add(feature.id)) continue;
      if (!_adminCanAccessFeature(currentUser, feature.id)) {
        continue;
      }
      items.add(
        _NavItem(
          id: feature.id,
          _localizedFeatureTitle(feature, localeCode),
          feature.icon,
          feature.builder,
        ),
      );
    }
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
                colors: [
                  color.withValues(alpha: 0.24),
                  const Color(0xFFD9E9D2),
                ],
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
                            selectedTileColor: Colors.white.withValues(
                              alpha: 0.75,
                            ),
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
                            onTap: () => _setIndex(i),
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
                        _buildNotificationButton(),
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
            colors: [color.withValues(alpha: 0.22), kAppBackground],
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
                                  onSelected: (_) => _setIndex(i),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    _buildNotificationButton(),
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
                    constraints: const BoxConstraints(maxWidth: 1560),
                    child: Card(
                      margin: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                      clipBehavior: Clip.antiAlias,
                      child: Column(
                        children: [
                          Container(
                            width: double.infinity,
                            color: color.withValues(alpha: 0.1),
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
        backgroundColor: color.withValues(alpha: 0.16),
        actions: [
          _buildNotificationButton(),
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
          _setIndex(value);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tabs = _buildTabs();
    if (_index < 0 || _index >= tabs.length) {
      _index = 0;
    }
    final color = widget.role.color;
    final title = tabs[_index].title;
    return LayoutBuilder(
      builder: (context, constraints) {
        switch (_resolveCanvas()) {
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
  _NavItem(this.title, this.icon, this.builder, {required this.id});
  final String id;
  final String title;
  final IconData icon;
  final WidgetBuilder builder;
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
  Timer? _autoRefreshTimer;
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
    _loadAdminFiltersForSelectedDate();
    _loadCachedSchedule(forDate: _selectedDate);
    final user = AppStateScope.of(context).user;
    if (user != null && (user.role == 'student' || user.role == 'teacher')) {
      final hasValue =
          (user.role == 'student' &&
              (user.studentGroup ?? '').trim().isNotEmpty) ||
          (user.role == 'teacher' &&
              ((user.teacherName ?? '').trim().isNotEmpty ||
                  user.fullName.trim().isNotEmpty));
      if (hasValue) {
        _loadScheduleForMe();
      }
    }
    _autoRefreshTimer = Timer.periodic(const Duration(seconds: 45), (_) {
      if (!mounted) return;
      _loadLatest();
      _loadAdminFiltersForSelectedDate(silent: true);
      _reloadForSelectedDate(silent: true);
    });
    _initialized = true;
  }

  @override
  void dispose() {
    _autoRefreshTimer?.cancel();
    _groupController.dispose();
    _teacherController.dispose();
    super.dispose();
  }

  List<DateTime> _buildDateRange() {
    final today = DateUtils.dateOnly(DateTime.now());
    final start = today.subtract(const Duration(days: 7));
    final end = today.add(const Duration(days: 3));
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

  String _lessonsSignature(List<ScheduleLesson> items) {
    return items
        .map(
          (item) => [
            item.shift,
            item.period,
            item.time,
            item.audience,
            item.lesson,
            item.groupName,
          ].join('|'),
        )
        .join('||');
  }

  String _lessonType(String lesson) {
    final lower = lesson.toLowerCase();
    if (lower.contains('lab') || lower.contains('\u043b\u0430\u0431')) {
      return 'Lab';
    }
    if (lower.contains('pract') ||
        lower.contains('\u043f\u0440\u0430\u043a\u0442')) {
      return 'Practice';
    }
    if (lower.contains('lec') || lower.contains('\u043b\u0435\u043a')) {
      return 'Lecture';
    }
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
      final oldKey = _latest == null
          ? ''
          : '${_latest!.id}|${_latest!.scheduleDate?.toIso8601String() ?? ''}|${_latest!.uploadedAt.toIso8601String()}';
      final newKey = latest == null
          ? ''
          : '${latest.id}|${latest.scheduleDate?.toIso8601String() ?? ''}|${latest.uploadedAt.toIso8601String()}';
      if (oldKey != newKey) {
        setState(() => _latest = latest);
      }
    } catch (_) {}
  }

  Future<void> _loadAdminFiltersForSelectedDate({bool silent = false}) async {
    final user = AppStateScope.of(context).user;
    if (user?.role != 'admin') return;
    try {
      final client = AppStateScope.of(context).client;
      final groups = await client.listScheduleGroups(at: _selectedDate);
      final teachers = await client.listScheduleTeachers(at: _selectedDate);
      if (!mounted) return;
      final selectedGroup = _groupController.text.trim();
      final selectedTeacher = _teacherController.text.trim();
      final hasGroup = groups.any((item) => item == selectedGroup);
      final hasTeacher = teachers.any((item) => item == selectedTeacher);
      setState(() {
        _groups = groups;
        _teachers = teachers;
        if (selectedGroup.isNotEmpty && !hasGroup) {
          _groupController.clear();
        }
        if (selectedTeacher.isNotEmpty && !hasTeacher) {
          _teacherController.clear();
        }
      });
    } catch (error) {
      if (!mounted || silent) return;
      setState(() {
        _noticeError = true;
        _noticeMessage = humanizeError(error);
      });
    }
  }

  Future<void> _uploadSchedule() async {
    if (_uploading) return;
    final client = AppStateScope.of(context).client;
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
      final uploaded = await client.uploadScheduleBytes(
        filename: file.name,
        bytes: bytes,
      );
      if (!mounted) return;
      setState(() => _latest = uploaded);
      setState(() {
        _noticeError = false;
        _noticeMessage = 'Расписание загружено: ${uploaded.filename}';
      });
      await _loadAdminFiltersForSelectedDate();
      await _reloadForSelectedDate();
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

  Future<void> _loadSchedule({bool silent = false}) async {
    final group = _groupController.text.trim();
    if (group.isEmpty) return;
    if (!silent) {
      setState(() => _loading = true);
    }
    try {
      final data = await AppStateScope.of(
        context,
      ).client.scheduleForGroup(group, at: _selectedDate);
      if (!mounted) return;
      final changed = _lessonsSignature(_lessons) != _lessonsSignature(data);
      if (changed) {
        setState(() => _lessons = data);
        _saveCachedSchedule(forDate: _selectedDate);
      }
    } catch (error) {
      if (!mounted) return;
      if (!silent) {
        setState(() {
          _noticeError = true;
          _noticeMessage =
              'Не удалось загрузить расписание: ${humanizeError(error)}';
        });
      }
    } finally {
      if (!silent && mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _loadScheduleForMe({bool silent = false}) async {
    if (!silent) {
      setState(() => _loading = true);
    }
    try {
      final data = await AppStateScope.of(
        context,
      ).client.scheduleForMe(at: _selectedDate);
      if (!mounted) return;
      final changed = _lessonsSignature(_lessons) != _lessonsSignature(data);
      if (changed) {
        setState(() => _lessons = data);
        _saveCachedSchedule(forDate: _selectedDate);
      }
    } catch (error) {
      if (!mounted) return;
      if (!silent) {
        setState(() {
          _noticeError = true;
          _noticeMessage =
              'Не удалось загрузить расписание: ${humanizeError(error)}';
        });
      }
    } finally {
      if (!silent && mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _loadScheduleForTeacher({bool silent = false}) async {
    final teacher = _teacherController.text.trim();
    if (teacher.isEmpty) return;
    if (!silent) {
      setState(() => _loading = true);
    }
    try {
      final data = await AppStateScope.of(
        context,
      ).client.scheduleForTeacher(teacher, at: _selectedDate);
      if (!mounted) return;
      final changed = _lessonsSignature(_lessons) != _lessonsSignature(data);
      if (changed) {
        setState(() => _lessons = data);
        _saveCachedSchedule(forDate: _selectedDate);
      }
    } catch (error) {
      if (!mounted) return;
      if (!silent) {
        setState(() {
          _noticeError = true;
          _noticeMessage =
              'Не удалось загрузить расписание: ${humanizeError(error)}';
        });
      }
    } finally {
      if (!silent && mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _reloadForSelectedDate({bool silent = false}) async {
    final user = AppStateScope.of(context).user;
    try {
      if (user != null && (user.role == 'student' || user.role == 'teacher')) {
        await _loadScheduleForMe(silent: silent);
        return;
      }
      final group = _groupController.text.trim();
      if (group.isNotEmpty) {
        await _loadSchedule(silent: silent);
        return;
      }
      final teacher = _teacherController.text.trim();
      if (teacher.isNotEmpty) {
        await _loadScheduleForTeacher(silent: silent);
        return;
      }
      if (_lessons.isNotEmpty) {
        setState(() => _lessons = []);
      }
    } catch (error) {
      if (!mounted || silent) return;
      setState(() {
        _noticeError = true;
        _noticeMessage = humanizeError(error);
      });
    }
  }

  Future<void> _onDateSelected(DateTime value) async {
    setState(() => _selectedDate = DateUtils.dateOnly(value));
    await _loadAdminFiltersForSelectedDate(silent: true);
    await _loadCachedSchedule(forDate: _selectedDate);
    await _reloadForSelectedDate();
  }

  String _cacheKey(UserProfile? user) {
    if (user == null) return 'schedule_cache_guest';
    if (user.role == 'student') {
      return 'schedule_cache_student_${user.studentGroup ?? 'none'}';
    }
    if (user.role == 'teacher') {
      final teacherKey = (user.teacherName ?? '').trim().isNotEmpty
          ? user.teacherName!.trim()
          : user.fullName.trim();
      return 'schedule_cache_teacher_${teacherKey.isEmpty ? 'none' : teacherKey}';
    }
    return 'schedule_cache_admin';
  }

  String _cacheKeyForDate(UserProfile? user, DateTime date) {
    final day = DateUtils.dateOnly(date);
    return '${_cacheKey(user)}_${DateFormat('yyyyMMdd').format(day)}';
  }

  Future<void> _loadCachedSchedule({required DateTime forDate}) async {
    final user = AppStateScope.of(context).user;
    final prefs = await SharedPreferences.getInstance();
    final key = _cacheKeyForDate(user, forDate);
    final raw = prefs.getString(key);
    if (raw == null || raw.isEmpty) {
      if (mounted && _lessons.isNotEmpty) {
        setState(() => _lessons = []);
      }
      return;
    }
    try {
      final data = jsonDecode(raw) as List<dynamic>;
      final lessons = data
          .map((item) => ScheduleLesson.fromJson(item as Map<String, dynamic>))
          .toList();
      if (!mounted) return;
      setState(() => _lessons = lessons);
    } catch (_) {}
  }

  Future<void> _saveCachedSchedule({required DateTime forDate}) async {
    final user = AppStateScope.of(context).user;
    final prefs = await SharedPreferences.getInstance();
    final key = _cacheKeyForDate(user, forDate);
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
    final user = AppStateScope.of(context).user;
    final canUpload = user?.role == 'admin';
    final visibleLessons = _lessons;
    final isEmpty = visibleLessons.isEmpty;

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        if (_noticeMessage != null)
          InlineNotice(message: _noticeMessage!, isError: _noticeError),
        if (_noticeMessage != null) const SizedBox(height: 12),
        if (_latest?.scheduleDate != null) ...[
          Text(
            'Актуальный пакет: ${DateFormat('dd.MM.yyyy').format(_latest!.scheduleDate!)}',
            style: TextStyle(color: kSecondaryText),
          ),
          const SizedBox(height: 10),
        ],
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
                          ChoiceChip(
                            selected: _groupController.text.trim() == group,
                            label: Text(group),
                            onSelected: (selected) {
                              if (!selected) {
                                setState(() {
                                  _groupController.clear();
                                  _lessons = [];
                                });
                                return;
                              }
                              _groupController.text = group;
                              _teacherController.clear();
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
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        SizedBox(
                          width: 280,
                          child: TextField(
                            controller: _teacherController,
                            decoration: const InputDecoration(
                              hintText: 'Search teacher',
                              isDense: true,
                            ),
                            onSubmitted: (_) {
                              _groupController.clear();
                              _loadScheduleForTeacher();
                            },
                          ),
                        ),
                        OutlinedButton.icon(
                          onPressed: () {
                            _groupController.clear();
                            _loadScheduleForTeacher();
                          },
                          icon: const Icon(Icons.search),
                          label: const Text('Find'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final teacher in _teachers.take(12))
                          ChoiceChip(
                            selected: _teacherController.text.trim() == teacher,
                            label: Text(teacher),
                            onSelected: (selected) {
                              if (!selected) {
                                setState(() {
                                  _teacherController.clear();
                                  _lessons = [];
                                });
                                return;
                              }
                              _teacherController.text = teacher;
                              _groupController.clear();
                              _loadScheduleForTeacher();
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
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, index) {
              final day = _dateRange[index];
              final isSelected = DateUtils.isSameDay(day, _selectedDate);
              final isToday = DateUtils.isSameDay(day, DateTime.now());
              return InkWell(
                onTap: () => _onDateSelected(day),
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
                                ).withValues(alpha: 0.15),
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
    if (role == 'parent') {
      return const ParentAttendancePage();
    }
    final canEdit = role == 'teacher' || role == 'admin';
    final canManageGroups = role == 'admin';
    return AttendanceJournalPage(
      canEdit: canEdit,
      canManageGroups: canManageGroups,
      client: AppStateScope.of(context).client,
    );
  }
}

class GradesPage extends StatelessWidget {
  const GradesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final role = AppStateScope.of(context).user?.role ?? '';
    if (role == 'parent') {
      return const ParentGradesPage();
    }
    final canEdit = role == 'teacher' || role == 'admin';
    final canManageGroups = role == 'admin';
    return GradesPresetJournalPage(
      canEdit: canEdit,
      canManageGroups: canManageGroups,
      client: AppStateScope.of(context).client,
    );
  }
}

class ParentAttendancePage extends StatefulWidget {
  const ParentAttendancePage({super.key});

  @override
  State<ParentAttendancePage> createState() => _ParentAttendancePageState();
}

class _ParentAttendancePageState extends State<ParentAttendancePage> {
  Future<List<AttendanceRecord>>? _future;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reload();
  }

  Future<void> _reload() async {
    final state = AppStateScope.of(context);
    setState(() {
      _future = state.client.listJournalGroups().then((groups) async {
        if (groups.isEmpty) return const <AttendanceRecord>[];
        return state.client.listAttendance(groups.first);
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final localeCode = AppStateScope.of(context).locale.languageCode;
    final isRu = localeCode == 'ru';
    return ModulePanel(
      title: isRu ? 'Посещаемость ребёнка' : 'Child attendance',
      subtitle: isRu
          ? 'Только записи по подтвержденному ребёнку.'
          : 'Only records for approved child.',
      child: FutureBuilder<List<AttendanceRecord>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: BrandLoadingIndicator());
          }
          if (snapshot.hasError) {
            return InlineNotice(
              message: humanizeError(snapshot.error!),
              isError: true,
            );
          }
          final rows = snapshot.data ?? const <AttendanceRecord>[];
          if (rows.isEmpty) {
            return Text(isRu ? 'Записей пока нет.' : 'No records yet.');
          }
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columns: [
                DataColumn(label: Text(isRu ? 'Дата' : 'Date')),
                DataColumn(label: Text(isRu ? 'Группа' : 'Group')),
                DataColumn(label: Text(isRu ? 'Статус' : 'Status')),
              ],
              rows: rows
                  .map(
                    (item) => DataRow(
                      cells: [
                        DataCell(
                          Text(DateFormat('dd.MM.yyyy').format(item.classDate)),
                        ),
                        DataCell(Text(item.groupName)),
                        DataCell(
                          Text(
                            item.present
                                ? (isRu ? 'Присутствовал' : 'Present')
                                : (isRu ? 'Отсутствовал' : 'Absent'),
                          ),
                        ),
                      ],
                    ),
                  )
                  .toList(),
            ),
          );
        },
      ),
    );
  }
}

class ParentGradesPage extends StatefulWidget {
  const ParentGradesPage({super.key});

  @override
  State<ParentGradesPage> createState() => _ParentGradesPageState();
}

class _ParentGradesPageState extends State<ParentGradesPage> {
  Future<List<GradeRecord>>? _future;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reload();
  }

  Future<void> _reload() async {
    final state = AppStateScope.of(context);
    setState(() {
      _future = state.client.listJournalGroups().then((groups) async {
        if (groups.isEmpty) return const <GradeRecord>[];
        return state.client.listGrades(groups.first);
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final localeCode = AppStateScope.of(context).locale.languageCode;
    final isRu = localeCode == 'ru';
    return ModulePanel(
      title: isRu ? 'Оценки ребёнка' : 'Child grades',
      subtitle: isRu
          ? 'Только оценки подтвержденного ребёнка.'
          : 'Only grades for approved child.',
      child: FutureBuilder<List<GradeRecord>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: BrandLoadingIndicator());
          }
          if (snapshot.hasError) {
            return InlineNotice(
              message: humanizeError(snapshot.error!),
              isError: true,
            );
          }
          final rows = snapshot.data ?? const <GradeRecord>[];
          if (rows.isEmpty) {
            return Text(isRu ? 'Оценок пока нет.' : 'No grades yet.');
          }
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columns: [
                DataColumn(label: Text(isRu ? 'Дата' : 'Date')),
                DataColumn(label: Text(isRu ? 'Группа' : 'Group')),
                DataColumn(label: Text(isRu ? 'Оценка' : 'Grade')),
              ],
              rows: rows
                  .map(
                    (item) => DataRow(
                      cells: [
                        DataCell(
                          Text(DateFormat('dd.MM.yyyy').format(item.classDate)),
                        ),
                        DataCell(Text(item.groupName)),
                        DataCell(Text(item.grade.toString())),
                      ],
                    ),
                  )
                  .toList(),
            ),
          );
        },
      ),
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
  bool _groupsLoading = false;
  final List<String> _groupCatalog = [];

  String _tt(String en) =>
      translateEnglishUi(AppStateScope.of(context).locale.languageCode, en);

  List<ExamGrade> _filterGradesByRole(List<ExamGrade> source) {
    final user = AppStateScope.of(context).user;
    if (user == null) return source;
    if (user.role != 'student') return source;
    final fullName = user.fullName.trim().toLowerCase();
    final group = (user.studentGroup ?? '').trim().toLowerCase();
    return source.where((item) {
      final sameName = item.studentName.trim().toLowerCase() == fullName;
      final sameGroup = group.isEmpty
          ? true
          : item.groupName.trim().toLowerCase() == group;
      return sameName && sameGroup;
    }).toList();
  }

  bool get _canUpload {
    final role = AppStateScope.of(context).user?.role ?? '';
    return role == 'teacher' || role == 'admin';
  }

  bool get _isAdmin {
    final role = AppStateScope.of(context).user?.role ?? '';
    return role == 'admin';
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    final user = AppStateScope.of(context).user;
    _groupController.text = user?.studentGroup ?? '';
    _reload();
    unawaited(_loadGroupCatalog(silent: true));
    _initialized = true;
  }

  @override
  void dispose() {
    _groupController.dispose();
    _examController.dispose();
    super.dispose();
  }

  List<String> _normalizeGroupNames(Iterable<String> values) {
    final set = <String>{};
    for (final raw in values) {
      final value = raw.trim();
      if (value.isNotEmpty) {
        set.add(value);
      }
    }
    final list = set.toList(growable: false);
    list.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return list;
  }

  Future<void> _loadGroupCatalog({bool silent = false}) async {
    if (!_canUpload || _groupsLoading) return;
    if (mounted) {
      setState(() => _groupsLoading = true);
    } else {
      _groupsLoading = true;
    }
    final client = AppStateScope.of(context).client;
    try {
      final collected = <String>{};
      try {
        collected.addAll(await client.listJournalGroupCatalog());
      } catch (_) {}
      try {
        collected.addAll(await client.listJournalGroups());
      } catch (_) {}
      final normalized = _normalizeGroupNames(collected);
      if (!mounted) return;
      setState(() {
        _groupCatalog
          ..clear()
          ..addAll(normalized);
      });
    } catch (error) {
      if (!mounted || silent) return;
      setState(() {
        _noticeError = true;
        _noticeMessage = humanizeError(error);
      });
    } finally {
      if (mounted) {
        setState(() => _groupsLoading = false);
      } else {
        _groupsLoading = false;
      }
    }
  }

  List<String> _filterGroupCatalog(String query) {
    if (_groupCatalog.isEmpty) return const <String>[];
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) {
      return _groupCatalog;
    }
    final startsWith = <String>[];
    final contains = <String>[];
    for (final group in _groupCatalog) {
      final normalized = group.toLowerCase();
      if (normalized.startsWith(needle)) {
        startsWith.add(group);
      } else if (normalized.contains(needle)) {
        contains.add(group);
      }
    }
    return [...startsWith, ...contains];
  }

  Future<String?> _pickGroupFromCatalog({
    required String title,
    String initialQuery = '',
  }) async {
    final queryController = TextEditingController(text: initialQuery);
    final selected = await showDialog<String>(
      context: context,
      builder: (context) {
        var filtered = _filterGroupCatalog(initialQuery);
        return StatefulBuilder(
          builder: (context, setStateDialog) => AlertDialog(
            title: Text(title),
            content: SizedBox(
              width: 460,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: queryController,
                    autofocus: true,
                    decoration: InputDecoration(
                      labelText: _tt('Search group'),
                      border: const OutlineInputBorder(),
                    ),
                    onChanged: (value) {
                      setStateDialog(() {
                        filtered = _filterGroupCatalog(value);
                      });
                    },
                  ),
                  const SizedBox(height: 10),
                  if (filtered.isEmpty)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(_tt('No groups found')),
                    )
                  else
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 280),
                      child: ListView(
                        shrinkWrap: true,
                        children: [
                          for (final group in filtered)
                            ListTile(
                              dense: true,
                              title: Text(group),
                              onTap: () => Navigator.of(context).pop(group),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(_tt('Close')),
              ),
            ],
          ),
        );
      },
    );
    queryController.dispose();
    return selected;
  }

  Future<void> _chooseFilterGroup() async {
    await _loadGroupCatalog();
    if (!mounted) return;
    if (_groupCatalog.isEmpty) {
      setState(() {
        _noticeError = true;
        _noticeMessage = _tt('No journal groups found.');
      });
      return;
    }
    final selected = await _pickGroupFromCatalog(
      title: _tt('Select group'),
      initialQuery: _groupController.text.trim(),
    );
    if (!mounted || selected == null || selected.isEmpty) return;
    setState(() => _groupController.text = selected);
    _reload();
  }

  Future<void> _downloadExamTemplate() async {
    final client = AppStateScope.of(context).client;
    final opened = await launchUrl(
      Uri.parse(client.examTemplateUrl()),
      mode: LaunchMode.platformDefault,
    );
    if (!mounted || opened) return;
    setState(() {
      _noticeError = true;
      _noticeMessage = _tt('Failed to open exam template download.');
    });
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
    final client = AppStateScope.of(context).client;
    await _loadGroupCatalog();
    if (!mounted) return;
    if (_groupCatalog.isEmpty) {
      setState(() {
        _noticeError = true;
        _noticeMessage = _tt('Create journal groups first.');
      });
      return;
    }
    final groupController = TextEditingController(
      text: _groupCatalog.contains(_groupController.text.trim())
          ? _groupController.text.trim()
          : _groupCatalog.first,
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
              title: Text(_tt('Upload exam grades')),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: groupController,
                    readOnly: true,
                    decoration: InputDecoration(
                      labelText: _tt('Group'),
                      border: const OutlineInputBorder(),
                      suffixIcon: const Icon(Icons.search),
                    ),
                    onTap: () async {
                      final selected = await _pickGroupFromCatalog(
                        title: _tt('Select group'),
                        initialQuery: groupController.text.trim(),
                      );
                      if (selected == null || selected.isEmpty) return;
                      setStateDialog(() {
                        groupController.text = selected;
                      });
                    },
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: examController,
                    decoration: InputDecoration(
                      labelText: _tt('Exam name'),
                      border: const OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => FocusScope.of(context).unfocus(),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(child: Text(filename ?? _tt('No file chosen'))),
                      IconButton(
                        icon: const Icon(Icons.upload_file),
                        onPressed: uploading
                            ? null
                            : () async {
                                final result = await FilePicker.platform
                                    .pickFiles(
                                      type: FileType.custom,
                                      allowedExtensions: ['xlsx', 'csv'],
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
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      onPressed: _downloadExamTemplate,
                      icon: const Icon(Icons.download_outlined),
                      label: Text(_tt('Download template (CSV)')),
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: uploading
                      ? null
                      : () => Navigator.of(context).pop(),
                  child: Text(_tt('Cancel')),
                ),
                FilledButton(
                  onPressed: uploading
                      ? null
                      : () async {
                          final group = groupController.text.trim();
                          final exam = examController.text.trim();
                          if (group.isEmpty ||
                              exam.isEmpty ||
                              !_groupCatalog.contains(group) ||
                              bytes == null ||
                              filename == null) {
                            setState(() {
                              _noticeError = true;
                              _noticeMessage = _tt(
                                'Select existing group, exam name and file.',
                              );
                            });
                            return;
                          }
                          setStateDialog(() => uploading = true);
                          try {
                            final count = await client.uploadExamGradesBytes(
                              groupName: group,
                              examName: exam,
                              filename: filename!,
                              bytes: bytes!,
                            );
                            if (!mounted) return;
                            setState(() {
                              _noticeError = false;
                              _noticeMessage =
                                  '${_tt('Uploaded grades')}: $count';
                            });
                            _groupController.text = group;
                            _examController.text = exam;
                            _reload();
                            if (mounted) Navigator.of(this.context).pop();
                          } catch (error) {
                            if (!mounted) return;
                            setState(() {
                              _noticeError = true;
                              _noticeMessage = humanizeError(error);
                            });
                          } finally {
                            if (mounted) {
                              setStateDialog(() => uploading = false);
                            }
                          }
                        },
                  child: uploading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(_tt('Upload')),
                ),
              ],
            );
          },
        );
      },
    );
    groupController.dispose();
    examController.dispose();
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
          return Text(
            '${_tt('Failed to load exam grades')}: ${snapshot.error}',
          );
        }
        final items = _filterGradesByRole(snapshot.data ?? []);
        if (items.isEmpty) {
          return Text(_tt('No exam grades yet'));
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

  Widget _buildParentExamTable() {
    final future = _gradesFuture;
    if (future == null) return const SizedBox.shrink();
    return FutureBuilder<List<ExamGrade>>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: BrandLoadingIndicator());
        }
        if (snapshot.hasError) {
          return InlineNotice(
            message: humanizeError(snapshot.error!),
            isError: true,
          );
        }
        final rows = snapshot.data ?? const <ExamGrade>[];
        final filteredRows = _filterGradesByRole(rows);
        if (filteredRows.isEmpty) {
          return Text(_tt('No exam grades yet.'));
        }
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            columns: [
              DataColumn(label: Text(_tt('Exam'))),
              DataColumn(label: Text(_tt('Date'))),
              DataColumn(label: Text(_tt('Group'))),
              DataColumn(label: Text(_tt('Grade'))),
            ],
            rows: filteredRows
                .map(
                  (item) => DataRow(
                    cells: [
                      DataCell(Text(item.examName)),
                      DataCell(
                        Text(DateFormat('dd.MM.yyyy').format(item.createdAt)),
                      ),
                      DataCell(Text(item.groupName)),
                      DataCell(Text(item.grade.toString())),
                    ],
                  ),
                )
                .toList(),
          ),
        );
      },
    );
  }

  Future<void> _editUpload(ExamUpload upload) async {
    final client = AppStateScope.of(context).client;
    await _loadGroupCatalog();
    if (!mounted) return;
    if (_groupCatalog.isEmpty) {
      setState(() {
        _noticeError = true;
        _noticeMessage = _tt('No journal groups found.');
      });
      return;
    }
    final groupController = TextEditingController(text: upload.groupName);
    final examController = TextEditingController(text: upload.examName);
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setStateDialog) => AlertDialog(
          title: Text(_tt('Edit upload')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: groupController,
                readOnly: true,
                decoration: InputDecoration(
                  labelText: _tt('Group'),
                  border: const OutlineInputBorder(),
                  suffixIcon: const Icon(Icons.search),
                ),
                onTap: () async {
                  final selected = await _pickGroupFromCatalog(
                    title: _tt('Select group'),
                    initialQuery: groupController.text.trim(),
                  );
                  if (selected == null || selected.isEmpty) return;
                  setStateDialog(() => groupController.text = selected);
                },
              ),
              const SizedBox(height: 12),
              TextField(
                controller: examController,
                decoration: InputDecoration(
                  labelText: _tt('Exam name'),
                  border: const OutlineInputBorder(),
                ),
                onSubmitted: (_) => Navigator.pop(context, true),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(_tt('Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(_tt('Save')),
            ),
          ],
        ),
      ),
    );
    if (result != true) {
      groupController.dispose();
      examController.dispose();
      return;
    }
    final selectedGroup = groupController.text.trim();
    if (!_groupCatalog.contains(selectedGroup)) {
      if (!mounted) return;
      setState(() {
        _noticeError = true;
        _noticeMessage = _tt('Select an existing group.');
      });
      groupController.dispose();
      examController.dispose();
      return;
    }
    try {
      await client.updateExamUpload(
        upload.id,
        groupName: selectedGroup,
        examName: examController.text.trim(),
      );
      if (!mounted) return;
      _reload();
      setState(() {
        _noticeError = false;
        _noticeMessage = _tt('Upload updated.');
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _noticeError = true;
        _noticeMessage = humanizeError(error);
      });
    }
    groupController.dispose();
    examController.dispose();
  }

  Future<void> _deleteUpload(ExamUpload upload) async {
    final client = AppStateScope.of(context).client;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_tt('Delete upload?')),
        content: Text(_tt('All grades from this upload will be deleted.')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_tt('Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(_tt('Delete')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await client.deleteExamUpload(upload.id);
      if (!mounted) return;
      _reload();
      setState(() {
        _noticeError = false;
        _noticeMessage = _tt('Upload deleted.');
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _noticeError = true;
        _noticeMessage = humanizeError(error);
      });
    }
  }

  Future<void> _deletePastUploads() async {
    if (!_isAdmin) return;
    final client = AppStateScope.of(context).client;
    final picked = await showDatePicker(
      context: context,
      initialDate: DateUtils.dateOnly(DateTime.now()),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      helpText: _tt('Delete uploads before date'),
    );
    if (picked == null || !mounted) return;
    final group = _groupController.text.trim();
    final exam = _examController.text.trim();
    final dateLabel = DateFormat('dd.MM.yyyy').format(picked);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_tt('Delete past uploads?')),
        content: Text(
          '${_tt('Uploads before')} $dateLabel ${_tt('will be deleted.')}${group.isEmpty ? '' : '\n${_tt('Group')}: $group'}${exam.isEmpty ? '' : '\n${_tt('Exam')}: $exam'}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(_tt('Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(_tt('Delete')),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final result = await client.deletePastExamUploads(
        beforeDate: picked,
        groupName: group.isEmpty ? null : group,
        examName: exam.isEmpty ? null : exam,
      );
      if (!mounted) return;
      final uploadsDeleted = (result['uploads_deleted'] as num?)?.toInt() ?? 0;
      final gradesDeleted = (result['grades_deleted'] as num?)?.toInt() ?? 0;
      setState(() {
        _noticeError = false;
        _noticeMessage =
            '${_tt('Deleted uploads')}: $uploadsDeleted. ${_tt('Deleted grades')}: $gradesDeleted.';
      });
      _reload();
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
          return Text('${_tt('Failed to load uploads')}: ${snapshot.error}');
        }
        final items = snapshot.data ?? [];
        if (items.isEmpty) {
          return Text(_tt('No uploads yet'));
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
                            PopupMenuItem(
                              value: 'edit',
                              child: Text(_tt('Edit')),
                            ),
                            PopupMenuItem(
                              value: 'delete',
                              child: Text(_tt('Delete')),
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
    final role = AppStateScope.of(context).user?.role ?? '';
    if (role == 'parent') {
      return FeatureScaffold(
        title: _tt('Child exam grades'),
        subtitle: _tt('Only grades for approved child.'),
        actionLabel: _tt('Refresh'),
        onAction: _reload,
        child: _buildParentExamTable(),
      );
    }
    return FeatureScaffold(
      title: _tt('Exam grades'),
      subtitle: _canUpload
          ? _tt('Upload and review exam grades')
          : _tt('Your exam results'),
      actionLabel: _canUpload ? _tt('Upload exam grades') : null,
      onAction: _canUpload ? _openUploadDialog : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_noticeMessage != null)
            InlineNotice(message: _noticeMessage!, isError: _noticeError),
          if (_noticeMessage != null) const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  TextField(
                    controller: _groupController,
                    readOnly: _canUpload,
                    decoration: InputDecoration(
                      labelText: _tt('Group'),
                      hintText: _canUpload
                          ? (_groupsLoading
                                ? _tt('Loading groups...')
                                : _tt('Select existing group'))
                          : null,
                      border: const OutlineInputBorder(),
                      suffixIcon: _canUpload
                          ? Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (_groupController.text.trim().isNotEmpty)
                                  IconButton(
                                    onPressed: () {
                                      setState(() => _groupController.clear());
                                      _reload();
                                    },
                                    icon: const Icon(Icons.close),
                                  ),
                                IconButton(
                                  onPressed: _groupsLoading
                                      ? null
                                      : _chooseFilterGroup,
                                  icon: const Icon(Icons.search),
                                ),
                              ],
                            )
                          : null,
                    ),
                    onTap: _canUpload ? _chooseFilterGroup : null,
                    onSubmitted: (_) => FocusScope.of(context).nextFocus(),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _examController,
                    decoration: InputDecoration(
                      labelText: _tt('Exam name'),
                      border: const OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _reload(),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      if (_canUpload)
                        OutlinedButton.icon(
                          onPressed: _downloadExamTemplate,
                          icon: const Icon(Icons.download_outlined),
                          label: Text(_tt('Template')),
                        ),
                      const Spacer(),
                      FilledButton.icon(
                        onPressed: _reload,
                        icon: const Icon(Icons.search),
                        label: Text(_tt('Filter')),
                      ),
                    ],
                  ),
                  if (_canUpload && _showUploads && _isAdmin) ...[
                    const SizedBox(height: 12),
                    Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton.icon(
                        onPressed: _deletePastUploads,
                        icon: const Icon(Icons.delete_sweep_outlined),
                        label: Text(_tt('Delete past uploads')),
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.red.shade600,
                        ),
                      ),
                    ),
                  ],
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
                            ).colorScheme.primary.withValues(alpha: 0.12),
                    ),
                    child: Text(_tt('Grades')),
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
                            ).colorScheme.primary.withValues(alpha: 0.12)
                          : null,
                    ),
                    child: Text(_tt('Uploads')),
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
      if (!mounted) return;
    }
    final client = AppStateScope.of(context).client;
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
              initialValue: selectedId,
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
      await client.createTeacherAssignment(
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
    final client = AppStateScope.of(context).client;
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
      await client.updateTeacherAssignment(
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
    final client = AppStateScope.of(context).client;
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
      await client.deleteTeacherAssignment(item.id);
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
                    ? Theme.of(
                        context,
                      ).colorScheme.primary.withValues(alpha: 0.12)
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
                    DateFormat('dd.MM.yyyy').format(item.classDate),
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
          if (_noticeMessage != null)
            InlineNotice(message: _noticeMessage!, isError: _noticeError),
          if (_noticeMessage != null) const SizedBox(height: 12),
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

  Future<void> _createRequest() async {
    final created = await pushAdaptivePage<RequestTicket>(
      context,
      RequestComposePage(),
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_noticeMessage != null)
            InlineNotice(message: _noticeMessage!, isError: _noticeError),
          if (_noticeMessage != null) const SizedBox(height: 12),
          FutureBuilder<List<RequestTicket>>(
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
                        leading: const CircleAvatar(
                          child: Icon(Icons.description),
                        ),
                        title: Text(item.requestType),
                        subtitle: Text(
                          '\u0421\u0442\u0430\u0442\u0443\u0441: ${item.status}\n${item.studentName} - ${_requestDateFormat.format(item.createdAt)}',
                        ),
                        trailing: widget.canProcess
                            ? IconButton(
                                icon: const Icon(Icons.delete_outline),
                                onPressed: () async {
                                  final client = AppStateScope.of(
                                    context,
                                  ).client;
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
                                    await client.deleteRequest(item.id);
                                    if (!mounted) return;
                                    setState(() {
                                      _requestsFuture = client.listRequests();
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
                          await pushAdaptivePage<RequestTicket>(
                            context,
                            RequestDetailPage(
                              ticket: item,
                              canProcess: canProcess,
                            ),
                          );
                          if (mounted) {
                            setState(() {
                              _requestsFuture = AppStateScope.of(
                                context,
                              ).client.listRequests();
                            });
                          }
                        },
                      ),
                    ),
                ],
              );
            },
          ),
        ],
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
  String? _selectedTeacherGroup;
  Future<List<String>>? _teacherGroupsFuture;
  bool _initialized = false;
  bool _sending = false;

  bool _profileComplete(UserProfile? user) {
    return user != null;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    final user = AppStateScope.of(context).user;
    if (user?.role == 'teacher') {
      _selectedType = kTeacherGroupRequestType;
      _teacherGroupsFuture = AppStateScope.of(
        context,
      ).client.listJournalGroupCatalog();
      _teacherGroupsFuture!.then((groups) {
        if (!mounted || groups.isEmpty) return;
        setState(() {
          _selectedTeacherGroup ??= groups.first;
        });
      });
    }
  }

  Future<void> _submit() async {
    final state = AppStateScope.of(context);
    final user = state.user;
    if (!_profileComplete(user)) {
      setState(() {
        _noticeError = true;
        _noticeMessage = 'Профиль не найден. Перезайдите в аккаунт.';
      });
      return;
    }
    final type = user?.role == 'teacher'
        ? kTeacherGroupRequestType
        : _selectedType;
    if (type == null) {
      setState(() {
        _noticeError = true;
        _noticeMessage = 'Выберите тип справки.';
      });
      return;
    }
    final groupName = user?.role == 'teacher'
        ? (_selectedTeacherGroup ?? '').trim()
        : '';
    if (user?.role == 'teacher' && groupName.isEmpty) {
      setState(() {
        _noticeError = true;
        _noticeMessage = 'Выберите группу для заявки.';
      });
      return;
    }
    setState(() => _sending = true);
    try {
      final ticket = await state.client.createRequest(
        requestType: type,
        groupName: groupName.isEmpty ? null : groupName,
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
    final role = AppStateScope.of(context).user?.role ?? '';
    return Scaffold(
      appBar: AppBar(title: const Text('New request')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          if (_noticeMessage != null) ...[
            InlineNotice(message: _noticeMessage!, isError: _noticeError),
            const SizedBox(height: 12),
          ],
          if (role == 'teacher') ...[
            InputDecorator(
              decoration: const InputDecoration(labelText: 'Request type'),
              child: Text(kTeacherGroupRequestType),
            ),
            const SizedBox(height: 12),
            FutureBuilder<List<String>>(
              future: _teacherGroupsFuture,
              builder: (context, snapshot) {
                final groups = snapshot.data ?? const <String>[];
                final selected = groups.contains(_selectedTeacherGroup)
                    ? _selectedTeacherGroup
                    : (groups.isNotEmpty ? groups.first : null);
                return DropdownButtonFormField<String>(
                  initialValue: selected,
                  items: groups
                      .map(
                        (group) =>
                            DropdownMenuItem(value: group, child: Text(group)),
                      )
                      .toList(),
                  onChanged: groups.isEmpty
                      ? null
                      : (value) =>
                            setState(() => _selectedTeacherGroup = value),
                  decoration: const InputDecoration(labelText: 'Group'),
                );
              },
            ),
          ] else
            DropdownButtonFormField<String>(
              initialValue: _selectedType,
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
  final _commentController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _ticket = widget.ticket;
    _commentController.text = (_ticket.comment ?? '').trim();
    if (_isTeachingGroupRequest(_ticket.requestType)) {
      _status = _normalizeTeachingDecisionStatus(_ticket.status);
    } else {
      _status = kRequestStatuses.contains(_ticket.status)
          ? _ticket.status
          : kRequestStatuses.first;
    }
  }

  @override
  void dispose() {
    _commentController.dispose();
    super.dispose();
  }

  bool _isTeachingGroupRequest(String value) {
    final text = value.toLowerCase();
    return text.contains('преподавание группы') ||
        (text.contains('teacher') && text.contains('group'));
  }

  String _normalizeTeachingDecisionStatus(String value) {
    final normalized = value.trim().toLowerCase();
    if (normalized == 'approved' ||
        normalized == 'одобрена' ||
        normalized == 'принята') {
      return 'approved';
    }
    if (normalized == 'rejected' || normalized == 'отклонена') {
      return 'rejected';
    }
    return 'approved';
  }

  Future<void> _save() async {
    if (!widget.canProcess) return;
    setState(() => _saving = true);
    try {
      final updated = await AppStateScope.of(context).client.updateRequest(
        _ticket.id,
        status: _status,
        comment: _commentController.text.trim(),
      );
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
    return Scaffold(
      appBar: AppBar(title: const Text('Request')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          if (_noticeMessage != null)
            InlineNotice(message: _noticeMessage!, isError: _noticeError),
          if (_noticeMessage != null) const SizedBox(height: 12),
          Card(
            child: ListTile(
              title: Text(_ticket.requestType),
              subtitle: Text(
                "${_ticket.studentName}\n"
                "${DateFormat("dd.MM.yyyy HH:mm").format(_ticket.createdAt)}\n"
                "Status: ${_ticket.status}"
                "${(_ticket.comment ?? '').trim().isEmpty ? '' : '\nКомментарий: ${_ticket.comment!.trim()}'}",
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (widget.canProcess) ...[
            if (_isTeachingGroupRequest(_ticket.requestType))
              DropdownButtonFormField<String>(
                initialValue: _status == 'rejected' ? 'rejected' : 'approved',
                items: const [
                  DropdownMenuItem(value: 'approved', child: Text('Принять')),
                  DropdownMenuItem(value: 'rejected', child: Text('Отклонить')),
                ],
                onChanged: (value) => setState(() => _status = value),
                decoration: const InputDecoration(labelText: 'Решение'),
              )
            else
              DropdownButtonFormField<String>(
                initialValue: kRequestStatuses.contains(_status)
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
            TextField(
              controller: _commentController,
              minLines: 2,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: 'Комментарий к решению (опционально)',
              ),
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _save(),
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
  bool _notifySchedule = true;
  bool _notifyRequests = true;
  bool get _isRu => AppStateScope.of(
    context,
  ).locale.languageCode.toLowerCase().startsWith('ru');

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
    final user = AppStateScope.of(context).user;
    _notifySchedule = user?.notifySchedule ?? true;
    _notifyRequests = user?.notifyRequests ?? true;
    if (_initialized) return;
    _fullNameController.text = user?.fullName ?? '';
    _phoneController.text = user?.phone ?? '';
    _birthController.text = user?.birthDate == null
        ? ''
        : DateFormat('yyyy-MM-dd').format(user!.birthDate!);
    _groupController.text = user?.studentGroup ?? '';
    _teacherController.text = user?.teacherName ?? '';
    _initialized = true;
  }

  Future<void> _saveNotificationPref(String key, bool value) async {
    final state = AppStateScope.of(context);
    final payload = <String, dynamic>{key: value};
    try {
      final updated = await state.updateProfile(payload);
      if (!mounted) return;
      setState(() {
        _notifySchedule = updated?.notifySchedule ?? _notifySchedule;
        _notifyRequests = updated?.notifyRequests ?? _notifyRequests;
      });
    } catch (error) {
      if (!mounted) return;
      final user = state.user;
      setState(() {
        _noticeError = true;
        _noticeMessage = humanizeError(error);
        _notifySchedule = user?.notifySchedule ?? true;
        _notifyRequests = user?.notifyRequests ?? true;
      });
    }
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

  Future<void> _pickAndUploadAvatar() async {
    final state = AppStateScope.of(context);
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;
    final bytes = file.bytes;
    if (bytes == null || bytes.isEmpty) {
      if (!mounted) return;
      setState(() {
        _noticeError = true;
        _noticeMessage = _isRu
            ? 'Не удалось прочитать выбранный файл.'
            : 'Failed to read selected file.';
      });
      return;
    }
    try {
      final uploaded = await state.client.uploadMyAvatarBytes(
        filename: file.name,
        bytes: bytes,
      );
      final avatarUrl = uploaded.avatarUrl;
      if (avatarUrl != null && avatarUrl.trim().isNotEmpty) {
        await state.updateProfile({'avatar_url': avatarUrl.trim()});
      }
      if (!mounted) return;
      setState(() {
        _noticeError = false;
        _noticeMessage = _isRu ? 'Аватар обновлён.' : 'Avatar updated.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _noticeError = true;
        _noticeMessage = humanizeError(error);
      });
    }
  }

  Future<void> _openEditProfileDialog() async {
    final l10n = AppLocalizations.of(context);
    final user = AppStateScope.of(context).user;
    if (user == null) return;
    _fullNameController.text = user.fullName;
    _phoneController.text = user.phone ?? '';
    _birthController.text = user.birthDate == null
        ? ''
        : DateFormat('yyyy-MM-dd').format(user.birthDate!);
    _teacherController.text = user.teacherName ?? '';
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) {
        bool uploadingAvatar = false;
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final currentUser = AppStateScope.of(context).user;
            final avatarUrl = currentUser?.avatarUrl?.trim();
            final hasAvatar = avatarUrl != null && avatarUrl.isNotEmpty;
            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              title: Row(
                children: [
                  Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      color: kBrandPrimary.withValues(alpha: 0.12),
                    ),
                    child: const Icon(
                      Icons.edit_rounded,
                      size: 18,
                      color: kBrandPrimary,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(_isRu ? 'Редактировать профиль' : 'Edit profile'),
                ],
              ),
              content: SingleChildScrollView(
                child: SizedBox(
                  width: 520,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          CircleAvatar(
                            radius: 26,
                            backgroundColor: kBrandPrimary.withValues(
                              alpha: 0.1,
                            ),
                            backgroundImage: hasAvatar
                                ? NetworkImage(_resolveMediaUrl(avatarUrl))
                                : null,
                            child: hasAvatar
                                ? null
                                : const Icon(Icons.person_outline_rounded),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: uploadingAvatar
                                  ? null
                                  : () async {
                                      setDialogState(() {
                                        uploadingAvatar = true;
                                      });
                                      await _pickAndUploadAvatar();
                                      if (!mounted) return;
                                      setDialogState(() {
                                        uploadingAvatar = false;
                                      });
                                    },
                              icon: uploadingAvatar
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.upload_file_rounded),
                              label: Text(
                                _isRu ? 'Загрузить аватар' : 'Upload avatar',
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _fullNameController,
                        decoration: InputDecoration(
                          labelText: l10n.t('full_name'),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        onSubmitted: (_) => FocusScope.of(context).nextFocus(),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _phoneController,
                        decoration: InputDecoration(
                          labelText: l10n.t('phone_label'),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        keyboardType: TextInputType.phone,
                        onSubmitted: (_) => FocusScope.of(context).nextFocus(),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _birthController,
                        decoration: InputDecoration(
                          labelText: l10n.t('birth_date_label'),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        onSubmitted: (_) => FocusScope.of(context).nextFocus(),
                      ),
                      if (user.role == 'teacher') ...[
                        const SizedBox(height: 12),
                        TextField(
                          controller: _teacherController,
                          decoration: InputDecoration(
                            labelText: l10n.t('teacher_name_label'),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: Text(_isRu ? 'Отмена' : 'Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: Text(_isRu ? 'Сохранить' : 'Save'),
                ),
              ],
            );
          },
        );
      },
    );
    if (ok != true) return;
    await _saveProfile();
  }

  Widget _buildRoleContextCard({
    required UserProfile? user,
    required bool isRu,
  }) {
    if (user == null) {
      return const SizedBox.shrink();
    }
    final role = user.role.trim();
    final approved = user.isApproved ?? true;
    final approvalChip = _ProfileInfoPill(
      text: approved
          ? (isRu ? 'Подтвержден' : 'Approved')
          : (isRu ? 'Ожидает подтверждения' : 'Pending approval'),
      backgroundColor: approved
          ? const Color(0xFFD1FAE5)
          : const Color(0xFFFFEDD5),
    );
    switch (role) {
      case 'student':
        return _ProfileSectionCard(
          title: isRu ? 'Профиль студента' : 'Student profile',
          icon: Icons.school_outlined,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  approvalChip,
                  _ProfileInfoPill(
                    text: (user.studentGroup ?? '').trim().isEmpty
                        ? (isRu ? 'Группа не назначена' : 'Group not set')
                        : '${isRu ? 'Группа' : 'Group'}: ${user.studentGroup}',
                    backgroundColor: const Color(0xFFEFF6FF),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                isRu
                    ? 'Доступ: расписание, оценки, экзамены, отработки и заявки.'
                    : 'Access: schedule, grades, exams, makeups and requests.',
              ),
            ],
          ),
        );
      case 'teacher':
        return _ProfileSectionCard(
          title: isRu ? 'Профиль преподавателя' : 'Teacher profile',
          icon: Icons.co_present_outlined,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  approvalChip,
                  _ProfileInfoPill(
                    text: (user.teacherName ?? '').trim().isEmpty
                        ? (isRu
                              ? 'ФИО преподавателя не заполнено'
                              : 'Teacher name not set')
                        : '${isRu ? 'ФИО в журнале' : 'Journal name'}: ${user.teacherName}',
                    backgroundColor: const Color(0xFFEFF6FF),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                isRu
                    ? 'Доступ: расписание, посещаемость, оценки, отработки и запросы на группы.'
                    : 'Access: schedule, attendance, grades, makeups and group-access requests.',
              ),
            ],
          ),
        );
      case 'parent':
        return _ProfileSectionCard(
          title: isRu ? 'Профиль родителя' : 'Parent profile',
          icon: Icons.family_restroom_outlined,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  approvalChip,
                  _ProfileInfoPill(
                    text: (user.childFullName ?? '').trim().isEmpty
                        ? (isRu ? 'Ребенок не привязан' : 'Child is not linked')
                        : '${isRu ? 'Ребенок' : 'Child'}: ${user.childFullName}',
                    backgroundColor: const Color(0xFFEFF6FF),
                  ),
                  if ((user.studentGroup ?? '').trim().isNotEmpty)
                    _ProfileInfoPill(
                      text:
                          '${isRu ? 'Группа ребенка' : 'Child group'}: ${user.studentGroup}',
                      backgroundColor: const Color(0xFFEFF6FF),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                isRu
                    ? 'Доступ только к данным подтвержденного ребенка: посещаемость, оценки, экзамены.'
                    : 'Access is limited to approved child data: attendance, grades and exams.',
              ),
            ],
          ),
        );
      case 'admin':
        final permissions = user.adminPermissions;
        return _ProfileSectionCard(
          title: isRu ? 'Профиль администратора' : 'Admin profile',
          icon: Icons.admin_panel_settings_outlined,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  approvalChip,
                  _ProfileInfoPill(
                    text: isRu ? 'Полный CRUD по системе' : 'Full system CRUD',
                    backgroundColor: const Color(0xFFEFF6FF),
                  ),
                  if (permissions.isNotEmpty)
                    ...permissions.map(
                      (item) => _ProfileInfoPill(
                        text: isRu ? 'Право: $item' : 'Permission: $item',
                        backgroundColor: const Color(0xFFEFF6FF),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                isRu
                    ? 'Используйте админ-панель для подтверждений, ролей и экосистемы пользователей.'
                    : 'Use admin panel for approvals, roles and user ecosystem management.',
              ),
            ],
          ),
        );
      default:
        return _ProfileSectionCard(
          title: isRu ? 'Профиль' : 'Profile',
          icon: Icons.person_outline_rounded,
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              approvalChip,
              _ProfileInfoPill(
                text: role.isEmpty ? '-' : role,
                backgroundColor: const Color(0xFFEFF6FF),
              ),
            ],
          ),
        );
    }
  }

  String _roleTitle(String role, bool isRu) {
    switch (role) {
      case 'admin':
        return isRu ? 'Администратор' : 'Administrator';
      case 'teacher':
        return isRu ? 'Преподаватель' : 'Teacher';
      case 'student':
        return isRu ? 'Студент' : 'Student';
      case 'parent':
        return isRu ? 'Родитель' : 'Parent';
      case 'smm':
        return isRu ? 'Редактор ленты' : 'News editor';
      case 'request_handler':
        return isRu ? 'Обработчик заявок' : 'Request handler';
      default:
        return role.isEmpty ? '-' : role;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final user = AppStateScope.of(context).user;
    final isRu = AppStateScope.of(
      context,
    ).locale.languageCode.toLowerCase().startsWith('ru');
    final displayName = (user?.fullName.isNotEmpty ?? false)
        ? user!.fullName
        : l10n.t('full_name');
    final subtitle = switch (user?.role) {
      'teacher' =>
        ((user?.teacherName?.isNotEmpty ?? false)
            ? user!.teacherName!
            : l10n.t('teacher_not_set')),
      'parent' =>
        ((user?.childFullName?.isNotEmpty ?? false)
            ? user!.childFullName!
            : l10n.t('group_not_set')),
      _ =>
        ((user?.studentGroup?.isNotEmpty ?? false)
            ? user!.studentGroup!
            : l10n.t('group_not_set')),
    };
    final roleTitle = _roleTitle(user?.role ?? '', isRu);
    final approved = user?.isApproved ?? true;
    final approvedLabel = approved
        ? (isRu ? 'Подтвержден' : 'Approved')
        : (isRu ? 'Ожидает подтверждения' : 'Pending approval');
    final approvedColor = approved
        ? const Color(0xFF16A34A)
        : const Color(0xFFD97706);
    final phoneValue = (user?.phone?.isNotEmpty ?? false)
        ? user!.phone!
        : l10n.t('group_not_set');
    final emailValue = (user?.email ?? '').trim().isEmpty ? '-' : user!.email;
    final initials = (user?.fullName.isNotEmpty ?? false)
        ? user!.fullName
              .split(' ')
              .map((e) => e.isNotEmpty ? e[0] : '')
              .take(2)
              .join()
              .toUpperCase()
        : 'PA';
    final avatarUrl = user?.avatarUrl?.trim();
    final hasAvatar = avatarUrl != null && avatarUrl.isNotEmpty;
    final width = MediaQuery.of(context).size.width;
    final isPhoneLayout = width < 640;
    final isUltraCompact = width < 400;
    final maxWidth = width >= 1500
        ? 1360.0
        : width >= 1100
        ? 1200.0
        : double.infinity;
    final horizontal = width >= 1100
        ? 28.0
        : isPhoneLayout
        ? 10.0
        : 16.0;
    final listTopPadding = isPhoneLayout ? 12.0 : 18.0;
    final listBottomPadding = isPhoneLayout ? 18.0 : 24.0;
    final sectionGap = isPhoneLayout ? 10.0 : 12.0;
    final compactTileDensity = isPhoneLayout
        ? const VisualDensity(horizontal: -2, vertical: -2)
        : VisualDensity.standard;
    final compactTilePadding = isPhoneLayout
        ? const EdgeInsets.symmetric(horizontal: 6)
        : null;
    final wideLayout = width >= 1100;
    final roleSection = _buildRoleContextCard(user: user, isRu: isRu);
    final accountSection = _ProfileSectionCard(
      title: l10n.t('account_info'),
      icon: Icons.person_outline_rounded,
      subtitle: isRu
          ? 'Ключевые персональные данные аккаунта.'
          : 'Primary account identity information.',
      child: Column(
        children: [
          ListTile(
            leading: const Icon(Icons.badge_outlined),
            title: Text(l10n.t('full_name')),
            subtitle: Text(displayName),
            dense: isPhoneLayout,
            visualDensity: compactTileDensity,
            contentPadding: compactTilePadding,
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.email_outlined),
            title: const Text('Email'),
            subtitle: Text(user?.email ?? '-'),
            dense: isPhoneLayout,
            visualDensity: compactTileDensity,
            contentPadding: compactTilePadding,
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.phone_outlined),
            title: Text(l10n.t('phone_label')),
            subtitle: Text(phoneValue),
            dense: isPhoneLayout,
            visualDensity: compactTileDensity,
            contentPadding: compactTilePadding,
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.cake_outlined),
            title: Text(l10n.t('birth_date_label')),
            dense: isPhoneLayout,
            visualDensity: compactTileDensity,
            contentPadding: compactTilePadding,
            subtitle: Text(
              (user?.birthDate == null)
                  ? (isRu ? 'Не указан' : 'Not set')
                  : DateFormat('yyyy-MM-dd').format(user!.birthDate!),
            ),
          ),
          if (user?.role == 'teacher') ...[
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.co_present_outlined),
              title: Text(l10n.t('teacher_name_label')),
              dense: isPhoneLayout,
              visualDensity: compactTileDensity,
              contentPadding: compactTilePadding,
              subtitle: Text(
                (user?.teacherName ?? '').trim().isEmpty
                    ? (isRu ? 'Не указан' : 'Not set')
                    : user!.teacherName!,
              ),
            ),
          ],
          if (user?.role == 'parent') ...[
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.family_restroom_outlined),
              dense: isPhoneLayout,
              visualDensity: compactTileDensity,
              contentPadding: compactTilePadding,
              title: Text(isRu ? 'Подтвержденный ребенок' : 'Approved child'),
              subtitle: Text(
                (user?.childFullName ?? '').trim().isEmpty
                    ? (isRu ? 'Не указан' : 'Not set')
                    : user!.childFullName!,
              ),
            ),
          ],
        ],
      ),
    );
    final preferencesSection = _ProfileSectionCard(
      title: l10n.t('preferences'),
      icon: Icons.tune_rounded,
      subtitle: isRu
          ? 'Язык интерфейса и уведомления.'
          : 'Interface language and notifications.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.t('language'),
            style: const TextStyle(
              fontWeight: FontWeight.w700,
              color: kSecondaryText,
            ),
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            initialValue: AppStateScope.of(context).locale.languageCode,
            decoration: InputDecoration(
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
            ),
            items: [
              DropdownMenuItem(value: 'ru', child: Text(l10n.t('language_ru'))),
              DropdownMenuItem(value: 'en', child: Text(l10n.t('language_en'))),
              DropdownMenuItem(value: 'kk', child: Text(l10n.t('language_kk'))),
              DropdownMenuItem(value: 'fr', child: Text(l10n.t('language_fr'))),
              DropdownMenuItem(value: 'de', child: Text(l10n.t('language_de'))),
              DropdownMenuItem(value: 'hi', child: Text(l10n.t('language_hi'))),
              DropdownMenuItem(value: 'zh', child: Text(l10n.t('language_zh'))),
            ],
            onChanged: (value) async {
              if (value != null) {
                await AppStateScope.of(context).setLocale(value);
              }
            },
          ),
          const SizedBox(height: 12),
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: const Color(0xFFF6FAF8),
            ),
            child: Column(
              children: [
                SwitchListTile(
                  value: _notifySchedule,
                  onChanged: (value) async {
                    setState(() => _notifySchedule = value);
                    await _saveNotificationPref('notify_schedule', value);
                  },
                  title: Text(l10n.t('schedule_updates')),
                  dense: isPhoneLayout,
                  contentPadding: isPhoneLayout
                      ? const EdgeInsets.symmetric(horizontal: 10)
                      : null,
                ),
                const Divider(height: 1),
                SwitchListTile(
                  value: _notifyRequests,
                  onChanged: (value) async {
                    setState(() => _notifyRequests = value);
                    await _saveNotificationPref('notify_requests', value);
                  },
                  title: Text(l10n.t('request_updates')),
                  dense: isPhoneLayout,
                  contentPadding: isPhoneLayout
                      ? const EdgeInsets.symmetric(horizontal: 10)
                      : null,
                ),
              ],
            ),
          ),
        ],
      ),
    );
    final securitySection = _ProfileSectionCard(
      title: l10n.t('security'),
      icon: Icons.security_outlined,
      subtitle: isRu
          ? 'Контроль доступа и безопасность аккаунта.'
          : 'Access control and account security.',
      child: Column(
        children: [
          ListTile(
            leading: const Icon(Icons.lock_reset_rounded),
            title: Text(l10n.t('reset_password_action')),
            subtitle: Text(
              isRu
                  ? 'Смена пароля через безопасный сценарий.'
                  : 'Change password with secure flow.',
            ),
            trailing: const Icon(Icons.chevron_right_rounded),
            dense: isPhoneLayout,
            visualDensity: compactTileDensity,
            contentPadding: compactTilePadding,
            onTap: () {
              pushAdaptivePage<void>(context, const ResetPasswordPage());
            },
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.logout_rounded),
            title: Text(l10n.t('logout')),
            subtitle: Text(
              isRu
                  ? 'Выход из текущего сеанса.'
                  : 'Sign out from current session.',
            ),
            trailing: const Icon(Icons.chevron_right_rounded),
            dense: isPhoneLayout,
            visualDensity: compactTileDensity,
            contentPadding: compactTilePadding,
            onTap: () => AppStateScope.of(context).logout(),
          ),
        ],
      ),
    );

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
          child: ListView(
            controller: _scrollController,
            padding: EdgeInsets.fromLTRB(
              horizontal,
              listTopPadding,
              horizontal,
              listBottomPadding,
            ),
            children: [
              Container(
                padding: EdgeInsets.fromLTRB(
                  isPhoneLayout ? 14 : 20,
                  isPhoneLayout ? 20 : 28,
                  isPhoneLayout ? 14 : 20,
                  isPhoneLayout ? 20 : 28,
                ),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [kBrandPrimary, kInfo],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(isPhoneLayout ? 20 : 24),
                  boxShadow: [
                    BoxShadow(
                      color: Color(0x220B2A1F),
                      blurRadius: isPhoneLayout ? 16 : 24,
                      offset: Offset(0, isPhoneLayout ? 6 : 10),
                    ),
                  ],
                ),
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    if (!isPhoneLayout)
                      Positioned(
                        right: -24,
                        top: -28,
                        child: Container(
                          width: 140,
                          height: 140,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.white.withValues(alpha: 0.10),
                          ),
                        ),
                      ),
                    if (!isPhoneLayout)
                      Positioned(
                        left: -20,
                        bottom: -36,
                        child: Container(
                          width: 110,
                          height: 110,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.white.withValues(alpha: 0.08),
                          ),
                        ),
                      ),
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final compact = constraints.maxWidth < 700;
                        final phone = constraints.maxWidth < 520;
                        final avatarRadius = phone
                            ? 34.0
                            : compact
                            ? 36.0
                            : 42.0;
                        final avatar = Container(
                          padding: const EdgeInsets.all(2.5),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: const LinearGradient(
                              colors: [
                                Color(0xFF38BDF8),
                                Color(0xFF2DD4BF),
                                Color(0xFF0EA5E9),
                              ],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                            boxShadow: const [
                              BoxShadow(
                                color: Color(0x26000000),
                                blurRadius: 14,
                                offset: Offset(0, 6),
                              ),
                            ],
                          ),
                          child: CircleAvatar(
                            radius: avatarRadius,
                            backgroundColor: Colors.white.withValues(
                              alpha: 0.24,
                            ),
                            backgroundImage: hasAvatar
                                ? NetworkImage(_resolveMediaUrl(avatarUrl))
                                : null,
                            child: hasAvatar
                                ? null
                                : Text(
                                    initials,
                                    style: TextStyle(
                                      fontSize: phone ? 20 : 22,
                                      fontWeight: FontWeight.w700,
                                      color: Colors.white,
                                    ),
                                  ),
                          ),
                        );

                        final info = Column(
                          crossAxisAlignment: compact
                              ? (phone
                                    ? CrossAxisAlignment.stretch
                                    : CrossAxisAlignment.center)
                              : CrossAxisAlignment.start,
                          children: [
                            Text(
                              displayName,
                              textAlign: compact
                                  ? TextAlign.center
                                  : TextAlign.start,
                              style: TextStyle(
                                fontSize: phone
                                    ? (isUltraCompact ? 24 : 26)
                                    : 24,
                                fontWeight: FontWeight.w800,
                                color: Colors.white,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              emailValue,
                              textAlign: compact
                                  ? TextAlign.center
                                  : TextAlign.start,
                              style: TextStyle(
                                fontSize: phone ? 17 : null,
                                color: Colors.white.withValues(alpha: 0.88),
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              isRu
                                  ? 'Личный кабинет PolyApp'
                                  : 'PolyApp personal space',
                              textAlign: compact
                                  ? TextAlign.center
                                  : TextAlign.start,
                              style: TextStyle(
                                fontSize: phone ? 13 : null,
                                color: Colors.white.withValues(alpha: 0.74),
                              ),
                            ),
                            const SizedBox(height: 10),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              alignment: compact
                                  ? WrapAlignment.center
                                  : WrapAlignment.start,
                              children: [
                                _ProfileBadge(
                                  text: roleTitle,
                                  color: Colors.white.withValues(alpha: 0.16),
                                ),
                                _ProfileBadge(
                                  text: approvedLabel,
                                  color: approvedColor.withValues(alpha: 0.26),
                                ),
                                _ProfileBadge(
                                  text: subtitle,
                                  color: Colors.white.withValues(alpha: 0.16),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            if (phone) ...[
                              _ProfileActionButton(
                                label: l10n.t('profile_edit'),
                                icon: Icons.edit_rounded,
                                isPrimary: true,
                                compact: true,
                                fullWidth: true,
                                onPressed: _openEditProfileDialog,
                              ),
                              const SizedBox(height: 8),
                              _ProfileActionButton(
                                label: l10n.t('reset_password_action'),
                                icon: Icons.lock_reset_rounded,
                                compact: true,
                                fullWidth: true,
                                onPressed: () {
                                  pushAdaptivePage<void>(
                                    context,
                                    const ResetPasswordPage(),
                                  );
                                },
                              ),
                              const SizedBox(height: 8),
                              _ProfileActionButton(
                                label: isRu ? 'Фото профиля' : 'Profile photo',
                                icon: Icons.add_a_photo_outlined,
                                compact: true,
                                fullWidth: true,
                                onPressed: _pickAndUploadAvatar,
                              ),
                            ] else
                              Wrap(
                                spacing: 10,
                                runSpacing: 10,
                                alignment: compact
                                    ? WrapAlignment.center
                                    : WrapAlignment.start,
                                children: [
                                  _ProfileActionButton(
                                    label: l10n.t('profile_edit'),
                                    icon: Icons.edit_rounded,
                                    isPrimary: true,
                                    onPressed: _openEditProfileDialog,
                                  ),
                                  _ProfileActionButton(
                                    label: l10n.t('reset_password_action'),
                                    icon: Icons.lock_reset_rounded,
                                    onPressed: () {
                                      pushAdaptivePage<void>(
                                        context,
                                        const ResetPasswordPage(),
                                      );
                                    },
                                  ),
                                  _ProfileActionButton(
                                    label: isRu
                                        ? 'Фото профиля'
                                        : 'Profile photo',
                                    icon: Icons.add_a_photo_outlined,
                                    onPressed: _pickAndUploadAvatar,
                                  ),
                                ],
                              ),
                          ],
                        );

                        if (compact) {
                          return Column(
                            crossAxisAlignment: phone
                                ? CrossAxisAlignment.stretch
                                : CrossAxisAlignment.center,
                            children: [
                              if (phone) Center(child: avatar) else avatar,
                              SizedBox(height: phone ? 10 : 12),
                              info,
                            ],
                          );
                        }

                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            avatar,
                            const SizedBox(width: 16),
                            Expanded(child: info),
                          ],
                        );
                      },
                    ),
                  ],
                ),
              ),
              Padding(
                padding: EdgeInsets.fromLTRB(0, sectionGap, 0, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_noticeMessage != null)
                      InlineNotice(
                        message: _noticeMessage!,
                        isError: _noticeError,
                      ),
                    if (_noticeMessage != null) SizedBox(height: sectionGap),
                    Container(
                      padding: EdgeInsets.all(isPhoneLayout ? 10 : 14),
                      decoration: BoxDecoration(
                        color: kCardSurface,
                        borderRadius: BorderRadius.circular(
                          isPhoneLayout ? 16 : 18,
                        ),
                        border: Border.all(color: const Color(0xFFD8E3DB)),
                        boxShadow: [
                          BoxShadow(
                            color: Color(0x140B2A1F),
                            blurRadius: isPhoneLayout ? 10 : 14,
                            offset: Offset(0, isPhoneLayout ? 5 : 8),
                          ),
                        ],
                      ),
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final stats = [
                            _ProfileStat(
                              icon: Icons.group_outlined,
                              label: l10n.t('profile_stats_group'),
                              value: subtitle,
                            ),
                            _ProfileStat(
                              icon: Icons.badge_outlined,
                              label: l10n.t('profile_stats_role'),
                              value: roleTitle,
                            ),
                            _ProfileStat(
                              icon: Icons.phone_outlined,
                              label: l10n.t('profile_stats_phone'),
                              value: phoneValue,
                            ),
                            _ProfileStat(
                              icon: Icons.email_outlined,
                              label: 'Email',
                              value: emailValue,
                            ),
                          ];

                          Widget row(
                            Widget a,
                            Widget b, [
                            Widget? c,
                            Widget? d,
                          ]) {
                            return Row(
                              children: [
                                Expanded(child: a),
                                const SizedBox(width: 10),
                                Expanded(child: b),
                                if (c != null) ...[
                                  const SizedBox(width: 10),
                                  Expanded(child: c),
                                ],
                                if (d != null) ...[
                                  const SizedBox(width: 10),
                                  Expanded(child: d),
                                ],
                              ],
                            );
                          }

                          if (constraints.maxWidth >= 980) {
                            return row(stats[0], stats[1], stats[2], stats[3]);
                          }
                          if (constraints.maxWidth >= 640) {
                            return Column(
                              children: [
                                row(stats[0], stats[1]),
                                const SizedBox(height: 10),
                                row(stats[2], stats[3]),
                              ],
                            );
                          }
                          return Column(
                            children: [
                              for (int i = 0; i < stats.length; i++) ...[
                                SizedBox(
                                  width: double.infinity,
                                  child: stats[i],
                                ),
                                if (i < stats.length - 1)
                                  const SizedBox(height: 10),
                              ],
                            ],
                          );
                        },
                      ),
                    ),
                    SizedBox(height: sectionGap),
                    if (wideLayout)
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                roleSection,
                                SizedBox(height: sectionGap),
                                preferencesSection,
                              ],
                            ),
                          ),
                          SizedBox(width: sectionGap),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                accountSection,
                                SizedBox(height: sectionGap),
                                securitySection,
                              ],
                            ),
                          ),
                        ],
                      )
                    else
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          roleSection,
                          SizedBox(height: sectionGap),
                          accountSection,
                          SizedBox(height: sectionGap),
                          preferencesSection,
                          SizedBox(height: sectionGap),
                          securitySection,
                        ],
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProfileInfoPill extends StatelessWidget {
  const _ProfileInfoPill({required this.text, required this.backgroundColor});

  final String text;
  final Color backgroundColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: Color(0xFF1F2937),
          fontWeight: FontWeight.w600,
          fontSize: 12,
        ),
      ),
    );
  }
}

class _ProfileBadge extends StatelessWidget {
  const _ProfileBadge({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 520;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 8 : 10,
        vertical: compact ? 5 : 6,
      ),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.25)),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w600,
          fontSize: compact ? 11 : 12,
        ),
      ),
    );
  }
}

class _ProfileActionButton extends StatelessWidget {
  const _ProfileActionButton({
    required this.label,
    required this.icon,
    required this.onPressed,
    this.isPrimary = false,
    this.compact = false,
    this.fullWidth = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;
  final bool isPrimary;
  final bool compact;
  final bool fullWidth;

  @override
  Widget build(BuildContext context) {
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
    );
    final padding = EdgeInsets.symmetric(
      horizontal: compact ? 12 : 14,
      vertical: compact ? 9 : 10,
    );
    final buttonHeight = compact ? 42.0 : 44.0;
    final iconSize = compact ? 18.0 : 20.0;
    final labelStyle = TextStyle(
      fontWeight: FontWeight.w600,
      fontSize: compact ? 15 : 16,
    );
    final button = isPrimary
        ? FilledButton.icon(
            onPressed: onPressed,
            icon: Icon(icon, size: iconSize),
            label: Text(label),
            style: FilledButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: kBrandPrimary,
              elevation: 0,
              shape: shape,
              minimumSize: Size(fullWidth ? double.infinity : 0, buttonHeight),
              padding: padding,
              visualDensity: compact
                  ? const VisualDensity(horizontal: -1, vertical: -1)
                  : VisualDensity.standard,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              textStyle: labelStyle,
            ),
          )
        : OutlinedButton.icon(
            onPressed: onPressed,
            icon: Icon(icon, size: iconSize),
            label: Text(label),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white,
              side: BorderSide(color: Colors.white.withValues(alpha: 0.5)),
              shape: shape,
              backgroundColor: Colors.white.withValues(alpha: 0.06),
              minimumSize: Size(fullWidth ? double.infinity : 0, buttonHeight),
              padding: padding,
              visualDensity: compact
                  ? const VisualDensity(horizontal: -1, vertical: -1)
                  : VisualDensity.standard,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              textStyle: labelStyle,
            ),
          );
    if (!fullWidth) {
      return button;
    }
    return SizedBox(width: double.infinity, child: button);
  }
}

class _ProfileStat extends StatelessWidget {
  const _ProfileStat({
    required this.label,
    required this.value,
    required this.icon,
  });

  final String label;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 640;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 10 : 12,
        vertical: compact ? 9 : 10,
      ),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(compact ? 11 : 12),
        color: const Color(0xFFF6FAF8),
        border: Border.all(color: const Color(0xFFD8E3DB)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: compact ? 15 : 16, color: kBrandPrimary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: kSecondaryText,
                    fontSize: compact ? 11 : 12,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: compact ? 15 : 16,
            ),
          ),
        ],
      ),
    );
  }
}

class _ProfileSectionCard extends StatelessWidget {
  const _ProfileSectionCard({
    required this.title,
    required this.child,
    this.icon,
    this.subtitle,
  });

  final String title;
  final Widget child;
  final IconData? icon;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 640;
    return Container(
      padding: EdgeInsets.all(compact ? 12 : 16),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFFFFFFF), Color(0xFFFBFDFC)],
        ),
        borderRadius: BorderRadius.circular(compact ? 16 : 18),
        border: Border.all(color: const Color(0xFFD8E3DB)),
        boxShadow: [
          BoxShadow(
            color: Color(0x140B2A1F),
            blurRadius: compact ? 10 : 14,
            offset: Offset(0, compact ? 5 : 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (icon != null)
                Container(
                  width: compact ? 26 : 28,
                  height: compact ? 26 : 28,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    color: kBrandPrimary.withValues(alpha: 0.12),
                  ),
                  child: Icon(
                    icon,
                    size: compact ? 15 : 16,
                    color: kBrandPrimary,
                  ),
                ),
              if (icon != null) const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontSize: compact ? 18 : null,
                  ),
                ),
              ),
            ],
          ),
          if (subtitle != null) ...[
            SizedBox(height: compact ? 3 : 4),
            Text(subtitle!, style: const TextStyle(color: kSecondaryText)),
          ],
          SizedBox(height: compact ? 10 : 12),
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
    final state = AppStateScope.of(context);
    final rows = await state.client.listNotifications();
    final role = (state.user?.role ?? '').trim().toLowerCase();
    if (role != 'request_handler') {
      return rows;
    }
    return rows
        .where((item) {
          final type = (item.data?['type'] ?? '')
              .toString()
              .trim()
              .toLowerCase();
          if (type != 'request_created' && type != 'request_updated') {
            return true;
          }
          final title = item.title.toLowerCase();
          final body = item.body.toLowerCase();
          final text = '$title $body';
          if (text.contains('преподав') && text.contains('груп')) {
            return false;
          }
          if (text.contains('teacher') && text.contains('group')) {
            return false;
          }
          return true;
        })
        .toList(growable: false);
  }

  Future<void> _refresh() async {
    setState(() => _future = _load());
    await _future;
  }

  Future<void> _consumeNotification(AppNotification notification) async {
    try {
      await AppStateScope.of(
        context,
      ).client.markNotificationRead(notification.id);
      if (!mounted) return;
      await _refresh();
    } catch (_) {}
  }

  Future<void> _openNotification(AppNotification notification) async {
    await _consumeNotification(notification);
    if (!mounted) return;
    final type = (notification.data?['type'] ?? '').toString().trim();
    final state = AppStateScope.of(context);
    final role = state.user?.role ?? '';
    Widget? target;
    switch (type) {
      case 'schedule_updated':
        target = const SchedulePage();
        break;
      case 'exam_grades':
        target = const ExamGradesPage();
        break;
      case 'request_created':
      case 'request_updated':
        target = RequestsPage(
          canProcess: role == 'admin' || role == 'request_handler',
        );
        break;
      case 'makeup_created':
      case 'makeup_updated':
      case 'makeup_message':
      case 'makeup_graded':
        if (state.user != null) {
          target = MakeupWorkspacePage(
            client: state.client,
            currentUser: state.user!,
            locale: state.locale,
            baseUrl: state.baseUrl,
            errorText: humanizeError,
          );
        }
        break;
      case 'attendance_updated':
        target = const AttendancePage();
        break;
      case 'grade_updated':
        target = const GradesPage();
        break;
      case 'news_created':
      case 'news_updated':
        target = NewsFeedPage(canEdit: role == 'admin' || role == 'smm');
        break;
      default:
        break;
    }
    if (target != null && mounted) {
      await pushAdaptivePage<void>(context, target);
    }
  }

  Future<void> _deleteNotification(AppNotification notification) async {
    setState(() {
      _future = _future.then(
        (items) => items.where((item) => item.id != notification.id).toList(),
      );
    });
    try {
      await AppStateScope.of(
        context,
      ).client.deleteNotification(notification.id);
    } catch (_) {
      if (!mounted) return;
      await _refresh();
    }
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
      appBar: AppBar(
        leading: IconButton(
          onPressed: () => Navigator.of(context).maybePop(),
          icon: const Icon(Icons.arrow_back),
        ),
        title: Text(l10n.t('notifications_title')),
      ),
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
              separatorBuilder: (_, _) => const SizedBox(height: 12),
              itemBuilder: (context, index) {
                final item = items[index];
                return GestureDetector(
                  onTap: () => _openNotification(item),
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: item.isRead ? kCardSurface : kSecondaryBackground,
                      borderRadius: BorderRadius.circular(16),
                      border: item.isRead
                          ? null
                          : Border.all(
                              color: kBrandPrimary.withValues(alpha: 0.3),
                            ),
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
                                  color: kBrandPrimary.withValues(alpha: 0.12),
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
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            OutlinedButton.icon(
                              onPressed: () => _deleteNotification(item),
                              icon: const Icon(Icons.delete_outline_rounded),
                              label: Text(l10n.t('notifications_delete')),
                            ),
                          ],
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
        final maxWidth = constraints.maxWidth >= 1440
            ? 1320.0
            : constraints.maxWidth >= 1100
            ? 1120.0
            : double.infinity;
        final horizontal = constraints.maxWidth >= 1100 ? 28.0 : 16.0;
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

class HomeDashboardPage extends StatefulWidget {
  const HomeDashboardPage({
    super.key,
    required this.role,
    required this.onOpenFeature,
  });

  final RoleDefinition role;
  final void Function(String featureId) onOpenFeature;

  @override
  State<HomeDashboardPage> createState() => _HomeDashboardPageState();
}

class _HomeDashboardPageState extends State<HomeDashboardPage> {
  bool _loading = true;
  bool _initialized = false;
  String? _error;

  NewsPost? _latestNews;
  ScheduleUpload? _latestSchedule;
  List<ExamGrade> _recentExams = const [];
  List<MakeupCaseDto> _recentMakeups = const [];
  List<RequestTicket> _recentRequests = const [];
  List<AppNotification> _newNotifications = const [];

  bool get _isRu => AppStateScope.of(context).locale.languageCode == 'ru';
  String _t(String ru, String en) =>
      trTextByCode(AppStateScope.of(context).locale.languageCode, ru, en);

  bool _hasFeature(String featureId) =>
      widget.role.features.any((item) => item.id == featureId);

  FeatureDefinition? _findFeature(String featureId) {
    for (final item in widget.role.features) {
      if (item.id == featureId) return item;
    }
    return null;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    _loadDashboard();
  }

  Future<void> _loadDashboard() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });

    final client = AppStateScope.of(context).client;
    final now = DateTime.now().toUtc();
    final weekAgo = now.subtract(const Duration(days: 7));

    NewsPost? latestNews;
    ScheduleUpload? latestSchedule;
    List<ExamGrade> recentExams = const [];
    List<MakeupCaseDto> recentMakeups = const [];
    List<RequestTicket> recentRequests = const [];
    List<AppNotification> notifications = const [];

    Future<void> safeRun(Future<void> Function() block) async {
      try {
        await block();
      } catch (_) {}
    }

    if (_hasFeature('news')) {
      await safeRun(() async {
        final posts = await client.listNews(limit: 1);
        if (posts.isNotEmpty) {
          latestNews = posts.first;
        }
      });
    }
    if (_hasFeature('schedule')) {
      await safeRun(() async {
        latestSchedule = await client.latestSchedule();
      });
    }
    if (_hasFeature('exams')) {
      await safeRun(() async {
        final rows = await client.listExamGrades();
        rows.sort((a, b) => b.createdAt.compareTo(a.createdAt));
        recentExams = rows.take(5).toList(growable: false);
      });
    }
    if (_hasFeature('makeup')) {
      await safeRun(() async {
        final rows = await client.listMakeups();
        rows.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
        final filtered = rows.where((item) {
          final status = item.status.trim().toLowerCase();
          final closed =
              status == 'closed' ||
              status == 'graded' ||
              status == 'completed' ||
              status == 'cancelled';
          return !closed || item.updatedAt.toUtc().isAfter(weekAgo);
        }).toList();
        recentMakeups = filtered.take(5).toList(growable: false);
      });
    }
    if (_hasFeature('requests')) {
      await safeRun(() async {
        final rows = await client.listRequests();
        rows.sort((a, b) => b.createdAt.compareTo(a.createdAt));
        final filtered = rows.where((item) {
          final status = item.status.trim().toLowerCase();
          final closed =
              status == 'approved' ||
              status == 'rejected' ||
              status == 'closed' ||
              status == 'done' ||
              status == 'completed';
          return !closed || item.createdAt.toUtc().isAfter(weekAgo);
        }).toList();
        recentRequests = filtered.take(5).toList(growable: false);
      });
    }
    await safeRun(() async {
      final rows = await client.listNotifications(limit: 20);
      rows.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      notifications = rows.where((item) => !item.isRead).take(6).toList();
    });

    if (!mounted) return;
    setState(() {
      _loading = false;
      _latestNews = latestNews;
      _latestSchedule = latestSchedule;
      _recentExams = recentExams;
      _recentMakeups = recentMakeups;
      _recentRequests = recentRequests;
      _newNotifications = notifications;
    });
  }

  void _openFeature(String featureId) {
    final feature = _findFeature(featureId);
    if (feature == null) return;
    widget.onOpenFeature(featureId);
  }

  String _requestLabel(String status) {
    if (!_isRu) return status;
    final normalized = status.trim().toLowerCase();
    if (normalized == 'submitted') return 'Отправлена';
    if (normalized == 'in_progress') return 'В обработке';
    if (normalized == 'approved') return 'Одобрена';
    if (normalized == 'rejected') return 'Отклонена';
    if (normalized == 'closed') return 'Закрыта';
    return status;
  }

  @override
  Widget build(BuildContext context) {
    final user = AppStateScope.of(context).user;
    final today = DateFormat(
      _isRu ? 'd MMMM yyyy, EEEE' : 'EEEE, MMMM d, yyyy',
      _isRu ? 'ru' : 'en',
    ).format(DateTime.now());

    final summaryRows = <String>[
      _t(
        'Новых уведомлений: ${_newNotifications.length}',
        'New notifications: ${_newNotifications.length}',
      ),
      if (_hasFeature('requests'))
        _t(
          'Актуальных заявок: ${_recentRequests.length}',
          'Active requests: ${_recentRequests.length}',
        ),
      if (_hasFeature('makeup'))
        _t(
          'Актуальных отработок: ${_recentMakeups.length}',
          'Active makeups: ${_recentMakeups.length}',
        ),
    ];

    return FeatureScaffold(
      title: _t('Главная', 'Home'),
      subtitle: _t(
        'Ключевые обновления по сервисам и вашим задачам.',
        'Key updates across services and your tasks.',
      ),
      actionLabel: _t('Обновить', 'Refresh'),
      onAction: _loadDashboard,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFFDBECE4), Color(0xFFF2FAF6)],
              ),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: const Color(0xFFC9E2D7)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _t(
                    'Здравствуйте, ${user?.fullName ?? widget.role.title}',
                    'Hello, ${user?.fullName ?? widget.role.title}',
                  ),
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 6),
                Text(today, style: const TextStyle(color: kSecondaryText)),
              ],
            ),
          ),
          const SizedBox(height: 14),
          if (_loading) const Center(child: BrandLoadingIndicator()),
          if (_error != null) ...[
            InlineNotice(message: _error!, isError: true),
            const SizedBox(height: 10),
          ],
          if (!_loading) ...[
            if (_hasFeature('news'))
              _HomeDashboardCard(
                title: _t('Последняя новость', 'Latest news'),
                actionLabel: _t('Открыть', 'Open'),
                onAction: () => _openFeature('news'),
                child: _latestNews == null
                    ? Text(_t('Новостей пока нет.', 'No news yet.'))
                    : Builder(
                        builder: (context) {
                          final previewText = _newsPreviewText(
                            _latestNews!.body,
                          );
                          final previewImage = _firstImageMedia(
                            _latestNews!.media,
                          );
                          final previewImageUrl = previewImage != null
                              ? _resolveMediaUrl(previewImage.url)
                              : _firstMarkdownImageUrl(_latestNews!.body);
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _latestNews!.title,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              if (previewImageUrl != null) ...[
                                const SizedBox(height: 8),
                                _buildNewsImagePreview(
                                  previewImageUrl,
                                  maxWidth: 520,
                                  maxHeight: 220,
                                  borderRadius: 12,
                                ),
                              ],
                              if (previewText.isNotEmpty) ...[
                                const SizedBox(height: 8),
                                Text(
                                  previewText,
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ],
                          );
                        },
                      ),
              ),
            if (_hasFeature('schedule')) ...[
              const SizedBox(height: 10),
              _HomeDashboardCard(
                title: _t('Последнее расписание', 'Latest schedule upload'),
                actionLabel: _t('Открыть', 'Open'),
                onAction: () => _openFeature('schedule'),
                child: Text(
                  _latestSchedule?.scheduleDate == null
                      ? _t(
                          'Дата расписания отсутствует.',
                          'Schedule date is not set.',
                        )
                      : '${_t('Дата', 'Date')}: ${DateFormat('dd.MM.yyyy').format(_latestSchedule!.scheduleDate!)}',
                ),
              ),
            ],
            if (_hasFeature('exams') && _recentExams.isNotEmpty) ...[
              const SizedBox(height: 10),
              _HomeDashboardCard(
                title: _t('Экзаменационные оценки', 'Exam grades'),
                actionLabel: _t('Открыть', 'Open'),
                onAction: () => _openFeature('exams'),
                child: Column(
                  children: [
                    for (final exam in _recentExams)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text('${exam.studentName} • ${exam.grade}'),
                        subtitle: Text('${exam.examName} • ${exam.groupName}'),
                      ),
                  ],
                ),
              ),
            ],
            if (_hasFeature('makeup') && _recentMakeups.isNotEmpty) ...[
              const SizedBox(height: 10),
              _HomeDashboardCard(
                title: _t(
                  'Отработки (новые/актуальные)',
                  'Makeups (new/active)',
                ),
                actionLabel: _t('Открыть', 'Open'),
                onAction: () => _openFeature('makeup'),
                child: Column(
                  children: [
                    for (final item in _recentMakeups)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text('${item.groupName} • ${item.studentName}'),
                        subtitle: Text(
                          '${DateFormat('dd.MM.yyyy').format(item.classDate)} • ${item.status}',
                        ),
                      ),
                  ],
                ),
              ),
            ],
            if (_hasFeature('requests') && _recentRequests.isNotEmpty) ...[
              const SizedBox(height: 10),
              _HomeDashboardCard(
                title: _t('Заявки (новые/актуальные)', 'Requests (new/active)'),
                actionLabel: _t('Открыть', 'Open'),
                onAction: () => _openFeature('requests'),
                child: Column(
                  children: [
                    for (final item in _recentRequests)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(item.requestType),
                        subtitle: Text(
                          '${item.studentName} • ${_requestLabel(item.status)}',
                        ),
                      ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 10),
            _HomeDashboardCard(
              title: _t('Новые уведомления', 'New notifications'),
              actionLabel: _t('Открыть', 'Open'),
              onAction: () {
                pushAdaptivePage<void>(context, const NotificationsPage());
              },
              child: _newNotifications.isEmpty
                  ? Text(_t('Новых уведомлений нет.', 'No new notifications.'))
                  : Column(
                      children: [
                        for (final item in _newNotifications)
                          ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: Text(item.title),
                            subtitle: Text(
                              DateFormat(
                                'dd.MM.yyyy HH:mm',
                              ).format(item.createdAt),
                            ),
                          ),
                      ],
                    ),
            ),
            const SizedBox(height: 10),
            _HomeDashboardCard(
              title: _t('Что нового', 'What is new'),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final row in summaryRows) ...[
                    Row(
                      children: [
                        const Icon(
                          Icons.fiber_manual_record,
                          size: 8,
                          color: kBrandPrimary,
                        ),
                        const SizedBox(width: 8),
                        Expanded(child: Text(row)),
                      ],
                    ),
                    if (row != summaryRows.last) const SizedBox(height: 8),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _HomeDashboardCard extends StatelessWidget {
  const _HomeDashboardCard({
    required this.title,
    required this.child,
    this.actionLabel,
    this.onAction,
  });

  final String title;
  final Widget child;
  final String? actionLabel;
  final VoidCallback? onAction;

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
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 16,
                    ),
                  ),
                ),
                if (actionLabel != null && onAction != null)
                  TextButton(onPressed: onAction, child: Text(actionLabel!)),
              ],
            ),
            const SizedBox(height: 8),
            child,
          ],
        ),
      ),
    );
  }
}

class HomePage extends StatelessWidget {
  const HomePage({super.key, required this.role});

  final RoleDefinition role;

  void _openFeature(BuildContext context, FeatureDefinition action) {
    final localeCode = AppStateScope.of(context).locale.languageCode;
    final isRu = localeCode == 'ru';
    pushAdaptivePage<void>(
      context,
      _FeatureStandalonePage(
        title: _featureTitle(action.id, action.title, isRu),
        accent: role.color,
        child: action.builder(context),
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
        case 'makeup':
          return 'Missed class makeups';
        case 'admin_panel':
          return 'Users and system CRUD';
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
      case 'makeup':
        return 'Отработки занятий';
      case 'admin_panel':
        return 'Пользователи и управление системой';
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
      case 'makeup':
        return 'Отработки';
      case 'admin_panel':
        return 'Админ панель';
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
    final localeCode = AppStateScope.of(context).locale.languageCode;
    final isRu = localeCode == 'ru';
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
                  role.color.withValues(alpha: 0.25),
                  Color.lerp(role.color, Colors.white, 0.8) ?? Colors.white,
                ],
              ),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: role.color.withValues(alpha: 0.25)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    CircleAvatar(
                      radius: 28,
                      backgroundColor: role.color.withValues(alpha: 0.18),
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
                          Colors.white.withValues(alpha: 0.9),
                        ],
                      ),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: role.color.withValues(alpha: 0.12),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            CircleAvatar(
                              backgroundColor: role.color.withValues(
                                alpha: 0.15,
                              ),
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
                                color: role.color.withValues(alpha: 0.09),
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
                            color: role.color.withValues(alpha: 0.7),
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
        color: Colors.white.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: accent.withValues(alpha: 0.2)),
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
        backgroundColor: accent.withValues(alpha: 0.14),
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
                        backgroundColor: widget.accent.withValues(alpha: 0.12),
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
                        backgroundColor: widget.accent.withValues(alpha: 0.12),
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

  bool get _useDialogForRoutes {
    if (kIsWeb) return true;
    return defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.linux;
  }

  Future<T?> _openNewsRoute<T>(Widget child) {
    if (!_useDialogForRoutes) {
      return Navigator.of(
        context,
      ).push<T>(MaterialPageRoute(builder: (_) => child));
    }
    return showDialog<T>(
      context: context,
      barrierDismissible: false,
      builder: (context) => Dialog(
        insetPadding: const EdgeInsets.all(24),
        child: SizedBox(width: 980, height: 760, child: child),
      ),
    );
  }

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
        clearMyReaction: nextReaction == null,
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
          clearMyReaction: result.myReaction == null,
        );
      });
    } catch (_) {}
  }

  Future<void> _share(NewsPost post) async {
    try {
      final result = await AppStateScope.of(context).client.shareNews(post.id);
      final index = _posts.indexWhere((item) => item.id == post.id);
      if (!mounted || index == -1) return;
      await Clipboard.setData(
        ClipboardData(text: publicNewsShareLink(context, post.id)),
      );
      setState(
        () => _posts[index] = _posts[index].copyWith(
          shareCount: result.shareCount,
        ),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.shared
                ? 'Репост сохранен, ссылка скопирована'
                : 'Репост уже был, ссылка скопирована',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _noticeError = true;
        _noticeMessage = humanizeError(error);
      });
    }
  }

  Future<void> _openDetail(NewsPost post) async {
    final result = await _openNewsRoute<NewsPostDetailResult>(
      NewsPostDetailPage(post: post, canEdit: widget.canEdit),
    );
    if (result == null) return;
    if (result.deleted) {
      setState(() => _posts.removeWhere((item) => item.id == post.id));
      return;
    }
    final index = _posts.indexWhere((item) => item.id == result.post.id);
    if (index == -1) return;
    setState(() => _posts[index] = result.post);
  }

  Future<void> _openEdit(NewsPost post) async {
    final result = await _openNewsRoute<NewsPost>(
      NewsComposePage(existingPost: post),
    );
    if (result == null) return;
    final index = _posts.indexWhere((item) => item.id == result.id);
    if (index == -1) {
      setState(() => _posts.insert(0, result));
      return;
    }
    setState(() => _posts[index] = result);
  }

  Future<void> _deletePost(NewsPost post) async {
    if (!widget.canEdit) return;
    final client = AppStateScope.of(context).client;
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
      await client.deleteNewsPost(post.id);
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
    final created = await _openNewsRoute<NewsPost>(const NewsComposePage());
    if (created != null) {
      setState(() => _posts.insert(0, created));
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Пост опубликован')));
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
              separatorBuilder: (_, _) => const SizedBox(width: 8),
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
                                kBrandPrimary.withValues(alpha: 0.25),
                                kInfo.withValues(alpha: 0.25),
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
                              color: Colors.white.withValues(alpha: 0.92),
                              borderRadius: BorderRadius.circular(22),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.06),
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
                                          color: kBrandPrimary.withValues(
                                            alpha: 0.12,
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
                                      PopupMenuButton<String>(
                                        onSelected: (value) {
                                          if (value == 'edit') {
                                            _openEdit(post);
                                            return;
                                          }
                                          if (value == 'delete') {
                                            _deletePost(post);
                                          }
                                        },
                                        itemBuilder: (context) => const [
                                          PopupMenuItem(
                                            value: 'edit',
                                            child: Text('Редактировать'),
                                          ),
                                          PopupMenuItem(
                                            value: 'delete',
                                            child: Text('Удалить'),
                                          ),
                                        ],
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
                                _NewsBodyContent(
                                  body: post.body,
                                  media: post.media,
                                  onOpenMedia: (index) =>
                                      _openMediaViewer(post.media, index),
                                ),
                                if (post.media.isNotEmpty) ...[
                                  ...() {
                                    final remainingMedia =
                                        _newsRemainingMediaIndices(
                                          post.body,
                                          post.media,
                                        );
                                    if (remainingMedia.isEmpty) {
                                      return const <Widget>[];
                                    }
                                    return <Widget>[
                                      const SizedBox(height: 12),
                                      Column(
                                        children: [
                                          for (
                                            int pos = 0;
                                            pos < remainingMedia.length;
                                            pos++
                                          ) ...[
                                            if (pos > 0)
                                              const SizedBox(height: 10),
                                            _buildNewsMediaBlock(
                                              media: post.media,
                                              mediaIndex: remainingMedia[pos],
                                              previewHeight: 190,
                                              onOpen: (index) =>
                                                  _openMediaViewer(
                                                    post.media,
                                                    index,
                                                  ),
                                            ),
                                          ],
                                        ],
                                      ),
                                    ];
                                  }(),
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
    pushAdaptivePage<void>(
      context,
      MediaViewerPage(media: media, initialIndex: startIndex),
      width: 1180,
      height: 840,
    );
  }
}

Widget _buildNewsMediaBlock({
  required List<NewsMedia> media,
  required int mediaIndex,
  required void Function(int index) onOpen,
  double previewHeight = 220,
}) {
  final item = media[mediaIndex];
  final url = _resolveMediaUrl(item.url);
  final normalizedHeight = previewHeight
      .clamp(140.0, kNewsMediaMaxHeight)
      .toDouble();
  if (_isVideo(item)) {
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: kNewsMediaMaxWidth),
        child: GestureDetector(
          onTap: () => onOpen(mediaIndex),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: SizedBox(
              height: normalizedHeight,
              width: double.infinity,
              child: NewsVideoPreview(url: url),
            ),
          ),
        ),
      ),
    );
  }
  if (_isImage(item)) {
    return _buildNewsImagePreview(
      url,
      maxWidth: kNewsMediaMaxWidth,
      maxHeight: normalizedHeight,
      borderRadius: 16,
      onTap: () => onOpen(mediaIndex),
    );
  }
  return Align(
    alignment: Alignment.centerLeft,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: kNewsMediaMaxWidth),
      child: NewsFileCard(media: item, url: url),
    ),
  );
}

Widget _buildNewsImagePreview(
  String url, {
  required double maxWidth,
  required double maxHeight,
  required double borderRadius,
  VoidCallback? onTap,
}) {
  Widget child = Align(
    alignment: Alignment.centerLeft,
    child: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth, maxHeight: maxHeight),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: DecoratedBox(
          decoration: const BoxDecoration(color: kSecondaryBackground),
          child: Image.network(
            url,
            fit: BoxFit.contain,
            alignment: Alignment.center,
            loadingBuilder: (context, image, progress) {
              if (progress == null) {
                return image;
              }
              return SizedBox(
                height: 180,
                child: const Center(
                  child: BrandLoadingIndicator(logoSize: 40, spacing: 8),
                ),
              );
            },
            errorBuilder: (context, error, stackTrace) => const SizedBox(
              height: 120,
              child: Center(
                child: Icon(Icons.broken_image_outlined, color: kMutedText),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  if (onTap != null) {
    child = GestureDetector(onTap: onTap, child: child);
  }
  return child;
}

class NewsComposePage extends StatefulWidget {
  const NewsComposePage({super.key, this.existingPost});

  final NewsPost? existingPost;

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
  bool get _isEdit => widget.existingPost != null;

  @override
  void initState() {
    super.initState();
    final existing = widget.existingPost;
    if (existing != null) {
      _titleController.text = existing.title;
      _bodyController.text = existing.body;
      _category = existing.category;
      _pinned = existing.pinned;
    }
  }

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
    if (_titleController.text.trim().isEmpty ||
        _bodyController.text.trim().isEmpty) {
      setState(() {
        _noticeError = true;
        _noticeMessage = 'Заполните заголовок и текст поста.';
      });
      return;
    }
    if (_submitting) return;
    setState(() {
      _submitting = true;
      _noticeMessage = null;
    });
    try {
      final client = AppStateScope.of(context).client;
      late final NewsPost saved;
      if (_isEdit) {
        saved = await client.updateNewsPost(
          widget.existingPost!.id,
          title: _titleController.text.trim(),
          body: _bodyController.text.trim(),
          category: _category,
          pinned: _pinned,
        );
      } else {
        saved = await client.createNews(
          title: _titleController.text.trim(),
          body: _bodyController.text.trim(),
          category: _category,
          pinned: _pinned,
          media: _media,
        );
      }
      if (!mounted) return;
      Navigator.pop(context, saved);
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

  Future<void> _insertInlineImageUrl() async {
    final controller = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Вставить изображение в текст'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: 'URL картинки',
            hintText: 'https://...',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Вставить'),
          ),
        ],
      ),
    );
    if (url == null || url.isEmpty) return;
    final line = '\n![image]($url)\n';
    final current = _bodyController.text;
    _bodyController.text = current + line;
    _bodyController.selection = TextSelection.collapsed(
      offset: _bodyController.text.length,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEdit ? 'Редактировать пост' : 'Создать пост'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          if (_noticeMessage != null) ...[
            InlineNotice(message: _noticeMessage!, isError: _noticeError),
            const SizedBox(height: 12),
          ],
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
          OutlinedButton.icon(
            onPressed: _insertInlineImageUrl,
            icon: const Icon(Icons.image_outlined),
            label: const Text('Вставить картинку в текст по URL'),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _category,
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
          if (!_isEdit) ...[
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
                    InputChip(
                      label: Text(_media[i].filename),
                      avatar: const Icon(Icons.insert_drive_file, size: 16),
                      onPressed: () {
                        _bodyController.text =
                            '${_bodyController.text}\n{{media:${i + 1}}}\n';
                      },
                      onDeleted: () => setState(() => _media.removeAt(i)),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              const Text(
                'Нажмите на файл, чтобы вставить маркер {{media:N}} в текст.',
                style: TextStyle(color: kSecondaryText, fontSize: 12),
              ),
            ],
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
                : Text(_isEdit ? 'Сохранить изменения' : 'Опубликовать'),
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

class NewsPostDetailResult {
  const NewsPostDetailResult({required this.post, required this.deleted});

  final NewsPost post;
  final bool deleted;
}

class _NewsPostDetailPageState extends State<NewsPostDetailPage> {
  String? _noticeMessage;
  bool _noticeError = false;
  late NewsPost _post;
  final _commentController = TextEditingController();
  bool _loading = false;
  bool _sending = false;
  bool _initialized = false;
  bool _deleted = false;

  bool get _useDialogForRoutes {
    if (kIsWeb) return true;
    return defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.linux;
  }

  Future<T?> _openNewsRoute<T>(Widget child) {
    if (!_useDialogForRoutes) {
      return Navigator.of(
        context,
      ).push<T>(MaterialPageRoute(builder: (_) => child));
    }
    return showDialog<T>(
      context: context,
      barrierDismissible: false,
      builder: (context) => Dialog(
        insetPadding: const EdgeInsets.all(24),
        child: SizedBox(width: 980, height: 760, child: child),
      ),
    );
  }

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
        clearMyReaction: nextReaction == null,
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
          clearMyReaction: result.myReaction == null,
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
      final result = await AppStateScope.of(context).client.shareNews(_post.id);
      if (!mounted) return;
      await Clipboard.setData(
        ClipboardData(text: publicNewsShareLink(context, _post.id)),
      );
      setState(() => _post = _post.copyWith(shareCount: result.shareCount));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.shared
                ? 'Репост сохранен, ссылка скопирована'
                : 'Репост уже был, ссылка скопирована',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _noticeError = true;
        _noticeMessage = humanizeError(error);
      });
    }
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
    if (!_canManageComment(comment)) return;
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

  bool _canManageComment(NewsComment comment) {
    final user = AppStateScope.of(context).user;
    if (user == null) return false;
    if (user.role == 'admin') return true;
    return comment.userId == user.id;
  }

  Future<void> _editComment(NewsComment comment) async {
    if (!_canManageComment(comment)) return;
    final client = AppStateScope.of(context).client;
    final controller = TextEditingController(text: comment.text);
    final nextText = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Изменить комментарий'),
        content: TextField(
          controller: controller,
          maxLines: 4,
          decoration: const InputDecoration(labelText: 'Комментарий'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    if (nextText == null || nextText.isEmpty || nextText == comment.text) {
      return;
    }
    try {
      final updated = await client.updateNewsComment(
        postId: _post.id,
        commentId: comment.id,
        text: nextText,
      );
      if (!mounted) return;
      setState(() {
        _post = _post.copyWith(
          comments: _post.comments.map((item) {
            if (item.id != updated.id) return item;
            return updated;
          }).toList(),
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
    final client = AppStateScope.of(context).client;
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
      await client.deleteNewsPost(_post.id);
      if (!mounted) return;
      _deleted = true;
      Navigator.pop(context, NewsPostDetailResult(post: _post, deleted: true));
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

  String _roleLabel(String? role) {
    final value = (role ?? '').trim().toLowerCase();
    switch (value) {
      case 'admin':
        return 'Админ';
      case 'teacher':
        return 'Преподаватель';
      case 'student':
        return 'Студент';
      case 'parent':
        return 'Родитель';
      case 'smm':
        return 'SMM';
      case 'request_handler':
        return 'Обработчик';
      default:
        return role?.trim().isNotEmpty == true ? role!.trim() : 'Пользователь';
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || !mounted) return;
        Navigator.pop(
          context,
          NewsPostDetailResult(post: _post, deleted: _deleted),
        );
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            onPressed: () {
              Navigator.pop(
                context,
                NewsPostDetailResult(post: _post, deleted: _deleted),
              );
            },
            icon: const Icon(Icons.arrow_back),
          ),
          title: const Text('Пост'),
          actions: [
            if (widget.canEdit)
              IconButton(
                onPressed: () async {
                  final updated = await _openNewsRoute<NewsPost>(
                    NewsComposePage(existingPost: _post),
                  );
                  if (updated != null && mounted) {
                    setState(() => _post = updated);
                  }
                },
                icon: const Icon(Icons.edit_outlined),
              ),
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
                    InlineNotice(
                      message: _noticeMessage!,
                      isError: _noticeError,
                    ),
                  if (_noticeMessage != null) const SizedBox(height: 12),
                  Text(
                    _post.title,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 6),
                  _NewsBodyContent(
                    body: _post.body,
                    media: _post.media,
                    onOpenMedia: (index) =>
                        _openMediaViewer(_post.media, index),
                  ),
                  ...() {
                    final remainingMedia = _newsRemainingMediaIndices(
                      _post.body,
                      _post.media,
                    );
                    if (remainingMedia.isEmpty) {
                      return const <Widget>[SizedBox(height: 12)];
                    }
                    return <Widget>[
                      const SizedBox(height: 12),
                      Column(
                        children: [
                          for (int i = 0; i < remainingMedia.length; i++)
                            Padding(
                              padding: EdgeInsets.only(
                                bottom: i == remainingMedia.length - 1 ? 0 : 10,
                              ),
                              child: _buildNewsMediaBlock(
                                media: _post.media,
                                mediaIndex: remainingMedia[i],
                                previewHeight: 240,
                                onOpen: (mediaIndex) =>
                                    _openMediaViewer(_post.media, mediaIndex),
                              ),
                            ),
                        ],
                      ),
                    ];
                  }(),
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
                    'Комментарии',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  for (final comment in _post.comments)
                    Card(
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: kSecondaryBackground,
                          backgroundImage:
                              (comment.userAvatarUrl != null &&
                                  comment.userAvatarUrl!.trim().isNotEmpty)
                              ? NetworkImage(
                                  _resolveMediaUrl(
                                    comment.userAvatarUrl!.trim(),
                                  ),
                                )
                              : null,
                          child:
                              (comment.userAvatarUrl == null ||
                                  comment.userAvatarUrl!.trim().isEmpty)
                              ? Text(
                                  comment.userName.isEmpty
                                      ? '?'
                                      : comment.userName[0].toUpperCase(),
                                )
                              : null,
                        ),
                        title: Text(comment.userName),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${_roleLabel(comment.userRole)} • ${DateFormat('dd.MM.yyyy HH:mm').format(comment.createdAt)}',
                              style: const TextStyle(
                                color: kSecondaryText,
                                fontSize: 12,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(comment.text),
                            if (comment.updatedAt != null)
                              Text(
                                'изменено ${DateFormat('dd.MM HH:mm').format(comment.updatedAt!)}',
                                style: const TextStyle(
                                  color: kMutedText,
                                  fontSize: 11,
                                ),
                              ),
                          ],
                        ),
                        trailing: _canManageComment(comment)
                            ? PopupMenuButton<String>(
                                onSelected: (value) {
                                  if (value == 'edit') {
                                    _editComment(comment);
                                    return;
                                  }
                                  if (value == 'delete') {
                                    _deleteComment(comment);
                                  }
                                },
                                itemBuilder: (context) => const [
                                  PopupMenuItem(
                                    value: 'edit',
                                    child: Text('Редактировать'),
                                  ),
                                  PopupMenuItem(
                                    value: 'delete',
                                    child: Text('Удалить'),
                                  ),
                                ],
                              )
                            : null,
                      ),
                    ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _commentController,
                    decoration: const InputDecoration(
                      labelText: 'Добавить комментарий',
                    ),
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
                        : const Text('Отправить'),
                  ),
                ],
              ),
      ),
    );
  }

  void _openMediaViewer(List<NewsMedia> media, int startIndex) {
    pushAdaptivePage<void>(
      context,
      MediaViewerPage(media: media, initialIndex: startIndex),
      width: 1180,
      height: 840,
    );
  }
}

class _NewsBodyContent extends StatelessWidget {
  const _NewsBodyContent({
    required this.body,
    required this.media,
    required this.onOpenMedia,
  });

  final String body;
  final List<NewsMedia> media;
  final void Function(int mediaIndex) onOpenMedia;

  static final RegExp _mediaToken = RegExp(r'^\s*\{\{media:(\d+)\}\}\s*$');
  static final RegExp _imageMarkdown = RegExp(r'!\[[^\]]*\]\(([^)]+)\)');

  @override
  Widget build(BuildContext context) {
    final lines = body.split('\n');
    final children = <Widget>[];
    for (final rawLine in lines) {
      final line = rawLine.trimRight();
      if (line.trim().isEmpty) {
        children.add(const SizedBox(height: 6));
        continue;
      }
      final mediaMatch = _mediaToken.firstMatch(line);
      if (mediaMatch != null) {
        final index = int.tryParse(mediaMatch.group(1) ?? '');
        if (index != null && index > 0 && index <= media.length) {
          final mediaIndex = index - 1;
          children.add(
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: _buildNewsMediaBlock(
                media: media,
                mediaIndex: mediaIndex,
                onOpen: onOpenMedia,
                previewHeight: 220,
              ),
            ),
          );
          continue;
        }
      }
      final markdownMatch = _imageMarkdown.firstMatch(line);
      if (markdownMatch != null) {
        final imageUrl = (markdownMatch.group(1) ?? '').trim();
        if (imageUrl.isNotEmpty) {
          children.add(
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: _buildNewsImagePreview(
                _resolveMediaUrl(imageUrl),
                maxWidth: kNewsMediaMaxWidth,
                maxHeight: 220,
                borderRadius: 14,
              ),
            ),
          );
          continue;
        }
      }
      children.add(
        Padding(padding: const EdgeInsets.only(bottom: 4), child: Text(line)),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
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
          if (_isImage(media)) {
            return InteractiveViewer(
              child: Center(child: Image.network(url, fit: BoxFit.contain)),
            );
          }
          return InteractiveViewer(
            child: Center(
              child: SizedBox(
                width: 620,
                child: NewsFileCard(media: media, url: url),
              ),
            ),
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
  final mime = (media.mimeType ?? '').toLowerCase();
  if (mime.startsWith('video/')) return true;
  final type = media.mediaType.toLowerCase();
  if (type.contains('video')) return true;
  final ext = _mediaExtension(media);
  return <String>{
    '.mp4',
    '.mov',
    '.avi',
    '.webm',
    '.mkv',
    '.m4v',
  }.contains(ext);
}

bool _isImage(NewsMedia media) {
  final mime = (media.mimeType ?? '').toLowerCase();
  if (mime.startsWith('image/')) return true;
  final type = media.mediaType.toLowerCase();
  if (type.contains('image')) return true;
  final ext = _mediaExtension(media);
  return <String>{
    '.jpg',
    '.jpeg',
    '.png',
    '.gif',
    '.webp',
    '.bmp',
    '.svg',
    '.heic',
    '.heif',
  }.contains(ext);
}

String _mediaExtension(NewsMedia media) {
  String source = media.originalName.trim();
  if (source.isEmpty) {
    source = media.url.trim();
  }
  if (source.isEmpty) return '';
  final normalized = source.split('?').first.split('#').first.toLowerCase();
  final dot = normalized.lastIndexOf('.');
  if (dot < 0 || dot == normalized.length - 1) {
    return '';
  }
  return normalized.substring(dot);
}

class NewsFileCard extends StatelessWidget {
  const NewsFileCard({super.key, required this.media, required this.url});

  final NewsMedia media;
  final String url;

  @override
  Widget build(BuildContext context) {
    final filename = media.originalName.trim().isEmpty
        ? 'Файл'
        : media.originalName.trim();
    final downloadUrl = _resolveNewsDownloadUrl(url);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: kSecondaryBackground,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: kBrandPrimary.withValues(alpha: 0.2)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.insert_drive_file_outlined,
                color: kBrandPrimary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  filename,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              FilledButton.tonalIcon(
                onPressed: () => _openExternalNewsUrl(context, url),
                icon: const Icon(Icons.open_in_new, size: 16),
                label: const Text('Открыть'),
              ),
              OutlinedButton.icon(
                onPressed: () => _openExternalNewsUrl(context, downloadUrl),
                icon: const Icon(Icons.download_outlined, size: 16),
                label: const Text('Скачать'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

String _resolveMediaUrl(String url) {
  var value = url.trim();
  if (value.isEmpty) return value;

  // Normalize escaped slashes and quoted blobs that can appear in legacy payloads.
  value = value.replaceAll(r'\/', '/').replaceAll('\\', '');
  if ((value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))) {
    value = value.substring(1, value.length - 1).trim();
  }

  // If URL was accidentally embedded inside a JSON/error blob, extract media path.
  final embedded = RegExp(
    r'(https?://\S+/media/\S+|/media/\S+|media/\S+)',
    caseSensitive: false,
  ).firstMatch(value);
  if (embedded != null) {
    value = embedded.group(0)!.trim();
    while (value.isNotEmpty && '"\'},'.contains(value[value.length - 1])) {
      value = value.substring(0, value.length - 1);
    }
  }

  if (value.startsWith('http://') || value.startsWith('https://')) {
    return value;
  }
  if (!value.startsWith('/')) {
    value = '/$value';
  }
  return '$apiBaseUrl$value';
}

String _resolveNewsDownloadUrl(String url) {
  final trimmed = url.trim();
  if (trimmed.isEmpty) return _resolveMediaUrl(url);
  if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
    return trimmed;
  }
  if (trimmed.startsWith('/media/news/')) {
    return '$apiBaseUrl/media/news-download/${trimmed.substring('/media/news/'.length)}';
  }
  if (trimmed.startsWith('media/news/')) {
    return '$apiBaseUrl/media/news-download/${trimmed.substring('media/news/'.length)}';
  }
  return _resolveMediaUrl(trimmed);
}

Future<void> _openExternalNewsUrl(BuildContext context, String url) async {
  final uri = Uri.tryParse(url.trim());
  if (uri == null) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Некорректная ссылка')));
    return;
  }
  final ok = await launchUrl(uri, mode: LaunchMode.platformDefault);
  if (!ok && context.mounted) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Не удалось открыть ссылку')));
  }
}
