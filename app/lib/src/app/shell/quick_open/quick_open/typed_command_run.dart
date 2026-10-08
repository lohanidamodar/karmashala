part of '../quick_open.dart';

// Picking, completing and running a typed command row.

extension _TypedCommandRun on _QuickOpenState {
  _CommandRow? get _selectedCommandRow {
    if (_flat.isEmpty) return null;
    return _commandRows[_flat[_selected].item.id];
  }

  /// Enter, or a click, on a command row.
  void _pickCommandRow(String id) {
    final row = _commandRows[id];
    if (row == null || !row.enabled) return;
    if (row.completion case final completion?) {
      _accept(completion);
      return;
    }
    if (row.plan case final plan?) {
      _run(plan);
      return;
    }
    if (row.history case final history?) {
      // Run again only what still resolves; anything else goes back into the
      // box, where its preview says what changed.
      final plan = parseTypedCommand('$history ', _catalogNow())?.plan;
      if (plan != null && plan.runnable) {
        _run(plan);
      } else {
        _accept('$history ');
      }
    }
  }

  /// Tab: accept the highlighted suggestion, or the first usable one when the
  /// highlight is on the preview.
  bool _tabComplete() {
    final selected = _selectedCommandRow;
    if (selected == null) return false;
    if (selected.history case final history?) {
      _accept('$history ');
      return true;
    }
    if (selected.completion != null) {
      if (selected.enabled) _accept(selected.completion!);
      return true;
    }
    for (final row in _commandRows.values) {
      if (row.completion != null && row.enabled) {
        _accept(row.completion!);
        return true;
      }
    }
    return true;
  }

  void _accept(String text) {
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _onQueryChanged(text);
  }

  void _run(CommandPlan plan) {
    final action = plan.action;
    if (action == null || !plan.runnable) return;
    if (plan.canonical.isNotEmpty) _recordHistory(plan.canonical);
    final container = ProviderScope.containerOf(context, listen: false);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final host = Navigator.of(context).context;
    final sources = _sources();
    sources.dismiss(() {
      if (action is OpenNewSessionDialogCommand) {
        final projectId = action.projectId;
        NewSessionDialog.show(
          host,
          destination: projectId == null
              ? null
              : SessionDestination(
                  projectId: projectId,
                  checkout: commandDefaultCheckout(container, projectId),
                ),
          firstPrompt: action.firstMessage,
          keepHere: container.read(launchInBackgroundProvider),
          onStarted: (session, {required keptHere}) {
            if (!keptHere) return;
            announceBackgroundLaunch(
              container,
              sessionId: session.id,
              messenger: messenger,
              started: true,
            );
          },
        );
        return;
      }
      if (action is ResumeCommand) {
        // The session jump every session row makes.
        sources.focusSession(action.sessionId, imported: action.imported);
        return;
      }
      // While the palette's ref still reads: the runner's own work outlives it.
      if (action is PeekCommand ||
          (action is StartCommand && action.keepHere)) {
        openOverviewTab(ref);
      }
      final runner = TypedCommandRunner(
        container,
        say: (message) =>
            messenger?.showSnackBar(SnackBar(content: Text(message))),
        announce: (sessionId, {started = false}) => announceBackgroundLaunch(
          container,
          sessionId: sessionId,
          messenger: messenger,
          started: started,
        ),
      );
      if (plan.confirm case final confirm?) {
        unawaited(
          confirmTypedCommand(host, confirm).then((go) {
            if (go) runner.run(action);
          }),
        );
        return;
      }
      runner.run(action);
      // A terminal opened, or a session's ask, is drawn on the session page.
      if (action is OpenTerminalCommand || action is AnswerCommand) {
        sources.phone?.showWorkbench();
      }
    });
  }
}
