// Улучшенный сервис для работы с журналом
import 'package:hive/hive.dart';
import '../models/journal_models.dart';
import 'calculations_service.dart';

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

  // ================= Groups ====================
  List<Group> getAllGroups() => groupBox.values.toList();
  Group? getGroupById(String id) {
    try {
      return groupBox.values.firstWhere((g) => g.groupId == id);
    } catch (e) {
      return null;
    }
  }
  
  Group? getGroupByName(String name) {
    try {
      return groupBox.values.firstWhere((g) => g.name == name);
    } catch (e) {
      return null;
    }
  }
  Future<void> addGroup(Group group) async {
    await groupBox.add(group);
    
    // Автоматически создаём зеркальную лабораторную группу, если это не лаб-группа
    if (!group.name.endsWith('_Лаб') && group.groupType != 'lab') {
      final labGroup = Group(
        name: '${group.name}_Лаб',
        includeExam: false,
        includeLabs: false,
        includeTheory: false,
        groupType: 'lab',
      );
      await groupBox.add(labGroup);
    }
  }
  Future<void> updateGroup(Group group) async => await group.save();
  Future<void> deleteGroup(Group group) async {
    // Удаляем связанных студентов, даты и оценки
    final students = getStudentsByGroup(group);
    for (final st in students) {
      await deleteStudent(st);
    }
    final dates = getDatesByGroup(group);
    for (final d in dates) {
      await deleteDate(d);
    }
    await group.delete();
  }

  // ================= Students ==================
  List<Student> getStudentsByGroup(Group group) =>
      studentBox.values.where((st) => st.groupId == group.groupId).toList();
  Student? getStudentByNameAndGroup(String name, String groupId) {
    try {
      return studentBox.values.firstWhere(
        (st) => st.name == name && st.groupId == groupId,
      );
    } catch (e) {
      return null;
    }
  }
  Future<void> addStudent(Student st) async => await studentBox.add(st);
  Future<void> updateStudent(Student st) async => await st.save();
  Future<void> deleteStudent(Student st) async {
    final grades = getGradesByStudent(st);
    for (final g in grades) {
      await deleteGrade(g);
    }
    final attendance = getAttendanceByStudent(st);
    for (final a in attendance) {
      await deleteAttendance(a);
    }
    await st.delete();
  }

  // ================= Dates =====================
  List<LessonDate> getDatesByGroup(Group group) =>
      dateBox.values.where((d) => d.groupId == group.groupId).toList()
        ..sort((a, b) => a.date.compareTo(b.date));
  Future<void> addDate(LessonDate d) async => await dateBox.add(d);
  Future<void> updateDate(LessonDate d) async => await d.save();
  Future<void> deleteDate(LessonDate d) async {
    final grades = getGradesByDate(d);
    for (final g in grades) {
      await deleteGrade(g);
    }
    final attendance = getAttendanceByDate(d);
    for (final a in attendance) {
      await deleteAttendance(a);
    }
    await d.delete();
  }

  // ================= Attendance =====================
  List<Attendance> getAttendanceByGroup(Group group) =>
      attendanceBox.values.where((a) => a.groupId == group.groupId).toList();
  List<Attendance> getAttendanceByStudent(Student st) =>
      attendanceBox.values.where((a) => a.studentName == st.name && a.groupId == st.groupId).toList();
  List<Attendance> getAttendanceByDate(LessonDate date) =>
      attendanceBox.values.where((a) => a.dateId == date.key.toString()).toList();
  Attendance? getAttendance(String studentName, String groupId, String dateId) {
    try {
      return attendanceBox.values.firstWhere(
        (a) => a.studentName == studentName && a.groupId == groupId && a.dateId == dateId,
      );
    } catch (e) {
      return null;
    }
  }
  Future<void> addOrUpdateAttendance(Attendance attendance) async {
    try {
      final existing = attendanceBox.values.firstWhere(
        (a) => a.studentName == attendance.studentName &&
            a.groupId == attendance.groupId &&
            a.dateId == attendance.dateId,
      );
      existing.present = attendance.present;
      await existing.save();
    } catch (e) {
      await attendanceBox.add(attendance);
    }
  }
  Future<void> updateAttendance(Attendance attendance) async => await attendance.save();
  Future<void> deleteAttendance(Attendance attendance) async => await attendance.delete();

  // ================= Grades =====================
  List<Grade> getGradesByStudent(Student st) =>
      gradeBox.values.where((g) => g.studentName == st.name && g.groupId == st.groupId).toList();
  List<Grade> getGradesByDate(LessonDate date) =>
      gradeBox.values.where((g) => g.dateId == date.key.toString()).toList();
  Grade? getGrade(String studentName, String groupId, String dateId) {
    try {
      return gradeBox.values.firstWhere(
        (g) => g.studentName == studentName && g.groupId == groupId && g.dateId == dateId,
      );
    } catch (e) {
      return null;
    }
  }
  Future<void> addOrUpdateGrade(Grade grade) async {
    try {
      final existing = gradeBox.values.firstWhere(
        (g) => g.studentName == grade.studentName &&
            g.groupId == grade.groupId &&
            g.dateId == grade.dateId,
      );
      existing.grade = grade.grade;
      await existing.save();
    } catch (e) {
      await gradeBox.add(grade);
    }
  }
  Future<void> updateGrade(Grade g) async => await g.save();
  Future<void> deleteGrade(Grade g) async => await g.delete();

  // ================= Calculations =====================
  Future<void> calculateRatings(Group group) async {
    final isLabGroup = group.isLabGroup;
    final students = getStudentsByGroup(group);
    final dates = getDatesByGroup(group);

    for (final student in students) {
      final gradesList = getGradesByStudent(student);
      final gradesMap = <String, String>{};
      for (final g in gradesList) {
        gradesMap[g.dateId] = g.grade;
      }

      final gradesArray = dates.map((d) => gradesMap[d.key.toString()] ?? '').toList();

      if (isLabGroup) {
        // Используем calcLabPraktValues для типа "lab", calcLabValues для обычных лаб-групп
        Map<String, dynamic> result;
        if (group.groupType == 'lab') {
          // Lab/Pract вариант: RO = ΣL_num / LC, R = (ΣL_num + O)/(LC + 1_(O>0))
          result = calcLabPraktValues(
            gradesList: gradesArray,
            manualO: student.otrabotka,
            labDatesCount: dates.length,
          );
        } else {
          // Обычный Lab вариант: RO = ΣL_num / LC, R = (ΣL_num + O * N)/LC
          result = calcLabValues(
            gradesList: gradesArray,
            manualO: student.otrabotka,
          );
        }
        student.letterCount = result['countN'] as int;
        student.roValue = result['ro'] as double;
        student.rValue = result['r'] as double;
        student.itogValue = result['itog'] as double;
        final eq = getEquivalents(student.itogValue);
        student.letterEq = eq['letter'] as String;
        student.digitalEq = eq['digital'] as double;
      } else {
        // Теоретическая группа
        if (!group.includeTheory) {
          // Если теория выключена - все значения 0
          student.letterCount = 0;
          student.roValue = 0;
          student.rValue = 0;
          student.itogValue = 0;
          student.letterEq = 'F';
          student.digitalEq = 0.0;
        } else {
          Map<String, dynamic>? labData;
          if (group.includeLabs) {
            final labGroupName = '${group.name}_Лаб';
            try {
              final labGroup = getGroupByName(labGroupName);
              if (labGroup != null) {
                final labStudents = getStudentsByGroup(labGroup);
                final labStudent = labStudents.firstWhere(
                  (ls) => ls.name.toLowerCase() == student.name.toLowerCase(),
                  orElse: () => throw Exception(),
                );
                final labDates = getDatesByGroup(labGroup);
                final labGradesList = getGradesByStudent(labStudent);
                final labGradesMap = <String, String>{};
                for (final g in labGradesList) {
                  labGradesMap[g.dateId] = g.grade;
                }
                final labGradesArray = labDates.map((d) => labGradesMap[d.key.toString()] ?? '').toList();

                // Согласно main.py: lab_replaced_sum = сумма, где "не число" заменено на otrabotka из лаб-студента
                // Важно: используем otrabotka из лаб-студента, а не из теории
                double labNumericSum = 0.0;
                double labReplacedSum = 0.0;
                int labCount = labDates.length;
                final labOVal = labStudent.otrabotka; // Берем отработку из лаб-студента

                for (final g in labGradesArray) {
                  try {
                    final v = double.parse(g);
                    labNumericSum += v;
                    labReplacedSum += v;
                  } catch (e) {
                    // Если не число, заменяем на otrabotka лаб-студента (как в main.py строка 2309)
                    labReplacedSum += labOVal;
                  }
                }

                labData = {
                  'lab_count': labCount,
                  'lab_numeric_sum': labNumericSum,
                  'lab_replaced_sum': labReplacedSum,
                };
              }
            } catch (e) {
              // Лаб группа не найдена
            }
          }

          final result = calcTheoryLabValues(
            theoryGrades: gradesArray,
            manualO: student.otrabotka,
            exam: student.exam,
            includeExam: group.includeExam,
            labData: labData,
          );

          student.letterCount = result['countN'] as int;
          student.roValue = result['ro'] as double;
          student.rValue = result['r'] as double;
          student.itogValue = result['itog'] as double;
          student.letterEq = result['letter'] as String;
          student.digitalEq = result['digital'] as double;

          // Сбрасываем отработку если Н = 0
          student.otrabotka = resetOtrabotkaIfNeeded(student.letterCount, student.otrabotka);
        }
      }

      await updateStudent(student);
    }
  }
}

