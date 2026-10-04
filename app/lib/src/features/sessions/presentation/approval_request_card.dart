import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_agent_status/karmashala_agent_status.dart';
import 'package:karmashala_companion_server/karmashala_companion_server.dart'
    show remoteMenuOf;
import 'package:karmashala_remote/client.dart' show GatewayException;
import 'package:karmashala_remote/host.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import '../../../app/widgets/adaptive_modal.dart';
import '../../../core/capabilities/capabilities.dart'
    show capabilitiesProvider, kApprovalNotGranted;
import '../../../core/util/clock_provider.dart';
import '../../agents/application/agent_providers.dart';
import 'package:agent_cli/descriptors.dart';
import '../../remote/application/remote_approval_bindings.dart';
import '../../terminal/application/terminal_sessions_controller.dart';
import '../../explorer/application/agent_state_providers.dart';
import '../application/ask_resolutions.dart';
import '../application/session_input.dart';
import '../application/session_prompt_answers.dart';
import '../application/session_status_providers.dart';
import 'prompt_cards/menu_prompt_card.dart';
import 'prompt_cards/question_prompt_card.dart';
import 'chat_cards/chat_tool_ask.dart' show ChatToolAsk, chatInlineAsksProvider;

part 'approval_request_card/answered_elsewhere.dart';
part 'approval_request_card/ask_dock.dart';
part 'approval_request_card/dock_buttons.dart';
part 'approval_request_card/tool_ask_answers.dart';

const _noLiveTerminal =
    'This session has no live terminal here, so it cannot be answered from '
    'Karmashala.';

/// The pending approval for one session, and the buttons that answer it. It
/// never words the request itself, and offers only keys the agent named.
class ApprovalRequestCard extends ConsumerWidget {
  const ApprovalRequestCard({
    required this.sessionId,
    this.docked = false,
    this.touch = false,
    this.inline = false,
    super.key,
  });

  final String sessionId;

  /// Docked above the terminal pane's status line (spec §5, the ask dock):
  /// the same card, without the way to a terminal it is already under.
  final bool docked;

  /// The phone's session page (Stage 2 step 5): the dock's answers stacked at
  /// [Touch.target], no key caps, and a reason typed in a sheet.
  final bool touch;

