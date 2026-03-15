import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../api/api_client.dart';

class AnalyticsWorkspacePage extends StatefulWidget {
  const AnalyticsWorkspacePage({
    super.key,
    required this.client,
    required this.currentUser,
    required this.locale,
    required this.errorText,
  });

  final ApiClient client;
  final UserProfile currentUser;
  final Locale locale;
  final String Function(Object) errorText;

  @override
  State<AnalyticsWorkspacePage> createState() => _AnalyticsWorkspacePageState();
}

class _AnalyticsWorkspacePageState extends State<AnalyticsWorkspacePage> {
  static const Color _brand = Color(0xFF0F766E);
  static const Color _bgTop = Color(0xFFF4F7F2);
  static const Color _bgBottom = Color(0xFFEAF0E4);
  static const Color _muted = Color(0xFF6B7280);
  static const Color _err = Color(0xFFDC2626);
  static const Color _ok = Color(0xFF16A34A);
  static const Color _warn = Color(0xFFF59E0B);

  bool _loading = true;
  bool _globalMode = true;
  bool _monthlyTrend = true;
  bool _gridLoading = false;
  bool _initialized = false;
  double _gridProgress = 0;

  String? _selectedGroup;
  String? _error;
  DateTime _loadedAt = DateTime.now();

  List<GroupAnalytics> _groups = const [];
  List<AttendanceRecord> _attendance = const [];
  List<GradeRecord> _grades = const [];
  List<ExamGrade> _exams = const [];
  List<MakeupCaseDto> _makeups = const [];
  List<RequestTicket> _requests = const [];
  List<TeacherGroupAssignment> _assignments = const [];
  List<DepartmentDto> _departments = const [];
  Map<String, _GridStats> _gridByGroup = const {};

