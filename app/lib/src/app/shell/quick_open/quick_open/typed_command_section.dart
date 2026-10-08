part of '../quick_open.dart';

// The palette's typed command rows: history, suggestions and the plan.

extension _TypedCommandSection on _QuickOpenState {
  // --- typed commands --------------------------------------------------------

  List<String> _readHistory() {
    try {
      return ref.read(typedCommandHistoryProvider).list();
    } catch (_) {
      // No store (a test harness without one) is no history, not a crash.
      return const [];
    }
  }

  void _recordHistory(String command) {
    try {
      ref.read(typedCommandHistoryProvider).record(command);
    } catch (_) {
      // Remembering is a convenience; failing to must not stop the command.
    }
  }

  CommandCatalog _catalogNow() => _catalog ??= readCommandCatalog(
    ProviderScope.containerOf(context, listen: false),
    notGitProjectIds: _notGit,
    conversationHits: (query) =>
        _hits.hitsFor(query, kCommandSuggestionLimit) ?? const [],
  );

  /// The rows a typed verb, or an empty box with history, puts above the
  /// search — or null, which leaves the palette exactly as it always was.
  QuickOpenSection? _commandSection() {
    _commandRows.clear();
    final text = _controller.text;
    if (text.trim().isEmpty) return _historySection();
    if (typedCommandVerbOf(text) == null && !typedCommandMayOpenSession(text)) {
      return null;
    }
    final typed = parseTypedCommand(text, _catalogNow());
    if (typed == null) return null;
    _askGitFor(typed);
    _readQuestionsFor(typed);

    final items = <QuickOpenItem>[];
    void add(String id, _CommandRow row, QuickOpenItem Function(String) make) {
      _commandRows[id] = row;
      items.add(make(id));
    }

    final error = typed.error;
    if (error != null) {
      add(
        'command/error',
        const _CommandRow(enabled: false),
        (id) => _commandItem(id, title: error, icon: AppIcons.warningCircle),
      );
    }
    final plan = typed.plan;
    if (plan != null) {
      add(
        'command/plan',
        _CommandRow(plan: plan, enabled: plan.runnable),
        (id) => _commandItem(
          id,
          title: plan.preview,
          subtitle: plan.refusal ?? plan.note ?? 'Enter to run',
          icon: plan.runnable ? AppIcons.playCircle : AppIcons.prohibit,
        ),
      );
    }
    for (final launch in typed.launches) {
      add(
        'command/launch/${launch.preview}',
        _CommandRow(plan: launch, enabled: launch.runnable),
        (id) => _commandItem(
          id,
          title: launch.preview,
          subtitle: launch.refusal ?? launch.note,
          icon: !launch.runnable
              ? AppIcons.prohibit
              : launch.action is OpenNewSessionDialogCommand
              ? AppIcons.chatCircleDots
              : AppIcons.playCircle,
        ),
      );
    }
    for (final suggestion in typed.suggestions) {
      add(
        'command/${suggestion.id}',
        _CommandRow(
          completion: suggestion.completion,
          enabled: suggestion.enabled,
          dot: suggestion.dot,
        ),
        (id) => _commandItem(
          id,
          title: suggestion.label,
          subtitle: suggestion.hint,
          detail: suggestion.disabledReason ?? suggestion.detail,
          icon: _iconFor(suggestion.kind),
        ),
      );
    }
    if (items.isEmpty) return null;
    return QuickOpenSection(
      group: QuickOpenGroup.command,
      results: [
        for (final item in items)
          QuickOpenResult(item: item, score: 0, titlePositions: const []),
      ],
    );
  }

  QuickOpenSection? _historySection() {
    if (_history.isEmpty) return null;
    final results = <QuickOpenResult>[];
    for (final (index, command)
        in _history.take(kTypedCommandHistoryShown).indexed) {
      final id = 'history/$index';
      _commandRows[id] = _CommandRow(history: command);
      results.add(
        QuickOpenResult(
          item: _commandItem(
            id,
            title: command,
            subtitle: 'Enter to run again · Tab to edit',
            icon: AppIcons.clockCounterClockwise,
            group: QuickOpenGroup.history,
          ),
          score: 0,
          titlePositions: const [],
        ),
      );
    }
    return QuickOpenSection(group: QuickOpenGroup.history, results: results);
  }

  QuickOpenItem _commandItem(
    String id, {
    required String title,
    required IconData icon,
    String? subtitle,
    String? detail,
    QuickOpenGroup group = QuickOpenGroup.command,
  }) => QuickOpenItem(
    id: id,
    group: group,
    title: title,
    subtitle: subtitle,
    detail: detail,
    icon: icon,
    onSelect: () => _pickCommandRow(id),
  );

  static IconData _iconFor(CommandArgKind kind) => switch (kind) {
    CommandArgKind.project => AppIcons.folder,
    CommandArgKind.agent => AppIcons.robot,
    CommandArgKind.session => AppIcons.chatCircle,
    CommandArgKind.environment || CommandArgKind.keyword => AppIcons.terminal,
    CommandArgKind.flag => AppIcons.gitBranch,
    CommandArgKind.option => AppIcons.listChecks,
  };
}