  /// Drawn in the chat under the call it is about ([ChatToolAsk]). The dock
  /// steps aside while one is, so the answers are on screen once.
  final bool inline;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (docked &&
        !inline &&
        ref.watch(chatInlineAsksProvider.select((s) => s.contains(sessionId)))) {
      return const SizedBox.shrink();
    }
    final report = ref
        .watch(agentSessionStatusProvider(sessionId))
        .asData
        ?.value;
    final asking = report != null && _asks(report) ? report : null;
    final card = asking == null
        ? const SizedBox.shrink()
        : _open(context, ref, asking);
    // Where the desktop shows the other screen, a phone's dock under a thumb
    // would simply vanish (Stage 3 step 4).
    return !touch
        ? card
        : _AnsweredElsewhere(sessionId: sessionId, asking: asking, child: card);
  }

  bool _asks(AgentStatusReport report) =>
      report.status == AgentActivityStatus.awaitingApproval &&
      // Docked, it is an ask or nothing: an agent that finished a turn and
      // waits for input has nothing to answer here, and an amber card saying
      // so under the prompt was the complaint that removed the first dock.
      (!docked ||
          report.waiting == AgentWaitKind.approval ||
          report.waiting == AgentWaitKind.question);

  Widget _open(BuildContext context, WidgetRef ref, AgentStatusReport report) {
    final waiting = report.waiting;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final descriptor = ref.read(agentRegistryProvider).byId(report.agentId);
    // An ACP agent types no keys: its request is answered by option.
    final rules = descriptor?.acp != null
        ? AcpLaunchSpec.permissionAnswers
        : descriptor?.approval ?? const AgentApprovalRules();
    final agentName = descriptor?.displayName ?? report.agentId;
    // A pane we can type into, or a process this machine's host runs and
    // answers in. Without either — an external terminal, a session whose
    // process has gone — the buttons would silently do nothing.
    final canAnswer = ref.read(sessionAnswerableProvider)(sessionId);
    // Why it cannot, in the companion's words when it is the phone's grant.
    final cannot = ref.watch(capabilitiesProvider.select((c) => c.mayApprove))
        ? _noLiveTerminal
        : kApprovalNotGranted;

    if (docked) {
      final dock = _AskDock(
        sessionId: sessionId,
        report: report,
        agentName: agentName,
        rules: rules,
        menus: descriptor?.menus,
        canAnswer: canAnswer,
        cannot: cannot,
      );
      return _Docked(
        touch: touch,
        child: !touch
            ? dock
            // Stacked 48dp answers can outgrow a phone held sideways; the
            // chat keeps the rest of the page.
            : ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height * _touchDockShare,
                ),
                child: SingleChildScrollView(primary: false, child: dock),
              ),
      );
    }

    final standard = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Icon(
              waiting == AgentWaitKind.approval
                  ? AppIcons.warningCircle
                  : AppIcons.chatCircleDots,
              size: Chrome.iconAction,
              color: scheme.tertiary,
            ),
            const SizedBox(width: Insets.xs),
            Expanded(
              child: Text(switch (waiting) {
                AgentWaitKind.approval => '$agentName is waiting for you',
                AgentWaitKind.input => '$agentName is waiting for your input',
                AgentWaitKind.unrecorded => '$agentName needs your attention',
                AgentWaitKind.question => '$agentName is asking you a question',
              }, style: theme.textTheme.labelLarge),
            ),
          ],
        ),
        const SizedBox(height: Insets.xs),
        _Evidence(report: report, agentName: agentName),
        const SizedBox(height: Insets.sm),
        if (waiting == AgentWaitKind.approval)
          _Answers(
            sessionId: sessionId,
            report: report,
            rules: rules,
            agentName: agentName,
            canAnswer: canAnswer,
            cannot: cannot,
          )
        else
          _NothingToAnswer(
            sessionId: sessionId,
            waiting: waiting,
            agentName: agentName,
          ),
      ],
    );

    final card = Container(
      // Flush with the composer stack it is pinned above.
      margin: const EdgeInsets.fromLTRB(8, 0, 8, 6),
      padding: const EdgeInsets.all(Insets.sm),
      // Amber, the one colour that means "needs you" (spec §5): the ask is
      // the thing on screen that is blocking the session.
      decoration: BoxDecoration(
        color: SurfaceTones.of(context).attentionSurface,
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(color: SurfaceTones.of(context).attentionEdge),
      ),
      // The phone's cards, answered through the phone's own guarded paths:
      // a menu by the option chosen, a question by the options picked. Never
      // Approve — Enter — on either.
      child: !canAnswer
          ? standard
          : switch (waiting) {
              AgentWaitKind.approval => _MenuOr(
                sessionId: sessionId,
                agentName: agentName,
                orElse: standard,
              ),
              AgentWaitKind.question => _QuestionOr(
                sessionId: sessionId,
                agentName: agentName,
                orElse: standard,
              ),
              _ => standard,
            },
    );
    return card;
  }
}

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

  Future<void> _choose(AgentScreenMenu menu, int option) async {
    final said = _AnswerSaid.of(context);
    try {
      await ref
          .read(sessionPromptAnswersProvider)
          .answer(
            MenuAnswerRequest(
              sessionId: widget.sessionId,
              menuId: menu.id,
              option: option,
            ),
          );
    } on SessionPromptRefusal catch (refusal) {
      // Worded for the card's own snack bar, which reads a gateway refusal.
      throw GatewayException(
        said == null ? refusal.message : _approvalRefusalText(refusal, touch: true),
      );
    }
    said?.say('Chosen.');
    if (mounted) setState(() => _menu = _read());
  }

  @override
  Widget build(BuildContext context) {
    final menu = _menu;
    if (menu == null) return widget.orElse;
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
  });

  final String sessionId;
  final String agentName;
  final Widget orElse;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final question = ref.watch(chatOpenQuestionProvider(sessionId)).value;
    if (question == null) return orElse;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        QuestionPromptCard(
          agentName: agentName,
          question: question,
          onAnswer: (answers, {decline = false}) async {
            final said = _AnswerSaid.of(context);
            try {
              await ref.read(chatQuestionAnswerProvider)(
                RemoteQuestionAnswerRequest(
                  sessionId: sessionId,
                  toolUseId: question.toolUseId,
                  answers: answers,
                  decline: decline,
                ),
              );
            } on RemoteApiRefusal catch (refusal) {
              throw GatewayException(refusal.message);
            }
            said?.say(decline ? 'Declined.' : 'Answered.');
          },
        ),
        _TerminalLink(sessionId: sessionId),
      ],
    );
  }
}

