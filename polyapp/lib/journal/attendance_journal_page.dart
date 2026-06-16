import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/api_client.dart';
import '../i18n/ui_text.dart';
import '../widgets/brand_logo.dart';
import 'journal_date_picker.dart';
import 'models/journal_models.dart';
import 'services/journal_service.dart';

class AttendanceJournalPage extends StatefulWidget {
  const AttendanceJournalPage({
    super.key,
    required this.canEdit,
    required this.canManageGroups,
    required this.client,
  });

  final bool canEdit;
  final bool canManageGroups;
  final ApiClient client;

  @override
  State<AttendanceJournalPage> createState() => _AttendanceJournalPageState();
}

class _AttendanceJournalPageState extends State<AttendanceJournalPage> {
  final JournalService _service = JournalService();
  final DateFormat _dateLabelFormat = DateFormat('dd.MM');
  final ScrollController _gridHorizontalController = ScrollController();

  bool _isInitialized = false;
  bool _loading = true;
  bool _busy = false;
  bool _online = true;
  bool _syncing = false;
  DateTime? _lastSync;
  Timer? _retryTimer;
  Future<void>? _loadDataRequest;
  Future<void>? _syncAllGroupsRequest;
  Future<void>? _syncFromServerRequest;
  String? _syncFromServerGroupName;

  Group? _group;
  List<Group> _groups = <Group>[];
  Map<String, String> _groupLabels = <String, String>{};
  List<Student> _students = <Student>[];
  List<LessonDate> _dates = <LessonDate>[];
  String _helpText = '';

  bool get _isRu {
    try {
      return Localizations.localeOf(
        context,
      ).languageCode.toLowerCase().startsWith('ru');
    } catch (_) {
      return WidgetsBinding.instance.platformDispatcher.locale.languageCode
          .toLowerCase()
          .startsWith('ru');
    }
  }

  String _tr(String ru, String en) =>
      trTextByCode(Localizations.localeOf(context).languageCode, ru, en);

  @override
  void initState() {
    super.initState();
    _startRetryTimer();
    _loadData();
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    _gridHorizontalController.dispose();
    super.dispose();
  }

  void _startRetryTimer() {
    _retryTimer?.cancel();
    _retryTimer = Timer.periodic(const Duration(seconds: 30), (timer) async {
      if (!mounted || _online || _syncing) return;
      await _syncAllGroups();
      if (_group != null) {
        await _syncFromServer();
      }
    });
  }

  Future<void> _loadData() async {
    final pending = _loadDataRequest;
    if (pending != null) {
      return pending;
    }
    final request = _loadDataOnce();
    _loadDataRequest = request;
    return request.whenComplete(() {
      if (identical(_loadDataRequest, request)) {
        _loadDataRequest = null;
      }
    });
  }

  Future<void> _loadDataOnce() async {
    setState(() => _loading = true);

    await _service.init();
    await _loadHelpText();
    await _mergeServerGroups();

    _groups = _service.getAllGroups();

    if (_groups.isNotEmpty) {
      _group ??= _groups.first;
    }

    if (_group != null) {
      _students = _service.getStudentsByGroup(_group!);
      _dates = _service.getDatesByGroup(_group!);
      _dates.sort(_compareLessonDates);
    }

    if (!mounted) return;

    setState(() {
      _isInitialized = true;
      _loading = false;
    });

    // Синхронизацию запускаем после отображения страницы,
    // чтобы пользователь не ждал на пустом экране.
    unawaited(_loadGroupData(sync: true));
  }

  Future<void> _loadHelpText() async {
    const key = 'attendance_journal_help_text_v1';
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(key)?.trim();
    if (saved != null && saved.isNotEmpty) {
      _helpText = saved;
      return;
    }
    _helpText = _defaultHelpText();
  }

  String _defaultHelpText() {
    if (_isRu) {
      return 'Отметки в ячейке:\n'
          '• P, +, 1, y, да — присутствовал.\n'
          '• Н, n, -, 0 — отсутствовал.\n'
          '• Пусто — очистить отметку.\n'
          'Система хранит факт посещения и подсвечивает ячейку.';
    }
    return 'Cell marks:\n'
        '• P, +, 1, y, yes = present.\n'
        '• N, -, 0 = absent.\n'
        '• Empty = clear mark.\n'
        'The system stores attendance state and highlights cells.';
  }

