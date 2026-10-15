part of '../approval_request_card.dart';

/// The board's three keys for a command approval: Y, A and D.
enum BoardApproval { allow, always, deny }

/// What [report]'s open approval offers, as the dock draws it ([_openAnswers]):
/// an ACP agent's own options, else the agent's keys and the menu option that
/// keeps approving — read only off the prompt the call raised.
List<_OpenAnswer> _boardAnswers(
  ProviderReader read,
  String sessionId,
  AgentStatusReport report,
) {
  final descriptor = read(agentRegistryProvider).byId(report.agentId);
  final rules = _rulesOf(descriptor);
  if (report.toolAsk?.options.isNotEmpty ?? false) {
    return _openAnswers(sessionId, report, rules: rules);
  }
  final menus = descriptor?.menus;
  final onScreen = read(sessionPromptAnswersProvider).menuOnScreen(sessionId);
  final menu = onScreen != null && (menus?.cancelDeclinesIn(onScreen) ?? false)
      ? onScreen
      : null;
  return _openAnswers(
    sessionId,
    report,
    rules: rules,
    menu: menu,
    menus: menus,
    ask: PromptAsk.drawnFrom(
      report,
      menu: read(promptMenuAtSessionGridProvider)(sessionId) ? menu : null,
    ),
  );
}

/// Sends [answer]: null when it went, else why not.
Future<String?> _sendBoardAnswer(
  ProviderReader read,
  _OpenAnswer answer,
) async {
  try {
    await read(sessionPromptAnswersProvider).answer(answer.request);
    return null;
  } on SessionPromptRefusal catch (refusal) {
    return approvalRefusalText(refusal);
  }
}

/// The status of [sessionId] when it waits on a command approval this machine
/// can answer; null otherwise.
AgentStatusReport? _boardAsk(ProviderReader read, String sessionId) {
  final report = read(sessionStatusLookupProvider)(sessionId);
  if (report == null ||
      report.status != AgentActivityStatus.awaitingApproval ||
      report.waiting != AgentWaitKind.approval ||
      report.toolAsk == null ||
      !read(sessionAnswerableProvider)(sessionId)) {
    return null;
  }
  return report;
}

/// Reads a provider: a widget's `ref.read`, or a container's `read` where no
/// widget is left to ask — quick open runs after its dialog has closed.
typedef ProviderReader = T Function<T>(ProviderListenable<T> provider);

/// Which [BoardApproval]s [sessionId]'s open approval offers right now.
Set<BoardApproval> boardApprovalOffers(WidgetRef ref, String sessionId) =>
    boardApprovalOffersBy(ref.read, sessionId);

/// [boardApprovalOffers], read through [read].
Set<BoardApproval> boardApprovalOffersBy(
  ProviderReader read,
  String sessionId,
) {
  final report = _boardAsk(read, sessionId);
  return report == null
      ? const {}
      : _boardKeys(_boardAnswers(read, sessionId, report)).keys.toSet();
}

/// Answers [sessionId]'s open approval with [kind]: null when it was sent,
/// else why nothing was.
Future<String?> answerBoardApproval(
  WidgetRef ref,
  String sessionId,
  BoardApproval kind,
) => answerBoardApprovalBy(ref.read, sessionId, kind);

/// [answerBoardApproval], read through [read].
Future<String?> answerBoardApprovalBy(
  ProviderReader read,
  String sessionId,
  BoardApproval kind,
) async {
  final report = _boardAsk(read, sessionId);
  if (report == null) return 'There is no approval open to answer.';
  final answer = _boardKeys(_boardAnswers(read, sessionId, report))[kind];
  if (answer == null) {
    return switch (kind) {
      BoardApproval.always => 'This prompt offers no way to always allow.',
      BoardApproval.deny => 'This prompt names no way to decline.',
      BoardApproval.allow => 'This prompt names no way to allow.',
    };
  }
  return _sendBoardAnswer(read, answer);
}

/// **A command approval on the Overview's board**: the command in two lines
/// at most, why it asks, where it runs, then Edit… and every answer the dock
/// would offer, in the agent's words and order.
class _BoardApprovalAnswers extends ConsumerStatefulWidget {
  const _BoardApprovalAnswers({
    required this.sessionId,
    required this.report,
    required this.summary,
    this.where,
    this.onEdit,
    this.onAnswered,
  });

  final String sessionId;
  final AgentStatusReport report;
  final ToolAskSummary summary;
  final String? where;
  final VoidCallback? onEdit;
  final VoidCallback? onAnswered;

  @override
  ConsumerState<_BoardApprovalAnswers> createState() =>
      _BoardApprovalAnswersState();
}

class _BoardApprovalAnswersState extends ConsumerState<_BoardApprovalAnswers> {
  bool _busy = false;