class _TerminalLink extends ConsumerWidget {
  const _TerminalLink({required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      // Docked, the dock's own quiet "Answer in the terminal" (board N1).
      _Docked.of(context)
      ? Align(
          alignment: AlignmentDirectional.centerEnd,
          child: _AnswerInTerminal(sessionId: sessionId),
        )
      : TextButton.icon(
          onPressed: () => _openTerminal(ref, sessionId),
          icon: const Icon(AppIcons.terminal, size: Chrome.iconSmall),
          label: const Text('Terminal view'),
        );
}

/// Marks a card docked under its terminal (see [ApprovalRequestCard.docked]).
class _Docked extends InheritedWidget {
  const _Docked({required super.child, this.touch = false});

  /// See [ApprovalRequestCard.touch].
  final bool touch;

  static bool of(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_Docked>() != null;

  static bool touchOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_Docked>()?.touch ?? false;

  @override
  bool updateShouldNotify(_Docked oldWidget) => touch != oldWidget.touch;
}

/// The most of the page's height the dock takes on a phone before it scrolls.
const double _touchDockShare = 0.55;

/// On the phone, a word that an answer landed — the companion's "Approved." —
/// because a dock that simply vanishes reads as a dropped tap. Null elsewhere,
/// where the agent's own screen is the acknowledgement. Read before the await.
class _AnswerSaid {
  const _AnswerSaid(this._messenger);

  final ScaffoldMessengerState _messenger;

  static _AnswerSaid? of(BuildContext context) {
    if (!_Docked.touchOf(context)) return null;
    final messenger = ScaffoldMessenger.maybeOf(context);
    return messenger == null ? null : _AnswerSaid(messenger);
  }

  void say(String words) => _messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(content: Text(words), duration: const Duration(seconds: 2)),
    );
}

/// What the agent said, quoted, or an admission that we do not know.
class _Evidence extends StatelessWidget {
  const _Evidence({required this.report, required this.agentName});

  final AgentStatusReport report;
  final String agentName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    if (report.evidence.isEmpty) {
      // The honest empty state: a hook that carried no message, or a source
      // that only knows the session stopped. "Asking for something" is a claim.
      return Text(
        switch (report.waiting) {
          AgentWaitKind.approval =>
            'We can tell $agentName is asking for something, but not what. '
                'Open the terminal view to read the prompt.',
          AgentWaitKind.input =>
            '$agentName has finished its turn and is sitting at its own '
                'prompt. Reply to it in the terminal view.',
          AgentWaitKind.unrecorded =>
            'We can tell $agentName has stopped for you, but not what it '
                'wants. Read what it is showing in the terminal view.',
          AgentWaitKind.question =>
            '$agentName is asking you a question. Choose your answer in the '
                'terminal view.',
        },
        style: theme.textTheme.bodySmall?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          switch (report.source) {
            AgentStatusSource.terminalGrid => 'From its terminal:',
            AgentStatusSource.hook => 'It says:',
            _ => 'It reports:',
          },
          style: theme.textTheme.labelSmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 2),
        // Scrolls rather than wrapping: these are rendered terminal rows and
        // re-flowing them would break the alignment they were drawn with.
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 132),
          child: SingleChildScrollView(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SelectableText(
                report.evidence.join('\n'),
                style: MonoStyles.body,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The notice for a session stopped for the user with no prompt open. No
/// buttons at all: every key is a keystroke with nothing here to land on.
class _NothingToAnswer extends ConsumerWidget {
  const _NothingToAnswer({
    required this.sessionId,
    required this.waiting,
    required this.agentName,
  });

  final String sessionId;
  final AgentWaitKind waiting;
  final String agentName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          switch (waiting) {
            AgentWaitKind.input =>
              'There is nothing to approve — $agentName is at its own prompt, '
                  'so answer it in the terminal view.',
            // Approve would be Enter, which answers with whatever option is
            // highlighted — so there is no Approve here, only the terminal.
            AgentWaitKind.question =>
              'Pick an answer in the terminal view, or from the companion app.',
            _ =>
              'We cannot tell whether $agentName has a prompt open, so '
                  'Karmashala will not send it a key. Answer it in the '
                  'terminal view.',
          },
          style: theme.textTheme.labelSmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: Insets.xs),
        _TerminalLink(sessionId: sessionId),
      ],
    );
  }
}

/// The buttons, and the sentence explaining any that are missing.
class _Answers extends ConsumerWidget {
  const _Answers({
    required this.sessionId,
    required this.report,
    required this.rules,
    required this.agentName,
    required this.canAnswer,
    required this.cannot,
  });

