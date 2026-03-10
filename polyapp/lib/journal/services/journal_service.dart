import 'package:hive/hive.dart';

import '../models/journal_models.dart';

class JournalService {
  late Box<Group> groupBox;
  late Box<Student> studentBox;
  late Box<LessonDate> dateBox;
  late Box<Grade> gradeBox;
  late Box<Attendance> attendanceBox;

  static final JournalService _instance = JournalService._();
  JournalService._();
  factory JournalService() => _instance;

  Future<void> init() async {
    groupBox = await Hive.openBox<Group>('groups');
    studentBox = await Hive.openBox<Student>('students');
    dateBox = await Hive.openBox<LessonDate>('dates');
    gradeBox = await Hive.openBox<Grade>('grades');
    attendanceBox = await Hive.openBox<Attendance>('attendance');
  }

  List<Group> getAllGroups() => groupBox.values.toList();

  Group? getGroupById(String id) {
    try {
      return groupBox.values.firstWhere((g) => g.groupId == id);
    } catch (_) {
      return null;
    }
  }

  Group? getGroupByName(String name) {
    try {
      return groupBox.values.firstWhere((g) => g.name == name);
    } catch (_) {
      return null;
    }
  }

  Future<void> addGroup(Group group) async => groupBox.add(group);
  Future<void> updateGroup(Group group) async => group.save();

  Future<void> deleteGroup(Group group) async {
    final students = getStudentsByGroup(group);
    for (final student in students) {
      await deleteStudent(student);
    }
    final dates = getDatesByGroup(group);
    for (final date in dates) {
      await deleteDate(date);
    }
    await group.delete();
  }

  List<Student> getStudentsByGroup(Group group) =>
      studentBox.values.where((st) => st.groupId == group.groupId).toList();

  Student? getStudentByNameAndGroup(String name, String groupId) {
    try {
      return studentBox.values.firstWhere(
        (st) => st.name == name && st.groupId == groupId,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> addStudent(Student student) async => studentBox.add(student);
  Future<void> updateStudent(Student student) async => student.save();

  Future<void> deleteStudent(Student student) async {
    final grades = getGradesByStudent(student);
    for (final grade in grades) {
      await deleteGrade(grade);
    }
    final attendance = getAttendanceByStudent(student);
    for (final item in attendance) {
      await deleteAttendance(item);
    }
    await student.delete();
  }

  List<LessonDate> getDatesByGroup(Group group) =>
      dateBox.values.where((d) => d.groupId == group.groupId).toList()
        ..sort((a, b) => a.date.compareTo(b.date));

  Future<void> addDate(LessonDate date) async => dateBox.add(date);
  Future<void> updateDate(LessonDate date) async => date.save();

  Future<void> deleteDate(LessonDate date) async {
    final grades = getGradesByDate(date);
    for (final grade in grades) {
      await deleteGrade(grade);
    }
    final attendance = getAttendanceByDate(date);
    for (final item in attendance) {
      await deleteAttendance(item);
    }
    await date.delete();
  }

  List<Attendance> getAttendanceByGroup(Group group) =>
      attendanceBox.values.where((a) => a.groupId == group.groupId).toList();

  List<Attendance> getAttendanceByStudent(Student student) => attendanceBox
      .values
      .where(
        (a) => a.studentName == student.name && a.groupId == student.groupId,
      )
      .toList();

  List<Attendance> getAttendanceByDate(LessonDate date) => attendanceBox.values
      .where((a) => a.dateId == date.key.toString())
      .toList();

  Attendance? getAttendance(String studentName, String groupId, String dateId) {
    try {
      return attendanceBox.values.firstWhere(
        (a) =>
            a.studentName == studentName &&
            a.groupId == groupId &&
            a.dateId == dateId,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> addOrUpdateAttendance(Attendance attendance) async {
    try {
      final existing = attendanceBox.values.firstWhere(
        (a) =>
            a.studentName == attendance.studentName &&
            a.groupId == attendance.groupId &&
            a.dateId == attendance.dateId,
      );
      existing.present = attendance.present;
      await existing.save();
    } catch (_) {
      await attendanceBox.add(attendance);
    }
  }

  Future<void> updateAttendance(Attendance attendance) async =>
      attendance.save();
  Future<void> deleteAttendance(Attendance attendance) async =>
      attendance.delete();

  List<Grade> getGradesByStudent(Student student) => gradeBox.values
      .where(
        (g) => g.studentName == student.name && g.groupId == student.groupId,
      )
      .toList();

  List<Grade> getGradesByDate(LessonDate date) =>
      gradeBox.values.where((g) => g.dateId == date.key.toString()).toList();

  Grade? getGrade(String studentName, String groupId, String dateId) {
    try {
      return gradeBox.values.firstWhere(
        (g) =>
            g.studentName == studentName &&
            g.groupId == groupId &&
            g.dateId == dateId,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> addOrUpdateGrade(Grade grade) async {
    try {
      final existing = gradeBox.values.firstWhere(
        (g) =>
            g.studentName == grade.studentName &&
            g.groupId == grade.groupId &&
            g.dateId == grade.dateId,
      );
      existing.grade = grade.grade;
      await existing.save();
    } catch (_) {
      await gradeBox.add(grade);
    }
  }

  Future<void> updateGrade(Grade grade) async => grade.save();
  Future<void> deleteGrade(Grade grade) async => grade.delete();
}
