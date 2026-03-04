// Бизнес-логика расчетов оценок для электронного журнала
// Оптимизированные версии формул из Python

/// Возвращает буквенную и цифровую оценку для итогового балла
/// По таблице эквивалентов:
/// A: 95-100 (4.00)
/// A-: 90-94 (3.67)
/// B+: 85-89 (3.33)
/// B: 80-84 (3.00)
/// B-: 75-79 (2.67)
/// C+: 70-74 (2.33)
/// C: 65-69 (2.00)
/// C-: 60-64 (1.67)
/// D+: 55-59 (1.33)
/// D: 50-54 (1.00)
/// F: 0-49 (0.00)
Map<String, dynamic> getEquivalents(double finalScore) {
  if (finalScore >= 95 && finalScore <= 100) {
    return {"letter": "A", "digital": 4.00};
  } else if (finalScore >= 90 && finalScore < 95) {
    return {"letter": "A-", "digital": 3.67};
  } else if (finalScore >= 85 && finalScore < 90) {
    return {"letter": "B+", "digital": 3.33};
  } else if (finalScore >= 80 && finalScore < 85) {
    return {"letter": "B", "digital": 3.00};
  } else if (finalScore >= 75 && finalScore < 80) {
    return {"letter": "B-", "digital": 2.67};
  } else if (finalScore >= 70 && finalScore < 75) {
    return {"letter": "C+", "digital": 2.33};
  } else if (finalScore >= 65 && finalScore < 70) {
    return {"letter": "C", "digital": 2.00};
  } else if (finalScore >= 60 && finalScore < 65) {
    return {"letter": "C-", "digital": 1.67};
  } else if (finalScore >= 55 && finalScore < 60) {
    return {"letter": "D+", "digital": 1.33};
  } else if (finalScore >= 50 && finalScore < 55) {
    return {"letter": "D", "digital": 1.00};
  } else {
    // 0-49
    return {"letter": "F", "digital": 0.00};
  }
}

/// Сбрасывает отработку, если Н = 0
double resetOtrabotkaIfNeeded(int nCount, double otrabotka) {
  if (nCount == 0 && otrabotka > 0) {
    return 0.0;
  }
  return otrabotka;
}

/// Расчёт для классической (теоретической) группы с лабками
Map<String, dynamic> calcClassicValues({
  required double numericSum,
  required int countNumeric,
  required int countN,
  required double otrabotka,
  required double exam,
  required bool includeExam,
  Map<String, dynamic>? labData,
}) {
  final labSum = labData?['sum'] ?? 0.0;
  final labCount = labData?['count'] ?? 0;
  final labOSum = labData?['otrabotka_sum'] ?? 0.0;

  // RO
  final datesTheory = countNumeric + countN;
  final totalDates = datesTheory + labCount;
  final roVal = totalDates > 0 ? (numericSum + labSum) / totalDates : 0.0;

  // O
  final oVal = otrabotka > 0 ? otrabotka : 0.0;

  // R
  final effTheory = (datesTheory - countN) + (otrabotka > 0 ? 1 : 0);
  final denom = effTheory + labCount;
  final numerator = numericSum + labSum + labOSum + oVal;
  final rVal = denom > 0 ? numerator / denom : 0.0;

  // Итог
  final itVal = includeExam ? rVal * 0.6 + exam * 0.4 : rVal;

  final eq = getEquivalents(itVal);
  return {
    "ro": roVal,
    "r": rVal,
    "itog": itVal,
    "letter": eq["letter"],
    "digital": eq["digital"],
  };
}

/// Расчёт для лабораторной группы (упрощенный)
Map<String, dynamic> calcLabValues({
  required List<String> gradesList,
  required double manualO,
}) {
  int countN = 0;
  final numericVals = <double>[];

  for (final g in gradesList) {
    final val = g.trim().toUpperCase();
    if (val.isEmpty) {
      numericVals.add(0.0);
      continue;
    }
    if (val == 'Н') {
      countN++;
      continue;
    }
    try {
      numericVals.add(double.parse(val));
    } catch (e) {
      countN++;
    }
  }

  final totalDates = gradesList.length;
  final roVal = totalDates > 0 ? numericVals.fold<double>(0, (a, b) => a + b) / totalDates : 0.0;

  final rSum = numericVals.fold<double>(0, (a, b) => a + b) + manualO * countN;
  final rVal = totalDates > 0 ? rSum / totalDates : 0.0;

  return {
    "countN": countN,
    "ro": roVal,
    "otrabotka": manualO,
    "r": rVal,
  };
}

