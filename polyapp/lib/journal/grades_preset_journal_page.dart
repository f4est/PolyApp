import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/api_client.dart';
import '../widgets/brand_logo.dart';
import 'journal_date_picker.dart';
import 'services/journal_service.dart';

const Set<String> _presetFormulaFunctions = {
  'IF',
  'ELSE',
  'SUM',
  'AVG',
  'MIN',
  'MAX',
  'COUNT_IF',
};

const Set<String> _presetFormulaKeywords = {
  'AND',
  'OR',
  'NOT',
  'TRUE',
  'FALSE',
};

const Set<String> _presetBuiltInRefs = {
  'DATE_AVG',
  'DATE_SUM',
  'DATE_COUNT',
  'DATE_MIN',
  'DATE_MAX',
  'MISS_COUNT',
  'STUDENT_MISS_COUNT',
};

final RegExp _presetIdentifierPattern = RegExp(
  r'\b[A-Za-zА-Яа-яЁё_][A-Za-zА-Яа-яЁё0-9_]*\b',
);
final RegExp _presetColumnKeyPattern = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');
final RegExp _presetStatusKeyPattern = RegExp(
  r'^[A-Za-zА-Яа-яЁё_][A-Za-zА-Яа-яЁё0-9_]*$',
);
final RegExp _presetStatusCodePattern = RegExp(r'^\S+$');
final RegExp _presetIfMissingCommaPattern = RegExp(
  r'^\s*IF\s*\([^)]*\)\s*\(',
  caseSensitive: false,
);

String _statusCodeRefSuffix(String code) {
  final normalized = code.trim().toUpperCase();
  if (normalized.isEmpty) {
    return 'CODE';
  }
  final buffer = StringBuffer();
  var lastUnderscore = false;
  for (final rune in normalized.runes) {
    final char = String.fromCharCode(rune);
    final isLetter = RegExp(r'[A-Za-zА-Яа-яЁё]').hasMatch(char);
    final isDigit = RegExp(r'[0-9]').hasMatch(char);
    if (isLetter || isDigit || char == '_') {
      buffer.write(char);
      lastUnderscore = false;
      continue;
    }
    if (!lastUnderscore) {
      buffer.write('_');
      lastUnderscore = true;
    }
  }
  final out = buffer.toString().replaceAll(RegExp(r'^_+|_+$'), '');
  return out.isEmpty ? 'CODE' : out;
}

String _readErrorText(Object error) {
  if (error is ApiException) {
    final body = error.body.trim();
    if (body.isNotEmpty) {
      try {
        final decoded = jsonDecode(body);
        if (decoded is Map<String, dynamic>) {
          final detail = decoded['detail'];
          if (detail is String && detail.trim().isNotEmpty) {
            return detail.trim();
          }
          final message = decoded['message'];
          if (message is String && message.trim().isNotEmpty) {
            return message.trim();
          }
          final err = decoded['error'];
          if (err is String && err.trim().isNotEmpty) {
            return err.trim();
          }
        }
      } catch (_) {}
    }
    return 'HTTP ${error.statusCode}';
  }
  return error.toString().replaceFirst('Exception: ', '').trim();
}

class GradesPresetJournalPage extends StatefulWidget {
  const GradesPresetJournalPage({
    super.key,
    required this.canEdit,
    required this.client,
  });

  final bool canEdit;
  final ApiClient client;

  @override
  State<GradesPresetJournalPage> createState() =>
      _GradesPresetJournalPageState();
}

class _GradesPresetJournalPageState extends State<GradesPresetJournalPage> {
  final DateFormat _dateKeyFormat = DateFormat('yyyy-MM-dd');
  final DateFormat _dateLabelFormat = DateFormat('dd.MM');
  final DateFormat _dateFullFormat = DateFormat('dd.MM.yyyy');
  final ScrollController _gridHorizontalController = ScrollController();

  final TextEditingController _newGroupController = TextEditingController();
  final TextEditingController _newStudentController = TextEditingController();
  final TextEditingController _searchController = TextEditingController();
  final JournalService _legacyService = JournalService();

  bool _loading = true;
  bool _saving = false;
  bool _online = true;
  String? _error;
  DateTime? _lastSync;

  List<String> _groups = <String>[];
  String? _groupName;
  JournalGridDto? _grid;

  bool get _isRu => Localizations.localeOf(
    context,
  ).languageCode.toLowerCase().startsWith('ru');
  bool get _syncing => _loading || _saving;
  String _tr(String ru, String en) => _isRu ? ru : en;

  void _markOnline() {
    _online = true;
    _lastSync = DateTime.now();
  }

