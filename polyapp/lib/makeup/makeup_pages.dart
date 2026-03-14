import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/api_client.dart';
import '../journal/journal_date_picker.dart';

const List<String> kMakeupStatuses = [
  'awaiting_proof',
  'proof_submitted',
  'task_assigned',
  'submission_sent',
  'graded',
  'rejected',
];

String makeupStatusLabel(String status, bool isRu) {
  switch (status) {
    case 'awaiting_proof':
      return isRu ? 'Ожидает справку' : 'Awaiting proof';
    case 'proof_submitted':
      return isRu ? 'Справка отправлена' : 'Proof submitted';
    case 'task_assigned':
      return isRu ? 'Задание назначено' : 'Task assigned';
    case 'submission_sent':
      return isRu ? 'Работа отправлена' : 'Submission sent';
    case 'graded':
      return isRu ? 'Оценено' : 'Graded';
    case 'rejected':
      return isRu ? 'Отклонено' : 'Rejected';
    default:
      return status;
  }
}

Color makeupStatusColor(String status) {
  switch (status) {
    case 'awaiting_proof':
      return const Color(0xFFF59E0B);
    case 'proof_submitted':
      return const Color(0xFF2563EB);
    case 'task_assigned':
      return const Color(0xFF7C3AED);
    case 'submission_sent':
      return const Color(0xFF0891B2);
    case 'graded':
      return const Color(0xFF16A34A);
    case 'rejected':
      return const Color(0xFFDC2626);
    default:
      return const Color(0xFF4B5563);
  }
}

class ModulePanel extends StatelessWidget {
  const ModulePanel({
    super.key,
    required this.title,
    required this.subtitle,
    required this.child,
    this.trailing,
  });

  final String title;
  final String subtitle;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final compact = width < 700;
    final maxWidth = width >= 1500
        ? 1400.0
        : width >= 1100
        ? 1200.0
        : double.infinity;
    final horizontal = width >= 1100 ? 28.0 : 16.0;
    return Material(
      type: MaterialType.transparency,
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFFF4F7F2), Color(0xFFEAF0E4)],
          ),
        ),
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: ListView(
              padding: EdgeInsets.fromLTRB(horizontal, 18, horizontal, 24),
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleLarge
                                ?.copyWith(fontWeight: FontWeight.w800),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            subtitle,
                            maxLines: compact ? 3 : 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: Colors.grey.shade700),
                          ),
                        ],
                      ),
                    ),
                    if (trailing != null) trailing!,
                  ],
                ),
                const SizedBox(height: 14),
                child,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class MakeupWorkspacePage extends StatefulWidget {
  const MakeupWorkspacePage({
    super.key,
    required this.client,
    required this.currentUser,
    required this.locale,
    required this.baseUrl,
    required this.errorText,
  });

  final ApiClient client;
  final UserProfile currentUser;
  final Locale locale;
  final String baseUrl;
  final String Function(Object) errorText;

  @override
  State<MakeupWorkspacePage> createState() => _MakeupWorkspacePageState();
}

class _MakeupWorkspacePageState extends State<MakeupWorkspacePage> {
  final _noteController = TextEditingController();
  final _dateFormat = DateFormat('dd.MM.yyyy');

