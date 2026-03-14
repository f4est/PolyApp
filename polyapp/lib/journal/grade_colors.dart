// Утилиты для цветовой раскраски оценок
import 'package:flutter/material.dart';

/// Возвращает цвет для ячейки с оценкой согласно диапазону:
/// 0-49: красный (темнее для светлой темы)
/// 50-69: оранжевый (темнее для светлой темы)
/// 70-89: жёлтый (темнее для светлой темы)
/// 90-100: светло-зелёный (темнее для светлой темы)
/// "Н": серый (темнее для светлой темы)
Color? getGradeColor(String gradeStr, {bool isDark = false}) {
  if (gradeStr.trim().isEmpty) {
    return null;
  }

  // "Н" получает специальный цвет
  if (gradeStr.trim().toUpperCase() == 'Н') {
    return isDark
        ? const Color(0xFFF0F0F0) // Светло-серый для темной темы
        : const Color(0xFFE0E0E0); // Темнее для светлой темы
  }

  try {
    final grade = double.parse(gradeStr.replaceAll(',', '.'));

    if (grade < 50) {
      return isDark
          ? const Color(0xFFFF6666) // Ярко-красный для темной темы
          : const Color(0xFFFF4444); // Темнее красный для светлой темы
    } else if (grade < 70) {
      return isDark
          ? const Color(0xFFFFB266) // Оранжевый для темной темы
          : const Color(0xFFFF9900); // Темнее оранжевый для светлой темы
    } else if (grade < 90) {
      return isDark
          ? const Color(0xFFFFFF99) // Жёлтый для темной темы
          : const Color(0xFFFFCC00); // Темнее жёлтый для светлой темы
    } else {
      return isDark
          ? const Color(0xFF99FF99) // Светло-зелёный для темной темы
          : const Color(0xFF66CC66); // Темнее зелёный для светлой темы
    }
  } catch (e) {
    // Если не число и не "Н" - без цвета
    return null;
  }
}