  void _markOffline() {
    _online = false;
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _gridHorizontalController.dispose();
    _newGroupController.dispose();
    _newStudentController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await _importLegacyHiveOnce();
      final groups = await widget.client.listJournalGroups();
      final selected = _groupName != null && groups.contains(_groupName)
          ? _groupName
          : (groups.isNotEmpty ? groups.first : null);
      JournalGridDto? grid;
      if (selected != null) {
        grid = await widget.client.getGroupGridV2(selected);
      }
      if (!mounted) return;
      setState(() {
        _markOnline();
        _groups = groups;
        _groupName = selected;
        _grid = grid;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _markOffline();
        _error = _readErrorText(error);
      });
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _importLegacyHiveOnce() async {
    const key = 'journal_v2_hive_import_done';
    final prefs = await SharedPreferences.getInstance();
    final done = prefs.getBool(key) ?? false;
    if (done) return;

    try {
      await _legacyService.init();
      final groups = _legacyService.getAllGroups();
      for (final group in groups) {
        await widget.client.upsertJournalGroup(group.name);

        final students = _legacyService.getStudentsByGroup(group);
        for (final student in students) {
          await widget.client.upsertJournalStudent(
            groupName: group.name,
            studentName: student.name,
          );
        }

        final dates = _legacyService.getDatesByGroup(group);
        for (final date in dates) {
          await widget.client.upsertJournalDate(
            groupName: group.name,
            classDate: date.date,
          );
        }

        final dateCells = <DateCellWriteDto>[];
        for (final date in dates) {
          for (final student in students) {
            final grade = _legacyService.getGrade(
              student.name,
              group.groupId,
              date.key.toString(),
            );
            if (grade == null || grade.grade.trim().isEmpty) {
              continue;
            }
            dateCells.add(
              DateCellWriteDto(
                classDate: date.date,
                studentName: student.name,
                rawValue: grade.grade.trim(),
              ),
            );
          }
        }
        if (dateCells.isNotEmpty) {
          await widget.client.upsertDateCellsV2(
            groupName: group.name,
            items: dateCells,
          );
        }
      }
      await prefs.setBool(key, true);
    } catch (_) {
      // Retry on next launch if migration was interrupted.
    }
  }

  Future<void> _reloadGrid() async {
    if (_groupName == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final grid = await widget.client.getGroupGridV2(_groupName!);
      if (!mounted) return;
      setState(() {
        _markOnline();
        _grid = grid;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _markOffline();
        _error = _readErrorText(error);
      });
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _addGroup() async {
    final name = _newGroupController.text.trim();
    if (name.isEmpty) return;
    if (_groups.contains(name)) {
      setState(() => _groupName = name);
      await _reloadGrid();
      return;
    }
    setState(() => _saving = true);
    try {
      await widget.client.upsertJournalGroup(name);
      if (!mounted) return;
      setState(() {
        _newGroupController.clear();
        _groupName = name;
        _groups = [..._groups, name]..sort();
      });
      await _reloadGrid();
      if (!mounted) return;
      _showMessage(_tr('Группа добавлена.', 'Group added.'));
    } catch (error) {
      if (!mounted) return;
      setState(_markOffline);
      if (error is ApiException && error.statusCode == 403) {
        _showMessage(
          _tr(
            'Недостаточно прав для добавления группы.',
            'Insufficient role to add group.',
          ),
          isError: true,
        );
      } else {
        _showMessage(_readErrorText(error), isError: true);
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  Future<void> _applyPreset() async {
    if (_groupName == null) return;
    final preset = await Navigator.of(context).push<GradingPreset>(
      MaterialPageRoute(
        builder: (_) => PresetLibraryPage(
          client: widget.client,
          initialQuery: _searchController.text.trim(),
        ),
      ),
    );
    if (preset == null) return;
    setState(() => _saving = true);
    try {
      await widget.client.applyPresetV2(
        groupName: _groupName!,
        presetId: preset.id,
      );
      await _reloadGrid();
      if (!mounted) return;
      _showMessage(
        _tr(
          'Пресет применён: ${preset.name}',
          'Preset applied: ${preset.name}',
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(_markOffline);
      _showMessage(_readErrorText(error), isError: true);
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  Future<void> _unapplyPreset() async {
    if (_groupName == null) return;
    setState(() => _saving = true);
    try {
      await widget.client.removePresetV2(_groupName!);
      await _reloadGrid();
    } catch (error) {
      if (!mounted) return;
      setState(_markOffline);
      _showMessage(_readErrorText(error), isError: true);
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  Future<void> _recalculate() async {
    if (_groupName == null) return;
    setState(() => _saving = true);
    try {
      await widget.client.recalculateGridV2(_groupName!);
      await _reloadGrid();
    } catch (error) {
      if (!mounted) return;
      setState(_markOffline);
      _showMessage(_readErrorText(error), isError: true);
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  void _showMessage(String message, {bool isError = false}) {
    final messenger = ScaffoldMessenger.of(context);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: isError
              ? const Color(0xFFB91C1C)
              : const Color(0xFF166534),
        ),
      );
  }

  String _formatSyncTime(DateTime time) {
    final y = time.year.toString().padLeft(4, '0');
    final m = time.month.toString().padLeft(2, '0');
    final d = time.day.toString().padLeft(2, '0');
    final h = time.hour.toString().padLeft(2, '0');
    final min = time.minute.toString().padLeft(2, '0');
    return '$y-$m-$d $h:$min';
  }

  Widget _buildSyncIndicator() {
    final label = _syncing
        ? _tr('Синхронизация...', 'Syncing...')
        : _online
        ? _tr('Онлайн', 'Online')
        : _tr('Офлайн', 'Offline');
    final color = _syncing
        ? Colors.orange
        : _online
        ? Colors.green
        : Colors.red;
    final subtitle = _lastSync == null
        ? ''
        : ' • ${_formatSyncTime(_lastSync!)}';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            _online ? Icons.cloud_done : Icons.cloud_off,
            size: 16,
            color: color,
          ),
          const SizedBox(width: 6),
          Text(
            '$label$subtitle',
            style: TextStyle(color: color, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final compact = width < 900;

    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFF8FCFA), Color(0xFFE9F5EF)],
        ),
      ),
      child: RefreshIndicator(
        onRefresh: _reloadGrid,
        child: ListView(
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 12 : 22,
            vertical: 16,
          ),
          children: [
            _buildHeader(compact),
            const SizedBox(height: 14),
            _buildToolbar(compact),
            const SizedBox(height: 14),
            if (_error != null) _ErrorCard(message: _error!),
            if (_error != null) const SizedBox(height: 14),
            _buildPresetBlock(),
            const SizedBox(height: 14),
            _buildQuickAddPanel(compact),
            const SizedBox(height: 14),
            _buildGrid(compact),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(bool compact) {
    return Container(
      padding: EdgeInsets.all(compact ? 14 : 20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        gradient: const LinearGradient(
          colors: [Color(0xFF0F766E), Color(0xFF14532D)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0x330F766E),
            blurRadius: 24,
            offset: Offset(0, 12),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: compact ? 44 : 52,
            height: compact ? 44 : 52,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Icons.auto_graph_rounded, color: Colors.white),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _tr('Журнал пресетов', 'Preset Journal'),
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: compact ? 22 : 27,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _tr(
                    'Оценки по датам + спецколонки + пересчёт на сервере',
                    'Date grades + custom columns + server recalculation',
                  ),
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.9)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildToolbar(bool compact) {
    return _Panel(
      title: _tr('Управление группой', 'Group management'),
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          _buildSyncIndicator(),
          SizedBox(
            width: compact ? double.infinity : 260,
            child: DropdownButtonFormField<String>(
              key: ValueKey(_groupName),
              initialValue: _groupName,
              decoration: InputDecoration(
                border: OutlineInputBorder(),
                labelText: _tr('Группа', 'Group'),
                isDense: true,
              ),
              items: _groups
                  .map(
                    (item) => DropdownMenuItem(value: item, child: Text(item)),
                  )
                  .toList(),
              onChanged: _loading
                  ? null
                  : (value) async {
                      if (value == null || value == _groupName) return;
                      setState(() {
                        _groupName = value;
                        _grid = null;
                      });
                      await _reloadGrid();
                    },
            ),
          ),
          if (widget.canEdit)
            SizedBox(
              width: compact ? double.infinity : 260,
              child: TextField(
                controller: _newGroupController,
                onSubmitted: (_) => _addGroup(),
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  labelText: _tr('Новая группа', 'New group'),
                  hintText: _tr('Например: П22-3Е', 'Example: P22-3E'),
                  isDense: true,
                ),
                onTapOutside: (_) {},
              ),
            ),
          if (widget.canEdit)
            FilledButton.icon(
              onPressed: _saving ? null : _addGroup,
              icon: const Icon(Icons.group_add_rounded),
              label: Text(_tr('Добавить группу', 'Add group')),
            ),
          OutlinedButton.icon(
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh_rounded),
            label: Text(_tr('Обновить', 'Refresh')),
          ),
        ],
      ),
    );
  }

  Widget _buildPresetBlock() {
    final preset = _grid?.preset;
    final binding = _grid?.binding;
    return _Panel(
      title: _tr('Пресет', 'Preset'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (binding == null)
            Text(_tr('Пресет не применён', 'No preset applied'))
          else
            Text(
              preset == null
                  ? _tr(
                      'Пресет #${binding.presetId} (v${binding.presetVersionId})',
                      'Preset #${binding.presetId} (v${binding.presetVersionId})',
                    )
                  : '${preset.name} (v${binding.presetVersionId})',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (widget.canEdit)
                FilledButton.icon(
                  onPressed: (_groupName == null || _saving)
                      ? null
                      : _applyPreset,
                  icon: const Icon(Icons.library_books_rounded),
                  label: Text(_tr('Библиотека', 'Library')),
                ),
              if (widget.canEdit)
                OutlinedButton.icon(
                  onPressed: (_saving || binding == null || _groupName == null)
                      ? null
                      : _unapplyPreset,
                  icon: const Icon(Icons.link_off_rounded),
                  label: Text(_tr('Снять', 'Unapply')),
                ),
              if (widget.canEdit)
                OutlinedButton.icon(
                  onPressed: (_saving || binding == null || _groupName == null)
                      ? null
                      : _recalculate,
                  icon: const Icon(Icons.calculate_rounded),
                  label: Text(_tr('Пересчитать', 'Recalculate')),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildQuickAddPanel(bool compact) {
    return _Panel(
      title: _tr('Быстрое добавление', 'Quick add'),
      child: _groupName == null
          ? Text(_tr('Сначала выберите группу.', 'Select a group first.'))
          : Wrap(
              spacing: 10,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (widget.canEdit)
                  SizedBox(
                    width: compact ? double.infinity : 360,
                    child: TextField(
                      controller: _newStudentController,
                      onSubmitted: (_) => _addStudent(),
                      decoration: InputDecoration(
                        border: const OutlineInputBorder(),
                        isDense: true,
                        labelText: _tr('Новый студент', 'New student'),
                      ),
                    ),
                  ),
                if (widget.canEdit)
                  FilledButton.icon(
                    onPressed: (_saving || _groupName == null)
                        ? null
                        : _addStudent,
                    icon: const Icon(Icons.person_add_alt_1_rounded),
                    label: Text(_tr('Добавить студента', 'Add student')),
                  ),
                if (widget.canEdit)
                  FilledButton.tonalIcon(
                    onPressed: (_saving || _groupName == null)
                        ? null
                        : _addDate,
                    icon: const Icon(Icons.event_available_rounded),
                    label: Text(_tr('Добавить дату', 'Add date')),
                  ),
                Text(
                  _tr(
                    'Изменение/удаление: ПКМ или двойной клик по имени студента/дате в таблице.',
                    'Edit/delete: right click or double click on student/date in table.',
                  ),
                  style: const TextStyle(
                    color: Color(0xFF64748B),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
    );
  }

  Future<void> _openStudentActions(
    String studentName, {
    TapDownDetails? tapDetails,
  }) async {
    if (!widget.canEdit || _saving || _groupName == null) return;
    final action = await _showActionPicker(
      title: studentName,
      tapDetails: tapDetails,
      actions: [
        _QuickActionItem(
          id: 'rename',
          title: _tr('Переименовать', 'Rename'),
          icon: Icons.edit_rounded,
        ),
        _QuickActionItem(
          id: 'delete',
          title: _tr('Удалить', 'Delete'),
          icon: Icons.delete_outline_rounded,
          destructive: true,
        ),
      ],
    );
    if (action == 'rename') {
      await _renameStudent(studentName);
    } else if (action == 'delete') {
      await _deleteStudent(studentName);
    }
  }

  Future<void> _openDateActions(
    DateTime classDate, {
    TapDownDetails? tapDetails,
  }) async {
    if (!widget.canEdit || _saving || _groupName == null) return;
    final action = await _showActionPicker(
      title: _dateFullFormat.format(classDate),
      tapDetails: tapDetails,
      actions: [
        _QuickActionItem(
          id: 'rename',
          title: _tr('Изменить дату', 'Edit date'),
          icon: Icons.edit_calendar_rounded,
        ),
        _QuickActionItem(
          id: 'delete',
          title: _tr('Удалить', 'Delete'),
          icon: Icons.delete_outline_rounded,
          destructive: true,
        ),
      ],
    );
    if (action == 'rename') {
      await _renameDate(classDate);
    } else if (action == 'delete') {
      await _deleteDate(classDate);
    }
  }

  Future<String?> _showActionPicker({
    required String title,
    required List<_QuickActionItem> actions,
    TapDownDetails? tapDetails,
  }) async {
    final desktopLike =
        kIsWeb ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.linux;
    if (desktopLike && tapDetails != null) {
      final overlay =
          Overlay.of(context).context.findRenderObject() as RenderBox;
      final position = RelativeRect.fromLTRB(
        tapDetails.globalPosition.dx,
        tapDetails.globalPosition.dy,
        overlay.size.width - tapDetails.globalPosition.dx,
        overlay.size.height - tapDetails.globalPosition.dy,
      );
      return showMenu<String>(
        context: context,
        position: position,
        items: actions
            .map(
              (action) => PopupMenuItem<String>(
                value: action.id,
                child: Row(
                  children: [
                    Icon(
                      action.icon,
                      size: 18,
                      color: action.destructive
                          ? const Color(0xFFB91C1C)
                          : null,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      action.title,
                      style: action.destructive
                          ? const TextStyle(color: Color(0xFFB91C1C))
                          : null,
                    ),
                  ],
                ),
              ),
            )
            .toList(),
      );
    }
    return showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              ...actions.map(
                (action) => ListTile(
                  leading: Icon(
                    action.icon,
                    color: action.destructive ? const Color(0xFFB91C1C) : null,
                  ),
                  title: Text(
                    action.title,
                    style: action.destructive
                        ? const TextStyle(color: Color(0xFFB91C1C))
                        : null,
                  ),
                  onTap: () => Navigator.of(context).pop(action.id),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  Widget _buildDateHeaderLabel(DateTime classDate) {
    final label = Text(_dateLabelFormat.format(classDate));
    if (!widget.canEdit) {
      return label;
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onDoubleTap: () => _openDateActions(classDate),
      onLongPress: () => _openDateActions(classDate),
      onSecondaryTapDown: (details) {
        _openDateActions(classDate, tapDetails: details);
      },
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          label,
          const SizedBox(width: 4),
          const Icon(Icons.more_horiz_rounded, size: 14),
        ],
      ),
    );
  }

  Widget _buildStudentHeaderCell(String studentName) {
    final text = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 220),
      child: Text(
        studentName,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
    );
    if (!widget.canEdit) {
      return text;
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onDoubleTap: () => _openStudentActions(studentName),
      onLongPress: () => _openStudentActions(studentName),
      onSecondaryTapDown: (details) {
        _openStudentActions(studentName, tapDetails: details);
      },
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          text,
          const SizedBox(width: 4),
          const Icon(Icons.more_horiz_rounded, size: 14),
        ],
      ),
    );
  }

  String _formatComputedValue(dynamic value) {
    if (value == null) {
      return '';
    }
    if (value is num) {
      return _formatNumberTwoDigits(value.toDouble());
    }
    final raw = value.toString();
    final numeric = double.tryParse(raw);
    if (numeric == null) {
      return raw;
    }
    return _formatNumberTwoDigits(numeric);
  }

  String _formatNumberTwoDigits(double value) {
    if (value.isNaN || value.isInfinite) {
      return '0';
    }
    final rounded = (value * 100).roundToDouble() / 100.0;
    var text = rounded.toStringAsFixed(2);
    text = text.replaceFirst(RegExp(r'0+$'), '');
    text = text.replaceFirst(RegExp(r'\.$'), '');
    if (text == '-0') {
      text = '0';
    }
    if (_isRu) {
      text = text.replaceAll('.', ',');
    }
    return text;
  }

  Future<void> _addStudent() async {
    final groupName = _groupName;
    final studentName = _newStudentController.text.trim();
    if (groupName == null || studentName.isEmpty) return;
    setState(() => _saving = true);
    try {
      await widget.client.upsertJournalStudent(
        groupName: groupName,
        studentName: studentName,
      );
      _newStudentController.clear();
      await _reloadGrid();
      if (!mounted) return;
      _showMessage(_tr('Студент добавлен.', 'Student added.'));
    } catch (error) {
      if (!mounted) return;
      setState(_markOffline);
      _showMessage(_readErrorText(error), isError: true);
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  Future<void> _renameStudent(String fromName) async {
    final groupName = _groupName;
    final grid = _grid;
    if (groupName == null || grid == null) return;
    final newName = await _showValueDialog(
      title: _tr('Переименовать студента', 'Rename student'),
      initial: fromName,
      hint: _tr('Новое имя', 'New name'),
    );
    if (newName == null) return;
    final trimmed = newName.trim();
    if (trimmed.isEmpty || trimmed == fromName) return;

    final confirmed = await _showConfirmDialog(
      _tr(
        'Переименовать "$fromName" в "$trimmed"?',
        'Rename "$fromName" to "$trimmed"?',
      ),
    );
    if (!confirmed) return;

    setState(() => _saving = true);
    try {
      await widget.client.upsertJournalStudent(
        groupName: groupName,
        studentName: trimmed,
      );

      final dateUpserts = grid.dateCells
          .where(
            (cell) => cell.studentName == fromName && cell.rawValue.isNotEmpty,
          )
          .map(
            (cell) => DateCellWriteDto(
              classDate: cell.classDate,
              studentName: trimmed,
              rawValue: cell.rawValue,
            ),
          )
          .toList();
      if (dateUpserts.isNotEmpty) {
        await widget.client.upsertDateCellsV2(
          groupName: groupName,
          items: dateUpserts,
        );
      }

      final manualUpserts = grid.manualCells
          .where(
            (cell) => cell.studentName == fromName && cell.rawValue.isNotEmpty,
          )
          .map(
            (cell) => ManualCellWriteDto(
              studentName: trimmed,
              columnKey: cell.columnKey,
              rawValue: cell.rawValue,
            ),
          )
          .toList();
      if (manualUpserts.isNotEmpty) {
        await widget.client.upsertManualCellsV2(
          groupName: groupName,
          items: manualUpserts,
        );
      }

      final dateDeletes = grid.dateCells
          .where((cell) => cell.studentName == fromName)
          .map(
            (cell) => DateCellDeleteDto(
              classDate: cell.classDate,
              studentName: fromName,
            ),
          )
          .toList();
      if (dateDeletes.isNotEmpty) {
        await widget.client.deleteDateCellsV2(
          groupName: groupName,
          items: dateDeletes,
        );
      }

      await widget.client.deleteJournalStudent(
        groupName: groupName,
        studentName: fromName,
      );
      await _reloadGrid();
      if (!mounted) return;
      _showMessage(_tr('Студент переименован.', 'Student renamed.'));
    } catch (error) {
      if (!mounted) return;
      setState(_markOffline);
      _showMessage(_readErrorText(error), isError: true);
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  Future<void> _deleteStudent(String studentName) async {
    final groupName = _groupName;
    final grid = _grid;
    if (groupName == null || grid == null) return;
    final confirmed = await _showConfirmDialog(
      _tr(
        'Удалить студента "$studentName" из группы?',
        'Delete student "$studentName" from the group?',
      ),
    );
    if (!confirmed) return;

    setState(() => _saving = true);
    try {
      final dateDeletes = grid.dateCells
          .where((cell) => cell.studentName == studentName)
          .map(
            (cell) => DateCellDeleteDto(
              classDate: cell.classDate,
              studentName: studentName,
            ),
          )
          .toList();
      if (dateDeletes.isNotEmpty) {
        await widget.client.deleteDateCellsV2(
          groupName: groupName,
          items: dateDeletes,
        );
      }
      await widget.client.deleteJournalStudent(
        groupName: groupName,
        studentName: studentName,
      );
      await _reloadGrid();
      if (!mounted) return;
      _showMessage(_tr('Студент удалён.', 'Student deleted.'));
    } catch (error) {
      if (!mounted) return;
      setState(_markOffline);
      _showMessage(_readErrorText(error), isError: true);
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  Future<void> _addDate() async {
    final groupName = _groupName;
    if (groupName == null) return;
    final selectedDates = await _pickDates();
    if (selectedDates == null || selectedDates.isEmpty) return;
    setState(() => _saving = true);
    try {
      for (final selected in selectedDates) {
        await widget.client.upsertJournalDate(
          groupName: groupName,
          classDate: selected,
        );
      }
      await _reloadGrid();
      if (!mounted) return;
      _showMessage(
        selectedDates.length == 1
            ? _tr('Дата добавлена.', 'Date added.')
            : _tr('Даты добавлены.', 'Dates added.'),
      );
    } catch (error) {
      if (!mounted) return;
      setState(_markOffline);
      _showMessage(_readErrorText(error), isError: true);
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  Future<void> _renameDate(DateTime fromDate) async {
    final groupName = _groupName;
    final grid = _grid;
    if (groupName == null || grid == null) return;
    final toDate = await _pickDate(initial: fromDate);
    if (toDate == null) return;
    final fromKey = _dateKeyFormat.format(fromDate);
    final toKey = _dateKeyFormat.format(toDate);
    if (fromKey == toKey) return;

    final confirmed = await _showConfirmDialog(
      _tr(
        'Изменить дату ${_dateFullFormat.format(fromDate)} на ${_dateFullFormat.format(toDate)}?',
        'Change ${_dateFullFormat.format(fromDate)} to ${_dateFullFormat.format(toDate)}?',
      ),
    );
    if (!confirmed) return;

    setState(() => _saving = true);
    try {
      await widget.client.upsertJournalDate(
        groupName: groupName,
        classDate: toDate,
      );

      final dateUpserts = grid.dateCells
          .where(
            (cell) =>
                _dateKeyFormat.format(cell.classDate) == fromKey &&
                cell.rawValue.isNotEmpty,
          )
          .map(
            (cell) => DateCellWriteDto(
              classDate: toDate,
              studentName: cell.studentName,
              rawValue: cell.rawValue,
            ),
          )
          .toList();
      if (dateUpserts.isNotEmpty) {
        await widget.client.upsertDateCellsV2(
          groupName: groupName,
          items: dateUpserts,
        );
      }

      final dateDeletes = grid.students
          .map(
            (student) =>
                DateCellDeleteDto(classDate: fromDate, studentName: student),
          )
          .toList();
      if (dateDeletes.isNotEmpty) {
        await widget.client.deleteDateCellsV2(
          groupName: groupName,
          items: dateDeletes,
        );
      }

      await widget.client.deleteJournalDate(
        groupName: groupName,
        classDate: fromDate,
      );
      await _reloadGrid();
      if (!mounted) return;
      _showMessage(_tr('Дата изменена.', 'Date updated.'));
    } catch (error) {
      if (!mounted) return;
      setState(_markOffline);
      _showMessage(_readErrorText(error), isError: true);
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  Future<void> _deleteDate(DateTime classDate) async {
    final groupName = _groupName;
    final grid = _grid;
    if (groupName == null || grid == null) return;
    final confirmed = await _showConfirmDialog(
      _tr(
        'Удалить дату ${_dateFullFormat.format(classDate)}?',
        'Delete date ${_dateFullFormat.format(classDate)}?',
      ),
    );
    if (!confirmed) return;

    setState(() => _saving = true);
    try {
      final dateDeletes = grid.students
          .map(
            (student) =>
                DateCellDeleteDto(classDate: classDate, studentName: student),
          )
          .toList();
      if (dateDeletes.isNotEmpty) {
        await widget.client.deleteDateCellsV2(
          groupName: groupName,
          items: dateDeletes,
        );
      }
      await widget.client.deleteJournalDate(
        groupName: groupName,
        classDate: classDate,
      );
      await _reloadGrid();
      if (!mounted) return;
      _showMessage(_tr('Дата удалена.', 'Date deleted.'));
    } catch (error) {
      if (!mounted) return;
      setState(_markOffline);
      _showMessage(_readErrorText(error), isError: true);
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  Future<List<DateTime>?> _pickDates({DateTime? initial}) async {
    final selected = await showJournalMultiDatePicker(
      context,
      title: _tr('Выберите даты', 'Select dates'),
      locale: Localizations.localeOf(context),
      initialDate: initial ?? DateTime.now(),
    );
    if (selected == null || selected.isEmpty) return null;
    return selected
        .map((d) => DateTime(d.year, d.month, d.day))
        .toList(growable: false);
  }

  Future<DateTime?> _pickDate({DateTime? initial}) async {
    final selected = await _pickDates(initial: initial);
    if (selected == null || selected.isEmpty) return null;
    return selected.first;
  }

  Future<bool> _showConfirmDialog(String question) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          content: Text(question),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(_tr('Отмена', 'Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(_tr('Подтвердить', 'Confirm')),
            ),
          ],
        );
      },
    );
    return result ?? false;
  }

  Widget _buildGrid(bool compact) {
    if (_loading) {
      return _Panel(
        title: _tr('Журнал', 'Journal'),
        child: const SizedBox(
          height: 180,
          child: Center(child: BrandLoadingIndicator(logoSize: 56, spacing: 8)),
        ),
      );
    }
    final grid = _grid;
    if (_groupName == null) {
      return _Panel(
        title: _tr('Журнал', 'Journal'),
        child: Text(
          _tr('Выберите или создайте группу.', 'Select or create a group.'),
        ),
      );
    }
    if (grid == null) {
      return _Panel(
        title: _tr('Журнал', 'Journal'),
        child: const SizedBox.shrink(),
      );
    }

    final manualColumns =
        (grid.presetVersion?.definition.columns ?? const <PresetColumnDto>[])
            .where((column) => column.kind == 'manual')
            .toList();
    final computedColumns =
        (grid.presetVersion?.definition.columns ?? const <PresetColumnDto>[])
            .where((column) => column.kind == 'computed')
            .toList();

    final dateCellMap = <String, String>{};
    for (final cell in grid.dateCells) {
      final key =
          '${cell.studentName}::${_dateKeyFormat.format(cell.classDate)}';
      dateCellMap[key] = cell.rawValue;
    }
    final manualCellMap = <String, String>{};
    for (final cell in grid.manualCells) {
      manualCellMap['${cell.studentName}::${cell.columnKey}'] = cell.rawValue;
    }
    final computedMap = <String, Map<String, dynamic>>{};
    for (final row in grid.computedCells) {
      computedMap[row.studentName] = row.values;
    }

    return _Panel(
      title: _tr('Сетка журнала', 'Journal grid'),
      child: ScrollConfiguration(
        behavior: const _GridScrollBehavior(),
        child: Scrollbar(
          controller: _gridHorizontalController,
          thumbVisibility: true,
          trackVisibility: true,
          notificationPredicate: (notification) =>
              notification.metrics.axis == Axis.horizontal,
          child: SingleChildScrollView(
            controller: _gridHorizontalController,
            primary: false,
            scrollDirection: Axis.horizontal,
            child: DataTable(
              dataRowMinHeight: compact ? 40 : 46,
              dataRowMaxHeight: compact ? 56 : 64,
              columns: [
                DataColumn(label: Text(_tr('Студент', 'Student'))),
                ...grid.dates.map(
                  (date) => DataColumn(label: _buildDateHeaderLabel(date)),
                ),
                ...manualColumns.map(
                  (column) => DataColumn(label: Text(column.title)),
                ),
                ...computedColumns.map(
                  (column) => DataColumn(label: Text(column.title)),
                ),
              ],
              rows: grid.students.map((student) {
                return DataRow(
                  cells: [
                    DataCell(_buildStudentHeaderCell(student)),
                    ...grid.dates.map((date) {
                      final key = '$student::${_dateKeyFormat.format(date)}';
                      final value = dateCellMap[key] ?? '';
                      return DataCell(
                        Text(value.isEmpty ? '—' : value),
                        onTap: widget.canEdit
                            ? () => _editDateValue(student, date, value)
                            : null,
                      );
                    }),
                    ...manualColumns.map((column) {
                      final key = '$student::${column.key}';
                      final value = manualCellMap[key] ?? '';
                      return DataCell(
                        Text(value.isEmpty ? '—' : value),
                        onTap: widget.canEdit
                            ? () => _editManualValue(student, column.key, value)
                            : null,
                      );
                    }),
                    ...computedColumns.map((column) {
                      final value = _formatComputedValue(
                        computedMap[student]?[column.key],
                      );
                      return DataCell(
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFFECFDF5),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(value.isEmpty ? '—' : value),
                        ),
                      );
                    }),
                  ],
                );
              }).toList(),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _editDateValue(
    String student,
    DateTime date,
    String initial,
  ) async {
    final value = await _showValueDialog(
      title: '$student • ${_dateKeyFormat.format(date)}',
      initial: initial,
      hint: _tr('0..100 или спецкод', '0..100 or status code'),
    );
    if (value == null || _groupName == null) return;
    setState(() => _saving = true);
    try {
      if (value.isEmpty) {
        await widget.client.deleteDateCellsV2(
          groupName: _groupName!,
          items: [DateCellDeleteDto(classDate: date, studentName: student)],
        );
      } else {
        await widget.client.upsertDateCellsV2(
          groupName: _groupName!,
          items: [
            DateCellWriteDto(
              classDate: date,
              studentName: student,
              rawValue: value,
            ),
          ],
        );
      }
      await _reloadGrid();
    } catch (error) {
      if (!mounted) return;
      setState(_markOffline);
      _showMessage(_readErrorText(error), isError: true);
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  Future<void> _editManualValue(
    String student,
    String columnKey,
    String initial,
  ) async {
    final value = await _showValueDialog(
      title: '$student • $columnKey',
      initial: initial,
      hint: _tr('Значение спецколонки', 'Special column value'),
    );
    if (value == null || _groupName == null) return;
    setState(() => _saving = true);
    try {
      await widget.client.upsertManualCellsV2(
        groupName: _groupName!,
        items: [
          ManualCellWriteDto(
            studentName: student,
            columnKey: columnKey,
            rawValue: value,
          ),
        ],
      );
      await _reloadGrid();
    } catch (error) {
      if (!mounted) return;
      setState(_markOffline);
      _showMessage(_readErrorText(error), isError: true);
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  Future<String?> _showValueDialog({
    required String title,
    required String initial,
    required String hint,
  }) async {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(title),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(hintText: hint),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(_tr('Отмена', 'Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: Text(_tr('Сохранить', 'Save')),
            ),
          ],
        );
      },
    );
  }
}

class PresetLibraryPage extends StatefulWidget {
  const PresetLibraryPage({super.key, required this.client, this.initialQuery});

  final ApiClient client;
  final String? initialQuery;

  @override
  State<PresetLibraryPage> createState() => _PresetLibraryPageState();
}

class _PresetLibraryPageState extends State<PresetLibraryPage> {
  late final TextEditingController _queryController = TextEditingController(
    text: widget.initialQuery ?? '',
  );
  final TextEditingController _tagController = TextEditingController();
  String _visibility = '';

  bool _loading = true;
  String? _error;
  List<GradingPreset> _items = <GradingPreset>[];
  int? _actorId;

  bool get _isRu => Localizations.localeOf(
    context,
  ).languageCode.toLowerCase().startsWith('ru');
  String _tr(String ru, String en) => _isRu ? ru : en;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _queryController.dispose();
    _tagController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (_actorId == null) {
        try {
          final me = await widget.client.me();
          _actorId = me.id;
        } catch (_) {}
      }
      final items = await widget.client.listPresets(
        q: _queryController.text.trim().isEmpty
            ? null
            : _queryController.text.trim(),
        tag: _tagController.text.trim().isEmpty
            ? null
            : _tagController.text.trim(),
        visibility: _visibility.isEmpty ? null : _visibility,
      );
      if (!mounted) return;
      setState(() => _items = items);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = _readErrorText(error));
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _openEditor() async {
    final created = await Navigator.of(context).push<GradingPreset>(
      MaterialPageRoute(
        builder: (_) => PresetEditorPage(client: widget.client),
      ),
    );
    if (created != null) {
      setState(() {
        _queryController.text = created.name;
        _visibility = '';
      });
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              _tr(
                'Пресет "${created.name}" сохранён.',
                'Preset "${created.name}" saved.',
              ),
            ),
            backgroundColor: const Color(0xFF166534),
          ),
        );
    }
  }

  Future<void> _openPresetDetails(GradingPreset item) async {
    final picked = await Navigator.of(context).push<GradingPreset>(
      MaterialPageRoute(
        builder: (_) => PresetDetailsPage(
          client: widget.client,
          presetId: item.id,
          canEdit: _actorId != null && _actorId == item.ownerId,
          allowPick: true,
        ),
      ),
    );
    if (!mounted) return;
    if (picked != null) {
      Navigator.pop(context, picked);
      return;
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_tr('Библиотека пресетов', 'Preset library'))),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                SizedBox(
                  width: 250,
                  child: TextField(
                    controller: _queryController,
                    decoration: InputDecoration(
                      border: const OutlineInputBorder(),
                      labelText: _tr('Название', 'Name'),
                      isDense: true,
                    ),
                  ),
                ),
                SizedBox(
                  width: 180,
                  child: TextField(
                    controller: _tagController,
                    decoration: InputDecoration(
                      border: const OutlineInputBorder(),
                      labelText: _tr('Тег', 'Tag'),
                      isDense: true,
                    ),
                  ),
                ),
                SizedBox(
                  width: 150,
                  child: DropdownButtonFormField<String>(
                    key: ValueKey('library_visibility_$_visibility'),
                    initialValue: _visibility,
                    decoration: InputDecoration(
                      border: const OutlineInputBorder(),
                      labelText: _tr('Видимость', 'Visibility'),
                      isDense: true,
                    ),
                    items: [
                      DropdownMenuItem(
                        value: '',
                        child: Text(_tr('Все', 'All')),
                      ),
                      DropdownMenuItem(
                        value: 'public',
                        child: Text(_tr('Публичный', 'Public')),
                      ),
                      DropdownMenuItem(
                        value: 'private',
                        child: Text(_tr('Приватный', 'Private')),
                      ),
                    ],
                    onChanged: (value) {
                      if (value == null) return;
                      setState(() => _visibility = value);
                    },
                  ),
                ),
                FilledButton.icon(
                  onPressed: _load,
                  icon: const Icon(Icons.search_rounded),
                  label: Text(_tr('Найти', 'Find')),
                ),
                OutlinedButton.icon(
                  onPressed: _openEditor,
                  icon: const Icon(Icons.add_rounded),
                  label: Text(_tr('Создать', 'Create')),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_error != null) _ErrorCard(message: _error!),
            const SizedBox(height: 8),
            Expanded(
              child: _loading
                  ? const Center(child: BrandLoadingIndicator())
                  : _items.isEmpty
                  ? Center(
                      child: Text(
                        _tr(
                          'Пресеты не найдены. Измените фильтры или создайте новый.',
                          'No presets found. Change filters or create a new one.',
                        ),
                        style: const TextStyle(color: Color(0xFF475569)),
                      ),
                    )
                  : ListView.separated(
                      itemCount: _items.length,
                      separatorBuilder: (_, index) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final item = _items[index];
                        final tagsText = item.tags.isEmpty
                            ? _tr('без тегов', 'no tags')
                            : item.tags.join(', ');
                        final subtitleParts = <String>[
                          item.description.trim().isEmpty
                              ? _tr('Без описания', 'No description')
                              : item.description.trim(),
                          _tr(
                            'Автор: #${item.ownerId}',
                            'Author: #${item.ownerId}',
                          ),
                          _tr(
                            'Видимость: ${item.visibility}',
                            'Visibility: ${item.visibility}',
                          ),
                          _tr('Теги: $tagsText', 'Tags: $tagsText'),
                        ];
                        return Card(
                          child: ListTile(
                            onTap: () => _openPresetDetails(item),
                            title: Text(item.name),
                            subtitle: Text(subtitleParts.join('\n')),
                            isThreeLine: true,
                            trailing: Wrap(
                              spacing: 6,
                              children: [
                                OutlinedButton(
                                  onPressed: () => _openPresetDetails(item),
                                  child: Text(_tr('Открыть', 'Open')),
                                ),
                                FilledButton(
                                  onPressed: () => Navigator.pop(context, item),
                                  child: Text(_tr('Применить', 'Apply')),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class PresetDetailsPage extends StatefulWidget {
  const PresetDetailsPage({
    super.key,
    required this.client,
    required this.presetId,
    required this.canEdit,
    required this.allowPick,
  });

  final ApiClient client;
  final int presetId;
  final bool canEdit;
  final bool allowPick;

  @override
  State<PresetDetailsPage> createState() => _PresetDetailsPageState();
}

class _PresetDetailsPageState extends State<PresetDetailsPage> {
  bool _loading = true;
  String? _error;
  GradingPreset? _preset;

  bool get _isRu => Localizations.localeOf(
    context,
  ).languageCode.toLowerCase().startsWith('ru');
  String _tr(String ru, String en) => _isRu ? ru : en;

  GradingPresetVersion? get _version => _preset?.currentVersion;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final item = await widget.client.getPreset(widget.presetId);
      if (!mounted) return;
      setState(() => _preset = item);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = _readErrorText(error));
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _editPreset() async {
    final preset = _preset;
    if (preset == null) return;
    final updated = await Navigator.of(context).push<GradingPreset>(
      MaterialPageRoute(
        builder: (_) => PresetEditorPage(
          client: widget.client,
          initialPreset: preset,
          initialVersion: _version,
        ),
      ),
    );
    if (updated == null) return;
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(_tr('Пресет обновлён.', 'Preset updated.')),
          backgroundColor: const Color(0xFF166534),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final preset = _preset;
    final version = _version;
    return Scaffold(
      appBar: AppBar(
        title: Text(_tr('Пресет', 'Preset')),
        actions: [
          if (widget.canEdit && preset != null)
            IconButton(
              onPressed: _loading ? null : _editPreset,
              icon: const Icon(Icons.edit_rounded),
              tooltip: _tr('Редактировать', 'Edit'),
            ),
          if (widget.allowPick && preset != null)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: FilledButton.icon(
                onPressed: () => Navigator.pop(context, preset),
                icon: const Icon(Icons.check_rounded),
                label: Text(_tr('Применить', 'Apply')),
              ),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: BrandLoadingIndicator())
          : _error != null
          ? ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _ErrorCard(message: _error!),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: _load,
                  icon: const Icon(Icons.refresh_rounded),
                  label: Text(_tr('Повторить', 'Retry')),
                ),
              ],
            )
          : preset == null
          ? Center(child: Text(_tr('Пресет не найден.', 'Preset not found.')))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _Panel(
                  title: preset.name,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        preset.description.trim().isEmpty
                            ? _tr('Без описания', 'No description')
                            : preset.description.trim(),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _MetaChip(
                            label: _tr('Автор', 'Author'),
                            value: '#${preset.ownerId}',
                          ),
                          _MetaChip(
                            label: _tr('Видимость', 'Visibility'),
                            value: preset.visibility,
                          ),
                          _MetaChip(
                            label: _tr('Версия', 'Version'),
                            value: version == null
                                ? '—'
                                : 'v${version.version}',
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _tr(
                          'Теги: ${preset.tags.isEmpty ? "—" : preset.tags.join(", ")}',
                          'Tags: ${preset.tags.isEmpty ? "—" : preset.tags.join(", ")}',
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                _Panel(
                  title: _tr('Переменные', 'Variables'),
                  child: (version?.definition.variables.isEmpty ?? true)
                      ? Text(_tr('Нет переменных.', 'No variables.'))
                      : Column(
                          children: version!.definition.variables
                              .map(
                                (variable) => ListTile(
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                  title: Text(variable.title),
                                  subtitle: Text(variable.key),
                                  trailing: Text(
                                    variable.defaultValue?.toString() ?? '—',
                                  ),
                                ),
                              )
                              .toList(),
                        ),
                ),
                const SizedBox(height: 12),
                _Panel(
                  title: _tr('Спецзначения', 'Status values'),
                  child: (version?.definition.statusCodes.isEmpty ?? true)
                      ? Text(_tr('Нет спецзначений.', 'No status values.'))
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: version!.definition.statusCodes
                              .map(
                                (status) => Container(
                                  width: double.infinity,
                                  margin: const EdgeInsets.only(bottom: 8),
                                  padding: const EdgeInsets.all(10),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFF8FAFC),
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(
                                      color: const Color(0xFFE2E8F0),
                                    ),
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        '${_tr('Ключ', 'Key')}: ${status.key}',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        '${_tr('Код в ячейке', 'Cell code')}: ${status.code}',
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        '${_tr('Числовой эквивалент', 'Numeric value')}: ${status.numericValue?.toString() ?? '—'}',
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        '${_tr('Считать пропуском', 'Count as miss')}: ${status.countsAsMiss ? _tr('Да', 'Yes') : _tr('Нет', 'No')}',
                                      ),
                                      Text(
                                        '${_tr('Учитывать в статистике', 'Include in stats')}: ${status.countsInStats ? _tr('Да', 'Yes') : _tr('Нет', 'No')}',
                                      ),
                                    ],
                                  ),
                                ),
                              )
                              .toList(),
                        ),
                ),
                const SizedBox(height: 12),
                _Panel(
                  title: _tr('Спецколонки', 'Special columns'),
                  child: (version?.definition.columns.isEmpty ?? true)
                      ? Text(_tr('Нет колонок.', 'No columns.'))
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: version!.definition.columns
                              .map(
                                (column) => Container(
                                  width: double.infinity,
                                  margin: const EdgeInsets.only(bottom: 8),
                                  padding: const EdgeInsets.all(10),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFF8FAFC),
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(
                                      color: const Color(0xFFE2E8F0),
                                    ),
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Expanded(
                                            child: Text(
                                              column.title,
                                              style: const TextStyle(
                                                fontWeight: FontWeight.w700,
                                              ),
                                            ),
                                          ),
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 8,
                                              vertical: 3,
                                            ),
                                            decoration: BoxDecoration(
                                              color: column.kind == 'computed'
                                                  ? const Color(0xFFDCFCE7)
                                                  : const Color(0xFFE2E8F0),
                                              borderRadius:
                                                  BorderRadius.circular(999),
                                            ),
                                            child: Text(
                                              column.kind,
                                              style: const TextStyle(
                                                fontSize: 12,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 4),
                                      Text('key: ${column.key}'),
                                      if (column.kind == 'computed' &&
                                          column.formula.trim().isNotEmpty) ...[
                                        const SizedBox(height: 4),
                                        Text('formula: ${column.formula}'),
                                      ],
                                      if (column.dependsOn.isNotEmpty) ...[
                                        const SizedBox(height: 4),
                                        Text(
                                          'depends_on: ${column.dependsOn.join(", ")}',
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                              )
                              .toList(),
                        ),
                ),
              ],
            ),
    );
  }
}

class PresetEditorPage extends StatefulWidget {
  const PresetEditorPage({
    super.key,
    required this.client,
    this.initialPreset,
    this.initialVersion,
  });

  final ApiClient client;
  final GradingPreset? initialPreset;
  final GradingPresetVersion? initialVersion;

  @override
  State<PresetEditorPage> createState() => _PresetEditorPageState();
}

class _PresetEditorPageState extends State<PresetEditorPage> {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _descriptionController = TextEditingController();
  final TextEditingController _tagsController = TextEditingController();
  final List<_PresetStatusCodeDraft> _statusCodes = <_PresetStatusCodeDraft>[];
  final List<_PresetVariableDraft> _variables = <_PresetVariableDraft>[];
  final List<_PresetManualColumnDraft> _manualColumns =
      <_PresetManualColumnDraft>[];
  final List<_PresetComputedColumnDraft> _computedColumns =
      <_PresetComputedColumnDraft>[];

  String _visibility = 'public';
  bool _saving = false;
  String? _error;
  bool get _isEditing => widget.initialPreset != null;

  bool get _isRu => Localizations.localeOf(
    context,
  ).languageCode.toLowerCase().startsWith('ru');
  String _tr(String ru, String en) => _isRu ? ru : en;

  @override
  void initState() {
    super.initState();
    if (_isEditing) {
      final preset = widget.initialPreset!;
      final version = widget.initialVersion ?? preset.currentVersion;
      _nameController.text = preset.name;
      _descriptionController.text = preset.description;
      _tagsController.text = preset.tags.join(', ');
      _visibility = preset.visibility;
      if (version != null) {
        for (final status in version.definition.statusCodes) {
          _statusCodes.add(
            _PresetStatusCodeDraft(
              key: status.key.trim().isEmpty
                  ? _statusCodeRefSuffix(status.code)
                  : status.key,
              code: status.code,
              numeric: status.numericValue?.toString() ?? '',
              countsAsMiss: status.countsAsMiss,
              countsInStats: status.countsInStats,
            ),
          );
        }
        for (final variable in version.definition.variables) {
          _variables.add(
            _PresetVariableDraft(
              key: variable.key,
              title: variable.title,
              value: variable.defaultValue?.toString() ?? '',
            ),
          );
        }
        for (final column in version.definition.columns) {
          if (column.kind == 'manual') {
            _manualColumns.add(
              _PresetManualColumnDraft(key: column.key, title: column.title),
            );
          } else if (column.kind == 'computed') {
            _computedColumns.add(
              _PresetComputedColumnDraft(
                key: column.key,
                title: column.title,
                formula: column.formula,
              ),
            );
          }
        }
      }
    }
    if (_manualColumns.isEmpty && _computedColumns.isEmpty) {
      _manualColumns.add(
        _PresetManualColumnDraft(key: 'bonus', title: 'Bonus'),
      );
      _computedColumns.add(
        _PresetComputedColumnDraft(
          key: 'final',
          title: 'Final',
          formula: 'DATE_AVG + bonus',
        ),
      );
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    _tagsController.dispose();
    for (final status in _statusCodes) {
      status.dispose();
    }
    for (final variable in _variables) {
      variable.dispose();
    }
    for (final column in _manualColumns) {
      column.dispose();
    }
    for (final column in _computedColumns) {
      column.dispose();
    }
    super.dispose();
  }

  void _addVariable() {
    setState(() {
      _variables.add(_PresetVariableDraft());
    });
  }

  void _addStatusCode() {
    setState(() {
      _statusCodes.add(_PresetStatusCodeDraft());
    });
  }

  void _addManualColumn() {
    setState(() {
      _manualColumns.add(_PresetManualColumnDraft());
    });
  }

  void _addComputedColumn() {
    setState(() {
      _computedColumns.add(_PresetComputedColumnDraft());
    });
  }

  void _removeVariable(int index) {
    if (index < 0 || index >= _variables.length) return;
    final draft = _variables.removeAt(index);
    draft.dispose();
    setState(() {});
  }

  void _removeStatusCode(int index) {
    if (index < 0 || index >= _statusCodes.length) return;
    final draft = _statusCodes.removeAt(index);
    draft.dispose();
    setState(() {});
  }

  void _removeManualColumn(int index) {
    if (index < 0 || index >= _manualColumns.length) return;
    final draft = _manualColumns.removeAt(index);
    draft.dispose();
    setState(() {});
  }

  void _removeComputedColumn(int index) {
    if (index < 0 || index >= _computedColumns.length) return;
    final draft = _computedColumns.removeAt(index);
    draft.dispose();
    setState(() {});
  }

  Set<String> _extractFormulaIdentifiers(String formula) {
    final refs = <String>{};
    for (final match in _presetIdentifierPattern.allMatches(formula)) {
      final raw = match.group(0);
      if (raw == null || raw.isEmpty) continue;
      final upper = raw.toUpperCase();
      if (_presetFormulaFunctions.contains(upper) ||
          _presetFormulaKeywords.contains(upper) ||
          _presetBuiltInRefs.contains(upper)) {
        continue;
      }
      refs.add(raw);
    }
    return refs;
  }

  List<String> _previewReferences() {
    final refs = <String>[..._presetBuiltInRefs];
    for (final status in _statusCodes) {
      final key = status.keyController.text.trim();
      if (key.isEmpty) continue;
      final suffix = key.toUpperCase();
      refs.add('CODE_COUNT_$suffix');
      refs.add('STATUS_COUNT_$suffix');
      refs.add('STUDENT_CODE_COUNT_$suffix');
    }
    refs.addAll(
      _variables
          .map((item) => item.keyController.text.trim())
          .where((item) => item.isNotEmpty),
    );
    refs.addAll(
      _manualColumns
          .map((item) => item.keyController.text.trim())
          .where((item) => item.isNotEmpty),
    );
    refs.addAll(
      _computedColumns
          .map((item) => item.keyController.text.trim())
          .where((item) => item.isNotEmpty),
    );
    final unique = refs.toSet().toList()..sort();
    return unique;
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(
        () => _error = _tr(
          'Укажите название пресета.',
          'Preset name is required.',
        ),
      );
      return;
    }

    final tags = _tagsController.text
        .split(',')
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList();

    final statusCodes = <StatusCodeRuleDto>[];
    final statusCodeRefKeys = <String>{};
    final uniqueStatusCodes = <String>{};
    final uniqueStatusKeys = <String>{};
    for (var i = 0; i < _statusCodes.length; i++) {
      final item = _statusCodes[i];
      final key = item.keyController.text.trim();
      final code = item.codeController.text.trim();
      final numericRaw = item.numericValueController.text.trim();
      if (key.isEmpty && code.isEmpty && numericRaw.isEmpty) {
        continue;
      }
      if (key.isEmpty) {
        setState(
          () => _error = _tr(
            'Заполните ключ спецзначения #${i + 1}.',
            'Fill key for status value #${i + 1}.',
          ),
        );
        return;
      }
      if (!_presetStatusKeyPattern.hasMatch(key)) {
        setState(
          () => _error = _tr(
            'Неверный ключ спецзначения "$key". Используйте буквы, цифры и _ (без пробелов).',
            'Invalid status key "$key". Use letters, digits and _ (no spaces).',
          ),
        );
        return;
      }
      final normalizedKey = key.toUpperCase();
      if (!uniqueStatusKeys.add(normalizedKey)) {
        setState(
          () => _error = _tr(
            'Ключ спецзначения "$key" повторяется.',
            'Status key "$key" is duplicated.',
          ),
        );
        return;
      }
      if (code.isEmpty) {
        setState(
          () => _error = _tr(
            'Заполните код спецзначения #${i + 1}.',
            'Fill code for status value #${i + 1}.',
          ),
        );
        return;
      }
      if (!_presetStatusCodePattern.hasMatch(code)) {
        setState(
          () => _error = _tr(
            'Код "$code" не должен содержать пробелы.',
            'Code "$code" must not contain spaces.',
          ),
        );
        return;
      }
      final normalizedCode = code.toUpperCase();
      if (!uniqueStatusCodes.add(normalizedCode)) {
        setState(
          () => _error = _tr(
            'Код "$code" повторяется.',
            'Code "$code" is duplicated.',
          ),
        );
        return;
      }
      double? numericValue;
      if (numericRaw.isNotEmpty) {
        numericValue = double.tryParse(numericRaw.replaceAll(',', '.'));
        if (numericValue == null) {
          setState(
            () => _error = _tr(
              'Неверное числовое значение у кода "$code".',
              'Invalid numeric value for code "$code".',
            ),
          );
          return;
        }
      }
      statusCodes.add(
        StatusCodeRuleDto(
          key: key,
          code: code,
          numericValue: numericValue,
          countsAsMiss: item.countsAsMiss,
          countsInStats: item.countsInStats,
        ),
      );
      final suffix = normalizedKey;
      statusCodeRefKeys.add('CODE_COUNT_$suffix');
      statusCodeRefKeys.add('STATUS_COUNT_$suffix');
      statusCodeRefKeys.add('STUDENT_CODE_COUNT_$suffix');
    }

    final variables = <PresetVariableDto>[];
    final variableKeys = <String>{};
    for (var i = 0; i < _variables.length; i++) {
      final item = _variables[i];
      final key = item.keyController.text.trim();
      final title = item.titleController.text.trim();
      final defaultRaw = item.defaultValueController.text.trim();
      if (key.isEmpty && title.isEmpty && defaultRaw.isEmpty) {
        continue;
      }
      if (key.isEmpty) {
        setState(
          () => _error = _tr(
            'Заполните ключ переменной #${i + 1}.',
            'Fill key for variable #${i + 1}.',
          ),
        );
        return;
      }
      if (!_presetColumnKeyPattern.hasMatch(key)) {
        setState(
          () => _error = _tr(
            'Неверный ключ переменной "$key". Используйте A-Z, 0-9 и _.',
            'Invalid variable key "$key". Use A-Z, 0-9 and _.',
          ),
        );
        return;
      }
      if (!variableKeys.add(key)) {
        setState(
          () => _error = _tr(
            'Ключ переменной "$key" повторяется.',
            'Variable key "$key" is duplicated.',
          ),
        );
        return;
      }
      final parsedDefault = double.tryParse(defaultRaw);
      variables.add(
        PresetVariableDto(
          key: key,
          title: title.isEmpty ? key : title,
          type: 'number',
          defaultValue: defaultRaw.isEmpty
              ? null
              : (parsedDefault ?? defaultRaw),
        ),
      );
    }

    final manualColumns = <PresetColumnDto>[];
    final computedDrafts = <_PreparedComputedDraft>[];
    final allColumnKeys = <String>{};
    for (var i = 0; i < _manualColumns.length; i++) {
      final item = _manualColumns[i];
      final key = item.keyController.text.trim();
      final title = item.titleController.text.trim();
      if (key.isEmpty && title.isEmpty) {
        continue;
      }
      if (key.isEmpty) {
        setState(
          () => _error = _tr(
            'Заполните ключ ручной колонки #${i + 1}.',
            'Fill key for manual column #${i + 1}.',
          ),
        );
        return;
      }
      if (!_presetColumnKeyPattern.hasMatch(key)) {
        setState(
          () => _error = _tr(
            'Неверный ключ колонки "$key". Используйте A-Z, 0-9 и _.',
            'Invalid column key "$key". Use A-Z, 0-9 and _.',
          ),
        );
        return;
      }
      if (!allColumnKeys.add(key) || variableKeys.contains(key)) {
        setState(
          () => _error = _tr(
            'Ключ "$key" уже используется.',
            'Key "$key" is already used.',
          ),
        );
        return;
      }
      manualColumns.add(
        PresetColumnDto(
          key: key,
          title: title.isEmpty ? key : title,
          kind: 'manual',
          type: 'number',
          editable: true,
        ),
      );
    }

    for (var i = 0; i < _computedColumns.length; i++) {
      final item = _computedColumns[i];
      final key = item.keyController.text.trim();
      final title = item.titleController.text.trim();
      final formula = item.formulaController.text.trim();
      if (key.isEmpty && title.isEmpty && formula.isEmpty) {
        continue;
      }
      if (key.isEmpty || formula.isEmpty) {
        setState(
          () => _error = _tr(
            'Заполните ключ и формулу вычисляемой колонки #${i + 1}.',
            'Fill key and formula for computed column #${i + 1}.',
          ),
        );
        return;
      }
      if (!_presetColumnKeyPattern.hasMatch(key)) {
        setState(
          () => _error = _tr(
            'Неверный ключ вычисляемой колонки "$key".',
            'Invalid computed column key "$key".',
          ),
        );
        return;
      }
      if (!allColumnKeys.add(key) || variableKeys.contains(key)) {
        setState(
          () => _error = _tr(
            'Ключ "$key" уже используется.',
            'Key "$key" is already used.',
          ),
        );
        return;
      }
      computedDrafts.add(
        _PreparedComputedDraft(
          key: key,
          title: title.isEmpty ? key : title,
          formula: formula,
        ),
      );
    }

    for (final draft in computedDrafts) {
      if (_presetIfMissingCommaPattern.hasMatch(draft.formula)) {
        setState(
          () => _error = _tr(
            'Похоже на неверный IF: используйте IF(условие, тогда, иначе) или IF(условие, тогда) ELSE(иначе).',
            'Invalid IF syntax: use IF(condition, then, else) or IF(condition, then) ELSE(else).',
          ),
        );
        return;
      }
    }

    if (manualColumns.isEmpty && computedDrafts.isEmpty) {
      setState(
        () => _error = _tr(
          'Добавьте хотя бы одну спецколонку (ручную или вычисляемую).',
          'Add at least one special column (manual or computed).',
        ),
      );
      return;
    }

    final allowedRefs = <String>{
      ...allColumnKeys,
      ...variableKeys,
      ..._presetBuiltInRefs,
      ...statusCodeRefKeys,
    };
    final computedColumns = <PresetColumnDto>[];
    for (final item in computedDrafts) {
      final refs = _extractFormulaIdentifiers(item.formula);
      if (refs.contains(item.key)) {
        setState(
          () => _error = _tr(
            'Колонка "${item.key}" не может ссылаться на саму себя.',
            'Column "${item.key}" cannot reference itself.',
          ),
        );
        return;
      }
      final unknown = refs.where((ref) => !allowedRefs.contains(ref)).toList()
        ..sort();
      if (unknown.isNotEmpty) {
        setState(
          () => _error = _tr(
            'В формуле "${item.key}" есть неизвестные ссылки: ${unknown.join(', ')}',
            'Formula "${item.key}" has unknown refs: ${unknown.join(', ')}',
          ),
        );
        return;
      }
      final dependsOn =
          refs
              .where(
                (ref) =>
                    allColumnKeys.contains(ref) || variableKeys.contains(ref),
              )
              .toList()
            ..sort();
      computedColumns.add(
        PresetColumnDto(
          key: item.key,
          title: item.title,
          kind: 'computed',
          type: 'number',
          formula: item.formula,
          format: '',
          dependsOn: dependsOn,
        ),
      );
    }

    final definition = PresetDefinition(
      statusCodes: statusCodes,
      variables: variables,
      columns: [...manualColumns, ...computedColumns],
    );

    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      late final GradingPreset preset;
      if (_isEditing) {
        preset = await widget.client.updatePreset(
          widget.initialPreset!.id,
          name: name,
          description: _descriptionController.text.trim(),
          tags: tags,
          visibility: _visibility,
          definition: definition,
        );
      } else {
        preset = await widget.client.createPreset(
          name: name,
          description: _descriptionController.text.trim(),
          tags: tags,
          visibility: _visibility,
          definition: definition,
        );
      }
      if (!mounted) return;
      Navigator.pop(context, preset);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = _readErrorText(error));
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final refs = _previewReferences();
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _isEditing
              ? _tr('Редактирование пресета', 'Edit preset')
              : _tr('Создание пресета', 'Create preset'),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _nameController,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              labelText: _tr('Название пресета', 'Preset name'),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _descriptionController,
            maxLines: 3,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              labelText: _tr('Описание', 'Description'),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _tagsController,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              labelText: _tr('Теги (через запятую)', 'Tags (comma separated)'),
            ),
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            key: ValueKey('editor_visibility_$_visibility'),
            initialValue: _visibility,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              labelText: _tr('Видимость', 'Visibility'),
            ),
            items: [
              DropdownMenuItem(
                value: 'public',
                child: Text(_tr('Публичный', 'Public')),
              ),
              DropdownMenuItem(
                value: 'private',
                child: Text(_tr('Приватный', 'Private')),
              ),
            ],
            onChanged: (value) {
              if (value == null) return;
              setState(() => _visibility = value);
            },
          ),
          const SizedBox(height: 16),
          _buildSectionHeader(
            title: _tr('Спецзначения', 'Status values'),
            subtitle: _tr(
              'Задайте ключ, код в ячейке и правила учета. Числа всегда разрешены.',
              'Set key, cell code and accounting rules. Numbers are always allowed.',
            ),
            onAdd: _addStatusCode,
          ),
          const SizedBox(height: 8),
          if (_statusCodes.isEmpty)
            Text(
              _tr(
                'Спецзначения не добавлены. Без них разрешены только числа.',
                'No status values added. Without them only numbers are accepted.',
              ),
              style: const TextStyle(color: Color(0xFF64748B)),
            ),
          for (var i = 0; i < _statusCodes.length; i++)
            _buildStatusCodeCard(i, _statusCodes[i]),
          const SizedBox(height: 16),
          _buildSectionHeader(
            title: _tr('Переменные', 'Variables'),
            subtitle: _tr(
              'Постоянные значения для формул (опционально).',
              'Constant values for formulas (optional).',
            ),
            onAdd: _addVariable,
          ),
          const SizedBox(height: 8),
          if (_variables.isEmpty)
            Text(
              _tr('Переменные не добавлены.', 'No variables added.'),
              style: const TextStyle(color: Color(0xFF64748B)),
            ),
          for (var i = 0; i < _variables.length; i++)
            _buildVariableCard(i, _variables[i]),
          const SizedBox(height: 16),
          _buildSectionHeader(
            title: _tr('Ручные спецколонки', 'Manual special columns'),
            subtitle: _tr(
              'Редактируются учителем прямо в журнале.',
              'Editable by a teacher directly in the journal.',
            ),
            onAdd: _addManualColumn,
          ),
          const SizedBox(height: 8),
          if (_manualColumns.isEmpty)
            Text(
              _tr(
                'Ручные спецколонки не добавлены.',
                'No manual special columns added.',
              ),
              style: const TextStyle(color: Color(0xFF64748B)),
            ),
          for (var i = 0; i < _manualColumns.length; i++)
            _buildManualCard(i, _manualColumns[i]),
          const SizedBox(height: 16),
          _buildSectionHeader(
            title: _tr('Вычисляемые спецколонки', 'Computed special columns'),
            subtitle: _tr(
              'Формулы пересчитываются на сервере для всей истории.',
              'Formulas are recalculated server-side for all history.',
            ),
            onAdd: _addComputedColumn,
          ),
          const SizedBox(height: 8),
          if (_computedColumns.isEmpty)
            Text(
              _tr(
                'Вычисляемые спецколонки не добавлены.',
                'No computed special columns added.',
              ),
              style: const TextStyle(color: Color(0xFF64748B)),
            ),
          for (var i = 0; i < _computedColumns.length; i++)
            _buildComputedCard(i, _computedColumns[i]),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFF8FAFC),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFE2E8F0)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _tr(
                    'Доступные ссылки в формулах',
                    'Available references in formulas',
                  ),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                if (refs.isEmpty)
                  Text(
                    _tr(
                      'Добавьте переменные или спецколонки, чтобы использовать их в формулах.',
                      'Add variables or special columns to use them in formulas.',
                    ),
                    style: const TextStyle(color: Color(0xFF475569)),
                  )
                else
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: refs
                        .map(
                          (ref) => Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 5,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFFDCFCE7),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              ref,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        )
                        .toList(),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          _buildEditorFormulaHelp(),
          const SizedBox(height: 14),
          _buildStatusFlagsHelp(),
          const SizedBox(height: 14),
          if (_error != null) ...[
            _ErrorCard(message: _error!),
            const SizedBox(height: 10),
          ],
          FilledButton.icon(
            onPressed: _saving ? null : _save,
            icon: const Icon(Icons.save_rounded),
            label: Text(
              _saving
                  ? _tr('Сохранение...', 'Saving...')
                  : _isEditing
                  ? _tr('Сохранить изменения', 'Save changes')
                  : _tr('Сохранить пресет', 'Save preset'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader({
    required String title,
    required String subtitle,
    required VoidCallback onAdd,
  }) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: const TextStyle(color: Color(0xFF64748B), fontSize: 12),
              ),
            ],
          ),
        ),
        FilledButton.tonalIcon(
          onPressed: onAdd,
          icon: const Icon(Icons.add_rounded),
          label: Text(_tr('Добавить', 'Add')),
        ),
      ],
    );
  }

  Widget _buildStatusCodeCard(int index, _PresetStatusCodeDraft draft) {
    final key = draft.keyController.text.trim();
    final suffix = key.isEmpty ? 'KEY' : key.toUpperCase();
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFCBD5E1)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Text(
                _tr('Спецзначение #${index + 1}', 'Status value #${index + 1}'),
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              IconButton(
                onPressed: () => _removeStatusCode(index),
                icon: const Icon(Icons.delete_outline_rounded),
                tooltip: _tr('Удалить', 'Delete'),
              ),
            ],
          ),
          const SizedBox(height: 6),
          TextField(
            controller: draft.keyController,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              labelText: _tr('Ключ', 'Key'),
              hintText: _tr(
                'например: NKI или НКИ',
                'for example: NKI or NKI_RU',
              ),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: draft.codeController,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              labelText: _tr('Код в ячейке', 'Cell code'),
              hintText: _tr('например: н', 'for example: n'),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: draft.numericValueController,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              labelText: _tr(
                'Числовой эквивалент (опционально)',
                'Numeric equivalent (optional)',
              ),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              FilterChip(
                selected: draft.countsAsMiss,
                label: Text(_tr('Считать пропуском', 'Count as miss')),
                onSelected: (value) {
                  setState(() => draft.countsAsMiss = value);
                },
              ),
              FilterChip(
                selected: draft.countsInStats,
                label: Text(_tr('Учитывать в статистике', 'Include in stats')),
                onSelected: (value) {
                  setState(() => draft.countsInStats = value);
                },
              ),
            ],
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              _tr(
                'Счетчики: CODE_COUNT_$suffix / STUDENT_CODE_COUNT_$suffix',
                'Counters: CODE_COUNT_$suffix / STUDENT_CODE_COUNT_$suffix',
              ),
              style: const TextStyle(color: Color(0xFF475569), fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVariableCard(int index, _PresetVariableDraft draft) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFCBD5E1)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Text(
                _tr('Переменная #${index + 1}', 'Variable #${index + 1}'),
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              IconButton(
                onPressed: () => _removeVariable(index),
                icon: const Icon(Icons.delete_outline_rounded),
                tooltip: _tr('Удалить', 'Delete'),
              ),
            ],
          ),
          const SizedBox(height: 6),
          TextField(
            controller: draft.keyController,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              labelText: _tr('Ключ', 'Key'),
              hintText: 'extra_weight',
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: draft.titleController,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              labelText: _tr('Название', 'Title'),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: draft.defaultValueController,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              labelText: _tr('Значение по умолчанию', 'Default value'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildManualCard(int index, _PresetManualColumnDraft draft) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFCBD5E1)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Text(
                _tr(
                  'Ручная колонка #${index + 1}',
                  'Manual column #${index + 1}',
                ),
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              IconButton(
                onPressed: () => _removeManualColumn(index),
                icon: const Icon(Icons.delete_outline_rounded),
                tooltip: _tr('Удалить', 'Delete'),
              ),
            ],
          ),
          const SizedBox(height: 6),
          TextField(
            controller: draft.keyController,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              labelText: _tr('Ключ', 'Key'),
              hintText: 'bonus',
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: draft.titleController,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              labelText: _tr('Название', 'Title'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildComputedCard(int index, _PresetComputedColumnDraft draft) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFCBD5E1)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Text(
                _tr(
                  'Вычисляемая колонка #${index + 1}',
                  'Computed column #${index + 1}',
                ),
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              IconButton(
                onPressed: () => _removeComputedColumn(index),
                icon: const Icon(Icons.delete_outline_rounded),
                tooltip: _tr('Удалить', 'Delete'),
              ),
            ],
          ),
          const SizedBox(height: 6),
          TextField(
            controller: draft.keyController,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              labelText: _tr('Ключ', 'Key'),
              hintText: 'final',
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: draft.titleController,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              labelText: _tr('Название', 'Title'),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: draft.formulaController,
            onChanged: (_) => setState(() {}),
            minLines: 2,
            maxLines: 4,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              labelText: _tr('Формула', 'Formula'),
              hintText: 'IF(DATE_AVG >= 50, SUM(DATE_AVG, bonus), 0)',
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEditorFormulaHelp() {
    final items = <String>[
      _tr(
        'Функции: IF, ELSE, SUM, AVG, MIN, MAX, COUNT_IF.',
        'Functions: IF, ELSE, SUM, AVG, MIN, MAX, COUNT_IF.',
      ),
      _tr(
        'Операторы: + - * /, сравнения > >= < <= == !=, логика AND/OR/NOT.',
        'Operators: + - * /, comparisons > >= < <= == !=, logic AND/OR/NOT.',
      ),
      _tr(
        'Синтаксис IF: IF(условие, значение_если_да, значение_если_нет).',
        'IF syntax: IF(condition, value_if_true, value_if_false).',
      ),
      _tr(
        'Альтернатива: IF(условие, значение_если_да) ELSE(значение_если_нет).',
        'Alternative: IF(condition, value_if_true) ELSE(value_if_false).',
      ),
      _tr(
        'COUNT_IF считает количество истинных условий: COUNT_IF(a>0, b>0, c>0).',
        'COUNT_IF counts true expressions: COUNT_IF(a>0, b>0, c>0).',
      ),
      _tr(
        'Встроенные ссылки: DATE_AVG, DATE_SUM, DATE_COUNT, DATE_MIN, DATE_MAX, MISS_COUNT, STUDENT_MISS_COUNT.',
        'Built-in refs: DATE_AVG, DATE_SUM, DATE_COUNT, DATE_MIN, DATE_MAX, MISS_COUNT, STUDENT_MISS_COUNT.',
      ),
      _tr(
        'Счетчики спецзначений по группе: CODE_COUNT_<KEY>, STATUS_COUNT_<KEY>.',
        'Group status counters: CODE_COUNT_<KEY>, STATUS_COUNT_<KEY>.',
      ),
      _tr(
        'Счетчик по текущему студенту: STUDENT_CODE_COUNT_<KEY>.',
        'Per-student counter: STUDENT_CODE_COUNT_<KEY>.',
      ),
      _tr(
        'Ключ задается в спецзначении отдельно от кода в ячейке.',
        'Status key is configured separately from the cell code.',
      ),
      _tr(
        'Ссылаться можно только на существующие переменные и спецколонки.',
        'You can reference only existing variables and special columns.',
      ),
      _tr(
        'Ключи переменных/колонок: только A-Z, 0-9 и _. Без пробелов.',
        'Variable/column keys: only A-Z, 0-9 and _. No spaces.',
      ),
    ];
    final templates = <String>[
      'IF(DATE_AVG >= 50, DATE_AVG, 0)',
      'IF(nki > 0, (DATE_SUM + otr) / (DATE_COUNT - nki + 1), DATE_AVG)',
      'IF(nki > 0, (DATE_SUM + otr) / (DATE_COUNT - nki + 1)) ELSE(DATE_AVG)',
      'SUM(DATE_AVG, bonus, project)',
      'IF(CODE_COUNT_NKI > 0, DATE_AVG, 0)',
      'IF(STUDENT_MISS_COUNT > 0, 0, DATE_AVG)',
      'IF(exam >= 50, AVG(DATE_AVG, exam), DATE_AVG)',
      'COUNT_IF(att1 > 0, att2 > 0, att3 > 0)',
    ];
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _tr('Подсказка по формулам', 'Formula quick guide'),
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          for (final item in items)
            Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: Text('• $item'),
            ),
          const SizedBox(height: 8),
          Text(
            _tr('Шаблоны:', 'Templates:'),
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: templates
                .map(
                  (formula) => Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFDCFCE7),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(formula),
                  ),
                )
                .toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusFlagsHelp() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _tr(
              'Что значит "Считать пропуском" и "Учитывать в статистике"',
              'What "Count as miss" and "Include in stats" mean',
            ),
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Text(
            _tr(
              '• Считать пропуском: код увеличивает счетчики MISS_COUNT и STUDENT_MISS_COUNT.',
              '• Count as miss: this code increments MISS_COUNT and STUDENT_MISS_COUNT counters.',
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _tr(
              '• Учитывать в статистике: код попадает в общие подсчеты и агрегаты (в том числе счетчики CODE_COUNT_*).',
              '• Include in stats: this code is included in aggregate counters and statistics (including CODE_COUNT_*).',
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _tr(
              '• Числа 0..100 принимаются всегда, а текстовые значения только из списка спецзначений.',
              '• Numeric values 0..100 are always accepted, while text values are accepted only from status values list.',
            ),
          ),
        ],
      ),
    );
  }
}

class _PreparedComputedDraft {
  const _PreparedComputedDraft({
    required this.key,
    required this.title,
    required this.formula,
  });

  final String key;
  final String title;
  final String formula;
}

class _PresetStatusCodeDraft {
  _PresetStatusCodeDraft({
    String key = '',
    String code = '',
    String numeric = '',
    this.countsAsMiss = false,
    this.countsInStats = true,
  }) : keyController = TextEditingController(text: key),
       codeController = TextEditingController(text: code),
       numericValueController = TextEditingController(text: numeric);

  final TextEditingController keyController;
  final TextEditingController codeController;
  final TextEditingController numericValueController;
  bool countsAsMiss;
  bool countsInStats;

  void dispose() {
    keyController.dispose();
    codeController.dispose();
    numericValueController.dispose();
  }
}

class _PresetVariableDraft {
  _PresetVariableDraft({String key = '', String title = '', String value = ''})
    : keyController = TextEditingController(text: key),
      titleController = TextEditingController(text: title),
      defaultValueController = TextEditingController(text: value);

  final TextEditingController keyController;
  final TextEditingController titleController;
  final TextEditingController defaultValueController;

  void dispose() {
    keyController.dispose();
    titleController.dispose();
    defaultValueController.dispose();
  }
}

class _PresetManualColumnDraft {
  _PresetManualColumnDraft({String key = '', String title = ''})
    : keyController = TextEditingController(text: key),
      titleController = TextEditingController(text: title);

  final TextEditingController keyController;
  final TextEditingController titleController;

  void dispose() {
    keyController.dispose();
    titleController.dispose();
  }
}

class _PresetComputedColumnDraft {
  _PresetComputedColumnDraft({
    String key = '',
    String title = '',
    String formula = '',
  }) : keyController = TextEditingController(text: key),
       titleController = TextEditingController(text: title),
       formulaController = TextEditingController(text: formula);

  final TextEditingController keyController;
  final TextEditingController titleController;
  final TextEditingController formulaController;

  void dispose() {
    keyController.dispose();
    titleController.dispose();
    formulaController.dispose();
  }
}

class _QuickActionItem {
  const _QuickActionItem({
    required this.id,
    required this.title,
    required this.icon,
    this.destructive = false,
  });

  final String id;
  final String title;
  final IconData icon;
  final bool destructive;
}

class _MetaChip extends StatelessWidget {
  const _MetaChip({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text('$label: $value'),
    );
  }
}

class _GridScrollBehavior extends MaterialScrollBehavior {
  const _GridScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => const {
    PointerDeviceKind.touch,
    PointerDeviceKind.mouse,
    PointerDeviceKind.stylus,
    PointerDeviceKind.invertedStylus,
    PointerDeviceKind.unknown,
    PointerDeviceKind.trackpad,
  };
}

class _Panel extends StatelessWidget {
  const _Panel({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: const [
          BoxShadow(
            color: Color(0x120F172A),
            blurRadius: 20,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFEE2E2),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFFCA5A5)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline_rounded, color: Color(0xFFB91C1C)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(color: Color(0xFF7F1D1D)),
            ),
          ),
        ],
      ),
    );
  }
}
