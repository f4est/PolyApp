import 'package:flutter/material.dart';
import '../api/api_client.dart';

import 'models/journal_models.dart';
import 'services/journal_service.dart';

class GradesJournalPage extends StatefulWidget {
  const GradesJournalPage({super.key, required this.canEdit, required this.client});

  final bool canEdit;
  final ApiClient client;

  @override
  State<GradesJournalPage> createState() => _GradesJournalPageState();
}

class _GradesJournalPageState extends State<GradesJournalPage> {
  final JournalService _service = JournalService();
  Group? _group;
  LessonDate? _date;
  List<Group> _groups = [];
  List<LessonDate> _dates = [];
  List<Student> _students = [];
  final Map<String, String> _gradeMap = {};

  @override
  void initState() {
    super.initState();
    _loadGroups();
  }

  void _loadGroups() {
    _groups = _service.getAllGroups();
    if (_groups.isNotEmpty) {
      _group ??= _groups.first;
    }
    _loadGroupData();
  }

  void _loadGroupData() {
    if (_group == null) {
      setState(() {});
      return;
    }
    _students = _service.getStudentsByGroup(_group!);
    _dates = _service.getDatesByGroup(_group!);
    if (_dates.isNotEmpty) {
      _date ??= _dates.last;
    } else {
      _date = null;
    }
    _loadGrades();
    setState(() {});
    _syncFromServer().then((_) {
      _loadGrades();
      setState(() {});
    });
  }

  Future<void> _syncFromServer() async {
    if (_group == null) return;
    try {
      final records = await widget.client.listGrades(_group!.name);
      if (records.isEmpty) return;
      for (final record in records) {
        final student = _students.firstWhere(
          (s) => s.name == record.studentName,
          orElse: () {
            final created = Student(name: record.studentName, groupId: _group!.groupId);
            _service.addStudent(created);
            return created;
          },
        );
        final label = '${record.classDate.day.toString().padLeft(2, '0')}.${record.classDate.month.toString().padLeft(2, '0')}.${record.classDate.year}';
        LessonDate? date = _dates.firstWhere(
          (d) => d.label == label,
          orElse: () => LessonDate(date: record.classDate, label: label, groupId: _group!.groupId),
        );
        if (date.key == null) {
          await _service.addDate(date);
          _dates = _service.getDatesByGroup(_group!);
          date = _dates.firstWhere((d) => d.label == label);
        }
        await _service.addOrUpdateGrade(
          Grade(
            studentName: student.name,
            groupId: _group!.groupId,
            grade: record.grade.toString(),
            dateId: date.key.toString(),
          ),
        );
      }
    } catch (_) {}
  }

  void _loadGrades() {
    _gradeMap.clear();
    if (_group == null || _date == null) return;
    for (final student in _students) {
      final grade = _service.getGrade(student.name, _group!.groupId, _date!.key.toString());
      _gradeMap[student.name] = grade?.grade ?? '';
    }
  }

  Future<void> _saveGrade(Student student, String value) async {
    if (_group == null || _date == null) return;
    final grade = Grade(
      studentName: student.name,
      groupId: _group!.groupId,
      grade: value.trim(),
      dateId: _date!.key.toString(),
    );
    await _service.addOrUpdateGrade(grade);
    final parsed = int.tryParse(value.trim());
    if (widget.canEdit && parsed != null) {
      try {
        await widget.client.createGrade(
          groupName: _group!.name,
          classDate: _date!.date,
          studentName: student.name,
          grade: parsed,
        );
      } catch (_) {}
    }
    setState(() {
      _gradeMap[student.name] = value.trim();
    });
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
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Add')),
        ],
      ),
    );
    if (ok == true && controller.text.trim().isNotEmpty) {
      final group = Group(name: controller.text.trim());
      await _service.addGroup(group);
      _group = group;
      _loadGroups();
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
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Add')),
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
        await _service.addStudent(Student(name: name, groupId: _group!.groupId));
      }
      _loadGroupData();
    }
  }

  Future<void> _addDate() async {
    if (_group == null) return;
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime(2035),
    );
    if (picked == null) return;
    final label = '${picked.day.toString().padLeft(2, '0')}.${picked.month.toString().padLeft(2, '0')}.${picked.year}';
    await _service.addDate(LessonDate(date: picked, label: label, groupId: _group!.groupId));
    _loadGroupData();
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<Group>(
                value: _group,
                items: [
                  for (final g in _groups)
                    DropdownMenuItem(value: g, child: Text(g.name)),
                ],
                onChanged: (value) {
                  setState(() {
                    _group = value;
                    _date = null;
                  });
                  _loadGroupData();
                },
                decoration: const InputDecoration(labelText: 'Group', border: OutlineInputBorder()),
              ),
            ),
            if (widget.canEdit) const SizedBox(width: 12),
            if (widget.canEdit)
              FilledButton(
                onPressed: _addGroup,
                child: const Text('Add group'),
              ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<LessonDate>(
                value: _date,
                items: [
                  for (final d in _dates)
                    DropdownMenuItem(value: d, child: Text(d.label)),
                ],
                onChanged: (value) {
                  setState(() => _date = value);
                  _loadGrades();
                },
                decoration: const InputDecoration(labelText: 'Date', border: OutlineInputBorder()),
              ),
            ),
            if (widget.canEdit) const SizedBox(width: 12),
            if (widget.canEdit)
              FilledButton(
                onPressed: _addDate,
                child: const Text('Add date'),
              ),
          ],
        ),
        const SizedBox(height: 12),
        if (widget.canEdit)
          FilledButton(
            onPressed: _addStudents,
            child: const Text('Add students'),
          ),
        const SizedBox(height: 16),
        if (_group == null || _date == null)
          const Text('Select group and date')
        else if (_students.isEmpty)
          const Text('No students yet')
        else
          Card(
            child: Column(
              children: [
                for (final student in _students)
                  ListTile(
                    title: Text(student.name),
                    trailing: SizedBox(
                      width: 80,
                      child: TextFormField(
                        key: ValueKey('${student.name}_${_date?.key ?? ''}'),
                        initialValue: _gradeMap[student.name] ?? '',
                        enabled: widget.canEdit,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          hintText: '0-100',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        onFieldSubmitted: (value) => _saveGrade(student, value),
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