  Future<List<MakeupCaseDto>>? _casesFuture;
  List<String> _groups = [];
  String? _group;
  List<UserPublicProfile> _students = [];
  int? _studentId;
  final Set<DateTime> _classDates = {
    DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day),
  };
  String _status = 'all';
  String? _message;
  bool _messageError = false;
  Timer? _autoRefreshTimer;

  bool get _isRu => widget.locale.languageCode == 'ru';
  bool get _canManage =>
      widget.currentUser.role == 'teacher' ||
      widget.currentUser.role == 'admin';
  String _t(String ru, String en) => _isRu ? ru : en;

  @override
  void initState() {
    super.initState();
    _init();
    _autoRefreshTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (!mounted) return;
      _reload();
    });
  }

  @override
  void dispose() {
    _autoRefreshTimer?.cancel();
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    if (_canManage) {
      try {
        _groups = await widget.client.listMakeupGroups();
        _group = _groups.isNotEmpty ? _groups.first : null;
        if (_group == null) {
          _message = _t(
            'Нет доступных групп. Отправьте заявку на преподавание группы или дождитесь назначения от администратора.',
            'No groups available. Send a group access request or wait for admin assignment.',
          );
          _messageError = false;
        } else {
          _students = await widget.client.listMakeupStudentsByGroup(_group!);
          _studentId = _students.isNotEmpty ? _students.first.id : null;
          if (_students.isEmpty) {
            _message = _t(
              'В выбранной группе нет подтвержденных студентов.',
              'Selected group has no approved students.',
            );
            _messageError = true;
          }
        }
      } catch (error) {
        _message = widget.errorText(error);
        _messageError = true;
      }
    }
    if (mounted) _reload();
  }

  void _reload() {
    setState(() {
      _casesFuture = widget.client.listMakeups(
        groupName: _group,
        status: _status == 'all' ? null : _status,
      );
    });
  }

  Future<void> _pickDates() async {
    final picked = await showJournalMultiDatePicker(
      context,
      title: _t('Выберите даты отработки', 'Select makeup dates'),
      locale: widget.locale,
      initialDate: _classDates.isNotEmpty ? _classDates.first : DateTime.now(),
    );
    if (picked == null || picked.isEmpty) return;
    setState(() {
      _classDates
        ..clear()
        ..addAll(picked.map((d) => DateTime(d.year, d.month, d.day)).toList());
    });
  }

  Future<void> _createCase() async {
    if (_group == null) {
      setState(() {
        _message = _t('Сначала выберите группу.', 'Select group first.');
        _messageError = true;
      });
      return;
    }
    if (_studentId == null) {
      setState(() {
        _message = _t(
          'Нет доступных студентов. Нужны подтвержденные студенты в этой группе.',
          'No students available. Approved students are required in this group.',
        );
        _messageError = true;
      });
      return;
    }
    if (_classDates.isEmpty) {
      setState(() {
        _message = _t(
          'Выберите хотя бы одну дату отработки.',
          'Select at least one makeup date.',
        );
        _messageError = true;
      });
      return;
    }
    try {
      final dates = _classDates.toList()..sort();
      for (final date in dates) {
        await widget.client.createMakeup(
          studentId: _studentId!,
          groupName: _group!,
          classDate: date,
          teacherNote: _noteController.text.trim(),
        );
      }
      if (!mounted) return;
      _noteController.clear();
      _message = dates.length == 1
          ? _t('Отработка создана.', 'Makeup created.')
          : _t('Отработки созданы.', 'Makeups created.');
      _messageError = false;
      _reload();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _message = widget.errorText(error);
        _messageError = true;
      });
    }
  }

  Widget _messageBanner() {
    if (_message == null) return const SizedBox.shrink();
    final color = _messageError
        ? const Color(0xFFDC2626)
        : const Color(0xFF16A34A);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(_message!, style: TextStyle(color: color)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ModulePanel(
      title: _t('Отработки', 'Makeups'),
      subtitle: _t(
        'Отдельный процесс: справка, задание, выполнение, оценка и чат.',
        'Independent flow: proof, task, submission, grade and chat.',
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _messageBanner(),
          if (_canManage)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    SizedBox(
                      width: 220,
                      child: DropdownButtonFormField<String>(
                        initialValue: _group,
                        items: [
                          for (final group in _groups)
                            DropdownMenuItem(value: group, child: Text(group)),
                        ],
                        onChanged: (value) async {
                          if (value == null) return;
                          setState(() => _group = value);
                          try {
                            _students = await widget.client
                                .listMakeupStudentsByGroup(value);
                            _studentId = _students.isNotEmpty
                                ? _students.first.id
                                : null;
                            if (_students.isEmpty) {
                              _message = _t(
                                'В выбранной группе нет подтвержденных студентов.',
                                'Selected group has no approved students.',
                              );
                              _messageError = true;
                            } else {
                              _message = null;
                            }
                          } catch (error) {
                            _message = widget.errorText(error);
                            _messageError = true;
                          }
                          _reload();
                        },
                        decoration: InputDecoration(
                          labelText: _t('Группа', 'Group'),
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 260,
                      child: DropdownButtonFormField<int>(
                        initialValue: _studentId,
                        items: [
                          for (final student in _students)
                            DropdownMenuItem(
                              value: student.id,
                              child: Text(student.fullName),
                            ),
                        ],
                        onChanged: (value) =>
                            setState(() => _studentId = value),
                        decoration: InputDecoration(
                          labelText: _t('Студент', 'Student'),
                        ),
                      ),
                    ),
                    if (_students.isEmpty && _group != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          _t(
                            'Для этой группы нет подтвержденных студентов.',
                            'No approved students for this group.',
                          ),
                          style: const TextStyle(
                            color: Color(0xFFB45309),
                            fontSize: 12,
                          ),
                        ),
                      ),
                    OutlinedButton.icon(
                      onPressed: _pickDates,
                      icon: const Icon(Icons.event),
                      label: Text(
                        _classDates.length == 1
                            ? _dateFormat.format(_classDates.first)
                            : _t(
                                'Выбрано: ${_classDates.length}',
                                'Selected: ${_classDates.length}',
                              ),
                      ),
                    ),
                    FilledButton.icon(
                      onPressed: _createCase,
                      icon: const Icon(Icons.add),
                      label: Text(_t('Создать', 'Create')),
                    ),
                    SizedBox(
                      width: 320,
                      child: TextField(
                        controller: _noteController,
                        decoration: InputDecoration(
                          labelText: _t('Комментарий', 'Note'),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 10),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Wrap(
                spacing: 10,
                runSpacing: 10,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SizedBox(
                    width: 240,
                    child: DropdownButtonFormField<String>(
                      initialValue: _status,
                      items: [
                        DropdownMenuItem(
                          value: 'all',
                          child: Text(_t('Все статусы', 'All statuses')),
                        ),
                        for (final status in kMakeupStatuses)
                          DropdownMenuItem(
                            value: status,
                            child: Text(makeupStatusLabel(status, _isRu)),
                          ),
                      ],
                      onChanged: (value) {
                        if (value == null) return;
                        setState(() => _status = value);
                        _reload();
                      },
                      decoration: InputDecoration(
                        labelText: _t('Статус', 'Status'),
                      ),
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: _reload,
                    icon: const Icon(Icons.refresh),
                    label: Text(_t('Обновить', 'Refresh')),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          FutureBuilder<List<MakeupCaseDto>>(
            future: _casesFuture,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Padding(
                  padding: EdgeInsets.all(28),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              if (snapshot.hasError) {
                return Text(
                  _t('Ошибка загрузки отработок.', 'Failed to load makeups.'),
                );
              }
              final items = snapshot.data ?? [];
              if (items.isEmpty) {
                return Text(_t('Отработок пока нет.', 'No makeups yet.'));
              }
              return Column(
                children: [
                  for (final item in items)
                    Card(
                      margin: const EdgeInsets.only(bottom: 10),
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: makeupStatusColor(
                            item.status,
                          ).withValues(alpha: 0.15),
                          child: Icon(
                            Icons.assignment_late_outlined,
                            color: makeupStatusColor(item.status),
                          ),
                        ),
                        title: Text('${item.groupName} - ${item.studentName}'),
                        subtitle: Text(
                          '${_dateFormat.format(item.classDate)}\n${makeupStatusLabel(item.status, _isRu)}',
                        ),
                        trailing: IconButton(
                          icon: const Icon(Icons.open_in_new),
                          onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => MakeupCaseDetailScreen(
                                caseId: item.id,
                                client: widget.client,
                                currentUser: widget.currentUser,
                                locale: widget.locale,
                                baseUrl: widget.baseUrl,
                                errorText: widget.errorText,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class MakeupCaseDetailScreen extends StatefulWidget {
  const MakeupCaseDetailScreen({
    super.key,
    required this.caseId,
    required this.client,
    required this.currentUser,
    required this.locale,
    required this.baseUrl,
    required this.errorText,
  });

  final int caseId;
  final ApiClient client;
  final UserProfile currentUser;
  final Locale locale;
  final String baseUrl;
  final String Function(Object) errorText;

  @override
  State<MakeupCaseDetailScreen> createState() => _MakeupCaseDetailScreenState();
}

class _MakeupCaseDetailScreenState extends State<MakeupCaseDetailScreen> {
  final _taskController = TextEditingController();
  final _noteController = TextEditingController();
  final _gradeController = TextEditingController();
  final _gradeCommentController = TextEditingController();
  final _proofCommentController = TextEditingController();
  final _messageController = TextEditingController();

  final _dateFormat = DateFormat('dd.MM.yyyy');
  final _timeFormat = DateFormat('dd.MM.yyyy HH:mm');

  MakeupCaseDto? _item;
  List<MakeupMessageDto> _messages = const [];
  bool _messagesLoading = true;
  String _status = 'awaiting_proof';
  String? _message;
  bool _messageError = false;
  bool _saving = false;
  PlatformFile? _chatAttachment;
  Timer? _autoRefreshTimer;

  bool get _isRu => widget.locale.languageCode == 'ru';
  String _t(String ru, String en) => _isRu ? ru : en;
  bool get _canTeacherEdit =>
      widget.currentUser.role == 'teacher' ||
      widget.currentUser.role == 'admin';
  bool get _canStudentUpload {
    final item = _item;
    if (item == null) return false;
    return widget.currentUser.role == 'student' &&
        widget.currentUser.id == item.studentId;
  }

  bool _hasTeacherDraftChanges() {
    final item = _item;
    if (item == null) return false;
    return _status != item.status ||
        _taskController.text.trim() != (item.teacherTask ?? '').trim() ||
        _noteController.text.trim() != (item.teacherNote ?? '').trim() ||
        _gradeController.text.trim() != (item.grade ?? '').trim() ||
        _gradeCommentController.text.trim() != (item.gradeComment ?? '').trim();
  }

  @override
  void initState() {
    super.initState();
    _load(showMessageErrors: true, forceSyncDraftControllers: true);
    _autoRefreshTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!mounted || _saving) return;
      if (_canTeacherEdit && _hasTeacherDraftChanges()) {
        _refreshMessages(silent: true);
      } else {
        _load(showMessageErrors: false, forceSyncDraftControllers: false);
      }
    });
  }

  @override
  void dispose() {
    _autoRefreshTimer?.cancel();
    _taskController.dispose();
    _noteController.dispose();
    _gradeController.dispose();
    _gradeCommentController.dispose();
    _proofCommentController.dispose();
    _messageController.dispose();
    super.dispose();
  }

  String _caseSignature(MakeupCaseDto item) {
    return [
      item.id,
      item.status,
      item.teacherNote ?? '',
      item.teacherTask ?? '',
      item.studentSubmission ?? '',
      item.studentSubmissionUrl ?? '',
      item.grade ?? '',
      item.gradeComment ?? '',
      item.medicalProofUrl ?? '',
      item.medicalProofComment ?? '',
      item.teacherTaskAt?.toUtc().toIso8601String() ?? '',
      item.teacherNoteAt?.toUtc().toIso8601String() ?? '',
      item.proofSubmittedAt?.toUtc().toIso8601String() ?? '',
      item.submissionSentAt?.toUtc().toIso8601String() ?? '',
      item.gradeSetAt?.toUtc().toIso8601String() ?? '',
      item.updatedAt.toUtc().toIso8601String(),
    ].join('|');
  }

  String _messagesSignature(List<MakeupMessageDto> items) {
    return items
        .map(
          (message) => [
            message.id,
            message.senderId,
            message.body ?? '',
            message.attachmentUrl ?? '',
            message.createdAt.toUtc().toIso8601String(),
          ].join('|'),
        )
        .join('||');
  }

  Future<void> _load({
    required bool showMessageErrors,
    required bool forceSyncDraftControllers,
  }) async {
    try {
      final item = await widget.client.getMakeup(widget.caseId);
      final nextMessages = await widget.client.listMakeupMessages(
        widget.caseId,
      );
      if (!mounted) return;
      final oldItem = _item;
      final itemChanged =
          oldItem == null || _caseSignature(oldItem) != _caseSignature(item);
      final oldMessagesSignature = _messagesSignature(_messages);
      final newMessagesSignature = _messagesSignature(nextMessages);
      final shouldSyncControllers =
          forceSyncDraftControllers ||
          !(_canTeacherEdit && _hasTeacherDraftChanges());
      final needRebuild =
          itemChanged ||
          _item == null ||
          oldMessagesSignature != newMessagesSignature ||
          _messagesLoading;
      if (!needRebuild) {
        return;
      }
      setState(() {
        if (itemChanged) {
          _item = item;
          if (shouldSyncControllers) {
            _status = item.status;
            _taskController.text = item.teacherTask ?? '';
            _noteController.text = item.teacherNote ?? '';
            _gradeController.text = item.grade ?? '';
            _gradeCommentController.text = item.gradeComment ?? '';
          }
        } else {
          _item ??= item;
        }

        if (oldMessagesSignature != newMessagesSignature || _messagesLoading) {
          _messages = nextMessages;
        }
        _messagesLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      if (!showMessageErrors) return;
      setState(() {
        _message = widget.errorText(error);
        _messageError = true;
      });
    }
  }

  Future<void> _refreshMessages({bool silent = false}) async {
    try {
      final nextMessages = await widget.client.listMakeupMessages(
        widget.caseId,
      );
      if (!mounted) return;
      final oldSignature = _messagesSignature(_messages);
      final newSignature = _messagesSignature(nextMessages);
      if (oldSignature == newSignature && !_messagesLoading) {
        return;
      }
      setState(() {
        _messages = nextMessages;
        _messagesLoading = false;
      });
    } catch (error) {
      if (!mounted || silent) return;
      setState(() {
        _messageError = true;
        _message = widget.errorText(error);
      });
    }
  }

  String _mediaUrl(String? value) {
    var raw = (value ?? '').trim();
    if (raw.isEmpty) return '';

    final fromJson = _extractMediaPathFromJsonish(raw);
    if (fromJson.isNotEmpty) {
      raw = fromJson;
    } else if (raw.contains('{') || raw.contains(r'\"')) {
      return '';
    }

    if (raw.startsWith('http://') || raw.startsWith('https://')) {
      final uri = Uri.tryParse(raw);
      return uri == null ? '' : raw;
    }
    if (!raw.startsWith('/')) {
      raw = '/$raw';
    }
    final full = '${_mediaBaseUrl()}$raw';
    final uri = Uri.tryParse(full);
    if (uri == null || !uri.hasScheme) {
      return '';
    }
    return full;
  }

  String _mediaBaseUrl() {
    final parsed = Uri.tryParse(widget.baseUrl.trim());
    if (parsed == null) {
      return widget.baseUrl.trim().replaceFirst(RegExp(r'/+$'), '');
    }
    var path = parsed.path.replaceFirst(RegExp(r'/+$'), '');
    if (path.endsWith('/api')) {
      path = path.substring(0, path.length - 4);
    }
    final normalized = parsed.replace(path: path, query: null, fragment: null);
    return normalized.toString().replaceFirst(RegExp(r'/+$'), '');
  }

  String _extractMediaPathFromJsonish(String raw) {
    dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      try {
        decoded = jsonDecode(raw.replaceAll(r'\"', '"').replaceAll(r'\/', '/'));
      } catch (_) {
        final match = RegExp(r'\\?/media/makeup/[^"\\\s]+').firstMatch(raw);
        return match?.group(0)?.replaceAll(r'\/', '/') ?? '';
      }
    }

    if (decoded is String) {
      try {
        decoded = jsonDecode(decoded);
      } catch (_) {
        final match = RegExp(r'\\?/media/makeup/[^"\\\s]+').firstMatch(decoded);
        return match?.group(0)?.replaceAll(r'\/', '/') ?? '';
      }
    }

    if (decoded is Map<String, dynamic>) {
      for (final key in const [
        'medical_proof_url',
        'student_submission_url',
        'attachment_url',
      ]) {
        final candidate = decoded[key];
        if (candidate is String && candidate.trim().isNotEmpty) {
          return candidate.trim();
        }
      }
    }
    return '';
  }

  bool _isImageUrl(String url) {
    final clean = url.toLowerCase().split('?').first;
    return clean.endsWith('.png') ||
        clean.endsWith('.jpg') ||
        clean.endsWith('.jpeg') ||
        clean.endsWith('.gif') ||
        clean.endsWith('.webp') ||
        clean.endsWith('.bmp');
  }

  String _fileNameFromUrl(String url) {
    final parsed = Uri.tryParse(url);
    if (parsed == null) return url;
    if (parsed.pathSegments.isEmpty) return url;
    return parsed.pathSegments.last;
  }

  Future<void> _openAttachment(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) {
      if (!mounted) return;
      setState(() {
        _messageError = true;
        _message = _t('Некорректный URL файла.', 'Invalid attachment URL.');
      });
      return;
    }
    final opened = await launchUrl(uri, mode: LaunchMode.platformDefault);
    if (!opened && mounted) {
      setState(() {
        _messageError = true;
        _message = _t('Не удалось открыть файл.', 'Failed to open file.');
      });
    }
  }

  Widget _buildAttachmentPreview({
    required String title,
    required String? rawUrl,
    bool compact = false,
    String? meta,
  }) {
    final url = _mediaUrl(rawUrl);
    if (url.isEmpty) return const SizedBox.shrink();
    final image = _isImageUrl(url);
    final border = BorderRadius.circular(compact ? 10 : 14);

    if (image) {
      return Container(
        margin: EdgeInsets.only(top: compact ? 6 : 10),
        padding: EdgeInsets.all(compact ? 8 : 10),
        decoration: BoxDecoration(
          color: const Color(0xFFF8FAFC),
          borderRadius: border,
          border: Border.all(color: const Color(0xFFE5E7EB)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
            if ((meta ?? '').trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  meta!,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF6B7280),
                  ),
                ),
              ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: AspectRatio(
                aspectRatio: compact ? 16 / 10 : 16 / 9,
                child: Image.network(
                  url,
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stackTrace) => Container(
                    color: const Color(0xFFE5E7EB),
                    alignment: Alignment.center,
                    child: Text(_t('Не удалось загрузить', 'Failed to load')),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: OutlinedButton.icon(
                onPressed: () => _openAttachment(url),
                icon: const Icon(Icons.open_in_new, size: 16),
                label: Text(_t('Открыть', 'Open')),
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      margin: EdgeInsets.only(top: compact ? 6 : 10),
      padding: EdgeInsets.all(compact ? 8 : 10),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: border,
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Row(
        children: [
          const Icon(Icons.insert_drive_file_outlined),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$title: ${_fileNameFromUrl(url)}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if ((meta ?? '').trim().isNotEmpty)
                  Text(
                    meta!,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF6B7280),
                    ),
                  ),
              ],
            ),
          ),
          IconButton(
            tooltip: _t('Открыть', 'Open'),
            onPressed: () => _openAttachment(url),
            icon: const Icon(Icons.open_in_new),
          ),
        ],
      ),
    );
  }

  Future<void> _openUserProfile(int userId) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => UserPublicProfileScreen(
          userId: userId,
          client: widget.client,
          locale: widget.locale,
          errorText: widget.errorText,
        ),
      ),
    );
  }

  Future<void> _saveTeacherChanges() async {
    final item = _item;
    if (item == null || !_canTeacherEdit) return;
    setState(() => _saving = true);
    try {
      final updated = await widget.client.updateMakeup(item.id, {
        'status': _status,
        'teacher_task': _taskController.text.trim(),
        'teacher_note': _noteController.text.trim(),
        'grade': _gradeController.text.trim(),
        'grade_comment': _gradeCommentController.text.trim(),
      });
      if (!mounted) return;
      setState(() {
        _item = updated;
        _messageError = false;
        _message = _t('Изменения сохранены.', 'Changes saved.');
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _messageError = true;
        _message = widget.errorText(error);
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _uploadProof() async {
    final item = _item;
    if (item == null || !_canStudentUpload) return;
    final picked = await FilePicker.platform.pickFiles(withData: true);
    if (picked == null ||
        picked.files.isEmpty ||
        picked.files.first.bytes == null) {
      return;
    }
    setState(() => _saving = true);
    try {
      final updated = await widget.client.uploadMakeupProof(
        caseId: item.id,
        filename: picked.files.first.name,
        bytes: picked.files.first.bytes!,
        comment: _proofCommentController.text.trim(),
      );
      if (!mounted) return;
      setState(() {
        _item = updated;
        _messageError = false;
        _message = _t('Справка отправлена.', 'Proof uploaded.');
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _messageError = true;
        _message = widget.errorText(error);
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _uploadSubmission() async {
    final item = _item;
    if (item == null || !_canStudentUpload) return;
    final textController = TextEditingController();
    PlatformFile? file;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_t('Отправить выполнение', 'Send submission')),
        content: StatefulBuilder(
          builder: (context, setStateDialog) => SizedBox(
            width: 560,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: textController,
                  maxLines: 4,
                  decoration: InputDecoration(
                    labelText: _t('Комментарий', 'Comment'),
                  ),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () async {
                    final picked = await FilePicker.platform.pickFiles(
                      withData: true,
                    );
                    if (picked == null || picked.files.isEmpty) return;
                    setStateDialog(() => file = picked.files.first);
                  },
                  icon: const Icon(Icons.attach_file),
                  label: Text(file?.name ?? _t('Выбрать файл', 'Select file')),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(_t('Отмена', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(_t('Отправить', 'Send')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _saving = true);
    try {
      final updated = await widget.client.uploadMakeupSubmission(
        caseId: item.id,
        text: textController.text.trim(),
        filename: file?.name,
        bytes: file?.bytes,
      );
      if (!mounted) return;
      setState(() {
        _item = updated;
        _messageError = false;
        _message = _t('Выполнение отправлено.', 'Submission sent.');
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _messageError = true;
        _message = widget.errorText(error);
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _sendMessage() async {
    final item = _item;
    if (item == null) return;
    if (_messageController.text.trim().isEmpty &&
        (_chatAttachment?.bytes == null)) {
      return;
    }
    setState(() => _saving = true);
    try {
      await widget.client.sendMakeupMessage(
        caseId: item.id,
        text: _messageController.text.trim(),
        filename: _chatAttachment?.name,
        bytes: _chatAttachment?.bytes,
      );
      if (!mounted) return;
      _messageController.clear();
      setState(() {
        _chatAttachment = null;
        _messageError = false;
        _message = _t('Сообщение отправлено.', 'Message sent.');
      });
      _refreshMessages();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _messageError = true;
        _message = widget.errorText(error);
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _messageBanner() {
    if (_message == null) return const SizedBox.shrink();
    final color = _messageError
        ? const Color(0xFFDC2626)
        : const Color(0xFF16A34A);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(_message!, style: TextStyle(color: color)),
    );
  }

  String? _fmtActionAt(DateTime? value) {
    if (value == null) return null;
    return _t(
      'Время: ${_timeFormat.format(value.toLocal())}',
      'Time: ${_timeFormat.format(value.toLocal())}',
    );
  }

  Widget _statusBadge(String status) {
    final color = makeupStatusColor(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        makeupStatusLabel(status, _isRu),
        style: TextStyle(color: color, fontWeight: FontWeight.w700),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final item = _item;
    final teacherNoteText = (item?.teacherNote ?? '').trim();
    final teacherTaskText = (item?.teacherTask ?? '').trim();
    final submissionText = (item?.studentSubmission ?? '').trim();
    final gradeText = (item?.grade ?? '').trim();
    final gradeCommentText = (item?.gradeComment ?? '').trim();
    final canSendProof =
        item != null &&
        _canStudentUpload &&
        (item.status == 'awaiting_proof' ||
            item.status == 'proof_submitted' ||
            item.status == 'rejected');
    final canSendSubmission =
        item != null &&
        _canStudentUpload &&
        (item.status == 'task_assigned' || item.status == 'submission_sent');
    return ModulePanel(
      title: _t('Отработка #${widget.caseId}', 'Makeup #${widget.caseId}'),
      subtitle: _t(
        'Процесс: справка, задание, выполнение, оценка и чат.',
        'Flow: proof, task, submission, grade and chat.',
      ),
      child: item == null
          ? const Center(child: CircularProgressIndicator())
          : Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: double.infinity,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        OutlinedButton.icon(
                          onPressed: () => Navigator.of(context).maybePop(),
                          icon: const Icon(Icons.arrow_back),
                          label: Text(_t('Назад', 'Back')),
                        ),
                        _statusBadge(item.status),
                        Text(
                          '${_t('Дата', 'Date')}: ${_dateFormat.format(item.classDate)}  •  ${_t('Группа', 'Group')}: ${item.groupName}',
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    _messageBanner(),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${_t('Дата', 'Date')}: ${_dateFormat.format(item.classDate)}  •  ${_t('Группа', 'Group')}: ${item.groupName}',
                            ),
                            const SizedBox(height: 6),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                TextButton(
                                  onPressed: () =>
                                      _openUserProfile(item.teacherId),
                                  child: Text(
                                    '${_t('Преподаватель', 'Teacher')}: ${item.teacherName}',
                                  ),
                                ),
                                TextButton(
                                  onPressed: () =>
                                      _openUserProfile(item.studentId),
                                  child: Text(
                                    '${_t('Студент', 'Student')}: ${item.studentName}',
                                  ),
                                ),
                              ],
                            ),
                            if (teacherTaskText.isNotEmpty ||
                                _canStudentUpload) ...[
                              const SizedBox(height: 8),
                              Container(
                                width: double.infinity,
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFEFF6FF),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: const Color(0xFFBFDBFE),
                                  ),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      _t(
                                        'Задание преподавателя',
                                        'Teacher task',
                                      ),
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    if (_fmtActionAt(item.teacherTaskAt) !=
                                        null)
                                      Padding(
                                        padding: const EdgeInsets.only(top: 2),
                                        child: Text(
                                          _fmtActionAt(item.teacherTaskAt)!,
                                          style: const TextStyle(
                                            fontSize: 12,
                                            color: Color(0xFF6B7280),
                                          ),
                                        ),
                                      ),
                                    const SizedBox(height: 6),
                                    Text(
                                      teacherTaskText.isEmpty
                                          ? _t(
                                              'Задание пока не назначено.',
                                              'Task has not been assigned yet.',
                                            )
                                          : teacherTaskText,
                                    ),
                                  ],
                                ),
                              ),
                            ],
                            if (teacherNoteText.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Container(
                                width: double.infinity,
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFFFF7ED),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: const Color(0xFFFED7AA),
                                  ),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      _t(
                                        'Комментарий преподавателя',
                                        'Teacher comment',
                                      ),
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    if (_fmtActionAt(item.teacherNoteAt) !=
                                        null)
                                      Padding(
                                        padding: const EdgeInsets.only(top: 2),
                                        child: Text(
                                          _fmtActionAt(item.teacherNoteAt)!,
                                          style: const TextStyle(
                                            fontSize: 12,
                                            color: Color(0xFF6B7280),
                                          ),
                                        ),
                                      ),
                                    const SizedBox(height: 6),
                                    Text(teacherNoteText),
                                  ],
                                ),
                              ),
                            ],
                            if (submissionText.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Container(
                                width: double.infinity,
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFF8FAFC),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: const Color(0xFFE2E8F0),
                                  ),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      _t(
                                        'Текст выполнения студента',
                                        'Student submission text',
                                      ),
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    Text(submissionText),
                                  ],
                                ),
                              ),
                            ],
                            if (gradeText.isNotEmpty ||
                                gradeCommentText.isNotEmpty ||
                                item.status == 'graded') ...[
                              const SizedBox(height: 8),
                              Container(
                                width: double.infinity,
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFECFDF3),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: const Color(0xFFA7F3D0),
                                  ),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      _t('Результат проверки', 'Review result'),
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    if (_fmtActionAt(item.gradeSetAt) != null)
                                      Padding(
                                        padding: const EdgeInsets.only(top: 2),
                                        child: Text(
                                          _fmtActionAt(item.gradeSetAt)!,
                                          style: const TextStyle(
                                            fontSize: 12,
                                            color: Color(0xFF6B7280),
                                          ),
                                        ),
                                      ),
                                    const SizedBox(height: 6),
                                    Text(
                                      '${_t('Оценка', 'Grade')}: ${gradeText.isEmpty ? '-' : gradeText}',
                                    ),
                                    if (gradeCommentText.isNotEmpty)
                                      Padding(
                                        padding: const EdgeInsets.only(top: 4),
                                        child: Text(
                                          '${_t('Комментарий', 'Comment')}: $gradeCommentText',
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ],
                            _buildAttachmentPreview(
                              title: _t('Справка', 'Proof'),
                              rawUrl: item.medicalProofUrl,
                              meta: _fmtActionAt(item.proofSubmittedAt),
                            ),
                            _buildAttachmentPreview(
                              title: _t('Файл выполнения', 'Submission file'),
                              rawUrl: item.studentSubmissionUrl,
                              meta: _fmtActionAt(item.submissionSentAt),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    if (_canTeacherEdit)
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _t('Действия преподавателя', 'Teacher actions'),
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 8),
                              DropdownButtonFormField<String>(
                                initialValue: _status,
                                items: [
                                  for (final status in kMakeupStatuses)
                                    DropdownMenuItem(
                                      value: status,
                                      child: Text(
                                        makeupStatusLabel(status, _isRu),
                                      ),
                                    ),
                                ],
                                onChanged: (value) =>
                                    setState(() => _status = value ?? _status),
                                decoration: InputDecoration(
                                  labelText: _t('Статус', 'Status'),
                                ),
                              ),
                              const SizedBox(height: 8),
                              TextField(
                                controller: _taskController,
                                maxLines: 2,
                                decoration: InputDecoration(
                                  labelText: _t('Задание', 'Task'),
                                ),
                              ),
                              const SizedBox(height: 8),
                              TextField(
                                controller: _noteController,
                                decoration: InputDecoration(
                                  labelText: _t(
                                    'Комментарий для студента',
                                    'Comment for student',
                                  ),
                                ),
                              ),
                              const SizedBox(height: 8),
                              TextField(
                                controller: _gradeController,
                                decoration: InputDecoration(
                                  labelText: _t('Оценка', 'Grade'),
                                ),
                              ),
                              const SizedBox(height: 8),
                              TextField(
                                controller: _gradeCommentController,
                                decoration: InputDecoration(
                                  labelText: _t(
                                    'Комментарий к оценке',
                                    'Grade comment',
                                  ),
                                ),
                              ),
                              const SizedBox(height: 10),
                              FilledButton.icon(
                                onPressed: _saving ? null : _saveTeacherChanges,
                                icon: const Icon(Icons.save_outlined),
                                label: Text(_t('Сохранить', 'Save')),
                              ),
                            ],
                          ),
                        ),
                      ),
                    if (_canTeacherEdit) const SizedBox(height: 10),
                    if (_canStudentUpload)
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _t('Действия студента', 'Student actions'),
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                canSendSubmission
                                    ? _t(
                                        'Можно отправить выполненное задание.',
                                        'You can submit your completed task.',
                                      )
                                    : _t(
                                        'Сначала отправьте справку и дождитесь задания преподавателя.',
                                        'First send proof and wait for a teacher task.',
                                      ),
                                style: const TextStyle(
                                  color: Color(0xFF4B5563),
                                ),
                              ),
                              const SizedBox(height: 8),
                              TextField(
                                controller: _proofCommentController,
                                decoration: InputDecoration(
                                  labelText: _t(
                                    'Комментарий к справке',
                                    'Proof comment',
                                  ),
                                ),
                              ),
                              const SizedBox(height: 10),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  FilledButton.tonalIcon(
                                    onPressed: (_saving || !canSendProof)
                                        ? null
                                        : _uploadProof,
                                    icon: const Icon(
                                      Icons.medical_services_outlined,
                                    ),
                                    label: Text(
                                      _t('Отправить справку', 'Send proof'),
                                    ),
                                  ),
                                  FilledButton.tonalIcon(
                                    onPressed: (_saving || !canSendSubmission)
                                        ? null
                                        : _uploadSubmission,
                                    icon: const Icon(
                                      Icons.upload_file_outlined,
                                    ),
                                    label: Text(
                                      _t(
                                        'Отправить выполнение',
                                        'Send submission',
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    if (_canStudentUpload) const SizedBox(height: 10),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Text(
                                  _t('Чат', 'Chat'),
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  _t(
                                    'Автообновление каждые 3 сек',
                                    'Auto-refresh every 3s',
                                  ),
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: Color(0xFF6B7280),
                                  ),
                                ),
                                const Spacer(),
                                IconButton(
                                  onPressed: () => _refreshMessages(),
                                  icon: const Icon(Icons.refresh),
                                ),
                              ],
                            ),
                            if (_messagesLoading)
                              const Padding(
                                padding: EdgeInsets.all(18),
                                child: Center(
                                  child: CircularProgressIndicator(),
                                ),
                              )
                            else if (_messages.isEmpty)
                              Text(
                                _t('Сообщений пока нет.', 'No messages yet.'),
                              )
                            else
                              Column(
                                children: [
                                  for (final message in _messages)
                                    Align(
                                      alignment:
                                          message.senderId ==
                                              widget.currentUser.id
                                          ? Alignment.centerRight
                                          : Alignment.centerLeft,
                                      child: Container(
                                        margin: const EdgeInsets.only(
                                          bottom: 8,
                                        ),
                                        padding: const EdgeInsets.all(10),
                                        constraints: const BoxConstraints(
                                          maxWidth: 640,
                                        ),
                                        decoration: BoxDecoration(
                                          color:
                                              message.senderId ==
                                                  widget.currentUser.id
                                              ? const Color(0xFFDDEFE8)
                                              : const Color(0xFFE5EEE6),
                                          borderRadius: BorderRadius.circular(
                                            10,
                                          ),
                                        ),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              message.senderName,
                                              style: const TextStyle(
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                            if ((message.body ?? '').isNotEmpty)
                                              Padding(
                                                padding: const EdgeInsets.only(
                                                  top: 4,
                                                ),
                                                child: Text(message.body!),
                                              ),
                                            _buildAttachmentPreview(
                                              title: _t(
                                                'Вложение',
                                                'Attachment',
                                              ),
                                              rawUrl: message.attachmentUrl,
                                              compact: true,
                                            ),
                                            Text(
                                              _timeFormat.format(
                                                message.createdAt,
                                              ),
                                              style: const TextStyle(
                                                fontSize: 11,
                                                color: Color(0xFF6B7280),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            const SizedBox(height: 8),
                            TextField(
                              controller: _messageController,
                              maxLines: 2,
                              decoration: InputDecoration(
                                labelText: _t('Сообщение', 'Message'),
                              ),
                            ),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                OutlinedButton.icon(
                                  onPressed: () async {
                                    final picked = await FilePicker.platform
                                        .pickFiles(withData: true);
                                    if (picked == null ||
                                        picked.files.isEmpty) {
                                      return;
                                    }
                                    setState(
                                      () =>
                                          _chatAttachment = picked.files.first,
                                    );
                                  },
                                  icon: const Icon(Icons.attach_file),
                                  label: Text(
                                    _chatAttachment?.name ??
                                        _t('Файл', 'Attachment'),
                                  ),
                                ),
                                FilledButton.icon(
                                  onPressed: _saving ? null : _sendMessage,
                                  icon: const Icon(Icons.send_outlined),
                                  label: Text(_t('Отправить', 'Send')),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}

class UserPublicProfileScreen extends StatelessWidget {
  const UserPublicProfileScreen({
    super.key,
    required this.userId,
    required this.client,
    required this.locale,
    required this.errorText,
  });

  final int userId;
  final ApiClient client;
  final Locale locale;
  final String Function(Object) errorText;

  @override
  Widget build(BuildContext context) {
    final isRu = locale.languageCode == 'ru';
    String t(String ru, String en) => isRu ? ru : en;
    return ModulePanel(
      title: t('Профиль пользователя', 'User profile'),
      subtitle: t('Публичная информация пользователя.', 'Public user info.'),
      child: FutureBuilder<UserPublicProfile>(
        future: client.getUserPublic(userId),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Text(errorText(snapshot.error!));
          }
          final user = snapshot.data;
          if (user == null) {
            return Text(t('Профиль не найден.', 'Profile not found.'));
          }
          return Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const CircleAvatar(
                        radius: 30,
                        child: Icon(Icons.person_outline, size: 30),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              user.fullName,
                              style: const TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            Text('${t('Роль', 'Role')}: ${user.role}'),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if ((user.studentGroup ?? '').isNotEmpty)
                    Text('${t('Группа', 'Group')}: ${user.studentGroup}'),
                  if ((user.teacherName ?? '').isNotEmpty)
                    Text('${t('Куратор', 'Curator')}: ${user.teacherName}'),
                  if ((user.about ?? '').isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text('${t('О себе', 'About')}: ${user.about}'),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class AdminWorkspacePage extends StatefulWidget {
  const AdminWorkspacePage({
    super.key,
    required this.client,
    required this.currentUser,
    required this.locale,
    required this.baseUrl,
    required this.errorText,
  });

  final ApiClient client;
  final UserProfile currentUser;
  final Locale locale;
  final String baseUrl;
  final String Function(Object) errorText;

  @override
  State<AdminWorkspacePage> createState() => _AdminWorkspacePageState();
}

class _AdminWorkspacePageState extends State<AdminWorkspacePage> {
  int _tab = 0;
  String _userRole = 'all';
  String _userApproval = 'all';
  String _userSort = 'id_asc';
  String _makeupStatus = 'all';
  String? _noticeMessage;
  bool _noticeError = false;
  Future<List<UserProfile>>? _usersFuture;
  Future<List<RequestTicket>>? _requestsFuture;
  Future<List<MakeupCaseDto>>? _makeupsFuture;
  Future<List<TeacherGroupAssignment>>? _assignmentsFuture;
  Future<List<UserProfile>>? _teachersFuture;
  Future<List<NewsPost>>? _newsFuture;
  Future<List<ExamUpload>>? _examUploadsFuture;
  Future<List<DepartmentDto>>? _departmentsFuture;
  Future<List<CuratorGroupAssignmentDto>>? _curatorGroupsFuture;
  Future<List<ScheduleUpload>>? _scheduleUploadsFuture;
  Future<List<AttendanceRecord>>? _attendanceCrudFuture;
  Future<List<GradeRecord>>? _gradesCrudFuture;
  Future<List<GroupAnalytics>>? _analyticsGroupsFuture;
  Future<List<AttendanceRecord>>? _analyticsAttendanceFuture;
  Future<List<GradeRecord>>? _analyticsGradesFuture;

  Future<List<String>>? _journalGroupsFuture;
  Future<List<String>>? _journalStudentsFuture;
  Future<List<DateTime>>? _journalDatesFuture;
  String? _journalGroup;

  bool get _isRu => widget.locale.languageCode == 'ru';
  String _t(String ru, String en) => _isRu ? ru : en;
  String _readError(Object error) => widget.errorText(error);

  @override
  void initState() {
    super.initState();
    _reloadAll();
  }

  void _reloadAll() {
    _usersFuture = widget.client.listUsers(
      role: _userRole == 'all' ? null : _userRole,
      approved: _userApproval == 'all' ? null : (_userApproval == 'approved'),
      sort: _userSort,
    );
    _requestsFuture = widget.client.listRequests();
    _makeupsFuture = widget.client.listMakeups(
      status: _makeupStatus == 'all' ? null : _makeupStatus,
    );
    _assignmentsFuture = widget.client.listTeacherAssignments();
    _teachersFuture = widget.client.listUsers(role: 'teacher', approved: true);
    _newsFuture = widget.client.listNews(limit: 100);
    _examUploadsFuture = widget.client.listExamUploads();
    _departmentsFuture = widget.client.listDepartments();
    _curatorGroupsFuture = widget.client.listCuratorGroups();
    _scheduleUploadsFuture = widget.client.listScheduleUploads();
    _analyticsGroupsFuture = widget.client.listAnalyticsGroups();
    _journalGroupsFuture = widget.client.listJournalGroups();
    _setJournalGroupSelection(_journalGroup);
    setState(() {});
  }

  Future<void> _createUser() async {
    List<UserPublicProfile> approvedStudents = const [];
    try {
      approvedStudents = await widget.client.listApprovedStudents();
    } catch (error) {
      if (mounted) {
        setState(() {
          _noticeError = true;
          _noticeMessage = _readError(error);
        });
      }
      return;
    }
    String role = 'student';
    bool isApproved = true;
    final fullNameController = TextEditingController();
    final emailController = TextEditingController();
    final passwordController = TextEditingController();
    final groupController = TextEditingController();
    final teacherController = TextEditingController();
    final childController = TextEditingController();
    int? selectedParentStudentId = approvedStudents.isNotEmpty
        ? approvedStudents.first.id
        : null;
    if (selectedParentStudentId != null) {
      final first = approvedStudents.first;
      childController.text = first.fullName;
      groupController.text = first.studentGroup ?? '';
    }
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(_t('Создать пользователя', 'Create user')),
          content: SizedBox(
            width: 520,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: role,
                  items: const [
                    DropdownMenuItem(value: 'admin', child: Text('admin')),
                    DropdownMenuItem(value: 'teacher', child: Text('teacher')),
                    DropdownMenuItem(value: 'student', child: Text('student')),
                    DropdownMenuItem(value: 'parent', child: Text('parent')),
                    DropdownMenuItem(value: 'smm', child: Text('smm')),
                    DropdownMenuItem(
                      value: 'request_handler',
                      child: Text('request_handler'),
                    ),
                  ],
                  onChanged: (value) =>
                      setDialogState(() => role = value ?? role),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: fullNameController,
                  decoration: InputDecoration(
                    labelText: _t('ФИО', 'Full name'),
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: emailController,
                  decoration: InputDecoration(labelText: _t('Email', 'Email')),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: passwordController,
                  decoration: InputDecoration(
                    labelText: _t('Пароль', 'Password'),
                  ),
                  obscureText: true,
                ),
                const SizedBox(height: 8),
                if (role == 'student')
                  TextField(
                    controller: groupController,
                    decoration: InputDecoration(
                      labelText: _t('Группа', 'Group'),
                    ),
                  ),
                if (role == 'teacher')
                  TextField(
                    controller: teacherController,
                    decoration: InputDecoration(
                      labelText: _t('ФИО преподавателя', 'Teacher name'),
                    ),
                  ),
                if (role == 'parent') ...[
                  DropdownButtonFormField<int>(
                    initialValue:
                        approvedStudents.any(
                          (s) => s.id == selectedParentStudentId,
                        )
                        ? selectedParentStudentId
                        : null,
                    items: [
                      for (final student in approvedStudents)
                        DropdownMenuItem(
                          value: student.id,
                          child: Text(
                            '${student.fullName}'
                            '${(student.studentGroup ?? '').isEmpty ? '' : ' (${student.studentGroup})'}',
                          ),
                        ),
                    ],
                    onChanged: approvedStudents.isEmpty
                        ? null
                        : (value) => setDialogState(() {
                            selectedParentStudentId = value;
                            final selected = approvedStudents
                                .where((s) => s.id == value)
                                .cast<UserPublicProfile?>()
                                .firstWhere(
                                  (s) => s != null,
                                  orElse: () => null,
                                );
                            if (selected != null) {
                              childController.text = selected.fullName;
                              groupController.text =
                                  selected.studentGroup ?? '';
                            }
                          }),
                    decoration: InputDecoration(
                      labelText: _t(
                        'Подтвержденный студент',
                        'Approved student',
                      ),
                    ),
                  ),
                  if (approvedStudents.isEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      _t(
                        'Нет подтвержденных студентов. Сначала подтвердите студентов.',
                        'No approved students. Approve students first.',
                      ),
                      style: const TextStyle(
                        color: Color(0xFFB45309),
                        fontSize: 12,
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  TextField(
                    controller: childController,
                    readOnly: true,
                    decoration: InputDecoration(
                      labelText: _t('ФИО ребенка', 'Child full name'),
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                SwitchListTile.adaptive(
                  value: isApproved,
                  onChanged: (value) =>
                      setDialogState(() => isApproved = value),
                  title: Text(_t('Подтвержден', 'Approved')),
                  contentPadding: EdgeInsets.zero,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(_t('Отмена', 'Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(_t('Создать', 'Create')),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    if (role == 'parent' && (selectedParentStudentId ?? 0) == 0) {
      if (mounted) {
        setState(() {
          _noticeError = true;
          _noticeMessage = _t(
            'Для родителя нужно выбрать подтвержденного студента.',
            'Parent account requires selecting an approved student.',
          );
        });
      }
      return;
    }
    await widget.client.createUserAsAdmin(
      role: role,
      fullName: fullNameController.text.trim(),
      email: emailController.text.trim(),
      password: passwordController.text.trim(),
      studentGroup: role == 'student' ? groupController.text.trim() : null,
      teacherName: role == 'teacher' ? teacherController.text.trim() : null,
      childFullName: role == 'parent' ? childController.text.trim() : null,
      parentStudentId: role == 'parent' ? selectedParentStudentId : null,
      isApproved: isApproved,
    );
    if (mounted) {
      setState(() {
        _noticeError = false;
        _noticeMessage = _t('Пользователь создан.', 'User created.');
      });
    }
    _reloadAll();
  }

  Future<void> _editUser(UserProfile user) async {
    List<UserPublicProfile> approvedStudents = const [];
    try {
      approvedStudents = await widget.client.listApprovedStudents();
    } catch (error) {
      if (mounted) {
        setState(() {
          _noticeError = true;
          _noticeMessage = _readError(error);
        });
      }
      return;
    }
    String role = user.role;
    final fullNameController = TextEditingController(text: user.fullName);
    final emailController = TextEditingController(text: user.email);
    final passwordController = TextEditingController();
    final phoneController = TextEditingController(text: user.phone ?? '');
    final groupController = TextEditingController(
      text: user.studentGroup ?? '',
    );
    final teacherController = TextEditingController(
      text: user.teacherName ?? '',
    );
    final childController = TextEditingController(
      text: user.childFullName ?? '',
    );
    int? selectedParentStudentId = user.parentStudentId;
    if (selectedParentStudentId != null) {
      for (final student in approvedStudents) {
        if (student.id == selectedParentStudentId) {
          childController.text = student.fullName;
          groupController.text = student.studentGroup ?? '';
          break;
        }
      }
    }
    final aboutController = TextEditingController(text: user.about ?? '');
    bool isApproved = user.isApproved ?? true;
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(_t('Редактировать пользователя', 'Edit user')),
          content: SizedBox(
            width: 560,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: role,
                  items: const [
                    DropdownMenuItem(value: 'admin', child: Text('admin')),
                    DropdownMenuItem(value: 'teacher', child: Text('teacher')),
                    DropdownMenuItem(value: 'student', child: Text('student')),
                    DropdownMenuItem(value: 'parent', child: Text('parent')),
                    DropdownMenuItem(value: 'smm', child: Text('smm')),
                    DropdownMenuItem(
                      value: 'request_handler',
                      child: Text('request_handler'),
                    ),
                  ],
                  onChanged: (value) =>
                      setDialogState(() => role = value ?? role),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: fullNameController,
                  decoration: InputDecoration(
                    labelText: _t('ФИО', 'Full name'),
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: emailController,
                  decoration: InputDecoration(labelText: _t('Email', 'Email')),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: passwordController,
                  decoration: InputDecoration(
                    labelText: _t(
                      'Новый пароль (необязательно)',
                      'New password (optional)',
                    ),
                  ),
                  obscureText: true,
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: phoneController,
                  decoration: InputDecoration(
                    labelText: _t('Телефон', 'Phone'),
                  ),
                ),
                const SizedBox(height: 8),
                if (role == 'student') ...[
                  TextField(
                    controller: groupController,
                    decoration: InputDecoration(
                      labelText: _t('Группа', 'Group'),
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
                if (role == 'teacher') ...[
                  TextField(
                    controller: teacherController,
                    decoration: InputDecoration(
                      labelText: _t('ФИО преподавателя', 'Teacher name'),
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
                if (role == 'parent') ...[
                  DropdownButtonFormField<int>(
                    initialValue:
                        approvedStudents.any(
                          (s) => s.id == selectedParentStudentId,
                        )
                        ? selectedParentStudentId
                        : null,
                    items: [
                      for (final student in approvedStudents)
                        DropdownMenuItem(
                          value: student.id,
                          child: Text(
                            '${student.fullName}'
                            '${(student.studentGroup ?? '').isEmpty ? '' : ' (${student.studentGroup})'}',
                          ),
                        ),
                    ],
                    onChanged: approvedStudents.isEmpty
                        ? null
                        : (value) => setDialogState(() {
                            selectedParentStudentId = value;
                            final selected = approvedStudents
                                .where((s) => s.id == value)
                                .cast<UserPublicProfile?>()
                                .firstWhere(
                                  (s) => s != null,
                                  orElse: () => null,
                                );
                            if (selected != null) {
                              childController.text = selected.fullName;
                              groupController.text =
                                  selected.studentGroup ?? '';
                            }
                          }),
                    decoration: InputDecoration(
                      labelText: _t(
                        'Подтвержденный студент',
                        'Approved student',
                      ),
                    ),
                  ),
                  if (approvedStudents.isEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      _t(
                        'Нет подтвержденных студентов. Сначала подтвердите студентов.',
                        'No approved students. Approve students first.',
                      ),
                      style: const TextStyle(
                        color: Color(0xFFB45309),
                        fontSize: 12,
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  TextField(
                    controller: childController,
                    readOnly: true,
                    decoration: InputDecoration(
                      labelText: _t('ФИО ребенка', 'Child full name'),
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
                TextField(
                  controller: aboutController,
                  decoration: InputDecoration(labelText: _t('О себе', 'About')),
                ),
                const SizedBox(height: 8),
                SwitchListTile.adaptive(
                  value: isApproved,
                  onChanged: (value) =>
                      setDialogState(() => isApproved = value),
                  title: Text(_t('Подтвержден', 'Approved')),
                  contentPadding: EdgeInsets.zero,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(_t('Отмена', 'Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(_t('Сохранить', 'Save')),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    if (role == 'parent' && (selectedParentStudentId ?? 0) == 0) {
      if (mounted) {
        setState(() {
          _noticeError = true;
          _noticeMessage = _t(
            'Для родителя нужно выбрать подтвержденного студента.',
            'Parent account requires selecting an approved student.',
          );
        });
      }
      return;
    }
    await widget.client.updateUser(user.id, {
      'role': role,
      'full_name': fullNameController.text.trim(),
      'email': emailController.text.trim(),
      if (passwordController.text.trim().isNotEmpty)
        'password': passwordController.text.trim(),
      'phone': phoneController.text.trim(),
      'student_group': role == 'student' ? groupController.text.trim() : '',
      'teacher_name': role == 'teacher' ? teacherController.text.trim() : '',
      'child_full_name': role == 'parent' ? childController.text.trim() : '',
      'parent_student_id': role == 'parent' ? selectedParentStudentId ?? 0 : 0,
      'is_approved': isApproved,
      'about': aboutController.text.trim(),
    });
    if (mounted) {
      setState(() {
        _noticeError = false;
        _noticeMessage = _t('Пользователь обновлен.', 'User updated.');
      });
    }
    _reloadAll();
  }

  Future<void> _deleteUser(UserProfile user) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_t('Удалить пользователя?', 'Delete user?')),
        content: Text('${user.fullName} (${user.email})'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(_t('Отмена', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(_t('Удалить', 'Delete')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await widget.client.deleteUserAsAdmin(user.id);
    _reloadAll();
  }

  Future<void> _approveUser(UserProfile user) async {
    await widget.client.approveUserAsAdmin(user.id);
    _reloadAll();
  }

  Future<void> _updateRequestStatus(RequestTicket item) async {
    final statuses = const [
      'Отправлена',
      'На рассмотрении',
      'Отклонена',
      'В работе',
      'Готова',
    ];
    String value = statuses.contains(item.status)
        ? item.status
        : statuses.first;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_t('Статус заявки', 'Request status')),
        content: DropdownButtonFormField<String>(
          initialValue: value,
          items: [
            for (final s in statuses)
              DropdownMenuItem(value: s, child: Text(s)),
          ],
          onChanged: (next) => value = next ?? value,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(_t('Отмена', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(_t('Сохранить', 'Save')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await widget.client.updateRequest(item.id, status: value);
    _reloadAll();
  }

  Future<void> _deleteRequest(RequestTicket item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_t('Удалить заявку?', 'Delete request?')),
        content: Text(item.requestType),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(_t('Отмена', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(_t('Удалить', 'Delete')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await widget.client.deleteRequest(item.id);
    _reloadAll();
  }

  Future<void> _deleteMakeup(MakeupCaseDto item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_t('Удалить отработку?', 'Delete makeup?')),
        content: Text('${item.groupName} / ${item.studentName}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(_t('Отмена', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(_t('Удалить', 'Delete')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await widget.client.deleteMakeup(item.id);
    _reloadAll();
  }

  Future<void> _createAssignment() async {
    final teachers =
        await (_teachersFuture ??
            widget.client.listUsers(role: 'teacher', approved: true));
    if (teachers.isEmpty) return;
    if (!mounted) return;
    int teacherId = teachers.first.id;
    final groupController = TextEditingController();
    final subjectController = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_t('Создать назначение', 'Create assignment')),
        content: SizedBox(
          width: 560,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<int>(
                initialValue: teacherId,
                items: [
                  for (final t in teachers)
                    DropdownMenuItem(value: t.id, child: Text(t.fullName)),
                ],
                onChanged: (value) => teacherId = value ?? teacherId,
                decoration: InputDecoration(
                  labelText: _t('Преподаватель', 'Teacher'),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: groupController,
                decoration: InputDecoration(labelText: _t('Группа', 'Group')),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: subjectController,
                decoration: InputDecoration(
                  labelText: _t('Предмет', 'Subject'),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(_t('Отмена', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(_t('Создать', 'Create')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await widget.client.createTeacherAssignment(
      teacherId: teacherId,
      groupName: groupController.text.trim(),
      subject: subjectController.text.trim(),
    );
    _reloadAll();
  }

  Future<void> _editAssignment(TeacherGroupAssignment item) async {
    final groupController = TextEditingController(text: item.groupName);
    final subjectController = TextEditingController(text: item.subject);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_t('Изменить назначение', 'Edit assignment')),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: groupController,
                decoration: InputDecoration(labelText: _t('Группа', 'Group')),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: subjectController,
                decoration: InputDecoration(
                  labelText: _t('Предмет', 'Subject'),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(_t('Отмена', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(_t('Сохранить', 'Save')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await widget.client.updateTeacherAssignment(
      item.id,
      groupName: groupController.text.trim(),
      subject: subjectController.text.trim(),
    );
    _reloadAll();
  }

  Future<void> _deleteAssignment(TeacherGroupAssignment item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_t('Удалить назначение?', 'Delete assignment?')),
        content: Text(
          '${item.teacherName} / ${item.groupName} / ${item.subject}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(_t('Отмена', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(_t('Удалить', 'Delete')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await widget.client.deleteTeacherAssignment(item.id);
    _reloadAll();
  }

  Future<void> _createJournalGroup() async {
    final controller = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_t('Новая группа', 'New group')),
        content: TextField(
          controller: controller,
          decoration: InputDecoration(labelText: _t('Название', 'Name')),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(_t('Отмена', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(_t('Создать', 'Create')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await widget.client.upsertJournalGroup(controller.text.trim());
    _reloadAll();
  }

  Future<void> _deleteJournalGroup(String group) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_t('Удалить группу?', 'Delete group?')),
        content: Text(group),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(_t('Отмена', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(_t('Удалить', 'Delete')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await widget.client.deleteJournalGroup(group);
    if (_journalGroup == group) {
      _journalGroup = null;
    }
    _reloadAll();
  }

  Future<void> _addJournalStudent() async {
    if (_journalGroup == null) return;
    List<UserPublicProfile> students = const [];
    try {
      students = await widget.client.listConfirmedJournalStudents(
        _journalGroup!,
      );
    } catch (error) {
      if (mounted) {
        setState(() {
          _noticeError = true;
          _noticeMessage = _readError(error);
        });
      }
      return;
    }
    if (students.isEmpty) {
      if (mounted) {
        setState(() {
          _noticeError = true;
          _noticeMessage = _t(
            'Нет подтвержденных студентов для выбранной группы.',
            'No approved students for selected group.',
          );
        });
      }
      return;
    }
    int selectedId = students.first.id;
    String selectedName = students.first.fullName;
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(_t('Новый студент', 'New student')),
          content: DropdownButtonFormField<int>(
            initialValue: selectedId,
            items: [
              for (final item in students)
                DropdownMenuItem(
                  value: item.id,
                  child: Text(
                    '${item.fullName}${(item.studentGroup ?? '').isEmpty ? '' : ' (${item.studentGroup})'}',
                  ),
                ),
            ],
            onChanged: (value) {
              if (value == null) return;
              final selected = students
                  .where((item) => item.id == value)
                  .cast<UserPublicProfile?>()
                  .firstWhere((item) => item != null, orElse: () => null);
              if (selected == null) return;
              setDialogState(() {
                selectedId = selected.id;
                selectedName = selected.fullName;
              });
            },
            decoration: InputDecoration(
              labelText: _t('Подтвержденный студент', 'Approved student'),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(_t('Отмена', 'Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(_t('Добавить', 'Add')),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    await widget.client.upsertJournalStudent(
      groupName: _journalGroup!,
      studentName: selectedName.trim(),
    );
    _reloadAll();
  }

  Future<void> _deleteJournalStudent(String studentName) async {
    if (_journalGroup == null) return;
    await widget.client.deleteJournalStudent(
      groupName: _journalGroup!,
      studentName: studentName,
    );
    _reloadAll();
  }

  Future<void> _addJournalDates() async {
    if (_journalGroup == null) return;
    final dates = await showJournalMultiDatePicker(
      context,
      title: _t('Добавить даты', 'Add dates'),
      locale: widget.locale,
      initialDate: DateTime.now(),
    );
    if (dates == null || dates.isEmpty) return;
    for (final date in dates) {
      final normalized = DateTime(date.year, date.month, date.day);
      await widget.client.upsertJournalDate(
        groupName: _journalGroup!,
        classDate: normalized,
      );
    }
    _reloadAll();
  }

  Future<void> _deleteJournalDate(DateTime classDate) async {
    if (_journalGroup == null) return;
    await widget.client.deleteJournalDate(
      groupName: _journalGroup!,
      classDate: classDate,
    );
    _reloadAll();
  }

  Future<void> _createNews() async {
    final titleController = TextEditingController();
    final bodyController = TextEditingController();
    String category = 'news';
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_t('Создать новость', 'Create news')),
        content: SizedBox(
          width: 620,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: titleController,
                decoration: InputDecoration(
                  labelText: _t('Заголовок', 'Title'),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: bodyController,
                maxLines: 4,
                decoration: InputDecoration(labelText: _t('Текст', 'Body')),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                initialValue: category,
                items: const [
                  DropdownMenuItem(value: 'news', child: Text('news')),
                  DropdownMenuItem(value: 'study', child: Text('study')),
                  DropdownMenuItem(
                    value: 'announcements',
                    child: Text('announcements'),
                  ),
                  DropdownMenuItem(value: 'events', child: Text('events')),
                ],
                onChanged: (value) => category = value ?? category,
                decoration: InputDecoration(
                  labelText: _t('Категория', 'Category'),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(_t('Отмена', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(_t('Создать', 'Create')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await widget.client.createNews(
      title: titleController.text.trim(),
      body: bodyController.text.trim(),
      category: category,
    );
    _reloadAll();
  }

  Future<void> _editNews(NewsPost post) async {
    final titleController = TextEditingController(text: post.title);
    final bodyController = TextEditingController(text: post.body);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_t('Изменить новость', 'Edit news')),
        content: SizedBox(
          width: 620,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: titleController,
                decoration: InputDecoration(
                  labelText: _t('Заголовок', 'Title'),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: bodyController,
                maxLines: 4,
                decoration: InputDecoration(labelText: _t('Текст', 'Body')),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(_t('Отмена', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(_t('Сохранить', 'Save')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await widget.client.updateNewsPost(
      post.id,
      title: titleController.text.trim(),
      body: bodyController.text.trim(),
    );
    _reloadAll();
  }

  Future<void> _deleteNews(NewsPost post) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_t('Удалить новость?', 'Delete news?')),
        content: Text(post.title),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(_t('Отмена', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(_t('Удалить', 'Delete')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await widget.client.deleteNewsPost(post.id);
    _reloadAll();
  }

  Future<void> _editExamUpload(ExamUpload item) async {
    final groupController = TextEditingController(text: item.groupName);
    final examController = TextEditingController(text: item.examName);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_t('Изменить загрузку', 'Edit upload')),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: groupController,
                decoration: InputDecoration(labelText: _t('Группа', 'Group')),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: examController,
                decoration: InputDecoration(labelText: _t('Экзамен', 'Exam')),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(_t('Отмена', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(_t('Сохранить', 'Save')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await widget.client.updateExamUpload(
      item.id,
      groupName: groupController.text.trim(),
      examName: examController.text.trim(),
    );
    _reloadAll();
  }

  Future<void> _deleteExamUpload(ExamUpload item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_t('Удалить загрузку?', 'Delete upload?')),
        content: Text('${item.groupName} / ${item.examName}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(_t('Отмена', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(_t('Удалить', 'Delete')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await widget.client.deleteExamUpload(item.id);
    _reloadAll();
  }

  Future<void> _createDepartment() async {
    final teachers =
        await (_teachersFuture ??
            widget.client.listUsers(role: 'teacher', approved: true));
    final nameController = TextEditingController();
    final keyController = TextEditingController();
    int? headUserId = teachers.isNotEmpty ? teachers.first.id : null;
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(_t('Новое отделение', 'New department')),
          content: SizedBox(
            width: 560,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  decoration: InputDecoration(
                    labelText: _t('Название', 'Name'),
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: keyController,
                  decoration: InputDecoration(labelText: _t('Ключ', 'Key')),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<int?>(
                  initialValue: headUserId,
                  items: [
                    DropdownMenuItem<int?>(
                      value: null,
                      child: Text(_t('Без заведующей', 'No head')),
                    ),
                    for (final teacher in teachers)
                      DropdownMenuItem<int?>(
                        value: teacher.id,
                        child: Text(teacher.fullName),
                      ),
                  ],
                  onChanged: (value) =>
                      setDialogState(() => headUserId = value),
                  decoration: InputDecoration(
                    labelText: _t('Заведующая', 'Head'),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(_t('Отмена', 'Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(_t('Создать', 'Create')),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    await widget.client.createDepartment(
      name: nameController.text.trim(),
      key: keyController.text.trim(),
      headUserId: headUserId,
    );
    _reloadAll();
  }

  Future<void> _editDepartment(DepartmentDto item) async {
    final teachers =
        await (_teachersFuture ??
            widget.client.listUsers(role: 'teacher', approved: true));
    final nameController = TextEditingController(text: item.name);
    final keyController = TextEditingController(text: item.key);
    int? headUserId = item.headUserId;
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(_t('Изменить отделение', 'Edit department')),
          content: SizedBox(
            width: 560,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  decoration: InputDecoration(
                    labelText: _t('Название', 'Name'),
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: keyController,
                  decoration: InputDecoration(labelText: _t('Ключ', 'Key')),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<int?>(
                  initialValue: headUserId,
                  items: [
                    DropdownMenuItem<int?>(
                      value: null,
                      child: Text(_t('Без заведующей', 'No head')),
                    ),
                    for (final teacher in teachers)
                      DropdownMenuItem<int?>(
                        value: teacher.id,
                        child: Text(teacher.fullName),
                      ),
                  ],
                  onChanged: (value) =>
                      setDialogState(() => headUserId = value),
                  decoration: InputDecoration(
                    labelText: _t('Заведующая', 'Head'),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(_t('Отмена', 'Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(_t('Сохранить', 'Save')),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    await widget.client.updateDepartment(
      id: item.id,
      name: nameController.text.trim(),
      key: keyController.text.trim(),
      headUserId: headUserId,
    );
    _reloadAll();
  }

  Future<void> _deleteDepartment(DepartmentDto item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_t('Удалить отделение?', 'Delete department?')),
        content: Text('${item.name} (${item.key})'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(_t('Отмена', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(_t('Удалить', 'Delete')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await widget.client.deleteDepartment(item.id);
    _reloadAll();
  }

  Future<void> _addDepartmentGroup(DepartmentDto item) async {
    final groups = await widget.client.listJournalGroups();
    String groupName = groups.isNotEmpty ? groups.first : '';
    final customController = TextEditingController();
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(_t('Добавить группу', 'Add group')),
          content: SizedBox(
            width: 520,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (groups.isNotEmpty)
                  DropdownButtonFormField<String>(
                    initialValue: groupName,
                    items: [
                      for (final group in groups)
                        DropdownMenuItem(value: group, child: Text(group)),
                    ],
                    onChanged: (value) =>
                        setDialogState(() => groupName = value ?? groupName),
                    decoration: InputDecoration(
                      labelText: _t(
                        'Группа (из журнала)',
                        'Group from journal',
                      ),
                    ),
                  ),
                const SizedBox(height: 8),
                TextField(
                  controller: customController,
                  decoration: InputDecoration(
                    labelText: _t('Или вручную', 'Or manual value'),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(_t('Отмена', 'Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(_t('Добавить', 'Add')),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final value = customController.text.trim().isNotEmpty
        ? customController.text.trim()
        : groupName;
    if (value.isEmpty) return;
    await widget.client.addDepartmentGroup(
      departmentId: item.id,
      groupName: value,
    );
    _reloadAll();
  }

  Future<void> _removeDepartmentGroup(
    DepartmentDto item,
    String groupName,
  ) async {
    await widget.client.removeDepartmentGroup(
      departmentId: item.id,
      groupName: groupName,
    );
    _reloadAll();
  }

  Future<void> _createCuratorGroupAssignment() async {
    final teachers =
        await (_teachersFuture ??
            widget.client.listUsers(role: 'teacher', approved: true));
    if (teachers.isEmpty) return;
    final groups = await widget.client.listJournalGroups();
    int curatorId = teachers.first.id;
    String groupName = groups.isNotEmpty ? groups.first : '';
    final customController = TextEditingController();
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(_t('Назначить куратора группе', 'Assign curator')),
          content: SizedBox(
            width: 540,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<int>(
                  initialValue: curatorId,
                  items: [
                    for (final teacher in teachers)
                      DropdownMenuItem(
                        value: teacher.id,
                        child: Text(teacher.fullName),
                      ),
                  ],
                  onChanged: (value) =>
                      setDialogState(() => curatorId = value ?? curatorId),
                  decoration: InputDecoration(
                    labelText: _t('Куратор', 'Curator'),
                  ),
                ),
                const SizedBox(height: 8),
                if (groups.isNotEmpty)
                  DropdownButtonFormField<String>(
                    initialValue: groupName,
                    items: [
                      for (final group in groups)
                        DropdownMenuItem(value: group, child: Text(group)),
                    ],
                    onChanged: (value) =>
                        setDialogState(() => groupName = value ?? groupName),
                    decoration: InputDecoration(
                      labelText: _t('Группа', 'Group'),
                    ),
                  ),
                const SizedBox(height: 8),
                TextField(
                  controller: customController,
                  decoration: InputDecoration(
                    labelText: _t('Или вручную', 'Or manual value'),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(_t('Отмена', 'Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(_t('Назначить', 'Assign')),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final value = customController.text.trim().isNotEmpty
        ? customController.text.trim()
        : groupName;
    if (value.isEmpty) return;
    await widget.client.createCuratorGroup(
      curatorId: curatorId,
      groupName: value,
    );
    _reloadAll();
  }

  Future<void> _deleteCuratorGroupAssignment(
    CuratorGroupAssignmentDto item,
  ) async {
    await widget.client.deleteCuratorGroup(item.id);
    _reloadAll();
  }

  Future<void> _moveGroupToDepartment({
    required String groupName,
    required DepartmentDto target,
    required List<DepartmentDto> departments,
  }) async {
    final normalizedGroup = groupName.trim();
    if (normalizedGroup.isEmpty) return;
    try {
      for (final department in departments) {
        final hasGroup = department.groups.any(
          (item) => item.trim() == normalizedGroup,
        );
        if (!hasGroup || department.id == target.id) {
          continue;
        }
        await widget.client.removeDepartmentGroup(
          departmentId: department.id,
          groupName: normalizedGroup,
        );
      }
      if (!target.groups.any((item) => item.trim() == normalizedGroup)) {
        await widget.client.addDepartmentGroup(
          departmentId: target.id,
          groupName: normalizedGroup,
        );
      }
      if (mounted) {
        setState(() {
          _noticeError = false;
          _noticeMessage = _t(
            'Группа перенесена в отделение.',
            'Group moved to department.',
          );
        });
      }
      _reloadAll();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _noticeError = true;
        _noticeMessage = _readError(error);
      });
    }
  }

  Future<void> _unassignGroupFromDepartments({
    required String groupName,
    required List<DepartmentDto> departments,
  }) async {
    final normalizedGroup = groupName.trim();
    if (normalizedGroup.isEmpty) return;
    try {
      for (final department in departments) {
        if (!department.groups.any((item) => item.trim() == normalizedGroup)) {
          continue;
        }
        await widget.client.removeDepartmentGroup(
          departmentId: department.id,
          groupName: normalizedGroup,
        );
      }
      if (mounted) {
        setState(() {
          _noticeError = false;
          _noticeMessage = _t(
            'Группа снята с отделения.',
            'Group removed from department.',
          );
        });
      }
      _reloadAll();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _noticeError = true;
        _noticeMessage = _readError(error);
      });
    }
  }

  Future<void> _editScheduleUploadDate(ScheduleUpload item) async {
    final picked = await showDatePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      initialDate: item.scheduleDate ?? DateTime.now(),
      locale: widget.locale,
    );
    if (picked == null) return;
    await widget.client.updateScheduleUpload(id: item.id, scheduleDate: picked);
    _reloadAll();
  }

  Future<void> _deleteScheduleUploadEntry(ScheduleUpload item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          _t('Удалить пакет расписания?', 'Delete schedule package?'),
        ),
        content: Text(item.filename),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(_t('Отмена', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(_t('Удалить', 'Delete')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await widget.client.deleteScheduleUpload(item.id);
    _reloadAll();
  }

  Future<void> _upsertAttendanceRecord({AttendanceRecord? existing}) async {
    if (_journalGroup == null) return;
    final students = await widget.client.listJournalStudents(_journalGroup!);
    if (students.isEmpty) return;
    if (!mounted) return;
    String studentName = existing?.studentName ?? students.first;
    DateTime classDate = existing?.classDate ?? DateTime.now();
    bool present = existing?.present ?? true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(
            existing == null
                ? _t('Добавить посещение', 'Add attendance')
                : _t('Изменить посещение', 'Edit attendance'),
          ),
          content: SizedBox(
            width: 520,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: studentName,
                  items: [
                    for (final student in students)
                      DropdownMenuItem(value: student, child: Text(student)),
                  ],
                  onChanged: (value) =>
                      setDialogState(() => studentName = value ?? studentName),
                  decoration: InputDecoration(
                    labelText: _t('Студент', 'Student'),
                  ),
                ),
                const SizedBox(height: 8),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(_t('Дата', 'Date')),
                  subtitle: Text(DateFormat('dd.MM.yyyy').format(classDate)),
                  trailing: IconButton(
                    icon: const Icon(Icons.event),
                    onPressed: () async {
                      final picked = await showDatePicker(
                        context: context,
                        firstDate: DateTime(2000),
                        lastDate: DateTime(2100),
                        initialDate: classDate,
                        locale: widget.locale,
                      );
                      if (picked == null) return;
                      setDialogState(() => classDate = picked);
                    },
                  ),
                ),
                SwitchListTile(
                  value: present,
                  onChanged: (value) => setDialogState(() => present = value),
                  title: Text(_t('Присутствовал', 'Present')),
                  contentPadding: EdgeInsets.zero,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(_t('Отмена', 'Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(_t('Сохранить', 'Save')),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    await widget.client.createAttendance(
      groupName: _journalGroup!,
      classDate: classDate,
      studentName: studentName,
      present: present,
    );
    _reloadAll();
  }

  Future<void> _deleteAttendanceRecord(AttendanceRecord item) async {
    await widget.client.deleteAttendance(
      groupName: item.groupName,
      classDate: item.classDate,
      studentName: item.studentName,
    );
    _reloadAll();
  }

  Future<void> _upsertGradeRecord({GradeRecord? existing}) async {
    if (_journalGroup == null) return;
    final students = await widget.client.listJournalStudents(_journalGroup!);
    if (students.isEmpty) return;
    if (!mounted) return;
    String studentName = existing?.studentName ?? students.first;
    DateTime classDate = existing?.classDate ?? DateTime.now();
    final gradeController = TextEditingController(
      text: (existing?.grade ?? 100).toString(),
    );
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(
            existing == null
                ? _t('Добавить оценку', 'Add grade')
                : _t('Изменить оценку', 'Edit grade'),
          ),
          content: SizedBox(
            width: 520,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: studentName,
                  items: [
                    for (final student in students)
                      DropdownMenuItem(value: student, child: Text(student)),
                  ],
                  onChanged: (value) =>
                      setDialogState(() => studentName = value ?? studentName),
                  decoration: InputDecoration(
                    labelText: _t('Студент', 'Student'),
                  ),
                ),
                const SizedBox(height: 8),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(_t('Дата', 'Date')),
                  subtitle: Text(DateFormat('dd.MM.yyyy').format(classDate)),
                  trailing: IconButton(
                    icon: const Icon(Icons.event),
                    onPressed: () async {
                      final picked = await showDatePicker(
                        context: context,
                        firstDate: DateTime(2000),
                        lastDate: DateTime(2100),
                        initialDate: classDate,
                        locale: widget.locale,
                      );
                      if (picked == null) return;
                      setDialogState(() => classDate = picked);
                    },
                  ),
                ),
                TextField(
                  controller: gradeController,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: _t('Оценка 1..100', 'Grade 1..100'),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(_t('Отмена', 'Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(_t('Сохранить', 'Save')),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final grade = int.tryParse(gradeController.text.trim());
    if (grade == null) return;
    await widget.client.createGrade(
      groupName: _journalGroup!,
      classDate: classDate,
      studentName: studentName,
      grade: grade,
    );
    _reloadAll();
  }

  Future<void> _deleteGradeRecord(GradeRecord item) async {
    await widget.client.deleteGrade(
      groupName: item.groupName,
      classDate: item.classDate,
      studentName: item.studentName,
    );
    _reloadAll();
  }

  void _setJournalGroupSelection(String? groupName) {
    _journalGroup = groupName;
    if (groupName != null && groupName.trim().isNotEmpty) {
      _journalStudentsFuture = widget.client.listJournalStudents(groupName);
      _journalDatesFuture = widget.client.listJournalDates(groupName);
      _attendanceCrudFuture = widget.client.listAttendance(groupName);
      _gradesCrudFuture = widget.client.listGrades(groupName);
      _analyticsAttendanceFuture = widget.client.listAnalyticsAttendance(
        groupName: groupName,
      );
      _analyticsGradesFuture = widget.client.listAnalyticsGrades(
        groupName: groupName,
      );
      return;
    }
    _journalStudentsFuture = null;
    _journalDatesFuture = null;
    _attendanceCrudFuture = null;
    _gradesCrudFuture = null;
    _analyticsAttendanceFuture = widget.client.listAnalyticsAttendance();
    _analyticsGradesFuture = widget.client.listAnalyticsGrades();
  }

  String? _syncJournalGroupFromList(List<String> groups) {
    final value = (_journalGroup != null && groups.contains(_journalGroup))
        ? _journalGroup
        : (groups.isNotEmpty ? groups.first : null);
    if (value != _journalGroup) {
      _setJournalGroupSelection(value);
    }
    return value;
  }

  Widget _buildJournalGroupCard({
    required bool withAttendanceCreate,
    required bool withGradeCreate,
  }) {
    return FutureBuilder<List<String>>(
      future: _journalGroupsFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Text(widget.errorText(snapshot.error!));
        }
        final groups = snapshot.data ?? [];
        final value = _syncJournalGroupFromList(groups);
        if (groups.isEmpty) {
          return Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                _t(
                  'Сначала создайте группы в разделе "Журнал".',
                  'Create journal groups first in "Journal" tab.',
                ),
              ),
            ),
          );
        }
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Wrap(
              spacing: 10,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: 260,
                  child: DropdownButtonFormField<String>(
                    initialValue: value,
                    items: [
                      for (final group in groups)
                        DropdownMenuItem(value: group, child: Text(group)),
                    ],
                    onChanged: (next) {
                      if (next == null) return;
                      setState(() => _setJournalGroupSelection(next));
                    },
                    decoration: InputDecoration(
                      labelText: _t('Группа', 'Group'),
                    ),
                  ),
                ),
                if (withAttendanceCreate)
                  FilledButton.tonalIcon(
                    onPressed: _upsertAttendanceRecord,
                    icon: const Icon(Icons.check_circle_outline),
                    label: Text(_t('Добавить посещение', 'Add attendance')),
                  ),
                if (withGradeCreate)
                  FilledButton.tonalIcon(
                    onPressed: _upsertGradeRecord,
                    icon: const Icon(Icons.grade_outlined),
                    label: Text(_t('Добавить оценку', 'Add grade')),
                  ),
                OutlinedButton.icon(
                  onPressed: _reloadAll,
                  icon: const Icon(Icons.refresh),
                  label: Text(_t('Обновить', 'Refresh')),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildScheduleCrudService() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _t('Пакеты расписания', 'Schedule packages'),
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        FutureBuilder<List<ScheduleUpload>>(
          future: _scheduleUploadsFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return Text(widget.errorText(snapshot.error!));
            }
            final items = snapshot.data ?? [];
            if (items.isEmpty) {
              return Text(_t('Пакетов нет.', 'No packages.'));
            }
            return Column(
              children: [
                for (final item in items)
                  Card(
                    child: ListTile(
                      title: Text(item.filename),
                      subtitle: Text(
                        '${_t('Дата', 'Date')}: ${item.scheduleDate == null ? '-' : DateFormat('dd.MM.yyyy').format(item.scheduleDate!)} / ${DateFormat('dd.MM.yyyy HH:mm').format(item.uploadedAt)}',
                      ),
                      trailing: PopupMenuButton<String>(
                        onSelected: (value) {
                          if (value == 'edit') {
                            _editScheduleUploadDate(item);
                          } else if (value == 'delete') {
                            _deleteScheduleUploadEntry(item);
                          }
                        },
                        itemBuilder: (context) => [
                          PopupMenuItem(
                            value: 'edit',
                            child: Text(_t('Изменить дату', 'Edit date')),
                          ),
                          PopupMenuItem(
                            value: 'delete',
                            child: Text(_t('Удалить', 'Delete')),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _buildAttendanceCrudService() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildJournalGroupCard(
          withAttendanceCreate: true,
          withGradeCreate: false,
        ),
        const SizedBox(height: 12),
        Text(
          _t('Посещаемость (CRUD)', 'Attendance (CRUD)'),
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        FutureBuilder<List<AttendanceRecord>>(
          future: _attendanceCrudFuture,
          builder: (context, snapshot) {
            if (_journalGroup == null) {
              return Text(_t('Выберите группу.', 'Select a group.'));
            }
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return Text(widget.errorText(snapshot.error!));
            }
            final items = snapshot.data ?? [];
            if (items.isEmpty) {
              return Text(_t('Записей нет.', 'No records.'));
            }
            return Column(
              children: [
                for (final item in items.take(80))
                  Card(
                    child: ListTile(
                      title: Text(item.studentName),
                      subtitle: Text(
                        '${DateFormat('dd.MM.yyyy').format(item.classDate)} / ${item.present ? _t('Присутствовал', 'Present') : _t('Отсутствовал', 'Absent')}',
                      ),
                      trailing: PopupMenuButton<String>(
                        onSelected: (value) {
                          if (value == 'edit') {
                            _upsertAttendanceRecord(existing: item);
                          } else if (value == 'delete') {
                            _deleteAttendanceRecord(item);
                          }
                        },
                        itemBuilder: (context) => [
                          PopupMenuItem(
                            value: 'edit',
                            child: Text(_t('Изменить', 'Edit')),
                          ),
                          PopupMenuItem(
                            value: 'delete',
                            child: Text(_t('Удалить', 'Delete')),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _buildGradesCrudService() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildJournalGroupCard(
          withAttendanceCreate: false,
          withGradeCreate: true,
        ),
        const SizedBox(height: 12),
        Text(
          _t('Оценки (CRUD)', 'Grades (CRUD)'),
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        FutureBuilder<List<GradeRecord>>(
          future: _gradesCrudFuture,
          builder: (context, snapshot) {
            if (_journalGroup == null) {
              return Text(_t('Выберите группу.', 'Select a group.'));
            }
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return Text(widget.errorText(snapshot.error!));
            }
            final items = snapshot.data ?? [];
            if (items.isEmpty) {
              return Text(_t('Записей нет.', 'No records.'));
            }
            return Column(
              children: [
                for (final item in items.take(80))
                  Card(
                    child: ListTile(
                      title: Text(item.studentName),
                      subtitle: Text(
                        '${DateFormat('dd.MM.yyyy').format(item.classDate)} / ${item.grade}',
                      ),
                      trailing: PopupMenuButton<String>(
                        onSelected: (value) {
                          if (value == 'edit') {
                            _upsertGradeRecord(existing: item);
                          } else if (value == 'delete') {
                            _deleteGradeRecord(item);
                          }
                        },
                        itemBuilder: (context) => [
                          PopupMenuItem(
                            value: 'edit',
                            child: Text(_t('Изменить', 'Edit')),
                          ),
                          PopupMenuItem(
                            value: 'delete',
                            child: Text(_t('Удалить', 'Delete')),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _buildAnalyticsCrudService() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildJournalGroupCard(
          withAttendanceCreate: false,
          withGradeCreate: false,
        ),
        const SizedBox(height: 12),
        Text(
          _t('Аналитика (срез)', 'Analytics snapshot'),
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        FutureBuilder<List<GroupAnalytics>>(
          future: _analyticsGroupsFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return Text(widget.errorText(snapshot.error!));
            }
            final rows = snapshot.data ?? [];
            if (rows.isEmpty) {
              return Text(_t('Данных нет.', 'No data.'));
            }
            return Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: FutureBuilder<List<AttendanceRecord>>(
                        future: _analyticsAttendanceFuture,
                        builder: (context, attendanceSnapshot) {
                          final count = attendanceSnapshot.data?.length ?? 0;
                          return Card(
                            child: ListTile(
                              title: Text(
                                _t('Записей посещаемости', 'Attendance rows'),
                              ),
                              subtitle: Text(count.toString()),
                            ),
                          );
                        },
                      ),
                    ),
                    Expanded(
                      child: FutureBuilder<List<GradeRecord>>(
                        future: _analyticsGradesFuture,
                        builder: (context, gradesSnapshot) {
                          final count = gradesSnapshot.data?.length ?? 0;
                          return Card(
                            child: ListTile(
                              title: Text(_t('Записей оценок', 'Grade rows')),
                              subtitle: Text(count.toString()),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
                for (final row in rows.take(30))
                  Card(
                    child: ListTile(
                      title: Text(row.groupName),
                      subtitle: Text(
                        '${_t('Предметы', 'Subjects')}: ${row.subjects.join(', ')}\n${_t('Преподаватели', 'Teachers')}: ${row.teachers.join(', ')}',
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _buildDepartmentsTreeService() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FilledButton.tonalIcon(
          onPressed: _createCuratorGroupAssignment,
          icon: const Icon(Icons.how_to_reg),
          label: Text(_t('Назначить куратора', 'Assign curator')),
        ),
        const SizedBox(height: 10),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              _t(
                'Дерево структуры: перетаскивайте группы между отделениями. Отпустите в блок "Без отделения", чтобы снять привязку.',
                'Structure tree: drag groups between departments. Drop to "Unassigned" to remove binding.',
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        FutureBuilder<List<DepartmentDto>>(
          future: _departmentsFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return Text(widget.errorText(snapshot.error!));
            }
            final departments = snapshot.data ?? [];
            return FutureBuilder<List<String>>(
              future: _journalGroupsFuture,
              builder: (context, groupsSnapshot) {
                final groupCatalog = groupsSnapshot.data ?? const <String>[];
                final allGroups = <String>{
                  ...groupCatalog
                      .map((item) => item.trim())
                      .where((item) => item.isNotEmpty),
                  for (final department in departments)
                    ...department.groups
                        .map((item) => item.trim())
                        .where((item) => item.isNotEmpty),
                };
                final assigned = <String>{
                  for (final department in departments)
                    ...department.groups
                        .map((item) => item.trim())
                        .where((item) => item.isNotEmpty),
                };
                final unassigned =
                    allGroups.where((item) => !assigned.contains(item)).toList()
                      ..sort();

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    DragTarget<String>(
                      onWillAcceptWithDetails: (details) =>
                          details.data.trim().isNotEmpty,
                      onAcceptWithDetails: (details) {
                        _unassignGroupFromDepartments(
                          groupName: details.data,
                          departments: departments,
                        );
                      },
                      builder: (context, candidate, rejected) {
                        return AnimatedContainer(
                          duration: const Duration(milliseconds: 140),
                          padding: const EdgeInsets.all(12),
                          margin: const EdgeInsets.only(bottom: 12),
                          decoration: BoxDecoration(
                            color: candidate.isNotEmpty
                                ? const Color(0xFFFDF2F8)
                                : const Color(0xFFF8FAFC),
                            border: Border.all(
                              color: candidate.isNotEmpty
                                  ? const Color(0xFFE11D48)
                                  : const Color(0xFFCBD5E1),
                            ),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _t('Без отделения', 'Unassigned'),
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 8),
                              if (unassigned.isEmpty)
                                Text(
                                  _t(
                                    'Все группы распределены по отделениям.',
                                    'All groups are assigned to departments.',
                                  ),
                                )
                              else
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: [
                                    for (final group in unassigned)
                                      Draggable<String>(
                                        data: group,
                                        feedback: Material(
                                          color: Colors.transparent,
                                          child: Chip(label: Text(group)),
                                        ),
                                        childWhenDragging: Opacity(
                                          opacity: 0.3,
                                          child: Chip(label: Text(group)),
                                        ),
                                        child: Chip(
                                          label: Text(group),
                                          avatar: const Icon(
                                            Icons.drag_indicator,
                                            size: 16,
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                            ],
                          ),
                        );
                      },
                    ),
                    if (departments.isEmpty)
                      Text(_t('Отделений пока нет.', 'No departments yet.'))
                    else
                      Column(
                        children: [
                          for (final department in departments)
                            DragTarget<String>(
                              onWillAcceptWithDetails: (details) =>
                                  details.data.trim().isNotEmpty,
                              onAcceptWithDetails: (details) {
                                _moveGroupToDepartment(
                                  groupName: details.data,
                                  target: department,
                                  departments: departments,
                                );
                              },
                              builder: (context, candidate, rejected) {
                                final hasCandidate = candidate.isNotEmpty;
                                final groups = [...department.groups]..sort();
                                return Card(
                                  child: AnimatedContainer(
                                    duration: const Duration(milliseconds: 140),
                                    padding: const EdgeInsets.all(12),
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(
                                        color: hasCandidate
                                            ? const Color(0xFF0E7490)
                                            : Colors.transparent,
                                        width: 1.4,
                                      ),
                                      color: hasCandidate
                                          ? const Color(0xFFF0FDFA)
                                          : null,
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        ListTile(
                                          contentPadding: EdgeInsets.zero,
                                          title: Text(
                                            '${department.name} [${department.key}]',
                                          ),
                                          subtitle: Text(
                                            '${_t('Заведующая', 'Head')}: ${department.headName ?? '-'}',
                                          ),
                                          trailing: PopupMenuButton<String>(
                                            onSelected: (action) async {
                                              if (action == 'edit') {
                                                await _editDepartment(
                                                  department,
                                                );
                                              } else if (action == 'delete') {
                                                await _deleteDepartment(
                                                  department,
                                                );
                                              } else if (action ==
                                                  'add_group') {
                                                await _addDepartmentGroup(
                                                  department,
                                                );
                                              }
                                            },
                                            itemBuilder: (context) => [
                                              PopupMenuItem(
                                                value: 'add_group',
                                                child: Text(
                                                  _t(
                                                    'Добавить группу',
                                                    'Add group',
                                                  ),
                                                ),
                                              ),
                                              PopupMenuItem(
                                                value: 'edit',
                                                child: Text(
                                                  _t('Изменить', 'Edit'),
                                                ),
                                              ),
                                              PopupMenuItem(
                                                value: 'delete',
                                                child: Text(
                                                  _t('Удалить', 'Delete'),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        if (groups.isEmpty)
                                          Text(
                                            _t(
                                              'Группы не назначены.',
                                              'No groups assigned.',
                                            ),
                                          )
                                        else
                                          Column(
                                            children: [
                                              for (final group in groups)
                                                Padding(
                                                  padding:
                                                      const EdgeInsets.only(
                                                        left: 8,
                                                        bottom: 6,
                                                      ),
                                                  child: Row(
                                                    children: [
                                                      const Icon(
                                                        Icons
                                                            .subdirectory_arrow_right_rounded,
                                                        size: 16,
                                                      ),
                                                      const SizedBox(width: 4),
                                                      Draggable<String>(
                                                        data: group,
                                                        feedback: Material(
                                                          color: Colors
                                                              .transparent,
                                                          child: Chip(
                                                            label: Text(group),
                                                          ),
                                                        ),
                                                        childWhenDragging:
                                                            Opacity(
                                                              opacity: 0.3,
                                                              child: Chip(
                                                                label: Text(
                                                                  group,
                                                                ),
                                                              ),
                                                            ),
                                                        child: Chip(
                                                          label: Text(group),
                                                          avatar: const Icon(
                                                            Icons
                                                                .drag_indicator,
                                                            size: 16,
                                                          ),
                                                          onDeleted: () =>
                                                              _removeDepartmentGroup(
                                                                department,
                                                                group,
                                                              ),
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                            ],
                                          ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                        ],
                      ),
                    const SizedBox(height: 12),
                    Text(
                      _t('Кураторство групп', 'Group curator mapping'),
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 8),
                    FutureBuilder<List<CuratorGroupAssignmentDto>>(
                      future: _curatorGroupsFuture,
                      builder: (context, snapshot) {
                        if (snapshot.connectionState ==
                            ConnectionState.waiting) {
                          return const Center(
                            child: CircularProgressIndicator(),
                          );
                        }
                        if (snapshot.hasError) {
                          return Text(widget.errorText(snapshot.error!));
                        }
                        final items = snapshot.data ?? [];
                        if (items.isEmpty) {
                          return Text(
                            _t(
                              'Назначений кураторства нет.',
                              'No curator assignments.',
                            ),
                          );
                        }
                        return Column(
                          children: [
                            for (final item in items)
                              Card(
                                child: ListTile(
                                  title: Text(item.groupName),
                                  subtitle: Text(item.curatorName ?? '-'),
                                  trailing: IconButton(
                                    icon: const Icon(Icons.delete_outline),
                                    onPressed: () =>
                                        _deleteCuratorGroupAssignment(item),
                                  ),
                                ),
                              ),
                          ],
                        );
                      },
                    ),
                  ],
                );
              },
            );
          },
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.currentUser.role != 'admin') {
      return ModulePanel(
        title: _t('Админ панель', 'Admin panel'),
        subtitle: _t('Недостаточно прав.', 'Insufficient role.'),
        child: Text(_t('Доступ запрещен.', 'Access denied.')),
      );
    }
    final tabs = <String>[
      _t('Пользователи', 'Users'),
      _t('Заявки', 'Requests'),
      _t('Отработки', 'Makeups'),
      _t('Назначения', 'Assignments'),
      _t('Журнал', 'Journal'),
      _t('Новости', 'News'),
      _t('Экзамены', 'Exams'),
      _t('Отделения', 'Departments'),
      _t('Расписание', 'Schedule'),
      _t('Посещаемость', 'Attendance'),
      _t('Оценки', 'Grades'),
      _t('Аналитика', 'Analytics'),
    ];
    return ModulePanel(
      title: _t('Админ панель', 'Admin panel'),
      subtitle: _t(
        'Управление пользователями, отделениями, расписанием, посещаемостью, аналитикой и учебными данными.',
        'Manage users, departments, schedule, attendance, analytics and academic data.',
      ),
      trailing: () {
        if (_tab == 0) {
          return FilledButton.icon(
            onPressed: _createUser,
            icon: const Icon(Icons.person_add_alt_1),
            label: Text(_t('Создать', 'Create')),
          );
        }
        if (_tab == 3) {
          return FilledButton.icon(
            onPressed: _createAssignment,
            icon: const Icon(Icons.add_task),
            label: Text(_t('Назначение', 'Assignment')),
          );
        }
        if (_tab == 4) {
          return FilledButton.icon(
            onPressed: _createJournalGroup,
            icon: const Icon(Icons.group_add),
            label: Text(_t('Группа', 'Group')),
          );
        }
        if (_tab == 5) {
          return FilledButton.icon(
            onPressed: _createNews,
            icon: const Icon(Icons.post_add),
            label: Text(_t('Новость', 'News')),
          );
        }
        if (_tab == 7) {
          return FilledButton.icon(
            onPressed: _createDepartment,
            icon: const Icon(Icons.account_tree_outlined),
            label: Text(_t('Отделение', 'Department')),
          );
        }
        if (_tab == 8 || _tab == 9 || _tab == 10 || _tab == 11) {
          return FilledButton.icon(
            onPressed: _reloadAll,
            icon: const Icon(Icons.refresh),
            label: Text(_t('Обновить', 'Refresh')),
          );
        }
        return null;
      }(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_noticeMessage != null) ...[
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color:
                    (_noticeError
                            ? const Color(0xFFDC2626)
                            : const Color(0xFF16A34A))
                        .withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                _noticeMessage!,
                style: TextStyle(
                  color: _noticeError
                      ? const Color(0xFFB91C1C)
                      : const Color(0xFF166534),
                ),
              ),
            ),
          ],
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                _t(
                  'CRUD доступ: пользователи, отделения, кураторство, расписание, посещаемость, аналитика и академические сущности.',
                  'CRUD scope: users, departments, curator mapping, schedule, attendance, analytics and academic entities.',
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final entry in tabs)
                ChoiceChip(
                  selected: _tab == tabs.indexOf(entry),
                  label: Text(entry),
                  onSelected: (_) => setState(() => _tab = tabs.indexOf(entry)),
                ),
            ],
          ),
          const SizedBox(height: 10),
          if (_tab == 0)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    SizedBox(
                      width: 220,
                      child: DropdownButtonFormField<String>(
                        initialValue: _userRole,
                        items: const [
                          DropdownMenuItem(value: 'all', child: Text('all')),
                          DropdownMenuItem(
                            value: 'admin',
                            child: Text('admin'),
                          ),
                          DropdownMenuItem(
                            value: 'teacher',
                            child: Text('teacher'),
                          ),
                          DropdownMenuItem(
                            value: 'student',
                            child: Text('student'),
                          ),
                          DropdownMenuItem(
                            value: 'parent',
                            child: Text('parent'),
                          ),
                          DropdownMenuItem(value: 'smm', child: Text('smm')),
                          DropdownMenuItem(
                            value: 'request_handler',
                            child: Text('request_handler'),
                          ),
                        ],
                        onChanged: (value) {
                          if (value == null) return;
                          setState(() => _userRole = value);
                          _reloadAll();
                        },
                        decoration: InputDecoration(
                          labelText: _t('Фильтр роли', 'Role filter'),
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 220,
                      child: DropdownButtonFormField<String>(
                        initialValue: _userApproval,
                        items: [
                          DropdownMenuItem(
                            value: 'all',
                            child: Text(_t('Все', 'All')),
                          ),
                          DropdownMenuItem(
                            value: 'approved',
                            child: Text(_t('Подтвержденные', 'Approved')),
                          ),
                          DropdownMenuItem(
                            value: 'pending',
                            child: Text(_t('Ожидают', 'Pending')),
                          ),
                        ],
                        onChanged: (value) {
                          if (value == null) return;
                          setState(() => _userApproval = value);
                          _reloadAll();
                        },
                        decoration: InputDecoration(
                          labelText: _t('Статус', 'Status'),
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 240,
                      child: DropdownButtonFormField<String>(
                        initialValue: _userSort,
                        items: [
                          DropdownMenuItem(
                            value: 'id_asc',
                            child: Text(_t('По ID', 'By ID')),
                          ),
                          DropdownMenuItem(
                            value: 'name_asc',
                            child: Text(_t('Имя A-Я', 'Name A-Z')),
                          ),
                          DropdownMenuItem(
                            value: 'name_desc',
                            child: Text(_t('Имя Я-A', 'Name Z-A')),
                          ),
                          DropdownMenuItem(
                            value: 'created_desc',
                            child: Text(_t('Новые сверху', 'Newest first')),
                          ),
                        ],
                        onChanged: (value) {
                          if (value == null) return;
                          setState(() => _userSort = value);
                          _reloadAll();
                        },
                        decoration: InputDecoration(
                          labelText: _t('Сортировка', 'Sort'),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                FutureBuilder<List<UserProfile>>(
                  future: _usersFuture,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    if (snapshot.hasError) {
                      return Text(widget.errorText(snapshot.error!));
                    }
                    final items = snapshot.data ?? [];
                    return Column(
                      children: [
                        for (final user in items)
                          Card(
                            child: ListTile(
                              title: Wrap(
                                spacing: 8,
                                runSpacing: 6,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  Text('${user.fullName} (${user.role})'),
                                  Chip(
                                    label: Text(
                                      (user.isApproved ?? true)
                                          ? _t('Подтвержден', 'Approved')
                                          : _t('Ожидает', 'Pending'),
                                    ),
                                    backgroundColor: (user.isApproved ?? true)
                                        ? const Color(0xFFD1FAE5)
                                        : const Color(0xFFFFEDD5),
                                  ),
                                ],
                              ),
                              subtitle: Text(user.email),
                              trailing: PopupMenuButton<String>(
                                onSelected: (action) async {
                                  if (action == 'profile') {
                                    if (!mounted) return;
                                    Navigator.of(context).push(
                                      MaterialPageRoute(
                                        builder: (_) => UserPublicProfileScreen(
                                          userId: user.id,
                                          client: widget.client,
                                          locale: widget.locale,
                                          errorText: widget.errorText,
                                        ),
                                      ),
                                    );
                                  } else if (action == 'edit') {
                                    await _editUser(user);
                                  } else if (action == 'approve') {
                                    await _approveUser(user);
                                  } else if (action == 'delete') {
                                    await _deleteUser(user);
                                  }
                                },
                                itemBuilder: (context) => [
                                  PopupMenuItem(
                                    value: 'profile',
                                    child: Text(_t('Профиль', 'Profile')),
                                  ),
                                  PopupMenuItem(
                                    value: 'edit',
                                    child: Text(_t('Редактировать', 'Edit')),
                                  ),
                                  if (!(user.isApproved ?? true))
                                    PopupMenuItem(
                                      value: 'approve',
                                      child: Text(_t('Подтвердить', 'Approve')),
                                    ),
                                  PopupMenuItem(
                                    value: 'delete',
                                    child: Text(_t('Удалить', 'Delete')),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ],
            ),
          if (_tab == 1)
            FutureBuilder<List<RequestTicket>>(
              future: _requestsFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  return Text(widget.errorText(snapshot.error!));
                }
                final items = snapshot.data ?? [];
                return Column(
                  children: [
                    for (final item in items)
                      Card(
                        child: ListTile(
                          title: Text(item.requestType),
                          subtitle: Text(
                            '${item.studentName} / ${item.status}',
                          ),
                          trailing: PopupMenuButton<String>(
                            onSelected: (value) {
                              if (value == 'status') {
                                _updateRequestStatus(item);
                              } else if (value == 'delete') {
                                _deleteRequest(item);
                              }
                            },
                            itemBuilder: (context) => [
                              PopupMenuItem(
                                value: 'status',
                                child: Text(
                                  _t('Изменить статус', 'Change status'),
                                ),
                              ),
                              PopupMenuItem(
                                value: 'delete',
                                child: Text(_t('Удалить', 'Delete')),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          if (_tab == 2)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 240,
                  child: DropdownButtonFormField<String>(
                    initialValue: _makeupStatus,
                    items: [
                      DropdownMenuItem(
                        value: 'all',
                        child: Text(_t('Все статусы', 'All statuses')),
                      ),
                      for (final status in kMakeupStatuses)
                        DropdownMenuItem(
                          value: status,
                          child: Text(makeupStatusLabel(status, _isRu)),
                        ),
                    ],
                    onChanged: (value) {
                      if (value == null) return;
                      setState(() => _makeupStatus = value);
                      _reloadAll();
                    },
                    decoration: InputDecoration(
                      labelText: _t('Фильтр статуса', 'Status filter'),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                FutureBuilder<List<MakeupCaseDto>>(
                  future: _makeupsFuture,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    if (snapshot.hasError) {
                      return Text(widget.errorText(snapshot.error!));
                    }
                    final items = snapshot.data ?? [];
                    return Column(
                      children: [
                        for (final item in items)
                          Card(
                            child: ListTile(
                              title: Text(
                                '${item.groupName} - ${item.studentName}',
                              ),
                              subtitle: Text(
                                '${DateFormat('dd.MM.yyyy').format(item.classDate)} / ${makeupStatusLabel(item.status, _isRu)}',
                              ),
                              onTap: () {
                                Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) => MakeupCaseDetailScreen(
                                      caseId: item.id,
                                      client: widget.client,
                                      currentUser: widget.currentUser,
                                      locale: widget.locale,
                                      baseUrl: widget.baseUrl,
                                      errorText: widget.errorText,
                                    ),
                                  ),
                                );
                              },
                              trailing: PopupMenuButton<String>(
                                onSelected: (value) {
                                  if (value == 'open') {
                                    Navigator.of(context).push(
                                      MaterialPageRoute(
                                        builder: (_) => MakeupCaseDetailScreen(
                                          caseId: item.id,
                                          client: widget.client,
                                          currentUser: widget.currentUser,
                                          locale: widget.locale,
                                          baseUrl: widget.baseUrl,
                                          errorText: widget.errorText,
                                        ),
                                      ),
                                    );
                                  } else if (value == 'delete') {
                                    _deleteMakeup(item);
                                  }
                                },
                                itemBuilder: (context) => [
                                  PopupMenuItem(
                                    value: 'open',
                                    child: Text(_t('Открыть', 'Open')),
                                  ),
                                  PopupMenuItem(
                                    value: 'delete',
                                    child: Text(_t('Удалить', 'Delete')),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ],
            ),
          if (_tab == 3)
            FutureBuilder<List<TeacherGroupAssignment>>(
              future: _assignmentsFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  return Text(widget.errorText(snapshot.error!));
                }
                final items = snapshot.data ?? [];
                if (items.isEmpty) {
                  return Text(
                    _t('Назначений пока нет.', 'No assignments yet.'),
                  );
                }
                return Column(
                  children: [
                    for (final item in items)
                      Card(
                        child: ListTile(
                          title: Text(
                            '${item.teacherName} - ${item.groupName}',
                          ),
                          subtitle: Text(item.subject),
                          trailing: PopupMenuButton<String>(
                            onSelected: (value) {
                              if (value == 'edit') {
                                _editAssignment(item);
                              } else if (value == 'delete') {
                                _deleteAssignment(item);
                              }
                            },
                            itemBuilder: (context) => [
                              PopupMenuItem(
                                value: 'edit',
                                child: Text(_t('Изменить', 'Edit')),
                              ),
                              PopupMenuItem(
                                value: 'delete',
                                child: Text(_t('Удалить', 'Delete')),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          if (_tab == 4)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                FutureBuilder<List<String>>(
                  future: _journalGroupsFuture,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    if (snapshot.hasError) {
                      return Text(widget.errorText(snapshot.error!));
                    }
                    final groups = snapshot.data ?? [];
                    if (groups.isNotEmpty &&
                        (_journalGroup == null ||
                            !groups.contains(_journalGroup))) {
                      _journalGroup = groups.first;
                      _journalStudentsFuture = widget.client
                          .listJournalStudents(_journalGroup!);
                      _journalDatesFuture = widget.client.listJournalDates(
                        _journalGroup!,
                      );
                      _attendanceCrudFuture = widget.client.listAttendance(
                        _journalGroup!,
                      );
                      _gradesCrudFuture = widget.client.listGrades(
                        _journalGroup!,
                      );
                    }
                    return Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: DropdownButtonFormField<String>(
                                    initialValue: _journalGroup,
                                    items: [
                                      for (final g in groups)
                                        DropdownMenuItem(
                                          value: g,
                                          child: Text(g),
                                        ),
                                    ],
                                    onChanged: (value) {
                                      if (value == null) return;
                                      setState(() {
                                        _journalGroup = value;
                                      });
                                      _reloadAll();
                                    },
                                    decoration: InputDecoration(
                                      labelText: _t('Группа', 'Group'),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                OutlinedButton.icon(
                                  onPressed: _reloadAll,
                                  icon: const Icon(Icons.refresh),
                                  label: Text(_t('Обновить', 'Refresh')),
                                ),
                                if (_journalGroup != null) ...[
                                  const SizedBox(width: 8),
                                  OutlinedButton.icon(
                                    onPressed: () =>
                                        _deleteJournalGroup(_journalGroup!),
                                    icon: const Icon(Icons.delete_outline),
                                    label: Text(
                                      _t('Удалить группу', 'Delete group'),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            const SizedBox(height: 10),
                            if (_journalGroup != null) ...[
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  FilledButton.tonalIcon(
                                    onPressed: _addJournalStudent,
                                    icon: const Icon(Icons.person_add_alt_1),
                                    label: Text(_t('Студент', 'Student')),
                                  ),
                                  FilledButton.tonalIcon(
                                    onPressed: _addJournalDates,
                                    icon: const Icon(Icons.event_available),
                                    label: Text(_t('Даты', 'Dates')),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 10),
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                    child: Card(
                                      child: Padding(
                                        padding: const EdgeInsets.all(12),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              _t('Студенты', 'Students'),
                                              style: const TextStyle(
                                                fontWeight: FontWeight.w700,
                                              ),
                                            ),
                                            const SizedBox(height: 8),
                                            FutureBuilder<List<String>>(
                                              future: _journalStudentsFuture,
                                              builder: (context, snapshot) {
                                                if (snapshot.connectionState ==
                                                    ConnectionState.waiting) {
                                                  return const Center(
                                                    child:
                                                        CircularProgressIndicator(),
                                                  );
                                                }
                                                if (snapshot.hasError) {
                                                  return Text(
                                                    widget.errorText(
                                                      snapshot.error!,
                                                    ),
                                                  );
                                                }
                                                final students =
                                                    snapshot.data ?? [];
                                                if (students.isEmpty) {
                                                  return Text(
                                                    _t(
                                                      'Студентов пока нет.',
                                                      'No students yet.',
                                                    ),
                                                  );
                                                }
                                                return Wrap(
                                                  spacing: 8,
                                                  runSpacing: 8,
                                                  children: [
                                                    for (final student
                                                        in students)
                                                      Chip(
                                                        label: Text(student),
                                                        onDeleted: () =>
                                                            _deleteJournalStudent(
                                                              student,
                                                            ),
                                                      ),
                                                  ],
                                                );
                                              },
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Card(
                                      child: Padding(
                                        padding: const EdgeInsets.all(12),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              _t('Даты', 'Dates'),
                                              style: const TextStyle(
                                                fontWeight: FontWeight.w700,
                                              ),
                                            ),
                                            const SizedBox(height: 8),
                                            FutureBuilder<List<DateTime>>(
                                              future: _journalDatesFuture,
                                              builder: (context, snapshot) {
                                                if (snapshot.connectionState ==
                                                    ConnectionState.waiting) {
                                                  return const Center(
                                                    child:
                                                        CircularProgressIndicator(),
                                                  );
                                                }
                                                if (snapshot.hasError) {
                                                  return Text(
                                                    widget.errorText(
                                                      snapshot.error!,
                                                    ),
                                                  );
                                                }
                                                final dates =
                                                    snapshot.data ?? [];
                                                if (dates.isEmpty) {
                                                  return Text(
                                                    _t(
                                                      'Дат пока нет.',
                                                      'No dates yet.',
                                                    ),
                                                  );
                                                }
                                                return Wrap(
                                                  spacing: 8,
                                                  runSpacing: 8,
                                                  children: [
                                                    for (final date in dates)
                                                      Chip(
                                                        label: Text(
                                                          DateFormat(
                                                            'dd.MM.yyyy',
                                                          ).format(date),
                                                        ),
                                                        onDeleted: () =>
                                                            _deleteJournalDate(
                                                              date,
                                                            ),
                                                      ),
                                                  ],
                                                );
                                              },
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
          if (_tab == 5)
            FutureBuilder<List<NewsPost>>(
              future: _newsFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  return Text(widget.errorText(snapshot.error!));
                }
                final items = snapshot.data ?? [];
                if (items.isEmpty) {
                  return Text(_t('Новостей пока нет.', 'No news yet.'));
                }
                return Column(
                  children: [
                    for (final post in items)
                      Card(
                        child: ListTile(
                          title: Text(post.title),
                          subtitle: Text(
                            '${post.category} / ${DateFormat('dd.MM.yyyy HH:mm').format(post.createdAt)}',
                          ),
                          trailing: PopupMenuButton<String>(
                            onSelected: (value) {
                              if (value == 'edit') {
                                _editNews(post);
                              } else if (value == 'delete') {
                                _deleteNews(post);
                              }
                            },
                            itemBuilder: (context) => [
                              PopupMenuItem(
                                value: 'edit',
                                child: Text(_t('Изменить', 'Edit')),
                              ),
                              PopupMenuItem(
                                value: 'delete',
                                child: Text(_t('Удалить', 'Delete')),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          if (_tab == 6)
            FutureBuilder<List<ExamUpload>>(
              future: _examUploadsFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  return Text(widget.errorText(snapshot.error!));
                }
                final items = snapshot.data ?? [];
                if (items.isEmpty) {
                  return Text(
                    _t('Загрузок экзаменов пока нет.', 'No exam uploads yet.'),
                  );
                }
                return Column(
                  children: [
                    for (final item in items)
                      Card(
                        child: ListTile(
                          title: Text('${item.groupName} - ${item.examName}'),
                          subtitle: Text(
                            '${item.filename} / ${item.rowsCount} / ${DateFormat('dd.MM.yyyy HH:mm').format(item.uploadedAt)}',
                          ),
                          trailing: PopupMenuButton<String>(
                            onSelected: (value) {
                              if (value == 'edit') {
                                _editExamUpload(item);
                              } else if (value == 'delete') {
                                _deleteExamUpload(item);
                              }
                            },
                            itemBuilder: (context) => [
                              PopupMenuItem(
                                value: 'edit',
                                child: Text(_t('Изменить', 'Edit')),
                              ),
                              PopupMenuItem(
                                value: 'delete',
                                child: Text(_t('Удалить', 'Delete')),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          if (_tab == 7) _buildDepartmentsTreeService(),
          if (_tab == 8) _buildScheduleCrudService(),
          if (_tab == 9) _buildAttendanceCrudService(),
          if (_tab == 10) _buildGradesCrudService(),
          if (_tab == 11) _buildAnalyticsCrudService(),
        ],
      ),
    );
  }
}
