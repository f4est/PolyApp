import 'dart:async';
import 'package:flutter/material.dart';
import 'package:pluto_grid/pluto_grid.dart';
import 'pluto_localization.dart';

import '../api/api_client.dart';
import '../widgets/brand_logo.dart';
import 'journal_date_picker.dart';
import 'models/journal_models.dart';
import 'services/journal_service.dart';

class AttendanceJournalPage extends StatefulWidget {
  const AttendanceJournalPage({
    super.key,
    required this.canEdit,
    required this.client,
  });

  final bool canEdit;
  final ApiClient client;

  @override
  State<AttendanceJournalPage> createState() => _AttendanceJournalPageState();
}

class _AttendanceJournalPageState extends State<AttendanceJournalPage> {
  final JournalService _service = JournalService();

  bool _isInitialized = false;
  Group? _group;
  List<Group> _groups = [];
  List<Student> _students = [];
  List<LessonDate> _dates = [];

  final List<PlutoColumn> _columns = [];
  List<PlutoRow> _rows = [];
  PlutoGridStateManager? _stateManager;

  bool _online = true;
  bool _syncing = false;
  DateTime? _lastSync;
  Timer? _retryTimer;

  bool get _gridReadOnly => !widget.canEdit;

  void _startRetryTimer() {
    _retryTimer?.cancel();
    _retryTimer = Timer.periodic(const Duration(seconds: 30), (timer) async {
      if (!mounted) return;
      if (_online || _syncing) return;
      await _syncAllGroups();
      if (_group != null) {
        await _syncFromServer();
        await _loadGroupData(sync: false);
      }
    });
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
        final serverDates = await widget.client.listJournalDates(name);
        for (final d in serverDates) {
          final label = _formatDateLabel(d);
          final dates = _service.getDatesByGroup(group);
          final exists = dates.any((item) => item.label == label);
          if (!exists) {
            await _service.addDate(
              LessonDate(date: d, label: label, groupId: group.groupId),
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
      if (mounted) setState(() => _online = false);
    }
  }

  @override
  void initState() {
    super.initState();
    _startRetryTimer();
    _loadData();
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

  Future<void> _loadData() async {
    await _service.init();
    await _mergeServerGroups();
    _groups = _service.getAllGroups();
    if (_groups.isNotEmpty) {
      _group ??= _groups.first;
    }
    await _loadGroupData(sync: true);
    if (mounted) {
      setState(() => _isInitialized = true);
    }
  }

  Future<void> _loadGroupData({required bool sync}) async {
    if (_group == null) {
      setState(() {
        _columns.clear();
        _rows.clear();
      });
      return;
    }
    _students = _service.getStudentsByGroup(_group!);
    _dates = _service.getDatesByGroup(_group!);
    _buildColumns();
    _buildRows();
    if (mounted) {
      setState(() {});
    }
    if (sync) {
      await _syncFromServer();
      _students = _service.getStudentsByGroup(_group!);
      _dates = _service.getDatesByGroup(_group!);
      _buildColumns();
      _buildRows();
      if (mounted) {
        setState(() {});
      }
    }
  }

  Future<void> _syncMeta() async {
    if (_group == null) return;
    try {
      await widget.client.upsertJournalGroup(_group!.name);
      final localStudents = _service.getStudentsByGroup(_group!);
      for (final student in localStudents) {
        await widget.client.upsertJournalStudent(
          groupName: _group!.name,
          studentName: student.name,
        );
      }
      final localDates = _service.getDatesByGroup(_group!);
      for (final d in localDates) {
        await widget.client.upsertJournalDate(
          groupName: _group!.name,
          classDate: d.date,
        );
      }

      final serverStudents = await widget.client.listJournalStudents(
        _group!.name,
      );
      for (final name in serverStudents) {
        final existing = _service.getStudentByNameAndGroup(
          name,
          _group!.groupId,
        );
        if (existing == null) {
          await _service.addStudent(
            Student(name: name, groupId: _group!.groupId),
          );
        }
      }
      final serverDates = await widget.client.listJournalDates(_group!.name);
      for (final d in serverDates) {
        final label = _formatDateLabel(d);
        final dates = _service.getDatesByGroup(_group!);
        final exists = dates.any((item) => item.label == label);
        if (!exists) {
          await _service.addDate(
            LessonDate(date: d, label: label, groupId: _group!.groupId),
          );
        }
      }
    } catch (_) {}
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
          _students.add(student);
        }
        final label = _formatDateLabel(record.classDate);
        LessonDate? date;
        for (final d in dates) {
          if (d.label == label) {
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
          date = dates.firstWhere((d) => d.label == label);
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

  void _buildColumns() {
    _columns.clear();
    _columns.add(
      PlutoColumn(
        title: 'Student',
        field: 'student',
        type: PlutoColumnType.text(),
        width: 180,
        frozen: PlutoColumnFrozen.start,
        readOnly: true,
      ),
    );

    for (var i = 0; i < _dates.length; i++) {
      final date = _dates[i];
      _columns.add(
        PlutoColumn(
          title: date.label,
          field: 'date_$i',
          type: PlutoColumnType.text(),
          width: 80,
          readOnly: _gridReadOnly,
          renderer: (context) {
            final value = (context.cell.value ?? '').toString();
            final isPresent = _parsePresent(value);
            final color = value.isEmpty
                ? null
                : (isPresent
                      ? Colors.green.withOpacity(0.2)
                      : Colors.red.withOpacity(0.2));
            return Container(
              color: color,
              alignment: Alignment.center,
              child: Text(isPresent ? 'P' : value),
            );
          },
        ),
      );
    }
  }

  String _formatSyncTime(DateTime time) {
    final y = time.year.toString().padLeft(4, '0');
    final m = time.month.toString().padLeft(2, '0');
    final d = time.day.toString().padLeft(2, '0');
    final h = time.hour.toString().padLeft(2, '0');
    final min = time.minute.toString().padLeft(2, '0');
    return "$y-$m-$d $h:$min";
  }

  Widget _buildSyncIndicator() {
    final label = _syncing
        ? 'Syncing...'
        : _online
        ? 'Online'
        : 'Offline';
    final color = _syncing
        ? Colors.orange
        : _online
        ? Colors.green
        : Colors.red;
    final subtitle = _lastSync == null
        ? ''
        : ' | ${_formatSyncTime(_lastSync!)}';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
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

  void _buildRows() {
    if (_group == null) return;
    final attendance = _service.getAttendanceByGroup(_group!);
    final map = <String, bool>{};
    for (final entry in attendance) {
      map['${entry.studentName}|${entry.dateId}'] = entry.present;
    }
    _rows = _students.map((student) {
      final cells = <String, PlutoCell>{};
      cells['student'] = PlutoCell(value: student.name);
      for (var i = 0; i < _dates.length; i++) {
        final dateId = _dates[i].key.toString();
        final present = map['${student.name}|$dateId'] ?? false;
        cells['date_$i'] = PlutoCell(value: present ? 'P' : '');
      }
      return PlutoRow(cells: cells);
    }).toList();
  }

  bool _parsePresent(String raw) {
    final value = raw.trim().toLowerCase();
    return value == 'p' ||
        value == '1' ||
        value == '+' ||
        value == 'y' ||
        value == '??';
  }

  String _formatDateLabel(DateTime date) {
    return '${date.day.toString().padLeft(2, '0')}.${date.month.toString().padLeft(2, '0')}.${date.year}';
  }

  Future<void> _onCellChanged(PlutoGridOnChangedEvent event) async {
    if (_group == null) return;
    final column = event.column.field;
    if (!column.startsWith('date_')) return;

    final studentName = event.row.cells['student']?.value as String?;
    if (studentName == null || studentName.isEmpty) return;

    final index = int.tryParse(column.split('_')[1]);
    if (index == null || index >= _dates.length) return;
    final date = _dates[index];

    final raw = (event.value ?? '').toString();
    final trimmed = raw.trim();

    if (trimmed.isEmpty) {
      final existing = _service.getAttendance(
        studentName,
        _group!.groupId,
        date.key.toString(),
      );
      if (existing != null) {
        await _service.deleteAttendance(existing);
      }
      event.row.cells[column]?.value = '';
      _stateManager?.notifyListeners();
      if (widget.canEdit) {
        try {
          await widget.client.deleteAttendance(
            groupName: _group!.name,
            classDate: date.date,
            studentName: studentName,
          );
          if (mounted) {
            setState(() {
              _online = true;
              _lastSync = DateTime.now();
            });
          }
        } catch (_) {
          if (mounted) setState(() => _online = false);
        }
      }
      return;
    }

    final present = _parsePresent(trimmed);
    await _service.addOrUpdateAttendance(
      Attendance(
        studentName: studentName,
        groupId: _group!.groupId,
        dateId: date.key.toString(),
        present: present,
      ),
    );

    event.row.cells[column]?.value = present ? 'P' : '';
    _stateManager?.notifyListeners();

    if (widget.canEdit) {
      try {
        await widget.client.createAttendance(
          groupName: _group!.name,
          classDate: date.date,
          studentName: studentName,
          present: present,
        );
        if (mounted) {
          setState(() {
            _online = true;
            _lastSync = DateTime.now();
          });
        }
      } catch (_) {
        if (mounted) setState(() => _online = false);
      }
    }
  }

  Future<void> _addGroup() async {
    final controller = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New group'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(labelText: 'Group name'),
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
    if (ok == true && controller.text.trim().isNotEmpty) {
      final group = Group(name: controller.text.trim());
      await _service.addGroup(group);
      try {
        await widget.client.upsertJournalGroup(group.name);
      } catch (_) {
        if (mounted) setState(() => _online = false);
      }
      _groups = _service.getAllGroups();
      _group = group;
      await _loadGroupData(sync: false);
      if (mounted) setState(() {});
    }
  }

  Future<void> _addStudents() async {
    if (_group == null) return;
    final controller = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add students'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(hintText: 'Names, comma separated'),
          maxLines: 4,
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
    if (ok == true) {
      final names = controller.text
          .split(',')
          .map((n) => n.trim())
          .where((n) => n.isNotEmpty)
          .toList();
      for (final name in names) {
        await _service.addStudent(
          Student(name: name, groupId: _group!.groupId),
        );
        try {
          await widget.client.upsertJournalStudent(
            groupName: _group!.name,
            studentName: name,
          );
        } catch (_) {
          if (mounted) setState(() => _online = false);
        }
      }
      await _loadGroupData(sync: false);
    }
  }

  Future<void> _addDate() async {
    if (_group == null) return;
    final pickedDates = await showJournalMultiDatePicker(
      context,
      title: 'Select dates',
      locale: Localizations.localeOf(context),
      initialDate: DateTime.now(),
    );
    if (pickedDates == null || pickedDates.isEmpty) return;
    for (final picked in pickedDates) {
      final normalized = DateTime(picked.year, picked.month, picked.day);
      final label = _formatDateLabel(normalized);
      await _service.addDate(
        LessonDate(date: normalized, label: label, groupId: _group!.groupId),
      );
      try {
        await widget.client.upsertJournalDate(
          groupName: _group!.name,
          classDate: normalized,
        );
      } catch (_) {
        if (mounted) setState(() => _online = false);
      }
    }
    await _loadGroupData(sync: false);
  }

  @override
  Widget build(BuildContext context) {
    if (!_isInitialized) {
      return const Center(child: BrandLoadingIndicator());
    }

    if (_group == null) {
      return Center(
        child: widget.canEdit
            ? FilledButton(onPressed: _addGroup, child: const Text('Add group'))
            : const Text('No group available'),
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              _buildSyncIndicator(),
              IconButton(
                onPressed: _syncing
                    ? null
                    : () async {
                        await _syncFromServer();
                        await _loadGroupData(sync: false);
                      },
                icon: const Icon(Icons.refresh),
                tooltip: 'Retry sync',
              ),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButtonFormField<Group>(
                  value: _group,
                  items: [
                    for (final g in _groups)
                      DropdownMenuItem(value: g, child: Text(g.name)),
                  ],
                  onChanged: (value) async {
                    setState(() => _group = value);
                    await _loadGroupData(sync: true);
                  },
                  decoration: const InputDecoration(
                    labelText: 'Group',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              if (widget.canEdit) const SizedBox(width: 12),
              if (widget.canEdit)
                FilledButton(
                  onPressed: _addGroup,
                  child: const Text('Add group'),
                ),
              if (widget.canEdit) const SizedBox(width: 8),
              if (widget.canEdit)
                FilledButton(
                  onPressed: _addStudents,
                  child: const Text('Add students'),
                ),
              if (widget.canEdit) const SizedBox(width: 8),
              if (widget.canEdit)
                FilledButton(
                  onPressed: _addDate,
                  child: const Text('Add date'),
                ),
            ],
          ),
        ),
        Expanded(
          child: PlutoGrid(
            key: ValueKey(
              '${_group?.groupId}_${_dates.length}_${_students.length}',
            ),
            columns: _columns,
            rows: _rows,
            onLoaded: (event) {
              _stateManager = event.stateManager;
              _stateManager?.setSelectingMode(PlutoGridSelectingMode.cell);
            },
            onChanged: _gridReadOnly ? null : _onCellChanged,
            configuration: PlutoGridConfiguration(
              localeText: RussianPlutoGridLocalization(),
            ),
          ),
        ),
      ],
    );
  }
}
