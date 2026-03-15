// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'journal_models.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class GroupAdapter extends TypeAdapter<Group> {
  @override
  final int typeId = 0;

  @override
  Group read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return Group(
      name: fields[0] as String,
      includeExam: fields[1] as bool,
      includeLabs: fields[2] as bool,
      includeTheory: fields[3] as bool,
      groupId: fields[4] as String?,
      groupType: fields[5] as String?,
    );
  }

  @override
  void write(BinaryWriter writer, Group obj) {
    writer
      ..writeByte(6)
      ..writeByte(0)
      ..write(obj.name)
      ..writeByte(1)
      ..write(obj.includeExam)
      ..writeByte(2)
      ..write(obj.includeLabs)
      ..writeByte(3)
      ..write(obj.includeTheory)
      ..writeByte(4)
      ..write(obj.groupId)
      ..writeByte(5)
      ..write(obj.groupType);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GroupAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class StudentAdapter extends TypeAdapter<Student> {
  @override
  final int typeId = 1;

  @override
  Student read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return Student(name: fields[0] as String, groupId: fields[1] as String)
      ..otrabotka = fields[2] as double
      ..exam = fields[3] as double
      ..letterCount = fields[4] as int
      ..roValue = fields[5] as double
      ..rValue = fields[6] as double
      ..itogValue = fields[7] as double
      ..letterEq = fields[8] as String
      ..digitalEq = fields[9] as double;
  }

  @override
  void write(BinaryWriter writer, Student obj) {
    writer
      ..writeByte(10)
      ..writeByte(0)
      ..write(obj.name)
      ..writeByte(1)
      ..write(obj.groupId)
      ..writeByte(2)
      ..write(obj.otrabotka)
      ..writeByte(3)
      ..write(obj.exam)
      ..writeByte(4)
      ..write(obj.letterCount)
      ..writeByte(5)
      ..write(obj.roValue)
      ..writeByte(6)
      ..write(obj.rValue)
      ..writeByte(7)
      ..write(obj.itogValue)
      ..writeByte(8)
      ..write(obj.letterEq)
      ..writeByte(9)
      ..write(obj.digitalEq);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StudentAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class LessonDateAdapter extends TypeAdapter<LessonDate> {
  @override
  final int typeId = 2;

  @override
  LessonDate read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return LessonDate(
      date: fields[0] as DateTime,
      label: fields[1] as String,
      groupId: fields[3] as String,
      notes: fields[2] as String?,
    );
  }

  @override
  void write(BinaryWriter writer, LessonDate obj) {
    writer
      ..writeByte(4)
      ..writeByte(0)
      ..write(obj.date)
      ..writeByte(1)
      ..write(obj.label)
      ..writeByte(2)
      ..write(obj.notes)
      ..writeByte(3)
      ..write(obj.groupId);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LessonDateAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class GradeAdapter extends TypeAdapter<Grade> {
  @override
  final int typeId = 3;

  @override
  Grade read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return Grade(
      studentName: fields[0] as String,
      groupId: fields[1] as String,
      grade: fields[2] as String,
      dateId: fields[3] as String,
    );
  }

  @override
  void write(BinaryWriter writer, Grade obj) {
    writer
      ..writeByte(4)
      ..writeByte(0)
      ..write(obj.studentName)
      ..writeByte(1)
      ..write(obj.groupId)
      ..writeByte(2)
      ..write(obj.grade)
      ..writeByte(3)
      ..write(obj.dateId);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GradeAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class AttendanceAdapter extends TypeAdapter<Attendance> {
  @override
  final int typeId = 4;

  @override
  Attendance read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return Attendance(
      studentName: fields[0] as String,
      groupId: fields[1] as String,
      dateId: fields[2] as String,
      present: fields[3] as bool,
    );
  }

  @override
  void write(BinaryWriter writer, Attendance obj) {
    writer
      ..writeByte(4)
      ..writeByte(0)
      ..write(obj.studentName)
      ..writeByte(1)
      ..write(obj.groupId)
      ..writeByte(2)
      ..write(obj.dateId)
      ..writeByte(3)
      ..write(obj.present);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AttendanceAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
