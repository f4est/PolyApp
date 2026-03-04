import 'package:hive_flutter/hive_flutter.dart';

import 'models/journal_models.dart';
import 'services/journal_service.dart';

class JournalStore {
  static bool _initialized = false;

  static Future<void> init() async {
    if (_initialized) return;
    await Hive.initFlutter();
    Hive.registerAdapter(GroupAdapter());
    Hive.registerAdapter(StudentAdapter());
    Hive.registerAdapter(LessonDateAdapter());
    Hive.registerAdapter(GradeAdapter());
    Hive.registerAdapter(AttendanceAdapter());
    await JournalService().init();
    _initialized = true;
  }
}
