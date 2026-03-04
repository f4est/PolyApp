import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:table_calendar/table_calendar.dart';

class JournalDatePickerDialog extends StatefulWidget {
  final String? initialLabel;

  const JournalDatePickerDialog({super.key, this.initialLabel});

  @override
  State<JournalDatePickerDialog> createState() => _JournalDatePickerDialogState();
}

class _JournalDatePickerDialogState extends State<JournalDatePickerDialog> {
  String? _noticeMessage;

  DateTime focusedDay = DateTime.now();
  DateTime firstDay = DateTime.utc(2020, 1, 1);
  DateTime lastDay = DateTime.utc(2100, 12, 31);
  Set<DateTime> selectedDates = {};
  DateTime? rangeStart;
  DateTime? rangeEnd;
  DateTime? lastSelectedDay;
  bool _ctrlPressed = false;
  bool _shiftPressed = false;
  
  // Режимы для мобильных устройств
  String _selectionMode = 'single'; // 'single', 'multiple', 'range'


  void _onDaySelected(DateTime selectedDay, DateTime focusedDayNew) {
    final normalizedDay = DateTime(selectedDay.year, selectedDay.month, selectedDay.day);
    
    setState(() {
      focusedDay = focusedDayNew;
      
      // Для мобильных устройств используем режим выбора
      if (_selectionMode == 'multiple') {
        // Множественный выбор (переключение)
        if (selectedDates.contains(normalizedDay)) {
          selectedDates.remove(normalizedDay);
        } else {
          selectedDates.add(normalizedDay);
        }
        lastSelectedDay = normalizedDay;
        rangeStart = null;
        rangeEnd = null;
      } else if (_selectionMode == 'range' && lastSelectedDay != null) {
        // Диапазон от lastSelectedDay до selectedDay
        selectedDates.clear();
        var start = lastSelectedDay!;
        var end = normalizedDay;
        if (end.isBefore(start)) {
          var temp = start;
          start = end;
          end = temp;
        }
        var current = start;
        while (current.isBefore(end) || current.isAtSameMomentAs(end)) {
          selectedDates.add(DateTime(current.year, current.month, current.day));
          current = current.add(const Duration(days: 1));
        }
        rangeStart = start;
        rangeEnd = end;
        lastSelectedDay = normalizedDay;
      } else if (_ctrlPressed) {
        // Ctrl - множественный выбор (переключение) для десктопа
        if (selectedDates.contains(normalizedDay)) {
          selectedDates.remove(normalizedDay);
        } else {
          selectedDates.add(normalizedDay);
        }
        lastSelectedDay = normalizedDay;
        rangeStart = null;
        rangeEnd = null;
      } else if (_shiftPressed && lastSelectedDay != null) {
        // Shift - диапазон от lastSelectedDay до selectedDay для десктопа
        selectedDates.clear();
        var start = lastSelectedDay!;
        var end = normalizedDay;
        if (end.isBefore(start)) {
          var temp = start;
          start = end;
          end = temp;
        }
        var current = start;
        while (current.isBefore(end) || current.isAtSameMomentAs(end)) {
          selectedDates.add(DateTime(current.year, current.month, current.day));
          current = current.add(const Duration(days: 1));
        }
        rangeStart = start;
        rangeEnd = end;
        lastSelectedDay = normalizedDay;
      } else {
        // Обычный клик - очищаем и выбираем одну дату
        selectedDates.clear();
        selectedDates.add(normalizedDay);
        lastSelectedDay = normalizedDay;
        rangeStart = null;
        rangeEnd = null;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final isMobile = MediaQuery.of(context).size.width < 600;
    
    return Dialog(
      child: Container(
        width: isMobile ? double.infinity : 400,
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
          if (_noticeMessage != null) ...[
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(_noticeMessage!, style: const TextStyle(color: Colors.red)),
            ),
          ],
            const Text(
              'Добавить даты',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            // Визуальные кнопки для мобильных устройств
            if (isMobile) ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _buildModeButton('Одна', 'single', Icons.circle_outlined),
                  const SizedBox(width: 8),
                  _buildModeButton('Несколько', 'multiple', Icons.check_circle_outline),
                  const SizedBox(width: 8),
                  _buildModeButton('Диапазон', 'range', Icons.date_range),
                ],
              ),
              const SizedBox(height: 8),
            ] else ...[
              const Text(
                'Выберите даты (Ctrl - множественный выбор, Shift - диапазон)',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const SizedBox(height: 8),
            ],
            SizedBox(
              height: isMobile ? 300 : 350,
              child: isMobile
                  ? TableCalendar(
                      firstDay: firstDay,
                      lastDay: lastDay,
                      focusedDay: focusedDay,
                      selectedDayPredicate: (day) {
                        final normalizedDay = DateTime(day.year, day.month, day.day);
                        return selectedDates.contains(normalizedDay);
                      },
                      rangeStartDay: rangeStart,
                      rangeEndDay: rangeEnd,
                      rangeSelectionMode: _selectionMode == 'range'
                          ? RangeSelectionMode.enforced
                          : RangeSelectionMode.disabled,
                      onDaySelected: _onDaySelected,
                      onRangeSelected: _selectionMode == 'range' ? _onRangeSelected : null,
                      calendarFormat: CalendarFormat.month,
                      startingDayOfWeek: StartingDayOfWeek.monday,
                      locale: 'ru_RU',
                    )
                  : KeyboardListener(
                      focusNode: FocusNode()..requestFocus(),
                      onKeyEvent: (event) {
                        if (event is KeyDownEvent) {
                          final isCtrl = event.logicalKey == LogicalKeyboardKey.controlLeft ||
                              event.logicalKey == LogicalKeyboardKey.controlRight ||
                              event.logicalKey == LogicalKeyboardKey.metaLeft ||
                              event.logicalKey == LogicalKeyboardKey.metaRight;
                          final isShift = event.logicalKey == LogicalKeyboardKey.shiftLeft ||
                              event.logicalKey == LogicalKeyboardKey.shiftRight;
                          setState(() {
                            if (isCtrl) _ctrlPressed = true;
                            if (isShift) _shiftPressed = true;
                          });
                        } else if (event is KeyUpEvent) {
                          final isCtrl = event.logicalKey == LogicalKeyboardKey.controlLeft ||
                              event.logicalKey == LogicalKeyboardKey.controlRight ||
                              event.logicalKey == LogicalKeyboardKey.metaLeft ||
                              event.logicalKey == LogicalKeyboardKey.metaRight;
                          final isShift = event.logicalKey == LogicalKeyboardKey.shiftLeft ||
                              event.logicalKey == LogicalKeyboardKey.shiftRight;
                          setState(() {
                            if (isCtrl) _ctrlPressed = false;
                            if (isShift) _shiftPressed = false;
                          });
                        }
                      },
                      child: TableCalendar(
                        firstDay: firstDay,
                        lastDay: lastDay,
                        focusedDay: focusedDay,
                        selectedDayPredicate: (day) {
                          final normalizedDay = DateTime(day.year, day.month, day.day);
                          return selectedDates.contains(normalizedDay);
                        },
                        rangeStartDay: rangeStart,
                        rangeEndDay: rangeEnd,
                        rangeSelectionMode: RangeSelectionMode.disabled,
                        onDaySelected: _onDaySelected,
                        calendarFormat: CalendarFormat.month,
                        startingDayOfWeek: StartingDayOfWeek.monday,
                        locale: 'ru_RU',
                      ),
                    ),
            ),
            const SizedBox(height: 8),
            Text(
              'Выбрано дат: ${selectedDates.length}',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context, null),
                  child: const Text('Отмена'),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () {
                    if (selectedDates.isEmpty) {
                      setState(() => _noticeMessage = 'Выберите хотя бы одну дату');
                      return;
                    }
                    Navigator.pop(context, {
                      'dates': selectedDates.toList()..sort(),
                    });
                  },
                  child: const Text('Добавить'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
  
  Widget _buildModeButton(String label, String mode, IconData icon) {
    final isSelected = _selectionMode == mode;
    return ElevatedButton.icon(
      onPressed: () {
        setState(() {
          _selectionMode = mode;
          if (mode == 'single') {
            selectedDates.clear();
            rangeStart = null;
            rangeEnd = null;
          }
        });
      },
      icon: Icon(icon, size: 16),
      label: Text(label, style: const TextStyle(fontSize: 12)),
      style: ElevatedButton.styleFrom(
        backgroundColor: isSelected ? Colors.blue : Colors.grey[300],
        foregroundColor: isSelected ? Colors.white : Colors.black87,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        minimumSize: const Size(0, 32),
      ),
    );
  }
  
  void _onRangeSelected(DateTime? start, DateTime? end, DateTime focusedDayNew) {
    setState(() {
      focusedDay = focusedDayNew;
      rangeStart = start;
      rangeEnd = end;
      selectedDates.clear();
      if (start != null && end != null) {
        var current = start;
        while (current.isBefore(end) || current.isAtSameMomentAs(end)) {
          selectedDates.add(DateTime(current.year, current.month, current.day));
          current = current.add(const Duration(days: 1));
        }
        lastSelectedDay = end;
      }
    });
  }
}