  bool get _isRu => widget.locale.languageCode.toLowerCase() == 'ru';
  bool get _isAdmin => widget.currentUser.role == 'admin';
  String _t(String ru, String en) => _isRu ? ru : en;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    _reload();
  }

  Future<T?> _safe<T>(Future<T> Function() run) async {
    try {
      return await run();
    } catch (_) {
      return null;
    }
  }

  Future<void> _reload() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final groups = await widget.client.listAnalyticsGroups();
      final attendance = await widget.client.listAnalyticsAttendance();
      final grades = await widget.client.listAnalyticsGrades();

      final exams =
          await _safe(() => widget.client.listExamGrades()) ??
          const <ExamGrade>[];
      final makeups =
          await _safe(() => widget.client.listMakeups()) ??
          const <MakeupCaseDto>[];
      final requests =
          await _safe(() => widget.client.listRequests()) ??
          const <RequestTicket>[];
      final assignments =
          await _safe(() => widget.client.listTeacherAssignments()) ??
          const <TeacherGroupAssignment>[];
      final departments = _isAdmin
          ? (await _safe(() => widget.client.listDepartments()) ??
                const <DepartmentDto>[])
          : const <DepartmentDto>[];

      final groupNames = _groupNames(
        groups: groups,
        attendance: attendance,
        grades: grades,
        exams: exams,
        makeups: makeups,
      );
      String? selected = _selectedGroup;
      if (selected == null || !groupNames.contains(selected)) {
        selected = groupNames.isEmpty ? null : groupNames.first;
      }

      if (!mounted) return;
      setState(() {
        _groups = groups;
        _attendance = attendance;
        _grades = grades;
        _exams = exams;
        _makeups = makeups;
        _requests = requests;
        _assignments = assignments;
        _departments = departments;
        _selectedGroup = selected;
        _loadedAt = DateTime.now();
        _loading = false;
      });

      unawaited(_loadGrid(groupNames));
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = widget.errorText(error);
      });
    }
  }

  Future<void> _loadGrid(List<String> groups) async {
    if (!mounted || groups.isEmpty) return;
    setState(() {
      _gridLoading = true;
      _gridProgress = 0;
    });
    final result = <String, _GridStats>{};
    for (int i = 0; i < groups.length; i++) {
      try {
        final grid = await widget.client.getGroupGridV2(groups[i]);
        result[groups[i]] = _GridStats.fromGrid(grid);
      } catch (_) {}
      if (!mounted) return;
      setState(() => _gridProgress = (i + 1) / groups.length);
    }
    if (!mounted) return;
    setState(() {
      _gridByGroup = result;
      _gridLoading = false;
      _gridProgress = 1;
    });
  }

  List<String> _groupNames({
    required List<GroupAnalytics> groups,
    required List<AttendanceRecord> attendance,
    required List<GradeRecord> grades,
    required List<ExamGrade> exams,
    required List<MakeupCaseDto> makeups,
  }) {
    final set = <String>{};
    for (final item in groups) {
      if (item.groupName.trim().isNotEmpty) set.add(item.groupName.trim());
    }
    for (final item in attendance) {
      if (item.groupName.trim().isNotEmpty) set.add(item.groupName.trim());
    }
    for (final item in grades) {
      if (item.groupName.trim().isNotEmpty) set.add(item.groupName.trim());
    }
    for (final item in exams) {
      if (item.groupName.trim().isNotEmpty) set.add(item.groupName.trim());
    }
    for (final item in makeups) {
      if (item.groupName.trim().isNotEmpty) set.add(item.groupName.trim());
    }
    final out = set.toList()..sort();
    return out;
  }

  Map<String, _GroupAgg> _aggregate() {
    final map = <String, _GroupAgg>{};
    _GroupAgg touch(String name) =>
        map.putIfAbsent(name, () => _GroupAgg(name));

    for (final row in _groups) {
      final agg = touch(row.groupName);
      agg.subjects.addAll(row.subjects);
      agg.teachers.addAll(row.teachers);
    }
    for (final row in _grades) {
      final agg = touch(row.groupName);
      agg.gradeCount += 1;
      agg.gradeTotal += row.grade;
      agg.gradeValues.add(row.grade.toDouble());
      agg.students.add(row.studentName);
    }
    for (final row in _attendance) {
      final agg = touch(row.groupName);
      agg.attendanceTotal += 1;
      if (row.present) agg.attendancePresent += 1;
      agg.students.add(row.studentName);
    }
    for (final row in _exams) {
      final agg = touch(row.groupName);
      agg.examCount += 1;
      agg.examTotal += row.grade;
      if (row.grade >= 50) agg.examPassed += 1;
    }
    for (final row in _makeups) {
      final agg = touch(row.groupName);
      agg.makeupTotal += 1;
      if (_isClosedMakeup(row.status)) {
        agg.makeupClosed += 1;
      } else {
        agg.makeupActive += 1;
      }
    }
    _gridByGroup.forEach((group, data) {
      final agg = touch(group);
      agg.specialTotal = data.statusCodeCounts.values.fold<int>(
        0,
        (a, b) => a + b,
      );
    });
    return map;
  }

  List<_Trend> _gradeTrend({String? group}) {
    final bucket = <DateTime, List<double>>{};
    for (final row in _grades) {
      if (group != null && row.groupName != group) continue;
      final key = _monthlyTrend
          ? DateTime(row.classDate.year, row.classDate.month, 1)
          : _weekStart(row.classDate);
      bucket.putIfAbsent(key, () => <double>[]).add(row.grade.toDouble());
    }
    final keys = bucket.keys.toList()..sort();
    return keys.map((key) {
      final values = bucket[key]!;
      final avg = values.fold<double>(0, (a, b) => a + b) / values.length;
      final med = _median(values);
      final label = _monthlyTrend
          ? DateFormat('MM.yyyy').format(key)
          : '${_t('Нед', 'W')}${_week(key)}';
      return _Trend(label, avg, med);
    }).toList();
  }

  DateTime _weekStart(DateTime date) {
    final day = DateUtils.dateOnly(date);
    return day.subtract(Duration(days: day.weekday - DateTime.monday));
  }

  int _week(DateTime value) {
    final thursday = value.add(Duration(days: 4 - value.weekday));
    final firstThursday = DateTime(thursday.year, 1, 4);
    return 1 + ((thursday.difference(firstThursday).inDays) / 7).floor();
  }

  double _median(List<double> values) {
    if (values.isEmpty) return 0;
    final sorted = [...values]..sort();
    final m = sorted.length ~/ 2;
    if (sorted.length.isOdd) return sorted[m];
    return (sorted[m - 1] + sorted[m]) / 2;
  }

  bool _isClosedMakeup(String status) {
    final lower = status.toLowerCase();
    return lower == 'graded' || lower == 'rejected';
  }

  List<int> _weekdayAbsences({String? group}) {
    final data = List<int>.filled(7, 0);
    for (final row in _attendance) {
      if (group != null && row.groupName != group) continue;
      if (row.present) continue;
      data[(row.classDate.weekday - 1).clamp(0, 6)] += 1;
    }
    return data;
  }

  Map<String, int> _specialCounts({String? group}) {
    if (group != null) return _gridByGroup[group]?.statusCodeCounts ?? const {};
    final result = <String, int>{};
    for (final item in _gridByGroup.values) {
      item.statusCodeCounts.forEach((code, count) {
        result[code] = (result[code] ?? 0) + count;
      });
    }
    return result;
  }

  Map<String, int> _makeupFunnel({String? group}) {
    const keys = <String>[
      'awaiting_proof',
      'proof_submitted',
      'task_assigned',
      'submission_sent',
      'graded',
    ];
    final result = <String, int>{for (final key in keys) key: 0};
    for (final row in _makeups) {
      if (group != null && row.groupName != group) continue;
      if (!result.containsKey(row.status)) continue;
      result[row.status] = (result[row.status] ?? 0) + 1;
    }
    return result;
  }

  List<_TeacherSla> _teacherSla() {
    final samples = <String, List<double>>{};
    for (final row in _makeups) {
      final teacher = row.teacherName.trim().isEmpty
          ? 'Unknown'
          : row.teacherName.trim();
      final target = samples.putIfAbsent(teacher, () => <double>[]);
      if (row.proofSubmittedAt != null && row.teacherTaskAt != null) {
        final d = row.teacherTaskAt!.difference(row.proofSubmittedAt!);
        if (!d.isNegative) target.add(d.inMinutes / 60);
      }
      if (row.submissionSentAt != null && row.gradeSetAt != null) {
        final d = row.gradeSetAt!.difference(row.submissionSentAt!);
        if (!d.isNegative) target.add(d.inMinutes / 60);
      }
    }
    final out = <_TeacherSla>[];
    samples.forEach((teacher, values) {
      if (values.isEmpty) return;
      final avg = values.reduce((a, b) => a + b) / values.length;
      out.add(_TeacherSla(teacher, avg, values.length));
    });
    out.sort((a, b) => a.avgHours.compareTo(b.avgHours));
    return out;
  }

  _ExamAgg _examAgg({String? group}) {
    final values = <int>[];
    final bins = <String, int>{'0-49': 0, '50-69': 0, '70-84': 0, '85-100': 0};
    final groupValues = <String, List<int>>{};
    for (final row in _exams) {
      if (group != null && row.groupName != group) continue;
      values.add(row.grade);
      groupValues.putIfAbsent(row.groupName, () => <int>[]).add(row.grade);
      if (row.grade < 50) {
        bins['0-49'] = (bins['0-49'] ?? 0) + 1;
      } else if (row.grade < 70) {
        bins['50-69'] = (bins['50-69'] ?? 0) + 1;
      } else if (row.grade < 85) {
        bins['70-84'] = (bins['70-84'] ?? 0) + 1;
      } else {
        bins['85-100'] = (bins['85-100'] ?? 0) + 1;
      }
    }
    final avg = values.isEmpty
        ? 0.0
        : values.reduce((a, b) => a + b) / values.length;
    final pass = values.where((v) => v >= 50).length;
    final risky = <String>[];
    if (group == null) {
      groupValues.forEach((name, rows) {
        if (rows.length < 3) return;
        final rate = rows.where((v) => v >= 50).length / rows.length;
        if (rate < 0.65) {
          risky.add('$name (${(rate * 100).toStringAsFixed(1)}%)');
        }
      });
    }
    return _ExamAgg(
      values.length,
      avg,
      values.isEmpty ? 0 : pass / values.length,
      bins,
      risky,
    );
  }

  _RequestAgg _requestAgg() {
    int fresh = 0;
    int progress = 0;
    int closed = 0;
    final closeHours = <double>[];
    for (final row in _requests) {
      final status = row.status.toLowerCase();
      final isClosed =
          status.contains('close') ||
          status.contains('done') ||
          status.contains('resolved') ||
          status.contains('approved') ||
          status.contains('rejected') ||
          status.contains('закры') ||
          status.contains('выполн');
      final isProgress =
          status.contains('progress') ||
          status.contains('review') ||
          status.contains('process') ||
          status.contains('работ');
      if (isClosed) {
        closed += 1;
        final diff = row.updatedAt.difference(row.createdAt);
        if (!diff.isNegative) closeHours.add(diff.inMinutes / 60);
      } else if (isProgress) {
        progress += 1;
      } else {
        fresh += 1;
      }
    }
    final avgClose = closeHours.isEmpty
        ? null
        : closeHours.reduce((a, b) => a + b) / closeHours.length;
    return _RequestAgg(fresh, progress, closed, avgClose);
  }

  List<_TeacherLoad> _teacherLoad() {
    final teacherGroups = <String, Set<String>>{};
    final groupStudents = <String, Set<String>>{};
    final activeCases = <String, int>{};

    for (final row in _attendance) {
      groupStudents
          .putIfAbsent(row.groupName, () => <String>{})
          .add(row.studentName);
    }
    for (final row in _grades) {
      groupStudents
          .putIfAbsent(row.groupName, () => <String>{})
          .add(row.studentName);
    }
    for (final row in _groups) {
      for (final teacher in row.teachers) {
        teacherGroups.putIfAbsent(teacher, () => <String>{}).add(row.groupName);
      }
    }
    for (final row in _assignments) {
      teacherGroups
          .putIfAbsent(row.teacherName, () => <String>{})
          .add(row.groupName);
    }
    for (final row in _makeups) {
      if (_isClosedMakeup(row.status)) continue;
      final name = row.teacherName.trim().isEmpty
          ? 'Unknown'
          : row.teacherName.trim();
      teacherGroups.putIfAbsent(name, () => <String>{}).add(row.groupName);
      activeCases[name] = (activeCases[name] ?? 0) + 1;
    }

    final out = <_TeacherLoad>[];
    teacherGroups.forEach((teacher, groups) {
      final students = <String>{};
      for (final group in groups) {
        students.addAll(groupStudents[group] ?? const <String>{});
      }
      out.add(
        _TeacherLoad(
          teacher,
          groups.length,
          students.length,
          activeCases[teacher] ?? 0,
        ),
      );
    });
    out.sort((a, b) => b.activeCases.compareTo(a.activeCases));
    return out;
  }

  Map<String, _StudentAgg> _studentAgg(String group) {
    final result = <String, _StudentAgg>{};
    _StudentAgg touch(String name) =>
        result.putIfAbsent(name, () => _StudentAgg(name));

    for (final row in _grades.where((g) => g.groupName == group)) {
      touch(row.studentName).grades.add(row);
    }
    for (final row in _attendance.where((a) => a.groupName == group)) {
      final agg = touch(row.studentName);
      agg.attTotal += 1;
      if (row.present) agg.attPresent += 1;
    }
    for (final row in _exams.where((e) => e.groupName == group)) {
      touch(row.studentName).exams.add(row.grade.toDouble());
    }
    for (final row in _makeups.where((m) => m.groupName == group)) {
      final agg = touch(row.studentName);
      if (_isClosedMakeup(row.status)) {
        agg.makeupsClosed += 1;
      } else {
        agg.makeupsActive += 1;
      }
    }
    final grid = _gridByGroup[group];
    if (grid != null) {
      grid.studentCodeCounts.forEach((student, codes) {
        final agg = touch(student);
        codes.forEach((code, count) {
          agg.specialCodes[code] = (agg.specialCodes[code] ?? 0) + count;
        });
      });
    }
    return result;
  }

  double _correlation(String group) {
    final values = _studentAgg(
      group,
    ).values.where((s) => s.attTotal > 0 && s.grades.isNotEmpty).toList();
    if (values.length < 2) return 0;
    final xs = values.map((v) => v.attRate).toList();
    final ys = values.map((v) => v.avgGrade).toList();
    final xMean = xs.reduce((a, b) => a + b) / xs.length;
    final yMean = ys.reduce((a, b) => a + b) / ys.length;
    double num = 0;
    double denX = 0;
    double denY = 0;
    for (int i = 0; i < xs.length; i++) {
      final dx = xs[i] - xMean;
      final dy = ys[i] - yMean;
      num += dx * dy;
      denX += dx * dx;
      denY += dy * dy;
    }
    if (denX == 0 || denY == 0) return 0;
    return num / math.sqrt(denX * denY);
  }

  List<_RiskRow> _riskRows(String group) {
    final now = DateTime.now();
    final out = <_RiskRow>[];
    for (final row in _studentAgg(group).values) {
      final avg = row.avgGrade;
      final att = row.attRate;
      final trend = row.trend(now);
      double score = 0;
      if (avg > 0 && avg < 55) score += 35;
      if (avg >= 55 && avg < 65) score += 20;
      if (att < 0.65) score += 30;
      if (att >= 0.65 && att < 0.8) score += 15;
      score += math.min(24, row.makeupsActive * 6).toDouble();
      if (trend < -8) score += 15;
      if (row.examAvg != null && row.examAvg! < 50) score += 25;
      if (row.examAvg != null && row.examAvg! >= 50 && row.examAvg! < 60) {
        score += 10;
      }
      out.add(
        _RiskRow(
          student: row.student,
          risk: score.clamp(1, 99).round(),
          avgGrade: avg,
          attendanceRate: att,
          trend: trend,
          activeMakeups: row.makeupsActive,
          examAverage: row.examAvg,
        ),
      );
    }
    out.sort((a, b) => b.risk.compareTo(a.risk));
    return out;
  }

  List<_ProblemDate> _problemDates(String group) {
    final map = <DateTime, _DateAcc>{};
    for (final row in _attendance.where((a) => a.groupName == group)) {
      final day = DateUtils.dateOnly(row.classDate);
      final acc = map.putIfAbsent(day, () => _DateAcc(day));
      acc.attTotal += 1;
      if (row.present) acc.attPresent += 1;
    }
    for (final row in _grades.where((g) => g.groupName == group)) {
      final day = DateUtils.dateOnly(row.classDate);
      final acc = map.putIfAbsent(day, () => _DateAcc(day));
      acc.gradeTotal += row.grade;
      acc.gradeCount += 1;
    }
    final out = <_ProblemDate>[];
    map.forEach((day, acc) {
      final absentRate = acc.attTotal == 0
          ? 0.0
          : 1 - (acc.attPresent / acc.attTotal);
      final avgGrade = acc.gradeCount == 0
          ? 0.0
          : acc.gradeTotal / acc.gradeCount;
      final score = absentRate * 60 + math.max(0, 70 - avgGrade) * 0.7;
      out.add(_ProblemDate(day, absentRate, avgGrade, score));
    });
    out.sort((a, b) => b.score.compareTo(a.score));
    return out;
  }

  _Compare _compare(String group, Map<String, _GroupAgg> aggregate) {
    final current = aggregate[group]?.gradeAvg ?? 0;
    final all = aggregate.values
        .where((g) => g.gradeCount > 0)
        .map((g) => g.gradeAvg)
        .toList();
    final course = _course(group);
    final courseValues = aggregate.values
        .where(
          (g) =>
              g.gradeCount > 0 &&
              _course(g.group) == course &&
              course.isNotEmpty,
        )
        .map((g) => g.gradeAvg)
        .toList();

    String? depName;
    double? depMedian;
    if (_departments.isNotEmpty) {
      for (final dep in _departments) {
        if (!dep.groups.contains(group)) continue;
        depName = dep.name;
        final values = dep.groups
            .map((name) => aggregate[name])
            .whereType<_GroupAgg>()
            .where((item) => item.gradeCount > 0)
            .map((item) => item.gradeAvg)
            .toList();
        if (values.isNotEmpty) depMedian = _median(values);
        break;
      }
    }

    return _Compare(
      current: current,
      depName: depName,
      depMedian: depMedian,
      courseMedian: courseValues.isEmpty ? null : _median(courseValues),
      allMedian: all.isEmpty ? null : _median(all),
      courseKey: course,
    );
  }

  String _course(String group) {
    final m = RegExp(r'(\d{1,2})').firstMatch(group);
    return m?.group(1) ?? '';
  }

  Widget _panel(String title, Widget child, {String? subtitle}) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFD8E3DB)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x120B2A1F),
            blurRadius: 18,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(subtitle, style: const TextStyle(color: _muted)),
          ],
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }

  Widget _pill(String title, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontSize: 12, color: _muted)),
          Text(
            value,
            style: TextStyle(fontWeight: FontWeight.w800, color: color),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final max = width >= 1500
        ? 1380.0
        : width >= 1100
        ? 1200.0
        : double.infinity;
    final horizontal = width >= 1100 ? 28.0 : 16.0;
    final twoColWidth = width >= 1100
        ? (max - horizontal * 2 - 12) / 2
        : double.infinity;

    final groups = _groupNames(
      groups: _groups,
      attendance: _attendance,
      grades: _grades,
      exams: _exams,
      makeups: _makeups,
    );
    final aggregate = _aggregate();
    final ranking = aggregate.values.toList()
      ..sort((a, b) => b.rankScore.compareTo(a.rankScore));
    final trend = _gradeTrend(group: _globalMode ? null : _selectedGroup);
    final heat = _weekdayAbsences(group: _globalMode ? null : _selectedGroup);
    final special = _specialCounts(group: _globalMode ? null : _selectedGroup);
    final funnel = _makeupFunnel(group: _globalMode ? null : _selectedGroup);
    final sla = _teacherSla();
    final exams = _examAgg(group: _globalMode ? null : _selectedGroup);
    final req = _requestAgg();
    final load = _teacherLoad();

    final selected = _selectedGroup;
    final risks = selected == null ? const <_RiskRow>[] : _riskRows(selected);
    final corr = selected == null ? 0.0 : _correlation(selected);
    final problems = selected == null
        ? const <_ProblemDate>[]
        : _problemDates(selected);
    final compare = selected == null ? null : _compare(selected, aggregate);
    final students = selected == null
        ? <_StudentAgg>[]
        : _studentAgg(selected).values.toList();
    students.sort((a, b) => a.student.compareTo(b.student));
    final contributionRows = selected == null
        ? <MapEntry<String, double>>[]
        : ((_gridByGroup[selected]?.contributions.entries.toList() ??
                <MapEntry<String, double>>[])
            ..sort((a, b) => b.value.compareTo(a.value)));
    final studentSpecialRows = selected == null
        ? <MapEntry<String, Map<String, int>>>[]
        : ((_gridByGroup[selected]?.studentCodeCounts.entries.toList() ??
                <MapEntry<String, Map<String, int>>>[])
            ..sort((a, b) {
              final av = a.value.values.fold<int>(0, (x, y) => x + y);
              final bv = b.value.values.fold<int>(0, (x, y) => x + y);
              return bv.compareTo(av);
            }));

    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [_bgTop, _bgBottom],
        ),
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: max),
          child: ListView(
            padding: EdgeInsets.fromLTRB(horizontal, 20, horizontal, 24),
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(18),
                  gradient: const LinearGradient(
                    colors: [Color(0xFF0F766E), Color(0xFF0B5D57)],
                  ),
                ),
                child: Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    const Icon(
                      Icons.analytics_outlined,
                      color: Colors.white,
                      size: 28,
                    ),
                    Text(
                      _t('Аналитика', 'Analytics'),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        '${_t('Обновлено', 'Updated')}: ${DateFormat('dd.MM.yyyy HH:mm').format(_loadedAt)}',
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                    if (_gridLoading)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          '${_t('Спецзначения', 'Special values')} ${(100 * _gridProgress).round()}%',
                          style: const TextStyle(color: Colors.white),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              if (_loading)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 40),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (_error != null)
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    color: _err.withValues(alpha: 0.12),
                  ),
                  child: Text(_error!),
                )
              else ...[
                _panel(
                  _t('Режим аналитики', 'Analytics mode'),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      ChoiceChip(
                        label: Text(_t('По всем группам', 'All groups')),
                        selected: _globalMode,
                        onSelected: (_) => setState(() => _globalMode = true),
                      ),
                      ChoiceChip(
                        label: Text(_t('По выбранной группе', 'Single group')),
                        selected: !_globalMode,
                        onSelected: (_) => setState(() => _globalMode = false),
                      ),
                      if (!_globalMode)
                        SizedBox(
                          width: 250,
                          child: DropdownButtonFormField<String>(
                            initialValue: _selectedGroup,
                            decoration: InputDecoration(
                              labelText: _t('Группа', 'Group'),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            items: [
                              for (final group in groups)
                                DropdownMenuItem(
                                  value: group,
                                  child: Text(group),
                                ),
                            ],
                            onChanged: (value) =>
                                setState(() => _selectedGroup = value),
                          ),
                        ),
                      FilledButton.icon(
                        onPressed: _reload,
                        icon: const Icon(Icons.refresh_rounded),
                        label: Text(_t('Обновить', 'Refresh')),
                      ),
                      SegmentedButton<bool>(
                        showSelectedIcon: false,
                        segments: <ButtonSegment<bool>>[
                          ButtonSegment(
                            value: true,
                            label: Text(_t('Месяцы', 'Months')),
                          ),
                          ButtonSegment(
                            value: false,
                            label: Text(_t('Недели', 'Weeks')),
                          ),
                        ],
                        selected: <bool>{_monthlyTrend},
                        onSelectionChanged: (value) {
                          if (value.isNotEmpty) {
                            setState(() => _monthlyTrend = value.first);
                          }
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    SizedBox(
                      width: twoColWidth,
                      child: _panel(
                        _t('Динамика среднего/медианы', 'Average/median trend'),
                        trend.isEmpty
                            ? Text(
                                _t(
                                  'Нет данных для динамики.',
                                  'No trend data.',
                                ),
                              )
                            : Column(
                                children: [
                                  for (final item
                                      in (trend.length > 8
                                          ? trend.sublist(trend.length - 8)
                                          : trend)) ...[
                                    Row(
                                      children: [
                                        SizedBox(
                                          width: 84,
                                          child: Text(item.label),
                                        ),
                                        Expanded(
                                          child: LinearProgressIndicator(
                                            value: (item.avg / 100).clamp(
                                              0.0,
                                              1.0,
                                            ),
                                            minHeight: 10,
                                            backgroundColor: const Color(
                                              0xFFE5E7EB,
                                            ),
                                            valueColor:
                                                const AlwaysStoppedAnimation<
                                                  Color
                                                >(_brand),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Text(item.avg.toStringAsFixed(1)),
                                      ],
                                    ),
                                    const SizedBox(height: 8),
                                  ],
                                ],
                              ),
                      ),
                    ),
                    SizedBox(
                      width: twoColWidth,
                      child: _panel(
                        _t('Рейтинг групп', 'Group ranking'),
                        ranking.isEmpty
                            ? Text(
                                _t('Нет данных по группам.', 'No groups data.'),
                              )
                            : Column(
                                children: [
                                  for (
                                    int i = 0;
                                    i < math.min(12, ranking.length);
                                    i++
                                  ) ...[
                                    Row(
                                      children: [
                                        SizedBox(
                                          width: 28,
                                          child: Text('${i + 1}.'),
                                        ),
                                        Expanded(
                                          child: Text(
                                            '${ranking[i].group} | ${_t('индекс', 'index')}: ${ranking[i].rankScore.toStringAsFixed(1)}',
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    Text(
                                      '${_t('Оценки', 'Grades')}: ${ranking[i].gradeAvg.toStringAsFixed(1)}; ${_t('Посещ.', 'Att.')}: ${(ranking[i].attRate * 100).toStringAsFixed(1)}%; ${_t('Отработки', 'Makeups')}: ${ranking[i].makeupActive}/${ranking[i].makeupTotal}',
                                      style: const TextStyle(color: _muted),
                                    ),
                                    const SizedBox(height: 8),
                                  ],
                                ],
                              ),
                      ),
                    ),
                    SizedBox(
                      width: twoColWidth,
                      child: _panel(
                        _t('Тепловая карта пропусков', 'Absence heatmap'),
                        subtitle: _t(
                          'День недели × все пары (детализация по парам после индексации пар в посещаемости).',
                          'Weekday × all classes (pair level after attendance period indexing).',
                        ),
                        Row(
                          children: [
                            for (int i = 0; i < 7; i++)
                              Expanded(
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 3,
                                  ),
                                  child: Column(
                                    children: [
                                      Container(
                                        height: 52,
                                        decoration: BoxDecoration(
                                          color: Color.lerp(
                                            const Color(0xFFE5E7EB),
                                            const Color(0xFFDC2626),
                                            (heat.fold<int>(
                                                      0,
                                                      (a, b) => math.max(a, b),
                                                    ) ==
                                                    0)
                                                ? 0
                                                : heat[i] /
                                                      heat.fold<int>(
                                                        0,
                                                        (a, b) =>
                                                            math.max(a, b),
                                                      ),
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            10,
                                          ),
                                        ),
                                        alignment: Alignment.center,
                                        child: Text(
                                          '${heat[i]}',
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(height: 6),
                                      Text(
                                        (_isRu
                                            ? const [
                                                'Пн',
                                                'Вт',
                                                'Ср',
                                                'Чт',
                                                'Пт',
                                                'Сб',
                                                'Вс',
                                              ]
                                            : const [
                                                'Mon',
                                                'Tue',
                                                'Wed',
                                                'Thu',
                                                'Fri',
                                                'Sat',
                                                'Sun',
                                              ])[i],
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    SizedBox(
                      width: twoColWidth,
                      child: _panel(
                        _t('Доля спецзначений', 'Special value share'),
                        special.isEmpty
                            ? Text(
                                _t('Нет спецзначений.', 'No special values.'),
                              )
                            : Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children:
                                    (special.entries.toList()..sort(
                                          (a, b) => b.value.compareTo(a.value),
                                        ))
                                        .take(12)
                                        .map(
                                          (e) => Chip(
                                            label: Text('${e.key}: ${e.value}'),
                                          ),
                                        )
                                        .toList(),
                              ),
                      ),
                    ),
                    SizedBox(
                      width: twoColWidth,
                      child: _panel(
                        _t('Воронка отработок', 'Makeup funnel'),
                        Column(
                          children: funnel.entries.map((e) {
                            final total = funnel.values.fold<int>(
                              0,
                              (a, b) => a + b,
                            );
                            final rate = total == 0 ? 0.0 : e.value / total;
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Row(
                                children: [
                                  SizedBox(width: 150, child: Text(e.key)),
                                  Expanded(
                                    child: LinearProgressIndicator(
                                      value: rate,
                                      minHeight: 10,
                                      backgroundColor: const Color(0xFFE5E7EB),
                                      valueColor:
                                          const AlwaysStoppedAnimation<Color>(
                                            _brand,
                                          ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text('${e.value}'),
                                ],
                              ),
                            );
                          }).toList(),
                        ),
                      ),
                    ),
                    SizedBox(
                      width: twoColWidth,
                      child: _panel(
                        _t('SLA преподавателей', 'Teacher SLA'),
                        sla.isEmpty
                            ? Text(
                                _t(
                                  'Недостаточно событий.',
                                  'Not enough events.',
                                ),
                              )
                            : Column(
                                children: [
                                  for (final row in sla.take(10)) ...[
                                    Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            row.teacher,
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        ),
                                        Text(
                                          '${row.avgHours.toStringAsFixed(1)} h (${row.samples})',
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 8),
                                  ],
                                ],
                              ),
                      ),
                    ),
                    SizedBox(
                      width: twoColWidth,
                      child: _panel(
                        _t('Экзамены', 'Exams'),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                _pill(
                                  _t('Всего', 'Total'),
                                  '${exams.total}',
                                  _brand,
                                ),
                                _pill(
                                  _t('Средний', 'Average'),
                                  exams.average.toStringAsFixed(2),
                                  const Color(0xFF2563EB),
                                ),
                                _pill(
                                  _t('Сдали', 'Pass rate'),
                                  '${(exams.passRate * 100).toStringAsFixed(1)}%',
                                  exams.passRate >= 0.7 ? _ok : _warn,
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: exams.bins.entries
                                  .map(
                                    (e) => Chip(
                                      label: Text('${e.key}: ${e.value}'),
                                    ),
                                  )
                                  .toList(),
                            ),
                            if (exams.riskyGroups.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Text(
                                _t('Группы риска:', 'Risk groups:'),
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              for (final row in exams.riskyGroups.take(8))
                                Text(row),
                            ],
                          ],
                        ),
                      ),
                    ),
                    SizedBox(
                      width: twoColWidth,
                      child: _panel(
                        _t('Заявки', 'Requests'),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                _pill(
                                  _t('Новые', 'New'),
                                  '${req.fresh}',
                                  _brand,
                                ),
                                _pill(
                                  _t('В работе', 'In progress'),
                                  '${req.progress}',
                                  _warn,
                                ),
                                _pill(
                                  _t('Закрытые', 'Closed'),
                                  '${req.closed}',
                                  _ok,
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            Text(
                              req.avgCloseHours == null
                                  ? _t(
                                      'Среднее время закрытия: нет данных.',
                                      'Average close time: no data.',
                                    )
                                  : '${_t('Среднее время закрытия', 'Average close time')}: ${req.avgCloseHours!.toStringAsFixed(1)} ${_t('ч.', 'h')}',
                              style: const TextStyle(color: _muted),
                            ),
                          ],
                        ),
                      ),
                    ),
                    SizedBox(
                      width: double.infinity,
                      child: _panel(
                        _t('Нагрузка преподавателей', 'Teacher workload'),
                        load.isEmpty
                            ? Text(_t('Нет данных.', 'No data.'))
                            : Column(
                                children: [
                                  for (final row in load.take(15)) ...[
                                    Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            row.teacher,
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        ),
                                        Text(
                                          '${_t('Групп', 'Groups')}: ${row.groupCount} | ${_t('Студентов', 'Students')}: ${row.studentCount} | ${_t('Активные кейсы', 'Active cases')}: ${row.activeCases}',
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 8),
                                  ],
                                ],
                              ),
                      ),
                    ),
                    if (!_globalMode && selected != null) ...[
                      SizedBox(
                        width: twoColWidth,
                        child: _panel(
                          _t(
                            'Связь посещаемости и оценок',
                            'Attendance-grade correlation',
                          ),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              _pill(
                                'r',
                                corr.toStringAsFixed(3),
                                corr >= 0 ? _ok : _err,
                              ),
                              _pill(
                                _t('Топ риск', 'Top risk'),
                                risks.isEmpty ? '-' : '${risks.first.risk}%',
                                risks.isEmpty
                                    ? _warn
                                    : risks.first.risk >= 70
                                    ? _err
                                    : _warn,
                              ),
                            ],
                          ),
                        ),
                      ),
                      SizedBox(
                        width: twoColWidth,
                        child: _panel(
                          _t(
                            'Топ-риски и прогноз несдачи',
                            'Top risks and exam-fail forecast',
                          ),
                          risks.isEmpty
                              ? Text(
                                  _t(
                                    'Недостаточно данных.',
                                    'Not enough data.',
                                  ),
                                )
                              : Column(
                                  children: [
                                    for (final row in risks.take(10)) ...[
                                      Row(
                                        children: [
                                          Expanded(
                                            child: Text(
                                              row.student,
                                              style: const TextStyle(
                                                fontWeight: FontWeight.w700,
                                              ),
                                            ),
                                          ),
                                          Text('${row.risk}%'),
                                        ],
                                      ),
                                      Text(
                                        '${_t('Оценка', 'Grade')}: ${row.avgGrade.toStringAsFixed(1)} | ${_t('Посещ.', 'Att.')}: ${(row.attendanceRate * 100).toStringAsFixed(1)}% | ${_t('Тренд', 'Trend')}: ${row.trend.toStringAsFixed(1)}',
                                        style: const TextStyle(color: _muted),
                                      ),
                                      const SizedBox(height: 8),
                                    ],
                                  ],
                                ),
                        ),
                      ),
                      SizedBox(
                        width: twoColWidth,
                        child: _panel(
                          _t(
                            'Вклад колонок пресета',
                            'Preset column contribution',
                          ),
                          (_gridByGroup[selected]?.contributions.isEmpty ??
                                  true)
                              ? Text(
                                  _t(
                                    'Нет вычисляемых колонок.',
                                    'No computed columns.',
                                  ),
                                )
                              : Column(
                                  children: contributionRows
                                      .take(12)
                                      .map(
                                        (e) => Padding(
                                          padding: const EdgeInsets.only(
                                            bottom: 8,
                                          ),
                                          child: Row(
                                            children: [
                                              SizedBox(
                                                width: 140,
                                                child: Text(
                                                  e.key,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                ),
                                              ),
                                              Expanded(
                                                child: LinearProgressIndicator(
                                                  value: (e.value / 100).clamp(
                                                    0.0,
                                                    1.0,
                                                  ),
                                                  minHeight: 10,
                                                ),
                                              ),
                                              const SizedBox(width: 8),
                                              Text(
                                                '${e.value.toStringAsFixed(1)}%',
                                              ),
                                            ],
                                          ),
                                        ),
                                      )
                                      .toList(),
                                ),
                        ),
                      ),
                      SizedBox(
                        width: twoColWidth,
                        child: _panel(
                          _t(
                            'Структура спецзначений',
                            'Special values structure',
                          ),
                          (_gridByGroup[selected]?.studentCodeCounts.isEmpty ??
                                  true)
                              ? Text(
                                  _t(
                                    'Нет спецзначений у студентов.',
                                    'No student special values.',
                                  ),
                                )
                              : Column(
                                  children: studentSpecialRows
                                      .take(12)
                                      .map(
                                        (e) => Padding(
                                          padding: const EdgeInsets.only(
                                            bottom: 8,
                                          ),
                                          child: Row(
                                            children: [
                                              Expanded(
                                                child: Text(
                                                  e.key,
                                                  style: const TextStyle(
                                                    fontWeight: FontWeight.w700,
                                                  ),
                                                ),
                                              ),
                                              Text(
                                                e.value.entries
                                                    .map(
                                                      (v) =>
                                                          '${v.key}:${v.value}',
                                                    )
                                                    .join('  •  '),
                                              ),
                                            ],
                                          ),
                                        ),
                                      )
                                      .toList(),
                                ),
                        ),
                      ),
                      SizedBox(
                        width: twoColWidth,
                        child: _panel(
                          _t('Проблемные даты', 'Problem dates'),
                          problems.isEmpty
                              ? Text(
                                  _t(
                                    'Проблемные даты не найдены.',
                                    'No problem dates found.',
                                  ),
                                )
                              : Column(
                                  children: problems
                                      .take(12)
                                      .map(
                                        (item) => Padding(
                                          padding: const EdgeInsets.only(
                                            bottom: 8,
                                          ),
                                          child: Row(
                                            children: [
                                              SizedBox(
                                                width: 100,
                                                child: Text(
                                                  DateFormat(
                                                    'dd.MM',
                                                  ).format(item.date),
                                                ),
                                              ),
                                              Expanded(
                                                child: Text(
                                                  '${_t('Пропуски', 'Absences')}: ${(item.absentRate * 100).toStringAsFixed(1)}% | ${_t('Средняя', 'Average')}: ${item.avgGrade.toStringAsFixed(1)}',
                                                ),
                                              ),
                                              Text(
                                                item.score.toStringAsFixed(1),
                                              ),
                                            ],
                                          ),
                                        ),
                                      )
                                      .toList(),
                                ),
                        ),
                      ),
                      SizedBox(
                        width: twoColWidth,
                        child: _panel(
                          _t(
                            'Сравнение с отделением/курсом',
                            'Department/course comparison',
                          ),
                          compare == null
                              ? Text(_t('Нет данных.', 'No data.'))
                              : Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: [
                                    _pill(
                                      _t('Группа', 'Group'),
                                      compare.current.toStringAsFixed(2),
                                      _brand,
                                    ),
                                    _pill(
                                      compare.depName == null
                                          ? _t('Отделение', 'Department')
                                          : compare.depName!,
                                      compare.depMedian == null
                                          ? '-'
                                          : compare.depMedian!.toStringAsFixed(
                                              2,
                                            ),
                                      const Color(0xFF2563EB),
                                    ),
                                    _pill(
                                      compare.courseKey.isEmpty
                                          ? _t('Курс', 'Course')
                                          : '${_t('Курс', 'Course')} ${compare.courseKey}',
                                      compare.courseMedian == null
                                          ? '-'
                                          : compare.courseMedian!
                                                .toStringAsFixed(2),
                                      const Color(0xFF7C3AED),
                                    ),
                                    _pill(
                                      _t('Общая медиана', 'Overall median'),
                                      compare.allMedian == null
                                          ? '-'
                                          : compare.allMedian!.toStringAsFixed(
                                              2,
                                            ),
                                      _warn,
                                    ),
                                  ],
                                ),
                        ),
                      ),
                      SizedBox(
                        width: double.infinity,
                        child: _panel(
                          _t('Индивидуальные карточки', 'Individual cards'),
                          students.isEmpty
                              ? Text(
                                  _t(
                                    'Нет данных по студентам.',
                                    'No student data.',
                                  ),
                                )
                              : Wrap(
                                  spacing: 10,
                                  runSpacing: 10,
                                  children: students
                                      .take(24)
                                      .map(
                                        (s) => ConstrainedBox(
                                          constraints: const BoxConstraints(
                                            minWidth: 240,
                                            maxWidth: 320,
                                          ),
                                          child: Container(
                                            padding: const EdgeInsets.all(12),
                                            decoration: BoxDecoration(
                                              borderRadius:
                                                  BorderRadius.circular(12),
                                              color: const Color(0xFFF7FBF8),
                                              border: Border.all(
                                                color: const Color(0xFFD8E3DB),
                                              ),
                                            ),
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  s.student,
                                                  style: const TextStyle(
                                                    fontWeight: FontWeight.w800,
                                                  ),
                                                ),
                                                const SizedBox(height: 6),
                                                Text(
                                                  '${_t('Оценка', 'Grade')}: ${s.avgGrade.toStringAsFixed(1)}',
                                                ),
                                                Text(
                                                  '${_t('Посещаемость', 'Attendance')}: ${(s.attRate * 100).toStringAsFixed(1)}%',
                                                ),
                                                Text(
                                                  '${_t('Отработки', 'Makeups')}: ${s.makeupsActive + s.makeupsClosed}',
                                                ),
                                                if (s.examAvg != null)
                                                  Text(
                                                    '${_t('Экзамен', 'Exam')}: ${s.examAvg!.toStringAsFixed(1)}',
                                                  ),
                                                if (s.specialCodes.isNotEmpty)
                                                  Text(
                                                    '${_t('Спецзначения', 'Special values')}: ${s.specialCodes.entries.map((e) => '${e.key}:${e.value}').join(', ')}',
                                                    style: const TextStyle(
                                                      color: _muted,
                                                      fontSize: 12,
                                                    ),
                                                  ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      )
                                      .toList(),
                                ),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Trend {
  _Trend(this.label, this.avg, this.median);
  final String label;
  final double avg;
  final double median;
}

class _GroupAgg {
  _GroupAgg(this.group);
  final String group;
  final Set<String> students = <String>{};
  final Set<String> subjects = <String>{};
  final Set<String> teachers = <String>{};
  int gradeCount = 0;
  int gradeTotal = 0;
  final List<double> gradeValues = <double>[];
  int attendanceTotal = 0;
  int attendancePresent = 0;
  int examCount = 0;
  int examTotal = 0;
  int examPassed = 0;
  int makeupTotal = 0;
  int makeupClosed = 0;
  int makeupActive = 0;
  int specialTotal = 0;

  double get gradeAvg => gradeCount == 0 ? 0 : gradeTotal / gradeCount;
  double get attRate =>
      attendanceTotal == 0 ? 0 : attendancePresent / attendanceTotal;
  double get examPassRate => examCount == 0 ? 0 : examPassed / examCount;
  double get makeupCloseRate =>
      makeupTotal == 0 ? 0 : makeupClosed / makeupTotal;
  double get rankScore =>
      gradeAvg * 0.45 +
      attRate * 100 * 0.30 +
      examPassRate * 100 * 0.15 +
      makeupCloseRate * 100 * 0.10;
}

class _GridStats {
  _GridStats({
    required this.statusCodeCounts,
    required this.studentCodeCounts,
    required this.contributions,
  });

  final Map<String, int> statusCodeCounts;
  final Map<String, Map<String, int>> studentCodeCounts;
  final Map<String, double> contributions;

  factory _GridStats.fromGrid(JournalGridDto grid) {
    final status = <String, int>{};
    final students = <String, Map<String, int>>{};
    final abs = <String, double>{};
    for (final cell in grid.dateCells) {
      final code = (cell.statusCode ?? '').trim();
      if (code.isEmpty) continue;
      status[code] = (status[code] ?? 0) + 1;
      final bucket = students.putIfAbsent(
        cell.studentName,
        () => <String, int>{},
      );
      bucket[code] = (bucket[code] ?? 0) + 1;
    }
    for (final row in grid.computedCells) {
      row.values.forEach((key, value) {
        double? v;
        if (value is num) v = value.toDouble();
        if (value is String) v = double.tryParse(value);
        if (v == null) return;
        abs[key] = (abs[key] ?? 0) + v.abs();
      });
    }
    final sum = abs.values.fold<double>(0, (a, b) => a + b);
    final contr = <String, double>{};
    if (sum > 0) {
      abs.forEach((key, value) {
        contr[key] = value * 100 / sum;
      });
    }
    return _GridStats(
      statusCodeCounts: status,
      studentCodeCounts: students,
      contributions: contr,
    );
  }
}

class _TeacherSla {
  _TeacherSla(this.teacher, this.avgHours, this.samples);
  final String teacher;
  final double avgHours;
  final int samples;
}

class _ExamAgg {
  _ExamAgg(
    this.total,
    this.average,
    this.passRate,
    this.bins,
    this.riskyGroups,
  );
  final int total;
  final double average;
  final double passRate;
  final Map<String, int> bins;
  final List<String> riskyGroups;
}

class _RequestAgg {
  _RequestAgg(this.fresh, this.progress, this.closed, this.avgCloseHours);
  final int fresh;
  final int progress;
  final int closed;
  final double? avgCloseHours;
}

class _TeacherLoad {
  _TeacherLoad(
    this.teacher,
    this.groupCount,
    this.studentCount,
    this.activeCases,
  );
  final String teacher;
  final int groupCount;
  final int studentCount;
  final int activeCases;
}

class _StudentAgg {
  _StudentAgg(this.student);
  final String student;
  final List<GradeRecord> grades = <GradeRecord>[];
  final List<double> exams = <double>[];
  final Map<String, int> specialCodes = <String, int>{};
  int attTotal = 0;
  int attPresent = 0;
  int makeupsActive = 0;
  int makeupsClosed = 0;

  double get avgGrade => grades.isEmpty
      ? 0
      : grades.fold<int>(0, (a, b) => a + b.grade) / grades.length;
  double get attRate => attTotal == 0 ? 0 : attPresent / attTotal;
  double? get examAvg => exams.isEmpty
      ? null
      : exams.fold<double>(0, (a, b) => a + b) / exams.length;

  double trend(DateTime now) {
    if (grades.length < 3) return 0;
    final recentFrom = now.subtract(const Duration(days: 30));
    final prevFrom = now.subtract(const Duration(days: 60));
    final recent = grades
        .where((g) => !g.classDate.isBefore(recentFrom))
        .map((g) => g.grade.toDouble())
        .toList();
    final prev = grades
        .where(
          (g) =>
              g.classDate.isBefore(recentFrom) &&
              !g.classDate.isBefore(prevFrom),
        )
        .map((g) => g.grade.toDouble())
        .toList();
    if (recent.isEmpty || prev.isEmpty) return 0;
    final r = recent.reduce((a, b) => a + b) / recent.length;
    final p = prev.reduce((a, b) => a + b) / prev.length;
    return r - p;
  }
}

class _RiskRow {
  _RiskRow({
    required this.student,
    required this.risk,
    required this.avgGrade,
    required this.attendanceRate,
    required this.trend,
    required this.activeMakeups,
    required this.examAverage,
  });
  final String student;
  final int risk;
  final double avgGrade;
  final double attendanceRate;
  final double trend;
  final int activeMakeups;
  final double? examAverage;
}

class _DateAcc {
  _DateAcc(this.date);
  final DateTime date;
  int attTotal = 0;
  int attPresent = 0;
  int gradeTotal = 0;
  int gradeCount = 0;
}

class _ProblemDate {
  _ProblemDate(this.date, this.absentRate, this.avgGrade, this.score);
  final DateTime date;
  final double absentRate;
  final double avgGrade;
  final double score;
}

class _Compare {
  _Compare({
    required this.current,
    required this.depName,
    required this.depMedian,
    required this.courseMedian,
    required this.allMedian,
    required this.courseKey,
  });
  final double current;
  final String? depName;
  final double? depMedian;
  final double? courseMedian;
  final double? allMedian;
  final String courseKey;
}
