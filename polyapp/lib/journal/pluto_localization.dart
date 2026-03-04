// Русификация для PlutoGrid
import 'package:pluto_grid/pluto_grid.dart';

class RussianPlutoGridLocalization extends PlutoGridLocaleText {
  String get freezeToStart => 'Закрепить в начале';
  
  String get freezeToEnd => 'Закрепить в конце';
  
  String get freeze => 'Закрепить';
  
  String get unfreeze => 'Открепить';
  
  String get autoFit => 'Автоподбор размера';
  
  @override
  String get hideColumn => 'Скрыть столбец';
  
  String get showColumn => 'Показать столбец';
  
  @override
  String get setColumns => 'Настроить столбцы';
  
  @override
  String get setFilter => 'Установить фильтр';
  
  @override
  String get resetFilter => 'Сбросить фильтр';
  
  String get clearFilter => 'Очистить фильтр';
  
  String get setSorting => 'Установить сортировку';
  
  String get resetSorting => 'Сбросить сортировку';
  
  String get clearSorting => 'Очистить сортировку';
  
  String get columnSettings => 'Настройки столбца';
  
  String get copyValue => 'Копировать значение';
  
  String get pasteValue => 'Вставить значение';
  
  String get selectAll => 'Выбрать все';
  
  String get filterByText => 'Фильтр по тексту';
  
  String get sortAscending => 'Сортировать по возрастанию';
  
  String get sortDescending => 'Сортировать по убыванию';
  
  // Дополнительные методы, необходимые для PlutoGridLocaleText
  @override
  String get autoFitColumn => autoFit;
  
  @override
  String get filterAllColumns => 'Фильтр всех столбцов';
  
  @override
  String get filterColumn => 'Фильтр столбца';
  
  @override
  String get filterContains => 'Содержит';
  
  @override
  String get filterEquals => 'Равно';
  
  String get filterNotEquals => 'Не равно';
  
  @override
  String get filterGreaterThan => 'Больше';
  
  @override
  String get filterLessThan => 'Меньше';
  
  @override
  String get filterGreaterThanOrEqualTo => 'Больше или равно';
  
  @override
  String get filterLessThanOrEqualTo => 'Меньше или равно';
  
  @override
  String get filterStartsWith => 'Начинается с';
  
  @override
  String get filterEndsWith => 'Заканчивается на';
  
  String get filterDate => 'Дата';
  
  String get filterBetween => 'Между';
  
  String get filterSelectAll => 'Выбрать все';
  
  String get filterApply => 'Применить';
  
  String get filterClear => 'Очистить';
  
  String get filterAnd => 'И';
  
  String get filterOr => 'ИЛИ';
  
  String get filterNot => 'НЕ';
  
  String get sort => 'Сортировка';
}