  Future<void> _editHelpText() async {
    if (!widget.canEdit) return;
    final controller = TextEditingController(text: _helpText);
    final next = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(_tr('Инструкция по отметкам', 'Marking instructions')),
          content: TextField(
            controller: controller,
            maxLines: 8,
            minLines: 6,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              hintText: _defaultHelpText(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(_tr('Отмена', 'Cancel')),
            ),
            OutlinedButton(
              onPressed: () => Navigator.pop(context, _defaultHelpText()),
              child: Text(_tr('Сбросить', 'Reset')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: Text(_tr('Сохранить', 'Save')),
            ),
          ],
        );
      },
    );
    if (next == null || next.trim().isEmpty) return;
    const key = 'attendance_journal_help_text_v1';
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, next.trim());
    if (!mounted) return;
    setState(() => _helpText = next.trim());
  }

  Future<void> _showHelpDialog() async {
    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(_tr('Подсказка по отметкам', 'Marking help')),
          content: Text(_helpText),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(_tr('Закрыть', 'Close')),
            ),
            if (widget.canEdit)
              FilledButton(
                onPressed: () {
                  Navigator.pop(context);
                  _editHelpText();
                },
                child: Text(_tr('Настроить', 'Configure')),
              ),
          ],
        );
      },
    );
  }

  Future<void> _mergeServerGroups() async {
    try {
      final labels = <String, String>{};
      List<String> serverGroups;
      try {
        final catalog = await widget.client.listJournalGroupCatalogV2();
        serverGroups = catalog
            .map((item) => item.groupName)
            .toList(growable: false);
        for (final item in catalog) {
          labels[item.groupName] = item.label;
        }
      } catch (_) {
        serverGroups = await widget.client.listJournalGroups();
      }

      for (final name in serverGroups) {
        final existing = _service.getGroupByName(name);
        if (existing == null) {
          await _service.addGroup(Group(name: name));
        }
      }
      final allowed = serverGroups
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toSet();
      final localNow = _service.getAllGroups();
      for (final local in localNow) {
        if (!allowed.contains(local.name.trim())) {
          await _service.deleteGroup(local);
        }
      }
      _groupLabels = labels;
    } catch (_) {}
  }

  Future<void> _loadGroupData({required bool sync}) async {
    if (_group == null) {
      if (!mounted) return;
      setState(() {
        _students = <Student>[];
        _dates = <LessonDate>[];
      });
      return;
    }
    _students = _service.getStudentsByGroup(_group!);
    _dates = _service.getDatesByGroup(_group!);
    _dates.sort(_compareLessonDates);
    if (mounted) {
      setState(() {});
    }
    if (!sync) return;
    await _syncFromServer();
    _students = _service.getStudentsByGroup(_group!);
    _dates = _service.getDatesByGroup(_group!);
    _dates.sort(_compareLessonDates);
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _syncAllGroups() async {
    final pending = _syncAllGroupsRequest;
    if (pending != null) {
      return pending;
    }
    final request = _syncAllGroupsOnce();
    _syncAllGroupsRequest = request;
    return request.whenComplete(() {
      if (identical(_syncAllGroupsRequest, request)) {
        _syncAllGroupsRequest = null;
      }
    });
  }

  Future<void> _syncAllGroupsOnce() async {
    try {
      List<String> serverGroups;
      try {
        final catalog = await widget.client.listJournalGroupCatalogV2();
        serverGroups = catalog
            .map((item) => item.groupName)
            .toList(growable: false);
        _groupLabels = {for (final item in catalog) item.groupName: item.label};
      } catch (_) {
        serverGroups = await widget.client.listJournalGroups();
      }
      final allowedGroups = serverGroups
          .map((item) => item.trim())
          .where((item) => item.isNotEmpty)
          .toSet();
      final localGroups = _service.getAllGroups();
      for (final local in localGroups) {
        if (!allowedGroups.contains(local.name.trim())) {
          await _service.deleteGroup(local);
        }
      }

      for (final name in serverGroups) {
        final normalizedGroupName = name.trim();
        if (normalizedGroupName.isEmpty) {
          continue;
        }
        var group = _service.getGroupByName(normalizedGroupName);
        if (group == null) {
          group = Group(name: normalizedGroupName);
          await _service.addGroup(group);
        }
        await _syncGroupRosterAndDates(group);
      }

      if (mounted) {
        setState(() {
          _online = true;
          _lastSync = DateTime.now();
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _online = false);
      }
    }
  }

  Future<void> _syncGroupRosterAndDates(Group group) async {
    final studentsFuture = widget.client.listJournalStudents(group.name);
    final datesFuture = widget.client.listJournalDateEntries(group.name);
    final serverStudents = await studentsFuture;
    final serverDates = await datesFuture;

    final serverStudentByKey = <String, String>{};
    for (final studentName in serverStudents) {
      final value = studentName.trim();
      if (value.isEmpty) {
        continue;
      }
      serverStudentByKey[value.toLowerCase()] = value;
    }
    for (final localStudent in _service.getStudentsByGroup(group)) {
      final key = localStudent.name.trim().toLowerCase();
      if (key.isEmpty) {
        continue;
      }
      if (!serverStudentByKey.containsKey(key)) {
        await _service.deleteStudent(localStudent);
      }
    }
    final localStudentKeys = _service
        .getStudentsByGroup(group)
        .map((item) => item.name.trim().toLowerCase())
        .where((item) => item.isNotEmpty)
        .toSet();
    for (final entry in serverStudentByKey.entries) {
      if (localStudentKeys.contains(entry.key)) {
        continue;
      }
      await _service.addStudent(
        Student(name: entry.value, groupId: group.groupId),
      );
    }

    final serverDateByKey = <String, JournalDateEntry>{};
    for (final item in serverDates) {
      serverDateByKey[_dateIdentity(item.classDate, item.lessonSlot)] = item;
    }
    for (final localDate in _service.getDatesByGroup(group)) {
      final key = _lessonDateIdentity(localDate);
      if (!serverDateByKey.containsKey(key)) {
        await _service.deleteDate(localDate);
      }
    }
    final localDateKeys = _service
        .getDatesByGroup(group)
        .map(_lessonDateIdentity)
        .toSet();
    for (final item in serverDateByKey.values) {
      final key = _dateIdentity(item.classDate, item.lessonSlot);
      if (localDateKeys.contains(key)) {
        continue;
      }
      final label = _formatDateLabelWithSlot(item.classDate, item.lessonSlot);
      await _service.addDate(
        LessonDate(date: item.classDate, label: label, groupId: group.groupId),
      );
    }
  }

  Future<void> _syncFromServer() async {
    if (_group == null) return;
    final groupName = _group!.name;
    final pending = _syncFromServerRequest;
    if (pending != null && _syncFromServerGroupName == groupName) {
      return pending;
    }
    final request = _syncFromServerOnce(groupName);
    _syncFromServerGroupName = groupName;
    _syncFromServerRequest = request;
    return request.whenComplete(() {
      if (identical(_syncFromServerRequest, request)) {
        _syncFromServerRequest = null;
        _syncFromServerGroupName = null;
      }
    });
  }

  Future<void> _syncFromServerOnce(String groupName) async {
    final group = _service.getGroupByName(groupName);
    if (group == null) return;

    setState(() => _syncing = true);

    try {
      final rosterAndDatesFuture = _syncGroupRosterAndDates(group);
      final attendanceFuture = widget.client.listAttendance(groupName);
      final results = await Future.wait<dynamic>([
        rosterAndDatesFuture,
        attendanceFuture,
      ]);
      final records = results[1] as List<AttendanceRecord>;

      var dates = _service.getDatesByGroup(group);

      for (final record in records) {
        var student = _service.getStudentByNameAndGroup(
          record.studentName,
          group.groupId,
        );

        if (student == null) {
          student = Student(name: record.studentName, groupId: group.groupId);
          await _service.addStudent(student);
        }

        final slot = record.lessonSlot < 1 ? 1 : record.lessonSlot;
        final label = _formatDateLabelWithSlot(record.classDate, slot);

        LessonDate? date;

        for (final d in dates) {
          if (_lessonDateIdentity(d) == _dateIdentity(record.classDate, slot)) {
            date = d;
            break;
          }
        }

        if (date == null) {
          final created = LessonDate(
            date: record.classDate,
            label: label,
            groupId: group.groupId,
          );

          await _service.addDate(created);

          dates = _service.getDatesByGroup(group);

          date = dates.firstWhere(
            (d) =>
                _lessonDateIdentity(d) == _dateIdentity(record.classDate, slot),
          );
        }

        await _service.addOrUpdateAttendance(
          Attendance(
            studentName: student.name,
            groupId: group.groupId,
            dateId: date.key.toString(),
            present: record.present,
          ),
        );
      }

      if (mounted) {
        setState(() {
          _online = true;
          _lastSync = DateTime.now();
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _online = false);
      }
    } finally {
      if (mounted) {
        setState(() => _syncing = false);
      }
    }
  }

  void _showMessage(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: isError
              ? const Color(0xFFB91C1C)
              : const Color(0xFF166534),
        ),
      );
  }

  String _readErrorText(Object error) {
    if (error is ApiException) {
      if (error.body.trim().isNotEmpty) {
        try {
          final decoded = jsonDecode(error.body);
          if (decoded is Map<String, dynamic>) {
            final detail = decoded['detail'];
            if (detail is String && detail.trim().isNotEmpty) {
              return detail.trim();
            }
            final message = decoded['message'];
            if (message is String && message.trim().isNotEmpty) {
              return message.trim();
            }
          }
        } catch (_) {}
      }
      return 'HTTP ${error.statusCode}';
    }
    return error.toString().replaceFirst('Exception: ', '');
  }

  List<int> _excelTableBytes(List<List<String>> rows) {
    String escape(String value) {
      final escaped = value.replaceAll('"', '""');
      final needsQuote =
          escaped.contains('\t') ||
          escaped.contains('\n') ||
          escaped.contains('\r') ||
          escaped.contains('"');
      return needsQuote ? '"$escaped"' : escaped;
    }

    final text = rows.map((row) => row.map(escape).join('\t')).join('\r\n');
    final bytes = <int>[0xFF, 0xFE];
    for (final unit in text.codeUnits) {
      bytes
        ..add(unit & 0xFF)
        ..add((unit >> 8) & 0xFF);
    }
    return bytes;
  }

  String _decodeTableBytes(List<int> bytes) {
    if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
      final units = <int>[];
      for (int i = 2; i + 1 < bytes.length; i += 2) {
        units.add(bytes[i] | (bytes[i + 1] << 8));
      }
      return String.fromCharCodes(units);
    }
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      return utf8.decode(bytes.sublist(3), allowMalformed: true);
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  List<List<String>> _parseTable(String text) {
    final normalized = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final firstLine = normalized
        .split('\n')
        .firstWhere((line) => line.trim().isNotEmpty, orElse: () => '');
    if (firstLine.isEmpty) return const [];
    final delimiter = firstLine.contains('\t')
        ? '\t'
        : (firstLine.contains(';') ? ';' : ',');
    final rows = <List<String>>[];
    final row = <String>[];
    final cell = StringBuffer();
    var quoted = false;
    for (var i = 0; i < normalized.length; i++) {
      final char = normalized[i];
      if (quoted) {
        if (char == '"') {
          if (i + 1 < normalized.length && normalized[i + 1] == '"') {
            cell.write('"');
            i++;
          } else {
            quoted = false;
          }
        } else {
          cell.write(char);
        }
        continue;
      }
      if (char == '"') {
        quoted = true;
      } else if (char == delimiter) {
        row.add(cell.toString());
        cell.clear();
      } else if (char == '\n') {
        row.add(cell.toString());
        cell.clear();
        if (row.any((value) => value.trim().isNotEmpty)) {
          rows.add(List<String>.from(row));
        }
        row.clear();
      } else {
        cell.write(char);
      }
    }
    row.add(cell.toString());
    if (row.any((value) => value.trim().isNotEmpty)) {
      rows.add(List<String>.from(row));
    }
    return rows;
  }

  bool? _parseAttendanceValue(String value) {
    final normalized = value.trim().toLowerCase();
    if (normalized.isEmpty) return null;
    if (normalized == 'true' ||
        normalized == '1' ||
        normalized == 'yes' ||
        normalized == 'y' ||
        normalized == 'да' ||
        normalized == 'д' ||
        normalized == 'p' ||
        normalized == 'р' ||
        normalized == 'присутствовал' ||
        normalized == 'присутствует') {
      return true;
    }
    if (normalized == 'false' ||
        normalized == '0' ||
        normalized == 'no' ||
        normalized == 'n' ||
        normalized == 'нет' ||
        normalized == 'н' ||
        normalized == 'отсутствовал' ||
        normalized == 'отсутствует') {
      return false;
    }
    return null;
  }

  Future<void> _openTableFile(List<List<String>> rows) async {
    final uri = Uri.dataFromBytes(_excelTableBytes(rows), mimeType: 'text/csv');
    await launchUrl(uri, mode: LaunchMode.platformDefault);
  }

  String _excelTextCell(String value) {
    final escaped = value.replaceAll('"', '""');
    return '="$escaped"';
  }

  String _normalizeExcelTextCell(String value) {
    final trimmed = value.trim();
    final match = RegExp(r'^="(.*)"$').firstMatch(trimmed);
    if (match == null) return trimmed;
    return match.group(1)!.replaceAll('""', '"');
  }

  DateTime? _parseExportDate(String value) {
    final trimmed = _normalizeExcelTextCell(value);
    if (trimmed.isEmpty) return null;
    final iso = DateTime.tryParse(trimmed);
    if (iso != null) return iso;
    final match = RegExp(
      r'^(\d{1,2})\.(\d{1,2})\.(\d{4})$',
    ).firstMatch(trimmed);
    if (match == null) return null;
    final day = int.tryParse(match.group(1)!);
    final month = int.tryParse(match.group(2)!);
    final year = int.tryParse(match.group(3)!);
    if (day == null || month == null || year == null) return null;
    return DateTime(year, month, day);
  }

  ({DateTime classDate, int lessonSlot})? _parseAttendanceDateHeader(
    String value,
  ) {
    final normalized = _normalizeExcelTextCell(value);
    final parts = normalized.split('|');
    final date = _parseExportDate(parts.first.trim());
    if (date == null) return null;
    var lessonSlot = 1;
    if (parts.length > 1) {
      final match = RegExp(
        r'[пp]?(\d+)',
        caseSensitive: false,
      ).firstMatch(parts.sublist(1).join('|'));
      lessonSlot = int.tryParse(match?.group(1) ?? '') ?? 1;
    }
    return (classDate: date, lessonSlot: lessonSlot < 1 ? 1 : lessonSlot);
  }

  List<List<String>> _buildAttendanceExportRows() {
    final byKey = <String, Attendance>{};
    for (final item
        in _group == null
            ? const <Attendance>[]
            : _service.getAttendanceByGroup(_group!)) {
      byKey['${item.studentName}|${item.dateId}'] = item;
    }
    return [
      [
        _tr('Студент', 'Student'),
        for (final date in _dates)
          _excelTextCell(
            _formatDateLabelWithSlot(date.date, _lessonSlotFromLesson(date)),
          ),
      ],
      for (final student in _students)
        [
          student.name,
          for (final date in _dates)
            switch (byKey['${student.name}|${date.key.toString()}']) {
              final mark? => mark.present ? 'P' : 'Н',
              null => '',
            },
        ],
    ];
  }

  Future<int> _importAttendanceGridTable(
    Group group,
    List<List<String>> table,
    List<String> errors,
  ) async {
    final header = table.first.map((item) => item.trim()).toList();
    if (header.length < 2) return 0;
    final datesByColumn = <int, ({DateTime classDate, int lessonSlot})>{};
    for (var i = 1; i < header.length; i++) {
      final date = _parseAttendanceDateHeader(header[i]);
      if (date != null) {
        datesByColumn[i] = date;
      }
    }
    if (datesByColumn.isEmpty) {
      throw Exception(
        _tr(
          'В файле нет колонок дат вида 01.01.2026',
          'No date columns like 01.01.2026 found in the file',
        ),
      );
    }

    var updated = 0;
    for (var rowIndex = 1; rowIndex < table.length; rowIndex++) {
      final row = table[rowIndex];
      if (row.isEmpty) continue;
      final student = row.first.trim();
      if (student.isEmpty) {
        errors.add(
          _tr(
            'строка ${rowIndex + 1}: пустой студент',
            'line ${rowIndex + 1}: empty student',
          ),
        );
        continue;
      }
      for (final entry in datesByColumn.entries) {
        final raw = entry.key < row.length ? row[entry.key].trim() : '';
        if (raw.isEmpty || raw == '-') continue;
        final present = _parseAttendanceValue(raw);
        if (present == null) {
          errors.add(
            _tr(
              'строка ${rowIndex + 1}: неверное значение посещения',
              'line ${rowIndex + 1}: invalid attendance value',
            ),
          );
          continue;
        }
        await widget.client.createAttendance(
          groupName: group.name,
          classDate: entry.value.classDate,
          lessonSlot: entry.value.lessonSlot,
          studentName: student,
          present: present,
        );
        updated++;
      }
    }
    return updated;
  }

  Future<void> _exportAttendanceCsv() async {
    final group = _group;
    if (group == null) return;
    try {
      await _openTableFile(_buildAttendanceExportRows());
      if (!mounted) return;
      _showMessage(
        _tr('Экспорт посещаемости открыт.', 'Attendance export opened.'),
      );
    } catch (error) {
      if (!mounted) return;
      _showMessage(_readErrorText(error), isError: true);
    }
  }

  Future<void> _importAttendanceCsv() async {
    final group = _group;
    if (group == null) return;
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['csv', 'tsv', 'txt'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final bytes = result.files.first.bytes;
    if (bytes == null || bytes.isEmpty) return;
    setState(() => _busy = true);
    var updated = 0;
    var skipped = 0;
    final errors = <String>[];
    try {
      final table = _parseTable(_decodeTableBytes(bytes));
      if (table.isEmpty) {
        throw Exception(_tr('Файл пустой', 'File is empty'));
      }
      final header = table.first.map((e) => e.trim().toLowerCase()).toList();
      int col(String name) => header.indexOf(name);
      final groupCol = col('group_name');
      final dateCol = col('class_date');
      final slotCol = col('lesson_slot');
      final studentCol = col('student_name');
      final presentCol = col('present');
      if (dateCol < 0 || studentCol < 0 || presentCol < 0) {
        updated = await _importAttendanceGridTable(group, table, errors);
        await _syncFromServer();
        await _loadGroupData(sync: false);
        if (!mounted) return;
        _showMessage(
          '${_tr('Обновлено', 'Updated')}: $updated; '
          '${_tr('Пропущено', 'Skipped')}: $skipped'
          '${errors.isEmpty ? '' : '\n${errors.take(4).join('\n')}'}',
          isError: errors.isNotEmpty,
        );
        return;
      }
      for (var i = 1; i < table.length; i++) {
        final row = table[i];
        String at(int index) =>
            index >= 0 && index < row.length ? row[index].trim() : '';
        final rowGroup = at(groupCol).isEmpty ? group.name : at(groupCol);
        final student = at(studentCol);
        final date = _parseExportDate(at(dateCol));
        final slot = int.tryParse(at(slotCol)) ?? 1;
        final present = _parseAttendanceValue(at(presentCol));
        if (rowGroup != group.name) {
          skipped++;
          errors.add(
            _tr(
              'строка ${i + 1}: другая группа',
              'line ${i + 1}: another group',
            ),
          );
          continue;
        }
        if (student.isEmpty || date == null || present == null) {
          skipped++;
          errors.add(
            _tr(
              'строка ${i + 1}: неверная дата/студент/посещение',
              'line ${i + 1}: invalid date/student/attendance',
            ),
          );
          continue;
        }
        await widget.client.createAttendance(
          groupName: group.name,
          classDate: date,
          lessonSlot: slot,
          studentName: student,
          present: present,
        );
        updated++;
      }
      await _syncFromServer();
      await _loadGroupData(sync: false);
      if (!mounted) return;
      _showMessage(
        '${_tr('Обновлено', 'Updated')}: $updated; '
        '${_tr('Пропущено', 'Skipped')}: $skipped'
        '${errors.isEmpty ? '' : '\n${errors.take(4).join('\n')}'}',
        isError: errors.isNotEmpty,
      );
    } catch (error) {
      if (!mounted) return;
      _showMessage(_readErrorText(error), isError: true);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _addStudents() async {
    if (!widget.canEdit || _group == null) return;
    final candidates = await widget.client.listConfirmedJournalStudents(
      _group!.name,
    );
    if (!mounted) return;
    if (candidates.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _tr(
              'Для выбранной группы нет подтвержденных студентов.',
              'No approved students found for the selected group.',
            ),
          ),
        ),
      );
      return;
    }
    final selectedName = await _pickStudentName(candidates);
    if (selectedName == null) return;
    final name = selectedName.trim();
    if (name.isEmpty) return;
    setState(() => _busy = true);
    try {
      await widget.client.upsertJournalStudent(
        groupName: _group!.name,
        studentName: name,
      );
      final existing = _service.getStudentByNameAndGroup(name, _group!.groupId);
      if (existing == null) {
        await _service.addStudent(
          Student(name: name, groupId: _group!.groupId),
        );
      }
      await _loadGroupData(sync: false);
      if (mounted) {
        setState(() => _online = true);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _online = false);
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<String?> _pickStudentName(List<UserPublicProfile> candidates) async {
    final names =
        candidates
            .map((item) => item.fullName.trim())
            .where((value) => value.isNotEmpty)
            .toSet()
            .toList(growable: false)
          ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    if (names.isEmpty) {
      return null;
    }
    final queryController = TextEditingController();
    String selected = names.first;
    final result = await showDialog<String>(
      context: context,
      builder: (context) {
        var filtered = names;
        return StatefulBuilder(
          builder: (context, setStateDialog) => AlertDialog(
            title: Text(_tr('Добавить студента', 'Add student')),
            content: SizedBox(
              width: 460,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: queryController,
                    autofocus: true,
                    decoration: InputDecoration(
                      labelText: _tr('Поиск студента', 'Search student'),
                      border: const OutlineInputBorder(),
                    ),
                    onChanged: (value) {
                      final needle = value.trim().toLowerCase();
                      setStateDialog(() {
                        if (needle.isEmpty) {
                          filtered = names;
                        } else {
                          filtered = names
                              .where(
                                (item) => item.toLowerCase().contains(needle),
                              )
                              .toList(growable: false);
                        }
                        if (filtered.isNotEmpty &&
                            !filtered.contains(selected)) {
                          selected = filtered.first;
                        }
                      });
                    },
                  ),
                  const SizedBox(height: 10),
                  if (filtered.isEmpty)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(_tr('Совпадений нет.', 'No matches found.')),
                    )
                  else
                    DropdownButtonFormField<String>(
                      initialValue: selected,
                      isExpanded: true,
                      items: filtered
                          .map(
                            (item) => DropdownMenuItem(
                              value: item,
                              child: Text(
                                item,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          )
                          .toList(),
                      selectedItemBuilder: (context) => filtered
                          .map(
                            (item) => Align(
                              alignment: Alignment.centerLeft,
                              child: Text(
                                item,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (value) {
                        if (value == null) return;
                        selected = value;
                      },
                      decoration: InputDecoration(
                        labelText: _tr(
                          'Подтвержденный студент группы',
                          'Approved student in group',
                        ),
                      ),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(_tr('Отмена', 'Cancel')),
              ),
              FilledButton(
                onPressed: filtered.isEmpty
                    ? null
                    : () => Navigator.of(context).pop(selected),
                child: Text(_tr('Добавить', 'Add')),
              ),
            ],
          ),
        );
      },
    );
    queryController.dispose();
    return result;
  }

  Future<void> _addDate() async {
    if (!widget.canEdit || _group == null) return;
    final pickedDates = await showJournalMultiDatePicker(
      context,
      title: _tr('Выберите даты', 'Select dates'),
      locale: Localizations.localeOf(context),
      initialDate: DateTime.now(),
    );
    if (pickedDates == null || pickedDates.isEmpty) return;
    setState(() => _busy = true);
    try {
      for (final picked in pickedDates) {
        final normalized = DateTime(picked.year, picked.month, picked.day);
        final created = await widget.client.upsertJournalDate(
          groupName: _group!.name,
          classDate: normalized,
        );
        final label = _formatDateLabelWithSlot(
          created.classDate,
          created.lessonSlot,
        );
        final exists = _service
            .getDatesByGroup(_group!)
            .any(
              (item) =>
                  _lessonDateIdentity(item) ==
                  _dateIdentity(created.classDate, created.lessonSlot),
            );
        if (!exists) {
          await _service.addDate(
            LessonDate(
              date: created.classDate,
              label: label,
              groupId: _group!.groupId,
            ),
          );
        }
      }
      await _loadGroupData(sync: false);
      if (mounted) {
        setState(() => _online = true);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _online = false);
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  bool _parsePresent(String raw) {
    final value = raw.trim().toLowerCase();
    return value == 'p' ||
        value == '+' ||
        value == '1' ||
        value == 'y' ||
        value == 'yes' ||
        value == 'да' ||
        value == 'present' ||
        value == 'пр' ||
        value == 'п';
  }

  Future<String?> _showMarkDialog({
    required String title,
    required String initial,
  }) async {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(title),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: controller,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: _tr('P / Н / пусто', 'P / N / empty'),
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _quickMarkChip('P', controller),
                  _quickMarkChip('Н', controller),
                  _quickMarkChip('', controller, clear: true),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(_tr('Отмена', 'Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: Text(_tr('Сохранить', 'Save')),
            ),
          ],
        );
      },
    );
  }

  Widget _quickMarkChip(
    String value,
    TextEditingController controller, {
    bool clear = false,
  }) {
    return ActionChip(
      label: Text(clear ? _tr('Очистить', 'Clear') : value),
      onPressed: () {
        controller.text = value;
      },
    );
  }

  Future<void> _editAttendanceCell(
    String studentName,
    LessonDate date,
    Attendance? existing,
  ) async {
    if (!widget.canEdit || _group == null) return;
    final initial = existing == null ? '' : (existing.present ? 'P' : 'Н');
    final value = await _showMarkDialog(
      title: '$studentName • ${date.label}',
      initial: initial,
    );
    if (value == null) return;

    setState(() => _busy = true);
    try {
      final trimmed = value.trim();
      final lessonSlot = _lessonSlotFromLesson(date);
      if (trimmed.isEmpty) {
        final current = _service.getAttendance(
          studentName,
          _group!.groupId,
          date.key.toString(),
        );
        if (current != null) {
          await _service.deleteAttendance(current);
        }
        await widget.client.deleteAttendance(
          groupName: _group!.name,
          classDate: date.date,
          lessonSlot: lessonSlot,
          studentName: studentName,
        );
      } else {
        final present = _parsePresent(trimmed);
        await _service.addOrUpdateAttendance(
          Attendance(
            studentName: studentName,
            groupId: _group!.groupId,
            dateId: date.key.toString(),
            present: present,
          ),
        );
        await widget.client.createAttendance(
          groupName: _group!.name,
          classDate: date.date,
          lessonSlot: lessonSlot,
          studentName: studentName,
          present: present,
        );
      }
      _students = _service.getStudentsByGroup(_group!);
      _dates = _service.getDatesByGroup(_group!);
      _dates.sort(_compareLessonDates);
      if (mounted) {
        setState(() {
          _online = true;
          _lastSync = DateTime.now();
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _online = false);
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  String _formatDateLabel(DateTime date) {
    return '${date.day.toString().padLeft(2, '0')}.${date.month.toString().padLeft(2, '0')}.${date.year}';
  }

  String _formatDateLabelWithSlot(DateTime date, int lessonSlot) {
    final normalized = lessonSlot < 1 ? 1 : lessonSlot;
    final base = _formatDateLabel(date);
    if (normalized <= 1) {
      return base;
    }
    return '$base |п$normalized';
  }

  String _dateIdentity(DateTime date, int lessonSlot) {
    final y = date.year.toString().padLeft(4, '0');
    final m = date.month.toString().padLeft(2, '0');
    final d = date.day.toString().padLeft(2, '0');
    final slot = lessonSlot < 1 ? 1 : lessonSlot;
    return '$y-$m-$d|$slot';
  }

  int _lessonSlotFromLesson(LessonDate date) {
    final match = RegExp(
      r'\|\s*[пp](\d+)\s*$',
      caseSensitive: false,
    ).firstMatch(date.label);
    if (match == null) {
      return 1;
    }
    return int.tryParse(match.group(1) ?? '') ?? 1;
  }

  String _lessonDateIdentity(LessonDate date) {
    return _dateIdentity(date.date, _lessonSlotFromLesson(date));
  }

  int _compareLessonDates(LessonDate left, LessonDate right) {
    final byDate = left.date.compareTo(right.date);
    if (byDate != 0) {
      return byDate;
    }
    return _lessonSlotFromLesson(left).compareTo(_lessonSlotFromLesson(right));
  }

  String _gridDateLabel(LessonDate date) {
    final base = _dateLabelFormat.format(date.date);
    final slot = _lessonSlotFromLesson(date);
    if (slot <= 1) {
      return base;
    }
    return '$base |п$slot';
  }

  String _formatSyncTime(DateTime time) {
    final y = time.year.toString().padLeft(4, '0');
    final m = time.month.toString().padLeft(2, '0');
    final d = time.day.toString().padLeft(2, '0');
    final h = time.hour.toString().padLeft(2, '0');
    final min = time.minute.toString().padLeft(2, '0');
    return '$y-$m-$d $h:$min';
  }

  Widget _buildSyncIndicator() {
    final label = _syncing
        ? _tr('Синхронизация...', 'Syncing...')
        : _online
        ? _tr('Онлайн', 'Online')
        : _tr('Офлайн', 'Offline');
    final color = _syncing
        ? Colors.orange
        : _online
        ? Colors.green
        : Colors.red;
    final subtitle = _lastSync == null
        ? ''
        : ' • ${_formatSyncTime(_lastSync!)}';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Wrap(
        spacing: 6,
        runSpacing: 2,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Icon(
            _online ? Icons.cloud_done : Icons.cloud_off,
            size: 16,
            color: color,
          ),
          Text(
            '$label$subtitle',
            style: TextStyle(color: color, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(bool compact) {
    return Container(
      padding: EdgeInsets.all(compact ? 14 : 20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        gradient: const LinearGradient(
          colors: [Color(0xFF0F766E), Color(0xFF14532D)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0x330F766E),
            blurRadius: 24,
            offset: Offset(0, 12),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: compact ? 44 : 52,
            height: compact ? 44 : 52,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Icons.fact_check_rounded, color: Colors.white),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _tr('Журнал посещений', 'Attendance Journal'),
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: compact ? 22 : 27,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Tooltip(
            message: _helpText,
            preferBelow: false,
            waitDuration: const Duration(milliseconds: 240),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(999),
                onTap: _showHelpDialog,
                child: Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withValues(alpha: 0.2),
                  ),
                  child: const Icon(
                    Icons.info_outline_rounded,
                    color: Colors.white,
                    size: 18,
                  ),
                ),
              ),
            ),
          ),
          if (widget.canEdit) ...[
            const SizedBox(width: 6),
            Tooltip(
              message: _tr('Настроить подсказку', 'Configure help'),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(999),
                  onTap: _editHelpText,
                  child: Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white.withValues(alpha: 0.2),
                    ),
                    child: const Icon(
                      Icons.tune_rounded,
                      color: Colors.white,
                      size: 17,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildToolbar(bool compact) {
    return _AttendancePanel(
      title: _tr('Управление группой', 'Group management'),
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          _buildSyncIndicator(),
          OutlinedButton.icon(
            onPressed: _syncing
                ? null
                : () async {
                    await _syncFromServer();
                    await _loadGroupData(sync: false);
                  },
            icon: const Icon(Icons.refresh_rounded),
            label: Text(_tr('Обновить', 'Refresh')),
          ),
          SizedBox(
            width: compact ? double.infinity : 260,
            child: DropdownButtonFormField<Group>(
              key: ValueKey('attendance_group_${_group?.groupId ?? 0}'),
              initialValue: _group,
              isExpanded: true,
              items: [
                for (final g in _groups)
                  DropdownMenuItem(
                    value: g,
                    child: Text(
                      _groupLabels[g.name] ?? g.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              selectedItemBuilder: (context) => _groups
                  .map(
                    (g) => Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        _groupLabels[g.name] ?? g.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  )
                  .toList(),
              onChanged: (value) async {
                if (value == null) return;
                setState(() => _group = value);
                await _loadGroupData(sync: true);
              },
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                labelText: _tr('Группа', 'Group'),
                isDense: true,
              ),
            ),
          ),
          OutlinedButton.icon(
            onPressed: (_syncing || _groups.isEmpty)
                ? null
                : () async {
                    final selected = await _pickGroupWithSearch();
                    if (!mounted || selected == null) return;
                    if (_group?.groupId == selected.groupId) return;
                    setState(() => _group = selected);
                    await _loadGroupData(sync: true);
                  },
            icon: const Icon(Icons.search_rounded),
            label: Text(_tr('Поиск группы', 'Search group')),
          ),
          OutlinedButton.icon(
            onPressed: (_syncing || _group == null)
                ? null
                : _exportAttendanceCsv,
            icon: const Icon(Icons.download_rounded),
            label: Text(_tr('Экспорт', 'Export')),
          ),
          FilledButton.tonalIcon(
            onPressed: (_syncing || _busy || _group == null)
                ? null
                : _importAttendanceCsv,
            icon: const Icon(Icons.upload_file_rounded),
            label: Text(_tr('Импорт', 'Import')),
          ),
        ],
      ),
    );
  }

  List<Group> _filterGroupsByQuery(String query) {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) {
      return _groups;
    }
    final startsWith = <Group>[];
    final contains = <Group>[];
    for (final group in _groups) {
      final label = (_groupLabels[group.name] ?? group.name).toLowerCase();
      final raw = group.name.toLowerCase();
      if (label.startsWith(needle) || raw.startsWith(needle)) {
        startsWith.add(group);
      } else if (label.contains(needle) || raw.contains(needle)) {
        contains.add(group);
      }
    }
    return [...startsWith, ...contains];
  }

  Future<Group?> _pickGroupWithSearch() async {
    if (_groups.isEmpty) {
      return null;
    }
    final queryController = TextEditingController();
    Group selected = _group ?? _groups.first;
    final result = await showDialog<Group>(
      context: context,
      builder: (context) {
        var filtered = _groups;
        return StatefulBuilder(
          builder: (context, setStateDialog) => AlertDialog(
            title: Text(_tr('Выбор группы', 'Select group')),
            content: SizedBox(
              width: 460,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: queryController,
                    autofocus: true,
                    decoration: InputDecoration(
                      labelText: _tr('Поиск группы', 'Search group'),
                      border: const OutlineInputBorder(),
                    ),
                    onChanged: (value) {
                      setStateDialog(() {
                        filtered = _filterGroupsByQuery(value);
                        if (filtered.isNotEmpty &&
                            !filtered.any(
                              (item) => item.groupId == selected.groupId,
                            )) {
                          selected = filtered.first;
                        }
                      });
                    },
                  ),
                  const SizedBox(height: 10),
                  if (filtered.isEmpty)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(_tr('Совпадений нет.', 'No matches found.')),
                    )
                  else
                    DropdownButtonFormField<Group>(
                      initialValue: filtered.firstWhere(
                        (item) => item.groupId == selected.groupId,
                        orElse: () => filtered.first,
                      ),
                      isExpanded: true,
                      items: filtered
                          .map(
                            (item) => DropdownMenuItem(
                              value: item,
                              child: Text(
                                _groupLabels[item.name] ?? item.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          )
                          .toList(),
                      selectedItemBuilder: (context) => filtered
                          .map(
                            (item) => Align(
                              alignment: Alignment.centerLeft,
                              child: Text(
                                _groupLabels[item.name] ?? item.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (value) {
                        if (value == null) return;
                        selected = value;
                      },
                      decoration: InputDecoration(
                        labelText: _tr('Группа', 'Group'),
                      ),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(_tr('Отмена', 'Cancel')),
              ),
              FilledButton(
                onPressed: filtered.isEmpty
                    ? null
                    : () => Navigator.of(context).pop(selected),
                child: Text(_tr('Открыть', 'Open')),
              ),
            ],
          ),
        );
      },
    );
    queryController.dispose();
    return result;
  }

  Widget _buildQuickAddPanel(bool compact) {
    return _AttendancePanel(
      title: _tr('Быстрое добавление', 'Quick add'),
      child: _group == null
          ? Text(_tr('Сначала выберите группу.', 'Select a group first.'))
          : Wrap(
              spacing: 10,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (widget.canEdit)
                  FilledButton.icon(
                    onPressed: _busy ? null : _addStudents,
                    icon: const Icon(Icons.person_add_alt_1_rounded),
                    label: Text(_tr('Добавить студента', 'Add student')),
                  ),
                if (widget.canEdit)
                  FilledButton.tonalIcon(
                    onPressed: _busy ? null : _addDate,
                    icon: const Icon(Icons.event_available_rounded),
                    label: Text(_tr('Добавить даты', 'Add dates')),
                  ),
                Text(
                  _tr(
                    'Редактирование: клик по ячейке в таблице.',
                    'Edit: tap any cell in the grid.',
                  ),
                  style: const TextStyle(
                    color: Color(0xFF64748B),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildGrid(bool compact) {
    if (_loading) {
      return _AttendancePanel(
        title: _tr('Сетка посещений', 'Attendance grid'),
        child: const SizedBox(
          height: 180,
          child: Center(child: BrandLoadingIndicator(logoSize: 56, spacing: 8)),
        ),
      );
    }
    if (_group == null) {
      return _AttendancePanel(
        title: _tr('Сетка посещений', 'Attendance grid'),
        child: Text(
          _tr('Выберите или создайте группу.', 'Select or create a group.'),
        ),
      );
    }

    final byKey = <String, Attendance>{};
    final attendance = _service.getAttendanceByGroup(_group!);
    for (final item in attendance) {
      byKey['${item.studentName}|${item.dateId}'] = item;
    }

    return _AttendancePanel(
      title: _tr('Сетка посещений', 'Attendance grid'),
      child: (_students.isEmpty || _dates.isEmpty)
          ? Text(
              _students.isEmpty
                  ? _tr(
                      'Добавьте студентов, чтобы начать отмечать посещаемость.',
                      'Add students to start marking attendance.',
                    )
                  : _tr(
                      'Добавьте даты занятий для группы.',
                      'Add class dates for the group.',
                    ),
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: compact ? 160 : 220,
                  child: DataTable(
                    dataRowMinHeight: compact ? 40 : 46,
                    dataRowMaxHeight: compact ? 56 : 64,
                    columns: [
                      DataColumn(label: Text(_tr('Студент', 'Student'))),
                    ],
                    rows: _students
                        .map(
                          (student) => DataRow(
                            cells: [
                              DataCell(
                                ConstrainedBox(
                                  constraints: const BoxConstraints(
                                    maxWidth: 210,
                                  ),
                                  child: Text(
                                    student.name,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        )
                        .toList(),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Scrollbar(
                    controller: _gridHorizontalController,
                    thumbVisibility: true,
                    trackVisibility: true,
                    notificationPredicate: (notification) =>
                        notification.metrics.axis == Axis.horizontal,
                    child: SingleChildScrollView(
                      controller: _gridHorizontalController,
                      scrollDirection: Axis.horizontal,
                      child: DataTable(
                        dataRowMinHeight: compact ? 40 : 46,
                        dataRowMaxHeight: compact ? 56 : 64,
                        columns: [
                          ..._dates.map(
                            (date) =>
                                DataColumn(label: Text(_gridDateLabel(date))),
                          ),
                        ],
                        rows: _students.map((student) {
                          return DataRow(
                            cells: [
                              ..._dates.map((date) {
                                final key =
                                    '${student.name}|${date.key.toString()}';
                                final mark = byKey[key];
                                final text = mark == null
                                    ? '-'
                                    : (mark.present ? 'P' : 'Н');
                                final color = mark == null
                                    ? const Color(0xFFF8FAFC)
                                    : mark.present
                                    ? const Color(0xFFDCFCE7)
                                    : const Color(0xFFFEE2E2);
                                return DataCell(
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 4,
                                    ),
                                    decoration: BoxDecoration(
                                      color: color,
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Text(text),
                                  ),
                                  onTap: widget.canEdit
                                      ? () => _editAttendanceCell(
                                          student.name,
                                          date,
                                          mark,
                                        )
                                      : null,
                                );
                              }),
                            ],
                          );
                        }).toList(),
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_isInitialized) {
      return const Center(child: BrandLoadingIndicator());
    }
    final width = MediaQuery.of(context).size.width;
    final compact = width < 900;
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFF8FCFA), Color(0xFFE9F5EF)],
        ),
      ),
      child: RefreshIndicator(
        onRefresh: () async {
          await _syncFromServer();
          await _loadGroupData(sync: false);
        },
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 12 : 22,
            vertical: 16,
          ),
          children: [
            _buildHeader(compact),
            const SizedBox(height: 14),
            _buildToolbar(compact),
            const SizedBox(height: 14),
            _buildQuickAddPanel(compact),
            const SizedBox(height: 14),
            _buildGrid(compact),
          ],
        ),
      ),
    );
  }
}

class _AttendancePanel extends StatelessWidget {
  const _AttendancePanel({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: Color(0xFF0F172A),
            ),
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}
