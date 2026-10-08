// The menu and the question read off the agent's screen, answered here.
part of '../approval_request_card.dart';

/// The menu on the agent's screen, answered by option — or [orElse] while the
/// screen shows none this can read. The screen is read again while this is
/// up: one menu can follow another (folder trust, then an MCP server) without
/// the session's status changing at all.
class _MenuOr extends ConsumerStatefulWidget {
  const _MenuOr({
    required this.sessionId,
    required this.agentName,
    required this.orElse,
    this.docked = false,
    this.menus,
    this.rules,
    this.dockedAsk,
  });

  final String sessionId;
  final String agentName;
  final Widget orElse;

  /// In the ask dock: each option is its own button (board N1) rather than
  /// the phone's pick-then-confirm list.
  final bool docked;

  /// How the agent draws its menus — which option means yes and which no, so
  /// the dock can fill the one and mark the other. Null names neither.
  final AgentMenuSupport? menus;

  /// The agent's own approve and deny keys, named on the options they are
  /// honestly the same as.
  final AgentApprovalRules? rules;

  /// Docked, the structured ask's answers for [menu] — or null when [menu] is
  /// not the prompt the ask is about, which then draws as its own options.
  final Widget? Function(
    AgentScreenMenu menu,
    Future<void> Function(int option) choose,
  )?
  dockedAsk;

  @override
  ConsumerState<_MenuOr> createState() => _MenuOrState();
}

class _MenuOrState extends ConsumerState<_MenuOr> {
  AgentScreenMenu? _menu;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _menu = _read();
    _timer = Timer.periodic(kMenuRereadInterval, (_) {
      final now = _read();
      if (now?.id != _menu?.id || now?.highlighted != _menu?.highlighted) {
        setState(() => _menu = now);
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  AgentScreenMenu? _read() =>
      ref.read(sessionPromptAnswersProvider).menuOnScreen(widget.sessionId);

  Future<void> _choose(AgentScreenMenu menu, int option) => _send(
    MenuAnswerRequest(
      sessionId: widget.sessionId,
      menuId: menu.id,
      option: option,
    ),
    said: 'Chosen.',
  );

  Future<void> _send(MenuAnswerRequest request, {required String said}) async {
    final answerSaid = _AnswerSaid.of(context);
    try {
      await ref.read(sessionPromptAnswersProvider).answer(request);
    } on SessionPromptRefusal catch (refusal) {
      // Worded for the card's own snack bar, which reads a gateway refusal.
      throw GatewayException(
        answerSaid == null
            ? refusal.message
            : approvalRefusalText(refusal, touch: true),
      );
    }
    answerSaid?.say(said);
    if (mounted) setState(() => _menu = _read());
  }

  @override
  Widget build(BuildContext context) {
    final menu = _menu;
    if (menu == null) return widget.orElse;
    final submit = menu.submit;
    if (menu.isChecklist && submit != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          ChecklistPromptCard(
            agentName: widget.agentName,
            menu: remoteMenuOf(menu),
            onSubmit: (ticks) => _send(
              MenuAnswerRequest.checklist(
                sessionId: widget.sessionId,
                menuId: menu.id,
                submit: submit,
                ticks: ticks,
              ),
              said: 'Submitted.',
            ),
            onReject: () => _send(
              MenuAnswerRequest.dismiss(
                sessionId: widget.sessionId,
                menuId: menu.id,
              ),
              said: 'Rejected.',
            ),
            onOpenTerminal: _hasTerminal(ref, widget.sessionId)
                ? () => _openTerminal(ref, widget.sessionId)
                : null,
          ),
          _TerminalLink(sessionId: widget.sessionId),
        ],
      );
    }
    if (widget.docked) {
      final asked = widget.dockedAsk?.call(
        menu,
        (option) => _choose(menu, option),
      );
      if (asked != null) return asked;
      final menus = widget.menus;
      final affirmative = menus?.affirmativeIn(menu);
      final negative = menus?.negativeIn(menu);
      final approve = widget.rules?.approve;
      final deny = widget.rules?.deny;
      return _DockMenu(
        menu: menu,
        affirmative: affirmative,
        // A key cap only where the key is honestly the same answer: Enter
        // on the option already highlighted, and the agent's cancel where
        // it declines safely.
        affirmativeKey: affirmative == menu.highlighted && approve != null
            ? _keyName(approve.keys)
            : null,
        negative: negative,
        negativeKey:
            negative != null &&
                deny != null &&
                (menus?.cancelDeclinesIn(menu) ?? false)
            ? _keyName(deny.keys)
            : null,
        sessionId: widget.sessionId,
        onChoose: (option) => _choose(menu, option),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        MenuPromptCard(
          agentName: widget.agentName,
          menu: remoteMenuOf(menu),
          onChoose: (option) => _choose(menu, option),
        ),
        _TerminalLink(sessionId: widget.sessionId),
      ],
    );
  }
}

/// The agent's open question, answered with the options picked — or [orElse]
/// while it cannot be read.
class _QuestionOr extends ConsumerWidget {
  const _QuestionOr({
    required this.sessionId,
    required this.agentName,
    required this.orElse,
    this.where,
    this.trailing,
    this.dense = false,
    this.board = false,
    this.onReplyInWords,
    this.controller,
    this.onAnswered,
  });

  final String sessionId;
  final String agentName;
  final Widget orElse;

  /// See [QuestionPromptCard.dense]; the caller draws the header.
  final bool dense;

  /// See [ApprovalRequestCard.board].
  final bool board;
  final VoidCallback? onReplyInWords;
  final QuestionPromptController? controller;
  final VoidCallback? onAnswered;

  /// See [QuestionPromptCard.where] and [QuestionPromptCard.trailing].
  final String? where;
  final Widget? trailing;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The value only: a re-read while the question is unreadable is no change.
    final question = ref.watch(
      chatOpenQuestionProvider(sessionId).select((q) => q.value),
    );
    if (question == null) return orElse;
    final agentId = ref
        .read(agentSessionStatusProvider(sessionId))
        .asData
        ?.value
        .agentId;
    final chatRow = agentId == null
        ? null
        : ref.read(agentRegistryProvider).byId(agentId)?.questions?.chatRow;
    return QuestionPromptCard(
      agentName: agentName,
      question: question,
      chatLabel: chatRow,
      where: where,
      trailing: trailing,
      dense: dense,
      showHeader: !dense,
      numbered: board,
      onReplyInWords: onReplyInWords,
      controller: controller,
      onAnswerInTerminal: _hasTerminal(ref, sessionId)
          ? () => _openTerminal(ref, sessionId)
          : null,
      onAnswer: (answers, {decline = false, chat = false}) async {
        final said = _AnswerSaid.of(context);
        try {
          await ref.read(chatQuestionAnswerProvider)(
            RemoteQuestionAnswerRequest(
              sessionId: sessionId,
              toolUseId: question.toolUseId,
              answers: answers,
              decline: decline,
              chat: chat,
            ),
          );
        } on RemoteApiRefusal catch (refusal) {
          throw GatewayException(refusal.message);
        }
        said?.say(
          decline
              ? 'Declined.'
              : chat
              ? 'Left to talk over.'
              : 'Answered.',
        );
        if (!chat) onAnswered?.call();
      },
    );
  }
}