  final String sessionId;

  /// The status the buttons were drawn from: the prompt they answer.
  final AgentStatusReport report;
  final AgentApprovalRules rules;
  final String agentName;
  final bool canAnswer;

  /// Said in place of the buttons when not [canAnswer].
  final String cannot;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    if (!canAnswer) {
      return Text(
        cannot,
        style: theme.textTheme.labelSmall?.copyWith(color: scheme.error),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(
          spacing: Insets.sm,
          runSpacing: Insets.xs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (rules.deny != null)
              OutlinedButton(
                onPressed: () => _press(context, ref, rules.deny!),
                child: Text(rules.deny!.label),
              ),
            if (rules.approve != null)
              FilledButton(
                onPressed: () => _press(context, ref, rules.approve!),
                child: Text(rules.approve!.label),
              ),
            _TerminalLink(sessionId: sessionId),
          ],
        ),
        const SizedBox(height: 2),
        // Every button says which key it presses: we are typing into another
        // program on the user's behalf, and "Approve" alone would hide that.
        for (final answer in [rules.approve, rules.deny].nonNulls)
          Text(
            '${answer.label}: ${answer.effect}',
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        if (rules.isEmpty)
          Text(
            '$agentName has not told us which keys answer its prompts, so '
            'answer it in the terminal.',
            style: theme.textTheme.labelSmall?.copyWith(color: scheme.error),
          )
        else if (rules.deny == null)
          Text(
            "$agentName's prompt names no way to decline. To refuse, "
            'use the terminal view.',
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
      ],
    );
  }

  Future<void> _press(
    BuildContext context,
    WidgetRef ref,
    AgentApprovalKey answer,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(sessionPromptAnswersProvider)
          .answer(
            ApprovalAnswerRequest(
              sessionId: sessionId,
              approve: identical(answer, rules.approve),
              ask: PromptAsk.drawnFrom(report),
            ),
          );
    } on SessionPromptRefusal catch (refusal) {
      // Only reported when it did not land: a successful keypress needs no
      // announcement — the agent's own screen is the acknowledgement.
      messenger.showSnackBar(
        SnackBar(content: Text(_approvalRefusalText(refusal))),
      );
    }
  }
}

/// A refused approve or deny, for a snack bar. On the phone a stale answer is
/// said plainly: the user was not looking at the screen it would have landed on.
String _approvalRefusalText(
  SessionPromptRefusal refusal, {
  bool touch = false,
}) => touch && refusal.stale
    ? 'That prompt changed before your answer arrived — nothing was pressed.'
    : refusal.unconfirmed
    ? '${refusal.message}.'
    : refusal.noTerminal || refusal.notFound
    ? 'That session is no longer running, so the key was not sent.'
    : 'Nothing was sent: ${refusal.message}.';

/// Reveals the pane so the user can answer anything we could not represent.
/// Shared by both halves of the card: the terminal is the complete answer.
void _openTerminal(WidgetRef ref, String sessionId) {
  final paneId = ref.read(paneSessionsProvider).paneOf(sessionId);
  if (paneId != null) {
    ref.read(terminalSessionsControllerProvider.notifier)
      ..reattachSession(paneId)
      ..focusPane(paneId);
  }
  // The group holding that session's pane. An approval is about one
  // session, so "go to the terminal" means the one running it.
  final terminals = ref.read(terminalSessionsControllerProvider.notifier);
  paneId == null
      ? terminals.showTerminalHere()
      : terminals.showTerminalForPane(paneId);
}