  Future<void> _answer(_OpenAnswer answer) async {
    if (_busy) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    final refused = await _sendBoardAnswer(ref.read, answer);
    if (refused != null) {
      messenger.showSnackBar(SnackBar(content: Text(refused)));
    } else {
      widget.onAnswered?.call();
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final density = UiDensity.of(context);
    final summary = widget.summary;
    final sessionId = widget.sessionId;
    final answers = _boardAnswers(ref.read, sessionId, widget.report);
    final keys = _boardKeys(answers);
    BoardApproval? keyOf(_OpenAnswer answer) =>
        keys.entries.where((e) => identical(e.value, answer)).firstOrNull?.key;
    final idle = !_busy;
    final where = widget.where;
    final why = _askWhy(widget.report.toolAsk);
    final described = switch (widget.report.toolAsk?.input['description']) {
      final String text when text.trim().isNotEmpty => text.trim(),
      _ => null,
    };
    return Column(
      key: ValueKey('board-approval:$sessionId'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (described != null)
          Text(
            described,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall,
          ),
        if (summary.subject.isNotEmpty) ...[
          const SizedBox(height: Insets.xs),
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: Insets.sm,
              vertical: Insets.xs,
            ),
            decoration: BoxDecoration(
              color: SurfaceTones.of(context).term,
              borderRadius: BorderRadius.circular(Radii.sm),
            ),
            child: Tooltip(
              message: summary.subject,
              child: Text(
                summary.subject,
                key: ValueKey('board-command:$sessionId'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: MonoStyles.small.copyWith(color: scheme.onSurface),
              ),
            ),
          ),
        ],
        if (why.isNotEmpty) ...[
          const SizedBox(height: Insets.xs),
          Tooltip(
            message: why,
            child: Text(
              why,
              key: ValueKey('board-ask-reason:$sessionId'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: density.muted(theme),
            ),
          ),
        ],
        if (where != null && where.isNotEmpty) ...[
          const SizedBox(height: Insets.xs),
          Text(
            where,
            key: ValueKey('board-where:$sessionId'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: density.muted(theme),
          ),
        ],
        const SizedBox(height: Insets.sm),
        Wrap(
          alignment: WrapAlignment.end,
          spacing: Insets.xs,
          runSpacing: Insets.xs,
          children: [
            // Edit… denies first: only where D has a deny to send.
            if (widget.onEdit != null && keys.containsKey(BoardApproval.deny))
              TextButton(
                key: ValueKey('board-edit:$sessionId'),
                onPressed: idle ? widget.onEdit : null,
                child: const Text('Edit…'),
              ),
            for (final answer in answers)
              ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: _dockOptionMaxWidth,
                ),
                child: _DockButton(
                  key: ValueKey(switch (keyOf(answer)) {
                    final key? => 'board-${key.name}:$sessionId',
                    null => 'board-option-${answer.id}:$sessionId',
                  }),
                  label: answer.label,
                  detail: answer.detail,
                  tooltip: answer.tooltip,
                  keyHint: switch (keyOf(answer)) {
                    BoardApproval.allow => 'Y',
                    BoardApproval.always => 'A',
                    BoardApproval.deny => 'D',
                    null => null,
                  },
                  primary: answer.primary,
                  wrap: true,
                  onPressed: idle ? () => _answer(answer) : null,
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// The words that send an edited command in place of the one denied.
String editedCommandMessage(String command) =>
    'Not that command. Run this instead:\n$command';

/// Denies [sessionId]'s open approval, then sends [command] as what to run
/// instead, through the one send path: null when both went, else why not.
Future<String?> runEditedCommand(
  WidgetRef ref,
  String sessionId,
  String command,
) async {
  final edited = command.trim();
  if (edited.isEmpty) return 'The command is empty.';
  final actions = ref.read(sessionActionsProvider);
  final refused = await answerBoardApproval(ref, sessionId, BoardApproval.deny);
  if (refused != null) return refused;
  try {
    await actions.continueSession(sessionId, editedCommandMessage(edited));
    return null;
  } on Object catch (error) {
    return 'Denied, but the edited command was not sent: $error';
  }
}

/// **The command of [sessionId]'s open approval, open to change**: Run
/// edited denies the original and sends the edit in its place.
class BoardEditCommand extends ConsumerStatefulWidget {
  const BoardEditCommand({
    required this.sessionId,
    required this.onDone,
    super.key,
  });

  final String sessionId;

  /// Run edited went, or Cancel was pressed.
  final VoidCallback onDone;

  @override
  ConsumerState<BoardEditCommand> createState() => _BoardEditCommandState();
}

class _BoardEditCommandState extends ConsumerState<BoardEditCommand> {
  late final TextEditingController _text;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final ask = ref
        .read(sessionStatusLookupProvider)(widget.sessionId)
        ?.toolAsk;
    _text = TextEditingController(
      text: ask == null ? '' : summarizeToolAsk(ask).subject,
    );
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    if (_busy) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    final refused = await runEditedCommand(ref, widget.sessionId, _text.text);
    if (!mounted) return;
    setState(() => _busy = false);
    if (refused != null) {
      messenger.showSnackBar(SnackBar(content: Text(refused)));
      return;
    }
    widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      key: ValueKey('board-edit-command:${widget.sessionId}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          key: const ValueKey('board-edit-field'),
          controller: _text,
          autofocus: true,
          enabled: !_busy,
          minLines: 1,
          maxLines: 6,
          style: MonoStyles.small.copyWith(color: theme.colorScheme.onSurface),
          decoration: const InputDecoration(
            isDense: true,
            labelText: 'Command to run instead',
          ),
        ),
        const SizedBox(height: Insets.sm),
        Wrap(
          alignment: WrapAlignment.end,
          spacing: Insets.xs,
          children: [
            TextButton(
              onPressed: _busy ? null : widget.onDone,
              child: const Text('Cancel'),
            ),
            Tooltip(
              message:
                  'Denies the command it asked for, then asks it to run '
                  'this one',
              child: FilledButton(
                key: const ValueKey('board-run-edited'),
                onPressed: _busy ? null : _run,
                child: const Text('Run edited'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Reveals [sessionId]'s terminal in the workbench, as "Answer in the
/// terminal" does.
void openSessionTerminal(WidgetRef ref, String sessionId) =>
    _openTerminal(ref, sessionId);
