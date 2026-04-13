import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  Group? _group;
  List<Group> _groups = <Group>[];
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
    setState(() => _loading = true);
    await _service.init();
    await _loadHelpText();
    await _mergeServerGroups();
    _groups = _service.getAllGroups();
    if (_groups.isNotEmpty) {
      _group ??= _groups.first;
    }
    await _loadGroupData(sync: true);
    if (!mounted) return;
    setState(() {
      _isInitialized = true;
      _loading = false;
    });
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
      final localGroups = _service.getAllGroups();
      for (final group in localGroups) {
        await widget.client.upsertJournalGroup(group.name);
      }
      final serverGroups = await widget.client.listJournalGroups();
      for (final name in serverGroups) {
        final existing = _service.getGroupByName(name);
        if (existing == null) {
          await _service.addGroup(Group(name: name));
        }
      }
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
    try {
      final localGroups = _service.getAllGroups();
      for (final group in localGroups) {
        await widget.client.upsertJournalGroup(group.name);
        final localStudents = _service.getStudentsByGroup(group);
        for (final student in localStudents) {
          await widget.client.upsertJournalStudent(
            groupName: group.name,
            studentName: student.name,
          );
        }
        final localDates = _service.getDatesByGroup(group);
        for (final d in localDates) {
          await widget.client.upsertJournalDate(
            groupName: group.name,
            classDate: d.date,
            lessonSlot: _lessonSlotFromLesson(d),
          );
        }
      }

      final serverGroups = await widget.client.listJournalGroups();
      for (final name in serverGroups) {
        var group = _service.getGroupByName(name);
        if (group == null) {
          group = Group(name: name);
          await _service.addGroup(group);
        }
        final serverStudents = await widget.client.listJournalStudents(name);
        for (final studentName in serverStudents) {
          final existing = _service.getStudentByNameAndGroup(
            studentName,
            group.groupId,
          );
          if (existing == null) {
            await _service.addStudent(
              Student(name: studentName, groupId: group.groupId),
            );
          }
        }
        final serverDates = await widget.client.listJournalDateEntries(name);
        for (final d in serverDates) {
          final label = _formatDateLabelWithSlot(d.classDate, d.lessonSlot);
          final dates = _service.getDatesByGroup(group);
          final exists = dates.any(
            (item) =>
                _lessonDateIdentity(item) ==
                _dateIdentity(d.classDate, d.lessonSlot),
          );
          if (!exists) {
            await _service.addDate(
              LessonDate(
                date: d.classDate,
                label: label,
                groupId: group.groupId,
              ),
            );
          }
        }
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

  Future<void> _syncFromServer() async {
    if (_group == null) return;
    setState(() => _syncing = true);
    try {
      await _syncAllGroups();
      final records = await widget.client.listAttendance(_group!.name);
      var dates = _service.getDatesByGroup(_group!);
      for (final record in records) {
        var student = _service.getStudentByNameAndGroup(
          record.studentName,
          _group!.groupId,
        );
        if (student == null) {
          student = Student(name: record.studentName, groupId: _group!.groupId);
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
            groupId: _group!.groupId,
          );
          await _service.addDate(created);
          dates = _service.getDatesByGroup(_group!);
          date = dates.firstWhere(
            (d) =>
                _lessonDateIdentity(d) == _dateIdentity(record.classDate, slot),
          );
        }

        await _service.addOrUpdateAttendance(
          Attendance(
            studentName: student.name,
            groupId: _group!.groupId,
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
              'Нет свободных подтвержденных студентов без группы.',
              'No free approved students without a group.',
            ),
          ),
        ),
      );
      return;
    }
    var selectedName = candidates.first.fullName.trim();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_tr('Добавить студента', 'Add student')),
        content: DropdownButtonFormField<String>(
          initialValue: selectedName,
          items: candidates
              .map(
                (item) => DropdownMenuItem(
                  value: item.fullName.trim(),
                  child: Text(item.fullName.trim()),
                ),
              )
              .toList(),
          onChanged: (value) => selectedName = value?.trim() ?? selectedName,
          decoration: InputDecoration(
            labelText: _tr(
              'Свободный подтвержденный студент',
              'Free approved student',
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(_tr('Отмена', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(_tr('Добавить', 'Add')),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
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
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            _online ? Icons.cloud_done : Icons.cloud_off,
            size: 16,
            color: color,
          ),
          const SizedBox(width: 6),
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
                const SizedBox(height: 4),
                Text(
                  _tr(
                    'Посещаемость по датам + синхронизация с сервером',
                    'Date attendance + server synchronization',
                  ),
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.9)),
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
                  DropdownMenuItem(value: g, child: Text(g.name)),
              ],
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
        ],
      ),
    );
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
