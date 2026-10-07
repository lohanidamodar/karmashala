part of '../approval_request_card.dart';

/// The three answers the Overview's board gives a command approval, by
/// button or by key.
enum BoardApproval { allow, always, deny }

/// What answers [report]'s open approval would send for each
/// [BoardApproval], through the paths the dock uses: an ACP agent's own
/// options, else the agent's approve and deny keys, and Always by the menu
/// option that keeps approving. Absent where the prompt offers none.
Map<BoardApproval, Future<void> Function()> _boardAnswers(
  WidgetRef ref,
  String sessionId,
  AgentStatusReport report,
) {
  final answers = ref.read(sessionPromptAnswersProvider);
  Future<void> send(ApprovalAnswerRequest request) => answers.answer(request);
  final offered = report.toolAsk?.options ?? const <AgentToolAskOption>[];
  if (offered.isNotEmpty) {
    AgentToolAskOption? kind(String k) =>
        offered.where((o) => o.kind == k).firstOrNull;
    final ask = PromptAsk.drawnFrom(report);
    Future<void> Function() choose(AgentToolAskOption option) =>
        () => send(
          ApprovalAnswerRequest(
            sessionId: sessionId,
            approve: option.allows,
            optionId: option.id,
            ask: ask,
          ),
        );
    return {
      if (kind('allow_once') case final o?) BoardApproval.allow: choose(o),
      if (kind('allow_always') case final o?) BoardApproval.always: choose(o),
      if (kind('reject_once') case final o?) BoardApproval.deny: choose(o),
    };
  }
  final descriptor = ref.read(agentRegistryProvider).byId(report.agentId);
  final rules = descriptor?.approval ?? const AgentApprovalRules();
  final menu = answers.menuOnScreen(sessionId);
  final ask = PromptAsk.drawnFrom(
    report,
    menu: ref.read(promptMenuAtSessionGridProvider)(sessionId) ? menu : null,
  );
  final always = menu == null ? null : _alwaysOption(menu, descriptor?.menus);
  return {
    if (rules.approve != null)
      BoardApproval.allow: () => send(
        ApprovalAnswerRequest(sessionId: sessionId, approve: true, ask: ask),
      ),
    if (always != null && menu != null)
      BoardApproval.always: () => answers.answer(
        MenuAnswerRequest(
          sessionId: sessionId,
          menuId: menu.id,
          option: always.index,
        ),
      ),
    if (rules.deny != null)
      BoardApproval.deny: () => send(
        ApprovalAnswerRequest(sessionId: sessionId, approve: false, ask: ask),
      ),
  };
}

/// The status of [sessionId] when it waits on a command approval this machine
/// can answer; null otherwise.
AgentStatusReport? _boardAsk(WidgetRef ref, String sessionId) {
  final report = ref.read(sessionStatusLookupProvider)(sessionId);
  if (report == null ||
      report.status != AgentActivityStatus.awaitingApproval ||
      report.waiting != AgentWaitKind.approval ||
      report.toolAsk == null ||
      !ref.read(sessionAnswerableProvider)(sessionId)) {
    return null;
  }
  return report;
}

/// Which [BoardApproval]s [sessionId]'s open approval offers right now.
Set<BoardApproval> boardApprovalOffers(WidgetRef ref, String sessionId) {
  final report = _boardAsk(ref, sessionId);
  return report == null
      ? const {}
      : _boardAnswers(ref, sessionId, report).keys.toSet();
}

/// Answers [sessionId]'s open approval with [kind]: null when it was sent,
/// else why nothing was.
Future<String?> answerBoardApproval(
  WidgetRef ref,
  String sessionId,
  BoardApproval kind,
) async {
  final report = _boardAsk(ref, sessionId);
  if (report == null) return 'There is no approval open to answer.';
  final send = _boardAnswers(ref, sessionId, report)[kind];
  if (send == null) {
    return switch (kind) {
      BoardApproval.always => 'This prompt offers no way to always allow.',
      BoardApproval.deny => 'This prompt names no way to decline.',
      BoardApproval.allow => 'This prompt names no way to allow.',
    };
  }
  try {
    await send();
    return null;
  } on SessionPromptRefusal catch (refusal) {
    return _approvalRefusalText(refusal);
  }
}

/// **A command approval on the Overview's board**: the command in two lines
/// at most, where it runs, and Edit…, Deny, Always and Allow.
class _BoardApprovalAnswers extends ConsumerStatefulWidget {
  const _BoardApprovalAnswers({
    required this.sessionId,
    required this.report,
    required this.summary,
    this.where,
    this.onEdit,
  });

  final String sessionId;
  final AgentStatusReport report;
  final ToolAskSummary summary;
  final String? where;
  final VoidCallback? onEdit;

  @override
  ConsumerState<_BoardApprovalAnswers> createState() =>
      _BoardApprovalAnswersState();
}

class _BoardApprovalAnswersState extends ConsumerState<_BoardApprovalAnswers> {
  bool _busy = false;

  Future<void> _answer(BoardApproval kind) async {
    if (_busy) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    final refused = await answerBoardApproval(ref, widget.sessionId, kind);
    if (refused != null) {
      messenger.showSnackBar(SnackBar(content: Text(refused)));
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final density = UiDensity.of(context);
    final summary = widget.summary;
    final offers = _boardAnswers(ref, widget.sessionId, widget.report).keys;
    final idle = !_busy;
    final where = widget.where;
    final described = switch (widget.report.toolAsk?.input['description']) {
      final String text when text.trim().isNotEmpty => text.trim(),
      _ => null,
    };
    return Column(
      key: ValueKey('board-approval:${widget.sessionId}'),
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
                key: ValueKey('board-command:${widget.sessionId}'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: MonoStyles.small.copyWith(color: scheme.onSurface),
              ),
            ),
          ),
        ],
        if (where != null && where.isNotEmpty) ...[
          const SizedBox(height: Insets.xs),
          Text(
            where,
            key: ValueKey('board-where:${widget.sessionId}'),
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
            if (widget.onEdit != null)
              TextButton(
                key: ValueKey('board-edit:${widget.sessionId}'),
                onPressed: idle ? widget.onEdit : null,
                child: const Text('Edit…'),
              ),
            if (offers.contains(BoardApproval.deny))
              _DockButton(
                key: ValueKey('board-deny:${widget.sessionId}'),
                label: 'Deny',
                keyHint: 'D',
                onPressed: idle ? () => _answer(BoardApproval.deny) : null,
              ),
            if (offers.contains(BoardApproval.always))
              _DockButton(
                key: ValueKey('board-always:${widget.sessionId}'),
                label: 'Always',
                keyHint: 'A',
                onPressed: idle ? () => _answer(BoardApproval.always) : null,
              ),
            if (offers.contains(BoardApproval.allow))
              _DockButton(
                key: ValueKey('board-allow:${widget.sessionId}'),
                label: 'Allow',
                keyHint: 'Y',
                primary: true,
                onPressed: idle ? () => _answer(BoardApproval.allow) : null,
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
    final ask = ref.read(sessionStatusLookupProvider)(widget.sessionId)?.toolAsk;
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
              message: 'Denies the command it asked for, then asks it to run '
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
