import 'dart:convert';

import 'package:http/http.dart' as http;

class ApiClient {
  ApiClient({required this.baseUrl, this.token});

  final String baseUrl;
  final String? token;

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

  String _sanitizeFilename(String filename) {
    final dot = filename.lastIndexOf('.');
    final base = dot == -1 ? filename : filename.substring(0, dot);
    final ext = dot == -1 ? '' : filename.substring(dot);
    final safeBase = base.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final safeExt = ext.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final combined = (safeBase.isEmpty ? 'schedule' : safeBase) + safeExt;
    return combined;
  }

  Future<AuthResponse> register({
    required String fullName,
    required String email,
    required String password,
    String? deviceId,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/auth/register'),
      headers: _headers(jsonBody: true),
      body: jsonEncode({
        'full_name': fullName,
        'email': email,
        'password': password,
        'device_id': deviceId,
      }),
    );
    return _parseAuthResponse(response);
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

  Future<List<UserProfile>> listUsers({String? role}) async {
    final uri = Uri.parse(
      '$baseUrl/users',
    ).replace(queryParameters: role == null ? null : {'role': role});
    final response = await http.get(uri, headers: _headers());
    _ensureSuccess(response);
    final data = jsonDecode(response.body) as List<dynamic>;
    return data
        .map((item) => UserProfile.fromJson(item as Map<String, dynamic>))
        .toList();
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

  Future<List<NewsPost>> listNews({
    int offset = 0,
    int limit = 20,
    String? category,
  }) async {
    final uri = Uri.parse('$baseUrl/news').replace(
      queryParameters: {'offset': offset.toString(), 'limit': limit.toString()},
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
      request.files.add(
        http.MultipartFile.fromBytes(
          'files',
          item.bytes,
          filename: item.filename,
        ),
      );
    }
    final response = await request.send();
    final responseBytes = await response.stream.toBytes();
    final bodyText = utf8.decode(responseBytes, allowMalformed: true);
    final wrapped = http.Response(bodyText, response.statusCode);
    _ensureSuccess(wrapped);
    return NewsPost.fromJson(_decodeJsonObject(bodyText));
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

  Future<int> shareNews(int postId) async {
    final response = await http.post(
      Uri.parse('$baseUrl/news/$postId/share'),
      headers: _headers(),
    );
    _ensureSuccess(response);
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return data['share_count'] as int;
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

  Future<List<String>> listScheduleGroups() async {
    final response = await http.get(
      Uri.parse('$baseUrl/schedule/groups'),
      headers: _headers(),
    );
    _ensureSuccess(response);
    final data = jsonDecode(response.body) as List<dynamic>;
    return data.map((item) => item.toString()).toList();
  }

  Future<List<String>> listScheduleTeachers() async {
    final response = await http.get(
      Uri.parse('$baseUrl/schedule/teachers'),
      headers: _headers(),
    );
    _ensureSuccess(response);
    final data = jsonDecode(response.body) as List<dynamic>;
    return data.map((item) => item.toString()).toList();
  }

  Future<ScheduleUpload> uploadScheduleBytes({
    required String filename,
    required List<int> bytes,
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

  Future<List<ScheduleLesson>> scheduleForGroup(String groupName) async {
    final response = await http.get(
      Uri.parse('$baseUrl/schedule/group/${Uri.encodeComponent(groupName)}'),
      headers: _headers(),
    );
    _ensureSuccess(response);
    final data = jsonDecode(response.body) as List<dynamic>;
    return data
        .map((item) => ScheduleLesson.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<List<ScheduleLesson>> scheduleForMe() async {
    final response = await http.get(
      Uri.parse('$baseUrl/schedule/me'),
      headers: _headers(),
    );
    _ensureSuccess(response);
    final data = jsonDecode(response.body) as List<dynamic>;
    return data
        .map((item) => ScheduleLesson.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<List<ScheduleLesson>> scheduleForTeacher(String teacherName) async {
    final response = await http.get(
      Uri.parse(
        '$baseUrl/schedule/teacher/${Uri.encodeComponent(teacherName)}',
      ),
      headers: _headers(),
    );
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
    String? details,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/requests'),
      headers: _headers(jsonBody: true),
      body: jsonEncode({'request_type': requestType, 'details': details}),
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

  AuthResponse _parseAuthResponse(http.Response response) {
    _ensureSuccess(response);
    return AuthResponse.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  void _ensureSuccess(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException(response.statusCode, response.body);
    }
  }

  Map<String, dynamic> _decodeJsonObject(String body) {
    final trimmed = body.trim();
    dynamic decoded;
    try {
      decoded = jsonDecode(trimmed);
    } catch (_) {
      if (trimmed.startsWith('"') && trimmed.endsWith('"')) {
        final unescaped = jsonDecode(trimmed) as String;
        decoded = jsonDecode(unescaped);
      } else {
        rethrow;
      }
    }
    if (decoded is String) {
      decoded = jsonDecode(decoded);
    }
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    throw FormatException('Invalid JSON object');
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

class UserProfile {
  UserProfile({
    required this.id,
    required this.role,
    required this.fullName,
    required this.email,
    this.phone,
    this.avatarUrl,
    this.about,
    this.studentGroup,
    this.teacherName,
    this.birthDate,
  });

  final int id;
  final String role;
  final String fullName;
  final String email;
  final String? phone;
  final String? avatarUrl;
  final String? about;
  final String? studentGroup;
  final String? teacherName;
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
      studentGroup: json['student_group'] as String?,
      teacherName: json['teacher_name'] as String?,
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
  });

  final int id;
  final String title;
  final String body;
  final Map<String, dynamic>? data;
  final DateTime createdAt;
  final DateTime? readAt;

  bool get isRead => readAt != null;

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
    required this.text,
    required this.createdAt,
  });

  final int id;
  final int userId;
  final String userName;
  final String text;
  final DateTime createdAt;

  factory NewsComment.fromJson(Map<String, dynamic> json) {
    return NewsComment(
      id: json['id'] as int,
      userId: json['user_id'] as int,
      userName: json['user_name'] as String,
      text: json['text'] as String,
      createdAt: DateTime.parse(json['created_at'] as String),
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
      myReaction: myReaction ?? this.myReaction,
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
    required this.studentName,
  });

  final int id;
  final int studentId;
  final String requestType;
  final String status;
  final String? details;
  final DateTime createdAt;
  final String studentName;

  factory RequestTicket.fromJson(Map<String, dynamic> json) {
    return RequestTicket(
      id: json['id'] as int,
      studentId: json['student_id'] as int,
      requestType: json['request_type'] as String,
      status: json['status'] as String,
      details: json['details'] as String?,
      createdAt: DateTime.parse(json['created_at'] as String),
      studentName: (json['student_name'] as String?) ?? '',
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