/// Расчёт для лабораторной практики (без Н, более простой)
Map<String, dynamic> calcLabPraktValues({
  required List<String> gradesList,
  required double manualO,
  required int labDatesCount,
}) {
  final nums = <double>[];
  for (final g in gradesList) {
    try {
      final v = double.parse(g);
      nums.add(v > 100 ? 100 : v);
    } catch (e) {
      continue;
    }
  }

  final sumNums = nums.fold<double>(0, (a, b) => a + b);
  final roVal = labDatesCount > 0 ? sumNums / labDatesCount : 0.0;

  final oVal = manualO > 0 ? manualO : 0.0;
  final cntO = manualO > 0 ? 1 : 0;

  final denom = labDatesCount + cntO;
  final rVal = denom > 0 ? (sumNums + oVal) / denom : 0.0;

  final itVal = rVal;
  final eq = getEquivalents(itVal);

  return {
    "ro": roVal,
    "r": rVal,
    "itog": itVal,
    "letter": eq["letter"],
    "digital": eq["digital"],
    "countN": 0,
  };
}

/// Расчёт для теории с учётом лаб-данных
/// Новые формулы:
/// РО: (Сумма Теория + Сумма Лаб) / (Кол-во дат Теория + Кол-во дат Лаб)
/// Р: если Кол-во Н > 0: (Сумма Теория + Сумма Лаб + О) / ((Кол-во дат Теория - Кол-во Н) + Кол-во дат Лаб + 1)
/// Р: если Кол-во Н = 0: (Сумма Теория + Сумма Лаб) / (Кол-во дат Теория + Кол-во дат Лаб)
/// Итог: если Экзам включен: 0.6 * Р + 0.4 * Экзам; если Экзам выключен: Р
Map<String, dynamic> calcTheoryLabValues({
  required List<String> theoryGrades,
  required double manualO,
  required double exam,
  required bool includeExam,
  Map<String, dynamic>? labData,
}) {
  double theorySum = 0.0;
  int theoryDatesCount = theoryGrades.length;
  int countN = 0;

  // Подсчитываем сумму теории и количество Н
  for (final g in theoryGrades) {
    final gTrimmed = g.trim();
    if (gTrimmed.isEmpty) {
      continue;
    }
    if (gTrimmed.toUpperCase() == 'Н') {
      countN++;
      continue;
    }
    try {
      theorySum += double.parse(gTrimmed);
    } catch (e) {
      countN++;
    }
  }

  // Данные лаб-группы
  final labCount = labData?['lab_count'] ?? 0;
  final labSum = labData?['lab_numeric_sum'] ?? 0.0;

  // РО: (Сумма Теория + Сумма Лаб) / (Кол-во дат Теория + Кол-во дат Лаб)
  final totalDates = theoryDatesCount + labCount;
  final roVal = totalDates > 0 ? (theorySum + labSum) / totalDates : 0.0;

  // Р: если Кол-во Н > 0 и О > 0: (Сумма Теория + Сумма Лаб + О) / ((Кол-во дат Теория - Кол-во Н) + Кол-во дат Лаб + 1)
  //    если Кол-во Н = 0 и О = 0: (Сумма Теория + Сумма Лаб) / (Кол-во дат Теория + Кол-во дат Лаб)
  //    если Кол-во Н > 0 и О = 0: Р = РО
  double rVal;
  if (countN > 0 && manualO > 0) {
    final numerator = theorySum + labSum + manualO;
    final denom = (theoryDatesCount - countN) + labCount + 1;
    rVal = denom > 0 ? numerator / denom : 0.0;
  } else if (countN == 0 && manualO == 0) {
    final numerator = theorySum + labSum;
    final denom = theoryDatesCount + labCount;
    rVal = denom > 0 ? numerator / denom : 0.0;
  } else if (countN > 0 && manualO == 0) {
    // Если Н есть, а О не поставлена, Р = РО
    rVal = roVal;
  } else {
    // Если countN = 0 но О > 0
    final numerator = theorySum + labSum + manualO;
    final denom = theoryDatesCount + labCount + 1;
    rVal = denom > 0 ? numerator / denom : 0.0;
  }

  // Итог: если Экзам включен: 0.6 * Р + 0.4 * Экзам; если Экзам выключен: Р
  final itVal = includeExam ? rVal * 0.6 + exam * 0.4 : rVal;

  final eq = getEquivalents(itVal);

  return {
    "countN": countN,
    "ro": roVal,
    "r": rVal,
    "itog": itVal,
    "letter": eq["letter"],
    "digital": eq["digital"],
  };
}

