import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:intl/intl.dart';

class ApiClient {
  ApiClient({required String baseUrl, this.token})
    : baseUrl = _normalizeBaseUrl(baseUrl);

  final String baseUrl;
  final String? token;

  static String _normalizeBaseUrl(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return trimmed;
    }
    return trimmed.replaceFirst(RegExp(r'/+$'), '');
  }

  Map<String, String> _headers({bool jsonBody = false}) {
    final headers = <String, String>{};
    if (jsonBody) {
      headers['Content-Type'] = 'application/json';
    }
    if (token != null && token!.isNotEmpty) {
      headers['Authorization'] = 'Bearer $token';
    }
    return headers;
  }

  String _formatDateOnly(DateTime value) {
    final localDate = DateTime(value.year, value.month, value.day);
    return DateFormat('yyyy-MM-dd').format(localDate);
  }

  String _sanitizeFilename(String filename) {
    final dot = filename.lastIndexOf('.');
    final base = dot == -1 ? filename : filename.substring(0, dot);
    final ext = dot == -1 ? '' : filename.substring(dot);
    final safeBase = base.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final safeExt = ext.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final combined = (safeBase.isEmpty ? 'schedule' : safeBase) + safeExt;
    return combined;
  }

  String _sanitizeMultipartFilename(String filename) {
    final trimmed = filename.trim();
    final safe = _sanitizeFilename(trimmed);
    if (safe.trim().isEmpty) {
      return 'file.bin';
    }
    return safe;
  }

  String? _guessMimeTypeByFilename(String filename) {
    final lower = filename.toLowerCase();
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
      return 'image/jpeg';
    }
    if (lower.endsWith('.png')) {
      return 'image/png';
    }
    if (lower.endsWith('.gif')) {
      return 'image/gif';
    }
    if (lower.endsWith('.webp')) {
      return 'image/webp';
    }
    if (lower.endsWith('.bmp')) {
      return 'image/bmp';
    }
    if (lower.endsWith('.svg')) {
      return 'image/svg+xml';
    }
    if (lower.endsWith('.mp4')) {
      return 'video/mp4';
    }
    if (lower.endsWith('.mov')) {
      return 'video/quicktime';
    }
    if (lower.endsWith('.webm')) {
      return 'video/webm';
    }
    if (lower.endsWith('.avi')) {
      return 'video/x-msvideo';
    }
    if (lower.endsWith('.mkv')) {
      return 'video/x-matroska';
    }
    if (lower.endsWith('.pdf')) {
      return 'application/pdf';
    }
    if (lower.endsWith('.doc')) {
      return 'application/msword';
    }
    if (lower.endsWith('.docx')) {
      return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
    }
    if (lower.endsWith('.xls')) {
      return 'application/vnd.ms-excel';
    }
    if (lower.endsWith('.xlsx')) {
      return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
    }
    if (lower.endsWith('.txt')) {
      return 'text/plain';
    }
    return null;
  }

  MediaType? _parseMediaType(String? value) {
    if (value == null || value.trim().isEmpty) {
      return null;
    }
    try {
      return MediaType.parse(value.trim());
    } catch (_) {
      return null;
    }
  }

  Future<RegisterResponse> register({
    required String fullName,
    required String email,
    required String password,
    required String role,
    bool? notifySchedule,
    bool? notifyRequests,
    String? studentGroup,
    String? teacherName,
    String? childFullName,
    int? parentStudentId,
    String? deviceId,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/auth/register'),
      headers: _headers(jsonBody: true),
      body: jsonEncode({
        'role': role,
        'full_name': fullName,
        'email': email,
        'password': password,
        'notify_schedule': notifySchedule,
        'notify_requests': notifyRequests,
        'student_group': studentGroup,
        'teacher_name': teacherName,
        'child_full_name': childFullName,
        'parent_student_id': parentStudentId,
        'device_id': deviceId,
      }),
    );
    return _parseRegisterResponse(response);
  }

  Future<AuthResponse> login({
    required String email,
    required String password,
    String? deviceId,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/auth/login'),
      headers: _headers(jsonBody: true),
      body: jsonEncode({
        'email': email,
        'password': password,
        'device_id': deviceId,
      }),
    );
    return _parseAuthResponse(response);
  }

  Future<bool> checkEmailRegistered(String email) async {
    final uri = Uri.parse(
      '$baseUrl/auth/check-email',
    ).replace(queryParameters: {'email': email.trim()});
    final response = await http.get(uri, headers: _headers());
    _ensureSuccess(response);
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return (data['exists'] as bool?) ?? false;
  }

  Future<UserProfile> me() async {
    final response = await http.get(
      Uri.parse('$baseUrl/auth/me'),
      headers: _headers(),
    );
    _ensureSuccess(response);
    return UserProfile.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  Future<UserProfile> updateUser(
    int userId,
    Map<String, dynamic> payload,
  ) async {
    final response = await http.patch(
      Uri.parse('$baseUrl/users/$userId'),
      headers: _headers(jsonBody: true),
      body: jsonEncode(payload),
    );
    _ensureSuccess(response);
    return UserProfile.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  Future<List<UserProfile>> listUsers({
    String? role,
    bool? approved,
    String? sort,
  }) async {
    final query = <String, String>{};
    if (role != null && role.trim().isNotEmpty) {
      query['role'] = role.trim();
    }
    if (approved != null) {
      query['approved'] = approved ? 'true' : 'false';
    }
    if (sort != null && sort.trim().isNotEmpty) {
      query['sort'] = sort.trim();
    }
    final uri = Uri.parse(
      '$baseUrl/users',
    ).replace(queryParameters: query.isEmpty ? null : query);
    final response = await http.get(uri, headers: _headers());
    _ensureSuccess(response);
    final data = jsonDecode(response.body) as List<dynamic>;
    return data
        .map((item) => UserProfile.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<List<UserPublicProfile>> listApprovedStudents() async {
    final response = await http.get(
      Uri.parse('$baseUrl/users/students/approved'),
      headers: _headers(),
    );
    _ensureSuccess(response);
    final data = jsonDecode(response.body) as List<dynamic>;
    return data
        .map((item) => UserPublicProfile.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<UserProfile> createUserAsAdmin({
    required String role,
    required String fullName,
    required String email,
    required String password,
    bool? notifySchedule,
    bool? notifyRequests,
    String? studentGroup,
    String? teacherName,
    String? childFullName,
    int? parentStudentId,
    bool? isApproved,
    String? deviceId,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/users'),
      headers: _headers(jsonBody: true),
      body: jsonEncode({
        'role': role,
        'full_name': fullName,
        'email': email,
        'password': password,
        'notify_schedule': notifySchedule,
        'notify_requests': notifyRequests,
        'student_group': studentGroup,
        'teacher_name': teacherName,
        'child_full_name': childFullName,
        'parent_student_id': parentStudentId,
        'is_approved': isApproved,
        'device_id': deviceId,
      }),
    );
    _ensureSuccess(response);
    return UserProfile.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  Future<void> deleteUserAsAdmin(int userId) async {
    final response = await http.delete(
      Uri.parse('$baseUrl/users/$userId'),
      headers: _headers(),
    );
    _ensureSuccess(response);
  }

  Future<UserProfile> approveUserAsAdmin(int userId) async {
    final response = await http.post(
      Uri.parse('$baseUrl/users/$userId/approve'),
      headers: _headers(),
    );
    _ensureSuccess(response);
    return UserProfile.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  Future<UserPublicProfile> getUserPublic(int userId) async {
    final response = await http.get(
      Uri.parse('$baseUrl/users/$userId/public'),
      headers: _headers(),
    );
    _ensureSuccess(response);
    return UserPublicProfile.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  Future<void> logout() async {
    if (token == null || token!.isEmpty) {
      return;
    }
    final response = await http.post(
      Uri.parse('$baseUrl/auth/logout'),
      headers: _headers(),
    );
    _ensureSuccess(response);
  }

  Future<void> registerDeviceToken({
    required String token,
    String? platform,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/devices/register'),
      headers: _headers(jsonBody: true),
      body: jsonEncode({'token': token, 'platform': platform}),
    );
    _ensureSuccess(response);
  }

  Future<List<AppNotification>> listNotifications({
    int offset = 0,
    int limit = 50,
  }) async {
    final uri = Uri.parse('$baseUrl/notifications').replace(
      queryParameters: {'offset': offset.toString(), 'limit': limit.toString()},
    );
    final response = await http.get(uri, headers: _headers());
    _ensureSuccess(response);
    final data = jsonDecode(response.body) as List<dynamic>;
    return data
        .map((item) => AppNotification.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<AppNotification> markNotificationRead(int id) async {
    final response = await http.post(
      Uri.parse('$baseUrl/notifications/$id/read'),
      headers: _headers(),
    );
    _ensureSuccess(response);
    return AppNotification.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  Future<void> deleteNotification(int id) async {
    final response = await http.delete(
      Uri.parse('$baseUrl/notifications/$id'),
      headers: _headers(),
    );
    _ensureSuccess(response);
  }

  Future<List<NewsPost>> listNews({
    int offset = 0,
    int limit = 20,
    String? category,
  }) async {
    final uri = Uri.parse('$baseUrl/news').replace(
      queryParameters: {
        'offset': offset.toString(),
        'limit': limit.toString(),
        if (category != null && category.trim().isNotEmpty)
          'category': category.trim(),
      },
    );
    final response = await http.get(uri, headers: _headers());
    _ensureSuccess(response);
    final data = jsonDecode(response.body) as List<dynamic>;
    return data
        .map((item) => NewsPost.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<NewsPost> createNews({
    required String title,
    required String body,
    String? category,
    bool pinned = false,
    List<NewsMediaUpload> media = const [],
  }) async {
    if (media.isEmpty) {
      final response = await http.post(
        Uri.parse('$baseUrl/news'),
        headers: _headers(jsonBody: true),
        body: jsonEncode({
          'title': title,
          'body': body,
          'category': category,
          'pinned': pinned,
        }),
      );
      _ensureSuccess(response);
      return NewsPost.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>,
      );
    }

    final request = http.MultipartRequest('POST', Uri.parse('$baseUrl/news'));
    request.headers.addAll(_headers());
    request.fields['title'] = title;
    request.fields['body'] = body;
    if (category != null) {
      request.fields['category'] = category;
    }
    request.fields['pinned'] = pinned.toString();
    for (final item in media) {
      final safeName = _sanitizeMultipartFilename(item.filename);
      final mediaType = _parseMediaType(
        item.mimeType ?? _guessMimeTypeByFilename(item.filename),
      );
      try {
        request.files.add(
          http.MultipartFile.fromBytes(
            'files',
            item.bytes,
            filename: safeName,
            contentType: mediaType,
          ),
        );
      } catch (_) {
        request.files.add(
          http.MultipartFile.fromBytes(
            'files',
            item.bytes,
            filename: 'file_${request.files.length + 1}.bin',
            contentType: mediaType,
          ),
        );
      }
    }
    final response = await request.send();
    final responseBytes = await response.stream.toBytes();
    final bodyText = utf8.decode(responseBytes, allowMalformed: true);
    final wrapped = http.Response(bodyText, response.statusCode);
    _ensureSuccess(wrapped);
    try {
      return NewsPost.fromJson(_decodeJsonObject(bodyText));
    } catch (_) {
      final fallback = await listNews(
        offset: 0,
        limit: 1,
        category: category ?? 'news',
      );
      if (fallback.isNotEmpty) {
        return fallback.first;
      }
      throw ApiException(response.statusCode, bodyText);
    }
  }

  Future<NewsLikeResult> toggleNewsLike(
    int postId, {
    bool? like,
    String? reaction,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/news/$postId/like'),
      headers: _headers(jsonBody: true),
      body: jsonEncode({'like': like, 'reaction': reaction}),
    );
    _ensureSuccess(response);
    return NewsLikeResult.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  Future<NewsComment> addNewsComment(int postId, String text) async {
    final response = await http.post(
      Uri.parse('$baseUrl/news/$postId/comment'),
      headers: _headers(jsonBody: true),
      body: jsonEncode({'text': text}),
    );
    _ensureSuccess(response);
    return NewsComment.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  Future<NewsComment> updateNewsComment({
    required int postId,
    required int commentId,
    required String text,
  }) async {
    final response = await http.patch(
      Uri.parse('$baseUrl/news/$postId/comment/$commentId'),
      headers: _headers(jsonBody: true),
      body: jsonEncode({'text': text}),
    );
    _ensureSuccess(response);
    return NewsComment.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  Future<NewsPost> getNewsPost(int postId) async {
    final response = await http.get(
      Uri.parse('$baseUrl/news/$postId'),
      headers: _headers(),
    );
    _ensureSuccess(response);
    return NewsPost.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  Future<NewsPost> updateNewsPost(
    int postId, {
    String? title,
    String? body,
    String? category,
    bool? pinned,
  }) async {
    final response = await http.patch(
      Uri.parse('$baseUrl/news/$postId'),
      headers: _headers(jsonBody: true),
      body: jsonEncode({
        if (title != null) 'title': title,
        if (body != null) 'body': body,
        if (category != null) 'category': category,
        if (pinned != null) 'pinned': pinned,
      }),
    );
    _ensureSuccess(response);
    return NewsPost.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  Future<void> deleteNewsPost(int postId) async {
    final response = await http.delete(
      Uri.parse('$baseUrl/news/$postId'),
      headers: _headers(),
    );
    _ensureSuccess(response);
  }

  Future<void> deleteNewsComment({
    required int postId,
    required int commentId,
  }) async {
    final response = await http.delete(
      Uri.parse('$baseUrl/news/$postId/comment/$commentId'),
      headers: _headers(),
    );
    _ensureSuccess(response);
  }

  Future<NewsShareResult> shareNews(int postId) async {
    final response = await http.post(
      Uri.parse('$baseUrl/news/$postId/share'),
      headers: _headers(),
    );
    _ensureSuccess(response);
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return NewsShareResult.fromJson(data);
  }

  Future<ScheduleUpload?> latestSchedule() async {
    final response = await http.get(
      Uri.parse('$baseUrl/schedule/latest'),
      headers: _headers(),
    );
    if (response.statusCode == 200) {
      if (response.body.trim().isEmpty || response.body.trim() == 'null') {
        return null;
      }
      return ScheduleUpload.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>,
      );
    }
    _ensureSuccess(response);
    return null;
  }

  Future<List<ScheduleUpload>> listScheduleUploads() async {
    final response = await http.get(
      Uri.parse('$baseUrl/schedule'),
      headers: _headers(),
    );
    _ensureSuccess(response);
    final data = jsonDecode(response.body) as List<dynamic>;
    return data
        .map((item) => ScheduleUpload.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<ScheduleUpload> updateScheduleUpload({
    required int id,
    DateTime? scheduleDate,
  }) async {
    final response = await http.patch(
      Uri.parse('$baseUrl/schedule/$id'),
      headers: _headers(jsonBody: true),
      body: jsonEncode({
        'schedule_date': scheduleDate == null
            ? ''
            : _formatDateOnly(scheduleDate),
      }),
    );
    _ensureSuccess(response);
    return ScheduleUpload.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  Future<void> deleteScheduleUpload(int id) async {
    final response = await http.delete(
      Uri.parse('$baseUrl/schedule/$id'),
      headers: _headers(),
    );
    _ensureSuccess(response);
  }

  Future<List<String>> listScheduleGroups({DateTime? at}) async {
    final uri = Uri.parse(
      '$baseUrl/schedule/groups',
    ).replace(queryParameters: {if (at != null) 'at': _formatDateOnly(at)});
    final response = await http.get(uri, headers: _headers());
    _ensureSuccess(response);
    final data = jsonDecode(response.body) as List<dynamic>;
    return data.map((item) => item.toString()).toList();
  }

  Future<List<String>> listScheduleTeachers({DateTime? at}) async {
    final uri = Uri.parse(
      '$baseUrl/schedule/teachers',
    ).replace(queryParameters: {if (at != null) 'at': _formatDateOnly(at)});
    final response = await http.get(uri, headers: _headers());
    _ensureSuccess(response);
    final data = jsonDecode(response.body) as List<dynamic>;
    return data.map((item) => item.toString()).toList();
  }

  Future<ScheduleUpload> uploadScheduleBytes({
    required String filename,
    required List<int> bytes,
    DateTime? scheduleDate,
  }) async {
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('$baseUrl/schedule/upload'),
    );
    if (token != null && token!.isNotEmpty) {
      request.headers['Authorization'] = 'Bearer $token';
    }
    final safeName = _sanitizeFilename(filename);
    request.files.add(
      http.MultipartFile.fromBytes('file', bytes, filename: safeName),
    );
    if (scheduleDate != null) {
      request.fields['schedule_date'] = _formatDateOnly(scheduleDate);
    }
    final response = await request.send();
    final responseBytes = await response.stream.toBytes();
    final body = utf8.decode(responseBytes, allowMalformed: true);
    final wrapped = http.Response(body, response.statusCode);
    _ensureSuccess(wrapped);
    try {
      return ScheduleUpload.fromJson(_decodeJsonObject(body));
    } catch (error) {
      throw ApiException(response.statusCode, body);
    }
  }

  Future<List<ScheduleLesson>> scheduleForGroup(
    String groupName, {
    DateTime? at,
  }) async {
    final uri = Uri.parse(
      '$baseUrl/schedule/group/${Uri.encodeComponent(groupName)}',
    ).replace(queryParameters: {if (at != null) 'at': _formatDateOnly(at)});
    final response = await http.get(uri, headers: _headers());
    _ensureSuccess(response);
    final data = jsonDecode(response.body) as List<dynamic>;
    return data
        .map((item) => ScheduleLesson.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<List<ScheduleLesson>> scheduleForMe({DateTime? at}) async {
    final uri = Uri.parse(
      '$baseUrl/schedule/me',
    ).replace(queryParameters: {if (at != null) 'at': _formatDateOnly(at)});
    final response = await http.get(uri, headers: _headers());
    _ensureSuccess(response);
    final data = jsonDecode(response.body) as List<dynamic>;
    return data
        .map((item) => ScheduleLesson.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<List<ScheduleLesson>> scheduleForTeacher(
    String teacherName, {
    DateTime? at,
  }) async {
    final uri = Uri.parse(
      '$baseUrl/schedule/teacher/${Uri.encodeComponent(teacherName)}',
    ).replace(queryParameters: {if (at != null) 'at': _formatDateOnly(at)});
    final response = await http.get(uri, headers: _headers());
    _ensureSuccess(response);
    final data = jsonDecode(response.body) as List<dynamic>;
    return data
        .map((item) => ScheduleLesson.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<List<RequestTicket>> listRequests() async {
    final response = await http.get(
      Uri.parse('$baseUrl/requests'),
      headers: _headers(),
    );
    _ensureSuccess(response);
    final data = jsonDecode(response.body) as List<dynamic>;
    return data
        .map((item) => RequestTicket.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<List<String>> listJournalGroups() async {
    final response = await http.get(
      Uri.parse('$baseUrl/journal/groups'),
      headers: _headers(),
    );
    _ensureSuccess(response);
    final data = jsonDecode(response.body) as List<dynamic>;
    return data.map((item) => item.toString()).toList();
  }

  Future<List<String>> listJournalGroupCatalog() async {
    final response = await http.get(
      Uri.parse('$baseUrl/journal/groups/catalog'),
      headers: _headers(),
    );
    _ensureSuccess(response);
    final data = jsonDecode(response.body) as List<dynamic>;
    return data.map((item) => item.toString()).toList();
  }

  Future<void> upsertJournalGroup(String name) async {
    final response = await http.post(
      Uri.parse('$baseUrl/journal/groups'),
      headers: _headers(jsonBody: true),
      body: jsonEncode({'name': name}),
    );
    _ensureSuccess(response);
  }

  Future<void> deleteJournalGroup(String name) async {
    final uri = Uri.parse(
      '$baseUrl/journal/groups',
    ).replace(queryParameters: {'group_name': name});
    final response = await http.delete(uri, headers: _headers());
    _ensureSuccess(response);
  }

  Future<List<String>> listJournalStudents(String groupName) async {
    final uri = Uri.parse(
      '$baseUrl/journal/students',
    ).replace(queryParameters: {'group_name': groupName});
    final response = await http.get(uri, headers: _headers());
    _ensureSuccess(response);
    final data = jsonDecode(response.body) as List<dynamic>;
    return data.map((item) => item.toString()).toList();
  }

  Future<List<UserPublicProfile>> listConfirmedJournalStudents(
    String groupName,
  ) async {
    final response = await http.get(
      Uri.parse(
        '$baseUrl/journal/groups/${Uri.encodeComponent(groupName)}/confirmed-students',
      ),
      headers: _headers(),
    );
    _ensureSuccess(response);
    final data = jsonDecode(response.body) as List<dynamic>;
    return data
        .map((item) => UserPublicProfile.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<void> upsertJournalStudent({
    required String groupName,
    required String studentName,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/journal/students'),
      headers: _headers(jsonBody: true),
      body: jsonEncode({'group_name': groupName, 'student_name': studentName}),
    );
    _ensureSuccess(response);
  }

  Future<void> deleteJournalStudent({
    required String groupName,
    required String studentName,
  }) async {
    final uri = Uri.parse('$baseUrl/journal/students').replace(
      queryParameters: {'group_name': groupName, 'student_name': studentName},
    );
    final response = await http.delete(uri, headers: _headers());
    _ensureSuccess(response);
  }

  Future<List<DateTime>> listJournalDates(String groupName) async {
    final uri = Uri.parse(
      '$baseUrl/journal/dates',
    ).replace(queryParameters: {'group_name': groupName});
    final response = await http.get(uri, headers: _headers());
    _ensureSuccess(response);
    final data = jsonDecode(response.body) as List<dynamic>;
    return data.map((item) => DateTime.parse(item.toString())).toList();
  }

  Future<void> upsertJournalDate({
    required String groupName,
    required DateTime classDate,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/journal/dates'),
      headers: _headers(jsonBody: true),
      body: jsonEncode({
        'group_name': groupName,
        'class_date': classDate.toIso8601String().substring(0, 10),
      }),
    );
    _ensureSuccess(response);
  }

  Future<void> deleteJournalDate({
    required String groupName,
    required DateTime classDate,
  }) async {
    final uri = Uri.parse('$baseUrl/journal/dates').replace(
      queryParameters: {
        'group_name': groupName,
        'class_date': classDate.toIso8601String().substring(0, 10),
      },
    );
    final response = await http.delete(uri, headers: _headers());
    _ensureSuccess(response);
  }

  Future<List<AttendanceRecord>> listAttendance(String groupName) async {
    final uri = Uri.parse(
      '$baseUrl/attendance',
    ).replace(queryParameters: {'group_name': groupName});
    final response = await http.get(uri, headers: _headers());
    _ensureSuccess(response);
    final data = jsonDecode(response.body) as List<dynamic>;
    return data
        .map((item) => AttendanceRecord.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<AttendanceRecord> createAttendance({
    required String groupName,
    required DateTime classDate,
    required String studentName,
    required bool present,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/attendance'),
      headers: _headers(jsonBody: true),
      body: jsonEncode({
        'group_name': groupName,
        'class_date': classDate.toIso8601String().substring(0, 10),
        'student_name': studentName,
        'present': present,
      }),
    );
    _ensureSuccess(response);
    return AttendanceRecord.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  Future<void> deleteAttendance({
    required String groupName,
    required DateTime classDate,
    required String studentName,
  }) async {
    final uri = Uri.parse('$baseUrl/attendance').replace(
      queryParameters: {
        'group_name': groupName,
        'class_date': classDate.toIso8601String().substring(0, 10),
        'student_name': studentName,
      },
    );
    final response = await http.delete(uri, headers: _headers());
    _ensureSuccess(response);
  }

  Future<List<GradeRecord>> listGrades(String groupName) async {
    final uri = Uri.parse(
      '$baseUrl/grades',
    ).replace(queryParameters: {'group_name': groupName});
    final response = await http.get(uri, headers: _headers());
    _ensureSuccess(response);
    final data = jsonDecode(response.body) as List<dynamic>;
    return data
        .map((item) => GradeRecord.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<GradeRecord> createGrade({
    required String groupName,
    required DateTime classDate,
    required String studentName,
    required int grade,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/grades'),
      headers: _headers(jsonBody: true),
      body: jsonEncode({
        'group_name': groupName,
        'class_date': classDate.toIso8601String().substring(0, 10),
        'student_name': studentName,
        'grade': grade,
      }),
    );
    _ensureSuccess(response);
    return GradeRecord.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  Future<void> deleteGrade({
    required String groupName,
    required DateTime classDate,
    required String studentName,
  }) async {
    final uri = Uri.parse('$baseUrl/grades').replace(
      queryParameters: {
        'group_name': groupName,
        'class_date': classDate.toIso8601String().substring(0, 10),
        'student_name': studentName,
      },
    );
    final response = await http.delete(uri, headers: _headers());
    _ensureSuccess(response);
  }

  Future<void> deleteRequest(int ticketId) async {
    final response = await http.delete(
      Uri.parse('$baseUrl/requests/$ticketId'),
      headers: _headers(),
    );
    _ensureSuccess(response);
  }

  Future<RequestTicket> updateRequest(
    int ticketId, {
    String? status,
    String? details,
  }) async {
    final response = await http.patch(
      Uri.parse('$baseUrl/requests/$ticketId'),
      headers: _headers(jsonBody: true),
      body: jsonEncode({
        if (status != null) 'status': status,
        if (details != null) 'details': details,
      }),
    );
    _ensureSuccess(response);
    return RequestTicket.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  Future<List<GroupAnalytics>> listAnalyticsGroups() async {
    final response = await http.get(
      Uri.parse('$baseUrl/analytics/groups'),
      headers: _headers(),
    );
    _ensureSuccess(response);
    final data = jsonDecode(response.body) as List<dynamic>;
    return data
        .map((item) => GroupAnalytics.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<List<AttendanceRecord>> listAnalyticsAttendance({
    String? groupName,
  }) async {
    final uri = Uri.parse('$baseUrl/analytics/attendance').replace(
      queryParameters: groupName == null ? null : {'group_name': groupName},
    );
    final response = await http.get(uri, headers: _headers());
    _ensureSuccess(response);
    final data = jsonDecode(response.body) as List<dynamic>;
    return data
        .map((item) => AttendanceRecord.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<List<GradeRecord>> listAnalyticsGrades({String? groupName}) async {
    final uri = Uri.parse('$baseUrl/analytics/grades').replace(
      queryParameters: groupName == null ? null : {'group_name': groupName},
    );
    final response = await http.get(uri, headers: _headers());
    _ensureSuccess(response);
    final data = jsonDecode(response.body) as List<dynamic>;
    return data
        .map((item) => GradeRecord.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<List<TeacherGroupAssignment>> listTeacherAssignments({
    String? groupName,
  }) async {
    final uri = Uri.parse('$baseUrl/teacher-assignments').replace(
      queryParameters: groupName == null ? null : {'group_name': groupName},
    );
    final response = await http.get(uri, headers: _headers());
    _ensureSuccess(response);
    final data = jsonDecode(response.body) as List<dynamic>;
    return data
        .map(
          (item) =>
              TeacherGroupAssignment.fromJson(item as Map<String, dynamic>),
        )
        .toList();
  }

  Future<TeacherGroupAssignment> createTeacherAssignment({
    required int teacherId,
    required String groupName,
    required String subject,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/teacher-assignments'),
      headers: _headers(jsonBody: true),
      body: jsonEncode({
        'teacher_id': teacherId,
        'group_name': groupName,
        'subject': subject,
      }),
    );
    _ensureSuccess(response);
    return TeacherGroupAssignment.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  Future<TeacherGroupAssignment> updateTeacherAssignment(
    int assignmentId, {
    String? groupName,
    String? subject,
  }) async {
    final response = await http.patch(
      Uri.parse('$baseUrl/teacher-assignments/$assignmentId'),
      headers: _headers(jsonBody: true),
      body: jsonEncode({
        if (groupName != null) 'group_name': groupName,
        if (subject != null) 'subject': subject,
      }),
    );
    _ensureSuccess(response);
    return TeacherGroupAssignment.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  Future<void> deleteTeacherAssignment(int assignmentId) async {
    final response = await http.delete(
      Uri.parse('$baseUrl/teacher-assignments/$assignmentId'),
      headers: _headers(),
    );
    _ensureSuccess(response);
  }

  Future<List<DepartmentDto>> listDepartments() async {
    final response = await http.get(
      Uri.parse('$baseUrl/departments'),
      headers: _headers(),
    );
    _ensureSuccess(response);
    final data = jsonDecode(response.body) as List<dynamic>;
    return data
        .map((item) => DepartmentDto.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<DepartmentDto> createDepartment({
    required String name,
    required String key,
    int? headUserId,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/departments'),
      headers: _headers(jsonBody: true),
      body: jsonEncode({'name': name, 'key': key, 'head_user_id': headUserId}),
    );
    _ensureSuccess(response);
    final id = (jsonDecode(response.body) as Map<String, dynamic>)['id'] as int;
    final departments = await listDepartments();
    return departments.firstWhere(
      (item) => item.id == id,
      orElse: () => DepartmentDto(
        id: id,
        name: name,
        key: key,
        headUserId: headUserId,
        headName: null,
        groups: const [],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ),
    );
  }

  Future<DepartmentDto> updateDepartment({
    required int id,
    String? name,
    String? key,
    int? headUserId,
  }) async {
    final response = await http.patch(
      Uri.parse('$baseUrl/departments/$id'),
      headers: _headers(jsonBody: true),
      body: jsonEncode({
        if (name != null) 'name': name,
        if (key != null) 'key': key,
        'head_user_id': headUserId,
      }),
    );
    _ensureSuccess(response);
    final departments = await listDepartments();
    return departments.firstWhere(
      (item) => item.id == id,
      orElse: () => DepartmentDto(
        id: id,
        name: name ?? '',
        key: key ?? '',
        headUserId: headUserId,
        headName: null,
        groups: const [],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ),
    );
  }

  Future<void> deleteDepartment(int id) async {
    final response = await http.delete(
      Uri.parse('$baseUrl/departments/$id'),
      headers: _headers(),
    );
    _ensureSuccess(response);
  }

  Future<void> addDepartmentGroup({
    required int departmentId,
    required String groupName,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/departments/$departmentId/groups'),
      headers: _headers(jsonBody: true),
      body: jsonEncode({'group_name': groupName}),
    );
    _ensureSuccess(response);
  }

  Future<void> removeDepartmentGroup({
    required int departmentId,
    required String groupName,
  }) async {
    final response = await http.delete(
      Uri.parse(
        '$baseUrl/departments/$departmentId/groups',
      ).replace(queryParameters: {'group_name': groupName}),
      headers: _headers(),
    );
    _ensureSuccess(response);
  }

  Future<List<CuratorGroupAssignmentDto>> listCuratorGroups({
    int? curatorId,
  }) async {
    final response = await http.get(
      Uri.parse('$baseUrl/curator-groups').replace(
        queryParameters: curatorId == null
            ? null
            : {'curator_id': curatorId.toString()},
      ),
      headers: _headers(),
    );
    _ensureSuccess(response);
    final data = jsonDecode(response.body) as List<dynamic>;
    return data
        .map(
          (item) =>
              CuratorGroupAssignmentDto.fromJson(item as Map<String, dynamic>),
        )
        .toList();
  }

  Future<CuratorGroupAssignmentDto> createCuratorGroup({
    required int curatorId,
    required String groupName,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/curator-groups'),
      headers: _headers(jsonBody: true),
      body: jsonEncode({'curator_id': curatorId, 'group_name': groupName}),
    );
    _ensureSuccess(response);
    return CuratorGroupAssignmentDto.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  Future<void> deleteCuratorGroup(int id) async {
    final response = await http.delete(
      Uri.parse('$baseUrl/curator-groups/$id'),
      headers: _headers(),
    );
    _ensureSuccess(response);
  }

  Future<List<ExamGrade>> listExamGrades({
    String? groupName,
    String? examName,
  }) async {
    final uri = Uri.parse('$baseUrl/exams').replace(
      queryParameters: {
        if (groupName != null && groupName.trim().isNotEmpty)
          'group_name': groupName,
        if (examName != null && examName.trim().isNotEmpty)
          'exam_name': examName,
      },
    );
    final response = await http.get(uri, headers: _headers());
    _ensureSuccess(response);
    final data = jsonDecode(response.body) as List<dynamic>;
    return data
        .map((item) => ExamGrade.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<List<ExamUpload>> listExamUploads({
    String? groupName,
    String? examName,
  }) async {
    final uri = Uri.parse('$baseUrl/exams/uploads').replace(
      queryParameters: {
        if (groupName != null && groupName.trim().isNotEmpty)
          'group_name': groupName,
        if (examName != null && examName.trim().isNotEmpty)
          'exam_name': examName,
      },
    );
    final response = await http.get(uri, headers: _headers());
    _ensureSuccess(response);
    final data = jsonDecode(response.body) as List<dynamic>;
    return data
        .map((item) => ExamUpload.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<ExamUpload> updateExamUpload(
    int uploadId, {
    String? groupName,
    String? examName,
  }) async {
    final response = await http.patch(
      Uri.parse('$baseUrl/exams/uploads/$uploadId'),
      headers: _headers(jsonBody: true),
      body: jsonEncode({
        if (groupName != null) 'group_name': groupName,
        if (examName != null) 'exam_name': examName,
      }),
    );
    _ensureSuccess(response);
    return ExamUpload.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  Future<void> deleteExamUpload(int uploadId) async {
    final response = await http.delete(
      Uri.parse('$baseUrl/exams/uploads/$uploadId'),
      headers: _headers(),
    );
    _ensureSuccess(response);
  }

  Future<int> uploadExamGradesBytes({
    required String groupName,
    required String examName,
    required String filename,
    required List<int> bytes,
  }) async {
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('$baseUrl/exams/upload'),
    );
    request.headers.addAll(_headers());
    request.fields['group_name'] = groupName;
    request.fields['exam_name'] = examName;
    request.files.add(
      http.MultipartFile.fromBytes('file', bytes, filename: filename),
    );
    final response = await request.send();
    final responseBytes = await response.stream.toBytes();
    final bodyText = utf8.decode(responseBytes, allowMalformed: true);
    final wrapped = http.Response(bodyText, response.statusCode);
    _ensureSuccess(wrapped);
    final data = jsonDecode(bodyText) as List<dynamic>;
    return data.length;
  }

  Future<RequestTicket> createRequest({
    required String requestType,
    String? groupName,
    String? details,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/requests'),
      headers: _headers(jsonBody: true),
      body: jsonEncode({
        'request_type': requestType,
        'group_name': groupName,
        'details': details,
      }),
    );
    _ensureSuccess(response);
    return RequestTicket.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  Future<List<AttendanceSummary>> attendanceSummary({String? groupName}) async {
    final uri = Uri.parse('$baseUrl/attendance/summary').replace(
      queryParameters: groupName == null ? null : {'group_name': groupName},
    );
    final response = await http.get(uri, headers: _headers());
    _ensureSuccess(response);
    final data = jsonDecode(response.body) as List<dynamic>;
    return data
        .map((item) => AttendanceSummary.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<List<GradeSummary>> gradeSummary({String? groupName}) async {
    final uri = Uri.parse('$baseUrl/grades/summary').replace(
      queryParameters: groupName == null ? null : {'group_name': groupName},
    );
    final response = await http.get(uri, headers: _headers());
    _ensureSuccess(response);
    final data = jsonDecode(response.body) as List<dynamic>;
    return data
        .map((item) => GradeSummary.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<List<GradingPreset>> listPresets({
    String? q,
    int? authorId,
    String? tag,
    String? visibility,
  }) async {
    final response = await http.get(
      Uri.parse('$baseUrl/grading-presets').replace(
        queryParameters: {
          if (q != null && q.trim().isNotEmpty) 'q': q.trim(),
          if (authorId != null) 'author_id': authorId.toString(),
          if (tag != null && tag.trim().isNotEmpty) 'tag': tag.trim(),
          if (visibility != null && visibility.trim().isNotEmpty)
            'visibility': visibility.trim(),
        },
      ),
      headers: _headers(),
    );
    _ensureSuccess(response);
    final data = jsonDecode(response.body) as List<dynamic>;
    return data
        .map((item) => GradingPreset.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<GradingPreset> createPreset({
    required String name,
    String? description,
    List<String> tags = const [],
    String visibility = 'private',
    required PresetDefinition definition,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/grading-presets'),
      headers: _headers(jsonBody: true),
      body: jsonEncode({
        'name': name,
        'description': description ?? '',
        'tags': tags,
        'visibility': visibility,
        'definition': definition.toJson(),
      }),
    );
    _ensureSuccess(response);
    return GradingPreset.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  Future<GradingPreset> getPreset(int presetId) async {
    final response = await http.get(
      Uri.parse('$baseUrl/grading-presets/$presetId'),
      headers: _headers(),
    );
    _ensureSuccess(response);
    return GradingPreset.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  Future<GradingPreset> updatePreset(
    int presetId, {
    String? name,
    String? description,
    List<String>? tags,
    String? visibility,
    PresetDefinition? definition,
  }) async {
    final response = await http.patch(
      Uri.parse('$baseUrl/grading-presets/$presetId'),
      headers: _headers(jsonBody: true),
      body: jsonEncode({
        if (name != null) 'name': name,
        if (description != null) 'description': description,
        if (tags != null) 'tags': tags,
        if (visibility != null) 'visibility': visibility,
        if (definition != null) 'definition': definition.toJson(),
      }),
    );
    _ensureSuccess(response);
    return GradingPreset.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  Future<GradingPreset> publishPreset(int presetId) async {
    final response = await http.post(
      Uri.parse('$baseUrl/grading-presets/$presetId/publish'),
      headers: _headers(),
    );
    _ensureSuccess(response);
    return GradingPreset.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  Future<GradingPreset> unpublishPreset(int presetId) async {
    final response = await http.post(
      Uri.parse('$baseUrl/grading-presets/$presetId/unpublish'),
      headers: _headers(),
    );
    _ensureSuccess(response);
    return GradingPreset.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  Future<GroupPresetBindingDto?> getGroupPresetV2(String groupName) async {
    final response = await http.get(
      Uri.parse(
        '$baseUrl/journal/v2/groups/${Uri.encodeComponent(groupName)}/preset',
      ),
      headers: _headers(),
    );
    _ensureSuccess(response);
    final body = response.body.trim();
    if (body.isEmpty || body == 'null') {
      return null;
    }
    return GroupPresetBindingDto.fromJson(
      jsonDecode(body) as Map<String, dynamic>,
    );
  }

  Future<GroupPresetBindingDto> applyPresetV2({
    required String groupName,
    required int presetId,
  }) async {
    final response = await http.put(
      Uri.parse(
        '$baseUrl/journal/v2/groups/${Uri.encodeComponent(groupName)}/preset',
      ),
      headers: _headers(jsonBody: true),
      body: jsonEncode({'preset_id': presetId}),
    );
    _ensureSuccess(response);
    return GroupPresetBindingDto.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  Future<void> removePresetV2(String groupName) async {
    final response = await http.delete(
      Uri.parse(
        '$baseUrl/journal/v2/groups/${Uri.encodeComponent(groupName)}/preset',
      ),
      headers: _headers(),
    );
    _ensureSuccess(response);
  }

  Future<JournalGridDto> getGroupGridV2(String groupName) async {
    final response = await http.get(
      Uri.parse(
        '$baseUrl/journal/v2/groups/${Uri.encodeComponent(groupName)}/grid',
      ),
      headers: _headers(),
    );
    _ensureSuccess(response);
    return JournalGridDto.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  Future<void> upsertDateCellsV2({
    required String groupName,
    required List<DateCellWriteDto> items,
  }) async {
    final response = await http.post(
      Uri.parse(
        '$baseUrl/journal/v2/groups/${Uri.encodeComponent(groupName)}/date-cells/bulk-upsert',
      ),
      headers: _headers(jsonBody: true),
      body: jsonEncode({'items': items.map((item) => item.toJson()).toList()}),
    );
    _ensureSuccess(response);
  }

  Future<void> deleteDateCellsV2({
    required String groupName,
    required List<DateCellDeleteDto> items,
  }) async {
    final response = await http.post(
      Uri.parse(
        '$baseUrl/journal/v2/groups/${Uri.encodeComponent(groupName)}/date-cells/bulk-delete',
      ),
      headers: _headers(jsonBody: true),
      body: jsonEncode({'items': items.map((item) => item.toJson()).toList()}),
    );
    _ensureSuccess(response);
  }

  Future<void> upsertManualCellsV2({
    required String groupName,
    required List<ManualCellWriteDto> items,
  }) async {
    final response = await http.post(
      Uri.parse(
        '$baseUrl/journal/v2/groups/${Uri.encodeComponent(groupName)}/manual-cells/bulk-upsert',
      ),
      headers: _headers(jsonBody: true),
      body: jsonEncode({'items': items.map((item) => item.toJson()).toList()}),
    );
    _ensureSuccess(response);
  }

  Future<void> recalculateGridV2(String groupName) async {
    final response = await http.post(
      Uri.parse(
        '$baseUrl/journal/v2/groups/${Uri.encodeComponent(groupName)}/recalculate',
      ),
      headers: _headers(),
    );
    _ensureSuccess(response);
  }

  Future<List<MakeupCaseDto>> listMakeups({
    String? groupName,
    String? status,
    int? studentId,
    int? teacherId,
  }) async {
    final query = <String, String>{};
    if (groupName != null && groupName.trim().isNotEmpty) {
      query['group_name'] = groupName.trim();
    }
    if (status != null && status.trim().isNotEmpty) {
      query['status'] = status.trim();
    }
    if (studentId != null && studentId > 0) {
      query['student_id'] = '$studentId';
    }
    if (teacherId != null && teacherId > 0) {
      query['teacher_id'] = '$teacherId';
    }
    final uri = Uri.parse(
      '$baseUrl/makeups',
    ).replace(queryParameters: query.isEmpty ? null : query);
    final response = await _getWithApiFallback(uri);
    _ensureSuccess(response);
    final data = _decodeJsonList(response.body);
    return data
        .map((item) => MakeupCaseDto.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<MakeupCaseDto> getMakeup(int id) async {
    final response = await _getWithApiFallback(
      Uri.parse('$baseUrl/makeups/$id'),
    );
    _ensureSuccess(response);
    return MakeupCaseDto.fromJson(_decodeJsonObject(response.body));
  }

  Future<MakeupCaseDto> createMakeup({
    int? teacherId,
    required int studentId,
    required String groupName,
    required DateTime classDate,
    String teacherNote = '',
  }) async {
    final body = <String, dynamic>{
      'student_id': studentId,
      'group_name': groupName,
      'class_date': DateFormat('yyyy-MM-dd').format(classDate.toUtc()),
      'teacher_note': teacherNote,
    };
    if (teacherId != null && teacherId > 0) {
      body['teacher_id'] = teacherId;
    }
    final response = await _postWithApiFallback(
      Uri.parse('$baseUrl/makeups'),
      jsonBody: true,
      body: jsonEncode(body),
    );
    _ensureSuccess(response);
    return MakeupCaseDto.fromJson(_decodeJsonObject(response.body));
  }

  Future<MakeupCaseDto> updateMakeup(
    int id,
    Map<String, dynamic> payload,
  ) async {
    final response = await _patchWithApiFallback(
      Uri.parse('$baseUrl/makeups/$id'),
      jsonBody: true,
      body: jsonEncode(payload),
    );
    _ensureSuccess(response);
    return MakeupCaseDto.fromJson(_decodeJsonObject(response.body));
  }

  Future<void> deleteMakeup(int id) async {
    final response = await _deleteWithApiFallback(
      Uri.parse('$baseUrl/makeups/$id'),
    );
    _ensureSuccess(response);
  }

  Future<MakeupCaseDto> uploadMakeupProof({
    required int caseId,
    required String filename,
    required List<int> bytes,
    String? comment,
  }) async {
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('$baseUrl/makeups/$caseId/proof'),
    );
    request.headers.addAll(_headers());
    request.files.add(
      http.MultipartFile.fromBytes('file', bytes, filename: filename),
    );
    if (comment != null && comment.trim().isNotEmpty) {
      request.fields['comment'] = comment.trim();
    }
    final sent = await request.send();
    final bodyText = utf8.decode(
      await sent.stream.toBytes(),
      allowMalformed: true,
    );
    final wrapped = http.Response(bodyText, sent.statusCode);
    _ensureSuccess(wrapped);
    return MakeupCaseDto.fromJson(_decodeJsonObject(bodyText));
  }

  Future<MakeupCaseDto> uploadMakeupSubmission({
    required int caseId,
    String? text,
    String? filename,
    List<int>? bytes,
  }) async {
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('$baseUrl/makeups/$caseId/submission'),
    );
    request.headers.addAll(_headers());
    if (text != null && text.trim().isNotEmpty) {
      request.fields['text'] = text.trim();
    }
    if (bytes != null &&
        bytes.isNotEmpty &&
        filename != null &&
        filename.isNotEmpty) {
      request.files.add(
        http.MultipartFile.fromBytes('file', bytes, filename: filename),
      );
    }
    final sent = await request.send();
    final bodyText = utf8.decode(
      await sent.stream.toBytes(),
      allowMalformed: true,
    );
    final wrapped = http.Response(bodyText, sent.statusCode);
    _ensureSuccess(wrapped);
    return MakeupCaseDto.fromJson(_decodeJsonObject(bodyText));
  }

  Future<List<MakeupMessageDto>> listMakeupMessages(int caseId) async {
    final response = await _getWithApiFallback(
      Uri.parse('$baseUrl/makeups/$caseId/messages'),
    );
    _ensureSuccess(response);
    final data = _decodeJsonList(response.body);
    return data
        .map((item) => MakeupMessageDto.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<MakeupMessageDto> sendMakeupMessage({
    required int caseId,
    String? text,
    String? filename,
    List<int>? bytes,
  }) async {
    if ((text == null || text.trim().isEmpty) &&
        (bytes == null ||
            bytes.isEmpty ||
            filename == null ||
            filename.isEmpty)) {
      throw Exception('Message text or attachment is required.');
    }
    if (bytes != null &&
        bytes.isNotEmpty &&
        filename != null &&
        filename.isNotEmpty) {
      final request = http.MultipartRequest(
        'POST',
        Uri.parse('$baseUrl/makeups/$caseId/messages'),
      );
      request.headers.addAll(_headers());
      if (text != null && text.trim().isNotEmpty) {
        request.fields['text'] = text.trim();
      }
      request.files.add(
        http.MultipartFile.fromBytes('file', bytes, filename: filename),
      );
      final sent = await request.send();
      final bodyText = utf8.decode(
        await sent.stream.toBytes(),
        allowMalformed: true,
      );
      final wrapped = http.Response(bodyText, sent.statusCode);
      _ensureSuccess(wrapped);
      return MakeupMessageDto.fromJson(_decodeJsonObject(bodyText));
    }

    final response = await _postWithApiFallback(
      Uri.parse('$baseUrl/makeups/$caseId/messages'),
      jsonBody: true,
      body: jsonEncode({'text': text?.trim() ?? ''}),
    );
    _ensureSuccess(response);
    return MakeupMessageDto.fromJson(_decodeJsonObject(response.body));
  }

  Future<List<String>> listMakeupGroups() async {
    final response = await _getWithApiFallback(
      Uri.parse('$baseUrl/makeups/groups'),
    );
    _ensureSuccess(response);
    final data = _decodeJsonList(response.body);
    return data.map((item) => item.toString()).toList();
  }

  Future<List<UserPublicProfile>> listMakeupStudentsByGroup(
    String groupName,
  ) async {
    final response = await _getWithApiFallback(
      Uri.parse(
        '$baseUrl/makeups/groups/${Uri.encodeComponent(groupName)}/students',
      ),
    );
    _ensureSuccess(response);
    final data = _decodeJsonList(response.body);
    return data
        .map((item) => UserPublicProfile.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  AuthResponse _parseAuthResponse(http.Response response) {
    _ensureSuccess(response);
    return AuthResponse.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  RegisterResponse _parseRegisterResponse(http.Response response) {
    if (response.statusCode == 202) {
      final body = _decodeJsonObject(response.body);
      return RegisterResponse(
        pendingApproval: (body['pending_approval'] as bool?) ?? true,
        detail: body['detail'] as String?,
        user: body['user'] is Map<String, dynamic>
            ? UserProfile.fromJson(body['user'] as Map<String, dynamic>)
            : null,
      );
    }
    _ensureSuccess(response);
    final auth = AuthResponse.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
    return RegisterResponse(auth: auth);
  }

  Future<http.Response> _getWithApiFallback(Uri uri) async {
    final primary = await http.get(uri, headers: _headers());
    if (primary.statusCode != 404) {
      return primary;
    }
    final fallbackUri = _toggleApiPrefix(uri);
    if (fallbackUri.toString() == uri.toString()) {
      return primary;
    }
    return http.get(fallbackUri, headers: _headers());
  }

  Future<http.Response> _postWithApiFallback(
    Uri uri, {
    required bool jsonBody,
    Object? body,
  }) async {
    final primary = await http.post(
      uri,
      headers: _headers(jsonBody: jsonBody),
      body: body,
    );
    if (primary.statusCode != 404) {
      return primary;
    }
    final fallbackUri = _toggleApiPrefix(uri);
    if (fallbackUri.toString() == uri.toString()) {
      return primary;
    }
    return http.post(
      fallbackUri,
      headers: _headers(jsonBody: jsonBody),
      body: body,
    );
  }

  Future<http.Response> _patchWithApiFallback(
    Uri uri, {
    required bool jsonBody,
    Object? body,
  }) async {
    final primary = await http.patch(
      uri,
      headers: _headers(jsonBody: jsonBody),
      body: body,
    );
    if (primary.statusCode != 404) {
      return primary;
    }
    final fallbackUri = _toggleApiPrefix(uri);
    if (fallbackUri.toString() == uri.toString()) {
      return primary;
    }
    return http.patch(
      fallbackUri,
      headers: _headers(jsonBody: jsonBody),
      body: body,
    );
  }

  Future<http.Response> _deleteWithApiFallback(Uri uri) async {
    final primary = await http.delete(uri, headers: _headers());
    if (primary.statusCode != 404) {
      return primary;
    }
    final fallbackUri = _toggleApiPrefix(uri);
    if (fallbackUri.toString() == uri.toString()) {
      return primary;
    }
    return http.delete(fallbackUri, headers: _headers());
  }

  Uri _toggleApiPrefix(Uri uri) {
    final path = uri.path;
    if (path == '/api' || path.startsWith('/api/')) {
      final nextPath = path == '/api' ? '/' : path.substring(4);
      return uri.replace(path: nextPath.isEmpty ? '/' : nextPath);
    }
    if (path == '/') {
      return uri.replace(path: '/api');
    }
    return uri.replace(path: '/api$path');
  }

  void _ensureSuccess(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException(response.statusCode, response.body);
    }
  }

  Map<String, dynamic> _decodeJsonObject(String body) {
    final trimmed = body.trim();
    if (trimmed.isEmpty) {
      throw const FormatException('Empty JSON object');
    }

    String normalizeEscapedJson(String value) {
      return value
          .replaceAll('\uFEFF', '')
          .replaceAll(r'\"', '"')
          .replaceAll(r'\\/', '/')
          .replaceAll(r'\/', '/')
          .replaceAll(r'\\n', '\n')
          .replaceAll(r'\\t', '\t')
          .replaceAll(r'\\r', '\r');
    }

    dynamic decoded;
    try {
      decoded = jsonDecode(trimmed);
    } catch (_) {
      if (trimmed.startsWith('"') && trimmed.endsWith('"')) {
        final unescaped = jsonDecode(trimmed) as String;
        decoded = jsonDecode(normalizeEscapedJson(unescaped));
      } else {
        decoded = jsonDecode(normalizeEscapedJson(trimmed));
      }
    }
    if (decoded is String) {
      decoded = jsonDecode(normalizeEscapedJson(decoded));
    }
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    throw FormatException('Invalid JSON object');
  }

  List<dynamic> _decodeJsonList(String body) {
    final trimmed = body.trim();
    if (trimmed.isEmpty) return const [];

    String normalizeEscapedJson(String value) {
      return value
          .replaceAll('\uFEFF', '')
          .replaceAll(r'\"', '"')
          .replaceAll(r'\\/', '/')
          .replaceAll(r'\/', '/')
          .replaceAll(r'\\n', '\n')
          .replaceAll(r'\\t', '\t')
          .replaceAll(r'\\r', '\r');
    }

    dynamic decoded;
    try {
      decoded = jsonDecode(trimmed);
    } catch (_) {
      if (trimmed.startsWith('"') && trimmed.endsWith('"')) {
        final unescaped = jsonDecode(trimmed) as String;
        decoded = jsonDecode(normalizeEscapedJson(unescaped));
      } else {
        decoded = jsonDecode(normalizeEscapedJson(trimmed));
      }
    }
    if (decoded is String) {
      decoded = jsonDecode(normalizeEscapedJson(decoded));
    }
    if (decoded is List<dynamic>) {
      return decoded;
    }
    throw const FormatException('Invalid JSON list');
  }
}

class ApiException implements Exception {
  ApiException(this.statusCode, this.body);

  final int statusCode;
  final String body;

  @override
  String toString() => 'ApiException($statusCode): $body';
}

class AuthResponse {
  AuthResponse({
    required this.accessToken,
    required this.tokenType,
    required this.user,
  });

  final String accessToken;
  final String tokenType;
  final UserProfile user;

  factory AuthResponse.fromJson(Map<String, dynamic> json) {
    return AuthResponse(
      accessToken: json['access_token'] as String,
      tokenType: json['token_type'] as String,
      user: UserProfile.fromJson(json['user'] as Map<String, dynamic>),
    );
  }
}

class RegisterResponse {
  RegisterResponse({
    this.auth,
    this.pendingApproval = false,
    this.detail,
    this.user,
  });

  final AuthResponse? auth;
  final bool pendingApproval;
  final String? detail;
  final UserProfile? user;
}

class UserProfile {
  UserProfile({
    required this.id,
    required this.role,
    required this.fullName,
    required this.email,
    this.phone,
    this.avatarUrl,
    this.about,
    this.notifySchedule,
    this.notifyRequests,
    this.studentGroup,
    this.teacherName,
    this.childFullName,
    this.parentStudentId,
    this.isApproved,
    this.approvedAt,
    this.approvedBy,
    this.createdAt,
    this.updatedAt,
    this.birthDate,
  });

  final int id;
  final String role;
  final String fullName;
  final String email;
  final String? phone;
  final String? avatarUrl;
  final String? about;
  final bool? notifySchedule;
  final bool? notifyRequests;
  final String? studentGroup;
  final String? teacherName;
  final String? childFullName;
  final int? parentStudentId;
  final bool? isApproved;
  final DateTime? approvedAt;
  final int? approvedBy;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final DateTime? birthDate;

  factory UserProfile.fromJson(Map<String, dynamic> json) {
    return UserProfile(
      id: json['id'] as int,
      role: json['role'] as String,
      fullName: json['full_name'] as String,
      email: json['email'] as String,
      phone: json['phone'] as String?,
      avatarUrl: json['avatar_url'] as String?,
      about: json['about'] as String?,
      notifySchedule: json['notify_schedule'] as bool?,
      notifyRequests: json['notify_requests'] as bool?,
      studentGroup: json['student_group'] as String?,
      teacherName: json['teacher_name'] as String?,
      childFullName: json['child_full_name'] as String?,
      parentStudentId: (json['parent_student_id'] as num?)?.toInt(),
      isApproved: json['is_approved'] as bool?,
      approvedAt: json['approved_at'] == null
          ? null
          : DateTime.tryParse(json['approved_at'] as String),
      approvedBy: (json['approved_by'] as num?)?.toInt(),
      createdAt: json['created_at'] == null
          ? null
          : DateTime.tryParse(json['created_at'] as String),
      updatedAt: json['updated_at'] == null
          ? null
          : DateTime.tryParse(json['updated_at'] as String),
      birthDate: json['birth_date'] == null
          ? null
          : DateTime.parse(json['birth_date'] as String),
    );
  }
}

class AppNotification {
  AppNotification({
    required this.id,
    required this.title,
    required this.body,
    required this.createdAt,
    this.data,
    this.readAt,
    this.isReadFlag,
    this.isUnreadFlag,
    this.isDeleted = false,
    this.status = 'unread',
    this.canMarkRead = true,
    this.canDelete = true,
    this.deleted = false,
  });

  final int id;
  final String title;
  final String body;
  final Map<String, dynamic>? data;
  final DateTime createdAt;
  final DateTime? readAt;
  final bool? isReadFlag;
  final bool? isUnreadFlag;
  final bool isDeleted;
  final String status;
  final bool canMarkRead;
  final bool canDelete;
  final bool deleted;

  bool get isRead => isReadFlag ?? (readAt != null);
  bool get isUnread => isUnreadFlag ?? !isRead;

  factory AppNotification.fromJson(Map<String, dynamic> json) {
    final rawData = json['data'];
    Map<String, dynamic>? data;
    if (rawData is Map<String, dynamic>) {
      data = rawData;
    } else if (rawData is Map) {
      data = rawData.map((key, value) => MapEntry(key.toString(), value));
    } else if (rawData is String && rawData.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(rawData);
        if (decoded is Map<String, dynamic>) {
          data = decoded;
        } else if (decoded is Map) {
          data = decoded.map((key, value) => MapEntry(key.toString(), value));
        }
      } catch (_) {}
    }
    return AppNotification(
      id: (json['id'] as num).toInt(),
      title: (json['title'] as String?) ?? '',
      body: (json['body'] as String?) ?? '',
      data: data,
      createdAt: DateTime.parse(json['created_at'] as String),
      readAt: json['read_at'] == null
          ? null
          : DateTime.parse(json['read_at'] as String),
      isReadFlag: json['is_read'] as bool?,
      isUnreadFlag: json['is_unread'] as bool?,
      isDeleted: (json['is_deleted'] as bool?) ?? false,
      status: (json['status'] as String?) ?? 'unread',
      canMarkRead: (json['can_mark_read'] as bool?) ?? true,
      canDelete: (json['can_delete'] as bool?) ?? true,
      deleted: (json['deleted'] as bool?) ?? false,
    );
  }
}

class NewsMediaUpload {
  NewsMediaUpload({required this.filename, required this.bytes, this.mimeType});

  final String filename;
  final List<int> bytes;
  final String? mimeType;
}

class NewsMedia {
  NewsMedia({
    required this.id,
    required this.url,
    required this.mediaType,
    required this.originalName,
    this.mimeType,
    this.size,
  });

  final int id;
  final String url;
  final String mediaType;
  final String originalName;
  final String? mimeType;
  final int? size;

  factory NewsMedia.fromJson(Map<String, dynamic> json) {
    return NewsMedia(
      id: json['id'] as int,
      url: json['url'] as String,
      mediaType: json['media_type'] as String,
      originalName: json['original_name'] as String,
      mimeType: json['mime_type'] as String?,
      size: json['size'] as int?,
    );
  }
}

class NewsComment {
  NewsComment({
    required this.id,
    required this.userId,
    required this.userName,
    this.userRole,
    this.userAvatarUrl,
    required this.text,
    required this.createdAt,
    this.updatedAt,
  });

  final int id;
  final int userId;
  final String userName;
  final String? userRole;
  final String? userAvatarUrl;
  final String text;
  final DateTime createdAt;
  final DateTime? updatedAt;

  factory NewsComment.fromJson(Map<String, dynamic> json) {
    return NewsComment(
      id: json['id'] as int,
      userId: json['user_id'] as int,
      userName: json['user_name'] as String,
      userRole: json['user_role'] as String?,
      userAvatarUrl: json['user_avatar_url'] as String?,
      text: json['text'] as String,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: json['updated_at'] == null
          ? null
          : DateTime.parse(json['updated_at'] as String),
    );
  }
}

class NewsShareResult {
  NewsShareResult({required this.shareCount, required this.shared});

  final int shareCount;
  final bool shared;

  factory NewsShareResult.fromJson(Map<String, dynamic> json) {
    return NewsShareResult(
      shareCount: (json['share_count'] as num?)?.toInt() ?? 0,
      shared: (json['shared'] as bool?) ?? false,
    );
  }
}

class NewsPost {
  NewsPost copyWith({
    int? id,
    String? title,
    String? body,
    int? authorId,
    String? authorName,
    DateTime? createdAt,
    DateTime? updatedAt,
    int? shareCount,
    int? likesCount,
    int? commentsCount,
    bool? likedByMe,
    Map<String, int>? reactionCounts,
    String? myReaction,
    bool clearMyReaction = false,
    List<NewsMedia>? media,
    List<NewsComment>? comments,
    String? category,
    bool? pinned,
  }) {
    return NewsPost(
      id: id ?? this.id,
      title: title ?? this.title,
      body: body ?? this.body,
      authorId: authorId ?? this.authorId,
      authorName: authorName ?? this.authorName,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      shareCount: shareCount ?? this.shareCount,
      likesCount: likesCount ?? this.likesCount,
      commentsCount: commentsCount ?? this.commentsCount,
      likedByMe: likedByMe ?? this.likedByMe,
      reactionCounts: reactionCounts ?? this.reactionCounts,
      myReaction: clearMyReaction ? null : (myReaction ?? this.myReaction),
      media: media ?? this.media,
      comments: comments ?? this.comments,
      category: category ?? this.category,
      pinned: pinned ?? this.pinned,
    );
  }

  NewsPost({
    required this.id,
    required this.title,
    required this.body,
    required this.authorId,
    required this.authorName,
    required this.category,
    required this.pinned,
    required this.createdAt,
    required this.updatedAt,
    required this.shareCount,
    required this.likesCount,
    required this.commentsCount,
    required this.likedByMe,
    required this.reactionCounts,
    required this.myReaction,
    required this.media,
    required this.comments,
  });

  final int id;
  final String title;
  final String body;
  final int authorId;
  final String authorName;
  final DateTime createdAt;
  final DateTime? updatedAt;
  final int shareCount;
  final int likesCount;
  final int commentsCount;
  final bool likedByMe;
  final Map<String, int> reactionCounts;
  final String? myReaction;
  final List<NewsMedia> media;
  final List<NewsComment> comments;
  final String category;
  final bool pinned;

  factory NewsPost.fromJson(Map<String, dynamic> json) {
    final mediaData = (json['media'] as List<dynamic>? ?? []);
    final commentData = (json['comments'] as List<dynamic>? ?? []);
    return NewsPost(
      id: json['id'] as int,
      title: json['title'] as String,
      body: json['body'] as String,
      authorId: json['author_id'] as int,
      authorName: json['author_name'] as String,
      category: (json['category'] as String?) ?? "news",
      pinned: (json['pinned'] as bool?) ?? false,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: json['updated_at'] == null
          ? null
          : DateTime.parse(json['updated_at'] as String),
      shareCount: json['share_count'] as int,
      likesCount: json['likes_count'] as int,
      commentsCount: json['comments_count'] as int,
      likedByMe: json['liked_by_me'] as bool,
      reactionCounts: (json['reaction_counts'] as Map<String, dynamic>? ?? {})
          .map((key, value) => MapEntry(key, (value as num).toInt())),
      myReaction: json['my_reaction'] as String?,
      media: mediaData
          .map((item) => NewsMedia.fromJson(item as Map<String, dynamic>))
          .toList(),
      comments: commentData
          .map((item) => NewsComment.fromJson(item as Map<String, dynamic>))
          .toList(),
    );
  }
}

class NewsLikeResult {
  NewsLikeResult({
    required this.likesCount,
    required this.liked,
    required this.reactionCounts,
    this.myReaction,
  });

  final int likesCount;
  final bool liked;
  final Map<String, int> reactionCounts;
  final String? myReaction;

  factory NewsLikeResult.fromJson(Map<String, dynamic> json) {
    return NewsLikeResult(
      likesCount: json['likes_count'] as int,
      liked: json['liked'] as bool,
      reactionCounts: (json['reaction_counts'] as Map<String, dynamic>? ?? {})
          .map((key, value) => MapEntry(key, (value as num).toInt())),
      myReaction: json['my_reaction'] as String?,
    );
  }
}

class ScheduleUpload {
  ScheduleUpload({
    required this.id,
    required this.filename,
    required this.dbFilename,
    required this.scheduleDate,
    required this.uploadedAt,
  });

  final int id;
  final String filename;
  final String? dbFilename;
  final DateTime? scheduleDate;
  final DateTime uploadedAt;

  factory ScheduleUpload.fromJson(Map<String, dynamic> json) {
    return ScheduleUpload(
      id: json['id'] as int,
      filename: json['filename'] as String,
      dbFilename: json['db_filename'] as String?,
      scheduleDate: json['schedule_date'] == null
          ? null
          : DateTime.parse(json['schedule_date'] as String),
      uploadedAt: DateTime.parse(json['uploaded_at'] as String),
    );
  }
}

class ScheduleLesson {
  ScheduleLesson({
    required this.shift,
    required this.period,
    required this.time,
    required this.audience,
    required this.lesson,
    required this.groupName,
  });

  final int shift;
  final int period;
  final String time;
  final String audience;
  final String lesson;
  final String groupName;

  factory ScheduleLesson.fromJson(Map<String, dynamic> json) {
    return ScheduleLesson(
      shift: json['shift'] as int,
      period: json['period'] as int,
      time: json['time'] as String,
      audience: json['audience'] as String,
      lesson: json['lesson'] as String,
      groupName: json['group_name'] as String,
    );
  }
}

class AttendanceRecord {
  AttendanceRecord({
    required this.id,
    required this.groupName,
    required this.classDate,
    required this.studentName,
    required this.present,
  });

  final int id;
  final String groupName;
  final DateTime classDate;
  final String studentName;
  final bool present;

  factory AttendanceRecord.fromJson(Map<String, dynamic> json) {
    return AttendanceRecord(
      id: json['id'] as int,
      groupName: json['group_name'] as String,
      classDate: DateTime.parse(json['class_date'] as String),
      studentName: json['student_name'] as String,
      present: json['present'] as bool,
    );
  }
}

class GradeRecord {
  GradeRecord({
    required this.id,
    required this.groupName,
    required this.classDate,
    required this.studentName,
    required this.grade,
  });

  final int id;
  final String groupName;
  final DateTime classDate;
  final String studentName;
  final int grade;

  factory GradeRecord.fromJson(Map<String, dynamic> json) {
    return GradeRecord(
      id: json['id'] as int,
      groupName: json['group_name'] as String,
      classDate: DateTime.parse(json['class_date'] as String),
      studentName: json['student_name'] as String,
      grade: json['grade'] as int,
    );
  }
}

class RequestTicket {
  RequestTicket({
    required this.id,
    required this.studentId,
    required this.requestType,
    required this.status,
    required this.details,
    required this.createdAt,
    required this.updatedAt,
    required this.studentName,
    this.creatorRole,
  });

  final int id;
  final int studentId;
  final String requestType;
  final String status;
  final String? details;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String studentName;
  final String? creatorRole;

  factory RequestTicket.fromJson(Map<String, dynamic> json) {
    return RequestTicket(
      id: json['id'] as int,
      studentId: json['student_id'] as int,
      requestType: json['request_type'] as String,
      status: json['status'] as String,
      details: json['details'] as String?,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(
        (json['updated_at'] as String?) ?? (json['created_at'] as String),
      ),
      studentName: (json['student_name'] as String?) ?? '',
      creatorRole: json['creator_role'] as String?,
    );
  }
}

class AttendanceSummary {
  AttendanceSummary({
    required this.groupName,
    required this.presentCount,
    required this.totalCount,
  });

  final String groupName;
  final int presentCount;
  final int totalCount;

  factory AttendanceSummary.fromJson(Map<String, dynamic> json) {
    return AttendanceSummary(
      groupName: json['group_name'] as String,
      presentCount: json['present_count'] as int,
      totalCount: json['total_count'] as int,
    );
  }
}

class GradeSummary {
  GradeSummary({
    required this.groupName,
    required this.average,
    required this.count,
  });

  final String groupName;
  final double average;
  final int count;

  factory GradeSummary.fromJson(Map<String, dynamic> json) {
    return GradeSummary(
      groupName: json['group_name'] as String,
      average: (json['average'] as num).toDouble(),
      count: json['count'] as int,
    );
  }
}

class ExamGrade {
  ExamGrade({
    required this.id,
    required this.groupName,
    required this.examName,
    required this.studentName,
    required this.grade,
    required this.createdAt,
  });

  final int id;
  final String groupName;
  final String examName;
  final String studentName;
  final int grade;
  final DateTime createdAt;

  factory ExamGrade.fromJson(Map<String, dynamic> json) {
    return ExamGrade(
      id: json['id'] as int,
      groupName: json['group_name'] as String,
      examName: json['exam_name'] as String,
      studentName: json['student_name'] as String,
      grade: json['grade'] as int,
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }
}

class ExamUpload {
  ExamUpload({
    required this.id,
    required this.groupName,
    required this.examName,
    required this.filename,
    required this.rowsCount,
    required this.uploadedAt,
    this.teacherName,
  });

  final int id;
  final String groupName;
  final String examName;
  final String filename;
  final int rowsCount;
  final DateTime uploadedAt;
  final String? teacherName;

  factory ExamUpload.fromJson(Map<String, dynamic> json) {
    return ExamUpload(
      id: json['id'] as int,
      groupName: json['group_name'] as String,
      examName: json['exam_name'] as String,
      filename: json['filename'] as String,
      rowsCount: json['rows_count'] as int,
      uploadedAt: DateTime.parse(json['uploaded_at'] as String),
      teacherName: json['teacher_name'] as String?,
    );
  }
}

class TeacherGroupAssignment {
  TeacherGroupAssignment({
    required this.id,
    required this.teacherId,
    required this.teacherName,
    required this.groupName,
    required this.subject,
    required this.createdAt,
  });

  final int id;
  final int teacherId;
  final String teacherName;
  final String groupName;
  final String subject;
  final DateTime createdAt;

  factory TeacherGroupAssignment.fromJson(Map<String, dynamic> json) {
    return TeacherGroupAssignment(
      id: json['id'] as int,
      teacherId: json['teacher_id'] as int,
      teacherName: json['teacher_name'] as String,
      groupName: json['group_name'] as String,
      subject: json['subject'] as String,
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }
}

class DepartmentDto {
  DepartmentDto({
    required this.id,
    required this.name,
    required this.key,
    required this.headUserId,
    required this.headName,
    required this.groups,
    required this.createdAt,
    required this.updatedAt,
  });

  final int id;
  final String name;
  final String key;
  final int? headUserId;
  final String? headName;
  final List<String> groups;
  final DateTime createdAt;
  final DateTime updatedAt;

  factory DepartmentDto.fromJson(Map<String, dynamic> json) {
    return DepartmentDto(
      id: (json['id'] as num?)?.toInt() ?? 0,
      name: (json['name'] as String?) ?? '',
      key: (json['key'] as String?) ?? '',
      headUserId: (json['head_user_id'] as num?)?.toInt(),
      headName: json['head_name'] as String?,
      groups: (json['groups'] as List<dynamic>? ?? [])
          .map((item) => item.toString())
          .toList(),
      createdAt: DateTime.parse(
        (json['created_at'] as String?) ?? DateTime.now().toIso8601String(),
      ),
      updatedAt: DateTime.parse(
        (json['updated_at'] as String?) ?? DateTime.now().toIso8601String(),
      ),
    );
  }
}

class CuratorGroupAssignmentDto {
  CuratorGroupAssignmentDto({
    required this.id,
    required this.curatorId,
    required this.curatorName,
    required this.groupName,
    required this.createdAt,
  });

  final int id;
  final int curatorId;
  final String? curatorName;
  final String groupName;
  final DateTime createdAt;

  factory CuratorGroupAssignmentDto.fromJson(Map<String, dynamic> json) {
    return CuratorGroupAssignmentDto(
      id: (json['id'] as num?)?.toInt() ?? 0,
      curatorId: (json['curator_id'] as num?)?.toInt() ?? 0,
      curatorName: json['curator_name'] as String?,
      groupName: (json['group_name'] as String?) ?? '',
      createdAt: DateTime.parse(
        (json['created_at'] as String?) ?? DateTime.now().toIso8601String(),
      ),
    );
  }
}

class GroupAnalytics {
  GroupAnalytics({
    required this.groupName,
    required this.subjects,
    required this.teachers,
  });

  final String groupName;
  final List<String> subjects;
  final List<String> teachers;

  factory GroupAnalytics.fromJson(Map<String, dynamic> json) {
    return GroupAnalytics(
      groupName: json['group_name'] as String,
      subjects: (json['subjects'] as List<dynamic>)
          .map((e) => e.toString())
          .toList(),
      teachers: (json['teachers'] as List<dynamic>)
          .map((e) => e.toString())
          .toList(),
    );
  }
}

class GradingPreset {
  GradingPreset({
    required this.id,
    required this.ownerId,
    required this.name,
    required this.description,
    required this.tags,
    required this.visibility,
    required this.createdAt,
    required this.updatedAt,
    this.archivedAt,
    this.currentVersion,
  });

  final int id;
  final int ownerId;
  final String name;
  final String description;
  final List<String> tags;
  final String visibility;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? archivedAt;
  final GradingPresetVersion? currentVersion;

  factory GradingPreset.fromJson(Map<String, dynamic> json) {
    return GradingPreset(
      id: json['id'] as int,
      ownerId: json['owner_id'] as int? ?? 0,
      name: (json['name'] as String?) ?? '',
      description: (json['description'] as String?) ?? '',
      tags: (json['tags'] as List<dynamic>? ?? [])
          .map((item) => item.toString())
          .toList(),
      visibility: (json['visibility'] as String?) ?? 'private',
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
      archivedAt: json['archived_at'] == null
          ? null
          : DateTime.parse(json['archived_at'] as String),
      currentVersion: json['current_version'] == null
          ? null
          : GradingPresetVersion.fromJson(
              json['current_version'] as Map<String, dynamic>,
            ),
    );
  }
}

class GradingPresetVersion {
  GradingPresetVersion({
    required this.id,
    required this.presetId,
    required this.version,
    required this.createdBy,
    required this.createdAt,
    required this.definition,
  });

  final int id;
  final int presetId;
  final int version;
  final int createdBy;
  final DateTime createdAt;
  final PresetDefinition definition;

  factory GradingPresetVersion.fromJson(Map<String, dynamic> json) {
    return GradingPresetVersion(
      id: json['id'] as int,
      presetId: json['preset_id'] as int,
      version: json['version'] as int,
      createdBy: json['created_by'] as int? ?? 0,
      createdAt: DateTime.parse(json['created_at'] as String),
      definition: PresetDefinition.fromJson(
        json['definition'] as Map<String, dynamic>? ?? const {},
      ),
    );
  }
}

class PresetDefinition {
  PresetDefinition({
    this.statusCodes = const [],
    this.variables = const [],
    this.columns = const [],
  });

  final List<StatusCodeRuleDto> statusCodes;
  final List<PresetVariableDto> variables;
  final List<PresetColumnDto> columns;

  Map<String, dynamic> toJson() {
    return {
      'status_codes': statusCodes.map((item) => item.toJson()).toList(),
      'variables': variables.map((item) => item.toJson()).toList(),
      'columns': columns.map((item) => item.toJson()).toList(),
    };
  }

  factory PresetDefinition.fromJson(Map<String, dynamic> json) {
    return PresetDefinition(
      statusCodes: (json['status_codes'] as List<dynamic>? ?? [])
          .map(
            (item) => StatusCodeRuleDto.fromJson(item as Map<String, dynamic>),
          )
          .toList(),
      variables: (json['variables'] as List<dynamic>? ?? [])
          .map(
            (item) => PresetVariableDto.fromJson(item as Map<String, dynamic>),
          )
          .toList(),
      columns: (json['columns'] as List<dynamic>? ?? [])
          .map((item) => PresetColumnDto.fromJson(item as Map<String, dynamic>))
          .toList(),
    );
  }
}

class StatusCodeRuleDto {
  StatusCodeRuleDto({
    required this.key,
    required this.code,
    this.numericValue,
    this.countsAsMiss = false,
    this.countsInStats = true,
  });

  final String key;
  final String code;
  final double? numericValue;
  final bool countsAsMiss;
  final bool countsInStats;

  Map<String, dynamic> toJson() {
    return {
      'key': key,
      'code': code,
      'numeric_value': numericValue,
      'counts_as_miss': countsAsMiss,
      'counts_in_stats': countsInStats,
    };
  }

  factory StatusCodeRuleDto.fromJson(Map<String, dynamic> json) {
    final numericRaw = json['numeric_value'];
    final fallbackCode = (json['code'] as String?) ?? '';
    return StatusCodeRuleDto(
      key: ((json['key'] as String?) ?? '').trim().isEmpty
          ? fallbackCode
          : (json['key'] as String?) ?? '',
      code: fallbackCode,
      numericValue: numericRaw is num ? numericRaw.toDouble() : null,
      countsAsMiss: (json['counts_as_miss'] as bool?) ?? false,
      countsInStats: (json['counts_in_stats'] as bool?) ?? true,
    );
  }
}

class PresetVariableDto {
  PresetVariableDto({
    required this.key,
    required this.title,
    required this.type,
    this.defaultValue,
  });

  final String key;
  final String title;
  final String type;
  final dynamic defaultValue;

  Map<String, dynamic> toJson() {
    return {
      'key': key,
      'title': title,
      'type': type,
      'default_value': defaultValue,
    };
  }

  factory PresetVariableDto.fromJson(Map<String, dynamic> json) {
    return PresetVariableDto(
      key: (json['key'] as String?) ?? '',
      title: (json['title'] as String?) ?? '',
      type: (json['type'] as String?) ?? 'number',
      defaultValue: json['default_value'],
    );
  }
}

class PresetColumnDto {
  PresetColumnDto({
    required this.key,
    required this.title,
    required this.kind,
    required this.type,
    this.editable = false,
    this.formula = '',
    this.format = '',
    this.dependsOn = const [],
  });

  final String key;
  final String title;
  final String kind;
  final String type;
  final bool editable;
  final String formula;
  final String format;
  final List<String> dependsOn;

  Map<String, dynamic> toJson() {
    return {
      'key': key,
      'title': title,
      'kind': kind,
      'type': type,
      'editable': editable,
      'formula': formula,
      'format': format,
      'depends_on': dependsOn,
    };
  }

  factory PresetColumnDto.fromJson(Map<String, dynamic> json) {
    return PresetColumnDto(
      key: (json['key'] as String?) ?? '',
      title: (json['title'] as String?) ?? '',
      kind: (json['kind'] as String?) ?? 'manual',
      type: (json['type'] as String?) ?? 'number',
      editable: (json['editable'] as bool?) ?? false,
      formula: (json['formula'] as String?) ?? '',
      format: (json['format'] as String?) ?? '',
      dependsOn: (json['depends_on'] as List<dynamic>? ?? [])
          .map((item) => item.toString())
          .toList(),
    );
  }
}

class GroupPresetBindingDto {
  GroupPresetBindingDto({
    required this.id,
    required this.groupName,
    required this.presetId,
    required this.presetVersionId,
    required this.autoUpdate,
    required this.appliedBy,
    required this.appliedAt,
    required this.updatedAt,
  });

  final int id;
  final String groupName;
  final int presetId;
  final int presetVersionId;
  final bool autoUpdate;
  final int appliedBy;
  final DateTime appliedAt;
  final DateTime updatedAt;

  factory GroupPresetBindingDto.fromJson(Map<String, dynamic> json) {
    return GroupPresetBindingDto(
      id: json['id'] as int,
      groupName: json['group_name'] as String,
      presetId: json['preset_id'] as int,
      presetVersionId: json['preset_version_id'] as int,
      autoUpdate: (json['auto_update'] as bool?) ?? true,
      appliedBy: json['applied_by'] as int? ?? 0,
      appliedAt: DateTime.parse(json['applied_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
    );
  }
}

class JournalGridDto {
  JournalGridDto({
    required this.groupName,
    required this.students,
    required this.dates,
    required this.dateCells,
    required this.manualCells,
    required this.computedCells,
    required this.syncState,
    this.binding,
    this.preset,
    this.presetVersion,
  });

  final String groupName;
  final List<String> students;
  final List<DateTime> dates;
  final List<DateCellDto> dateCells;
  final List<ManualCellDto> manualCells;
  final List<ComputedCellDto> computedCells;
  final String syncState;
  final GroupPresetBindingDto? binding;
  final GradingPreset? preset;
  final GradingPresetVersion? presetVersion;

  factory JournalGridDto.fromJson(Map<String, dynamic> json) {
    return JournalGridDto(
      groupName: (json['group_name'] as String?) ?? '',
      students: (json['students'] as List<dynamic>? ?? [])
          .map((item) => item.toString())
          .toList(),
      dates: (json['dates'] as List<dynamic>? ?? [])
          .map((item) => DateTime.parse(item.toString()))
          .toList(),
      dateCells: (json['date_cells'] as List<dynamic>? ?? [])
          .map((item) => DateCellDto.fromJson(item as Map<String, dynamic>))
          .toList(),
      manualCells: (json['manual_cells'] as List<dynamic>? ?? [])
          .map((item) => ManualCellDto.fromJson(item as Map<String, dynamic>))
          .toList(),
      computedCells: (json['computed_cells'] as List<dynamic>? ?? [])
          .map((item) => ComputedCellDto.fromJson(item as Map<String, dynamic>))
          .toList(),
      syncState: (json['sync_state'] as String?) ?? 'authoritative',
      binding: json['binding'] == null
          ? null
          : GroupPresetBindingDto.fromJson(
              json['binding'] as Map<String, dynamic>,
            ),
      preset: json['preset'] == null
          ? null
          : GradingPreset.fromJson(json['preset'] as Map<String, dynamic>),
      presetVersion: json['preset_version'] == null
          ? null
          : GradingPresetVersion.fromJson(
              json['preset_version'] as Map<String, dynamic>,
            ),
    );
  }
}

class DateCellDto {
  DateCellDto({
    required this.groupName,
    required this.classDate,
    required this.studentName,
    required this.rawValue,
    this.numericValue,
    this.statusCode,
  });

  final String groupName;
  final DateTime classDate;
  final String studentName;
  final String rawValue;
  final double? numericValue;
  final String? statusCode;

  factory DateCellDto.fromJson(Map<String, dynamic> json) {
    final numericRaw = json['numeric_value'];
    return DateCellDto(
      groupName: (json['group_name'] as String?) ?? '',
      classDate: DateTime.parse(json['class_date'] as String),
      studentName: (json['student_name'] as String?) ?? '',
      rawValue: (json['raw_value'] as String?) ?? '',
      numericValue: numericRaw is num ? numericRaw.toDouble() : null,
      statusCode: json['status_code'] as String?,
    );
  }
}

class ManualCellDto {
  ManualCellDto({
    required this.groupName,
    required this.studentName,
    required this.columnKey,
    required this.rawValue,
    this.numericValue,
  });

  final String groupName;
  final String studentName;
  final String columnKey;
  final String rawValue;
  final double? numericValue;

  factory ManualCellDto.fromJson(Map<String, dynamic> json) {
    final numericRaw = json['numeric_value'];
    return ManualCellDto(
      groupName: (json['group_name'] as String?) ?? '',
      studentName: (json['student_name'] as String?) ?? '',
      columnKey: (json['column_key'] as String?) ?? '',
      rawValue: (json['raw_value'] as String?) ?? '',
      numericValue: numericRaw is num ? numericRaw.toDouble() : null,
    );
  }
}

class ComputedCellDto {
  ComputedCellDto({
    required this.groupName,
    required this.studentName,
    required this.presetVersionId,
    required this.values,
    required this.calculatedAt,
  });

  final String groupName;
  final String studentName;
  final int presetVersionId;
  final Map<String, dynamic> values;
  final DateTime calculatedAt;

  factory ComputedCellDto.fromJson(Map<String, dynamic> json) {
    final valuesRaw = json['values'];
    return ComputedCellDto(
      groupName: (json['group_name'] as String?) ?? '',
      studentName: (json['student_name'] as String?) ?? '',
      presetVersionId: json['preset_version_id'] as int? ?? 0,
      values: valuesRaw is Map<String, dynamic>
          ? valuesRaw
          : <String, dynamic>{},
      calculatedAt: DateTime.parse(json['calculated_at'] as String),
    );
  }
}

class DateCellWriteDto {
  DateCellWriteDto({
    required this.classDate,
    required this.studentName,
    required this.rawValue,
  });

  final DateTime classDate;
  final String studentName;
  final String rawValue;

  Map<String, dynamic> toJson() {
    return {
      'class_date': classDate.toIso8601String().substring(0, 10),
      'student_name': studentName,
      'raw_value': rawValue,
    };
  }
}

class DateCellDeleteDto {
  DateCellDeleteDto({required this.classDate, required this.studentName});

  final DateTime classDate;
  final String studentName;

  Map<String, dynamic> toJson() {
    return {
      'class_date': classDate.toIso8601String().substring(0, 10),
      'student_name': studentName,
      'raw_value': '',
    };
  }
}

class ManualCellWriteDto {
  ManualCellWriteDto({
    required this.studentName,
    required this.columnKey,
    required this.rawValue,
  });

  final String studentName;
  final String columnKey;
  final String rawValue;

  Map<String, dynamic> toJson() {
    return {
      'student_name': studentName,
      'column_key': columnKey,
      'raw_value': rawValue,
    };
  }
}

class UserPublicProfile {
  UserPublicProfile({
    required this.id,
    required this.role,
    required this.fullName,
    this.avatarUrl,
    this.about,
    this.studentGroup,
    this.teacherName,
  });

  final int id;
  final String role;
  final String fullName;
  final String? avatarUrl;
  final String? about;
  final String? studentGroup;
  final String? teacherName;

  factory UserPublicProfile.fromJson(Map<String, dynamic> json) {
    return UserPublicProfile(
      id: (json['id'] as num?)?.toInt() ?? 0,
      role: (json['role'] as String?) ?? '',
      fullName: (json['full_name'] as String?) ?? '',
      avatarUrl: json['avatar_url'] as String?,
      about: json['about'] as String?,
      studentGroup: json['student_group'] as String?,
      teacherName: json['teacher_name'] as String?,
    );
  }
}

class MakeupCaseDto {
  MakeupCaseDto({
    required this.id,
    required this.groupName,
    required this.teacherId,
    required this.teacherName,
    required this.studentId,
    required this.studentName,
    required this.classDate,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.closedAt,
    this.teacherNote,
    this.medicalProofUrl,
    this.medicalProofComment,
    this.teacherTask,
    this.teacherTaskAt,
    this.studentSubmission,
    this.studentSubmissionUrl,
    this.submissionSentAt,
    this.grade,
    this.gradeComment,
    this.gradeSetAt,
    this.proofSubmittedAt,
    this.teacherNoteAt,
  });

  final int id;
  final String groupName;
  final int teacherId;
  final String teacherName;
  final int studentId;
  final String studentName;
  final DateTime classDate;
  final String status;
  final String? teacherNote;
  final String? medicalProofUrl;
  final String? medicalProofComment;
  final String? teacherTask;
  final DateTime? teacherTaskAt;
  final String? studentSubmission;
  final String? studentSubmissionUrl;
  final DateTime? submissionSentAt;
  final String? grade;
  final String? gradeComment;
  final DateTime? gradeSetAt;
  final DateTime? proofSubmittedAt;
  final DateTime? teacherNoteAt;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? closedAt;

  factory MakeupCaseDto.fromJson(Map<String, dynamic> json) {
    return MakeupCaseDto(
      id: (json['id'] as num?)?.toInt() ?? 0,
      groupName: (json['group_name'] as String?) ?? '',
      teacherId: (json['teacher_id'] as num?)?.toInt() ?? 0,
      teacherName: (json['teacher_name'] as String?) ?? '',
      studentId: (json['student_id'] as num?)?.toInt() ?? 0,
      studentName: (json['student_name'] as String?) ?? '',
      classDate: DateTime.parse(
        (json['class_date'] as String?) ?? '1970-01-01',
      ),
      status: (json['status'] as String?) ?? '',
      teacherNote: json['teacher_note'] as String?,
      medicalProofUrl: json['medical_proof_url'] as String?,
      medicalProofComment: json['medical_proof_comment'] as String?,
      teacherTask: json['teacher_task'] as String?,
      teacherTaskAt: json['teacher_task_at'] == null
          ? null
          : DateTime.parse(json['teacher_task_at'] as String),
      studentSubmission: json['student_submission'] as String?,
      studentSubmissionUrl: json['student_submission_url'] as String?,
      submissionSentAt: json['submission_sent_at'] == null
          ? null
          : DateTime.parse(json['submission_sent_at'] as String),
      grade: json['grade'] as String?,
      gradeComment: json['grade_comment'] as String?,
      gradeSetAt: json['grade_set_at'] == null
          ? null
          : DateTime.parse(json['grade_set_at'] as String),
      proofSubmittedAt: json['proof_submitted_at'] == null
          ? null
          : DateTime.parse(json['proof_submitted_at'] as String),
      teacherNoteAt: json['teacher_note_at'] == null
          ? null
          : DateTime.parse(json['teacher_note_at'] as String),
      createdAt: DateTime.parse(
        (json['created_at'] as String?) ?? DateTime.now().toIso8601String(),
      ),
      updatedAt: DateTime.parse(
        (json['updated_at'] as String?) ?? DateTime.now().toIso8601String(),
      ),
      closedAt: json['closed_at'] == null
          ? null
          : DateTime.parse(json['closed_at'] as String),
    );
  }
}

class MakeupMessageDto {
  MakeupMessageDto({
    required this.id,
    required this.makeupCaseId,
    required this.senderId,
    required this.senderName,
    required this.senderRole,
    required this.createdAt,
    this.body,
    this.attachmentUrl,
  });

  final int id;
  final int makeupCaseId;
  final int senderId;
  final String senderName;
  final String senderRole;
  final String? body;
  final String? attachmentUrl;
  final DateTime createdAt;

  factory MakeupMessageDto.fromJson(Map<String, dynamic> json) {
    return MakeupMessageDto(
      id: (json['id'] as num?)?.toInt() ?? 0,
      makeupCaseId: (json['makeup_case_id'] as num?)?.toInt() ?? 0,
      senderId: (json['sender_id'] as num?)?.toInt() ?? 0,
      senderName: (json['sender_name'] as String?) ?? '',
      senderRole: (json['sender_role'] as String?) ?? '',
      body: json['body'] as String?,
      attachmentUrl: json['attachment_url'] as String?,
      createdAt: DateTime.parse(
        (json['created_at'] as String?) ?? DateTime.now().toIso8601String(),
      ),
    );
  }
}
