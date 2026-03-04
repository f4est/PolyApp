// Улучшенные модели для журнала с правильными связями
import 'package:hive/hive.dart';

part 'journal_models.g.dart';

@HiveType(typeId: 0)
class Group extends HiveObject {
  @HiveField(0)
  String name;

  @HiveField(1)
  bool includeExam;

  @HiveField(2)
  bool includeLabs;

  @HiveField(3)
  bool includeTheory;

  @HiveField(4)
  String groupId; // Уникальный ID группы

  @HiveField(5)
  String groupType; // 'classic' или 'lab'

  Group({
    required this.name,
    this.includeExam = true,
    this.includeLabs = false,
    this.includeTheory = true,
    String? groupId,
    String? groupType,
  }) : groupId = groupId ?? DateTime.now().millisecondsSinceEpoch.toString(),
       groupType = groupType ?? (name.endsWith('_Лаб') ? 'lab' : 'classic');

  bool get isLabGroup => name.endsWith('_Лаб') || groupType == 'lab';
}

@HiveType(typeId: 1)
class Student extends HiveObject {
  @HiveField(0)
  String name;

  @HiveField(1)
  String groupId; // Связь с группой

  @HiveField(2)
  double otrabotka = 0;

  @HiveField(3)
  double exam = 0;

  @HiveField(4)
  int letterCount = 0;

  @HiveField(5)
  double roValue = 0;

  @HiveField(6)
  double rValue = 0;

  @HiveField(7)
  double itogValue = 0;

  @HiveField(8)
  String letterEq = '';

  @HiveField(9)
  double digitalEq = 0;

  Student({
    required this.name,
    required this.groupId,
  });
}

@HiveType(typeId: 2)
class LessonDate extends HiveObject {
  @HiveField(0)
  DateTime date;

  @HiveField(1)
  String label;

  @HiveField(2)
  String? notes;

  @HiveField(3)
  String groupId; // Связь с группой

  LessonDate({
    required this.date,
    required this.label,
    required this.groupId,
    this.notes,
  });
}

@HiveType(typeId: 3)
class Grade extends HiveObject {
  @HiveField(0)
  String studentName;

  @HiveField(1)
  String groupId;

  @HiveField(2)
  String grade; // "Н" или значение 0-100

  @HiveField(3)
  String dateId; // ID даты (LessonDate.key)

  Grade({
    required this.studentName,
    required this.groupId,
    required this.grade,
    required this.dateId,
  });
}

@HiveType(typeId: 4)
class Attendance extends HiveObject {
  @HiveField(0)
  String studentName;

  @HiveField(1)
  String groupId;

  @HiveField(2)
  String dateId;

  @HiveField(3)
  bool present;

  Attendance({
    required this.studentName,
    required this.groupId,
    required this.dateId,
    required this.present,
  });
}
