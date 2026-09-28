import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_agent_status/karmashala_agent_status.dart';
import 'package:karmashala_companion/widgets.dart';
import 'package:karmashala_companion_server/karmashala_companion_server.dart'
    show remoteMenuOf;
import 'package:karmashala_remote/companion.dart';
import 'package:karmashala_remote/host.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import '../../agents/application/agent_providers.dart';
import 'package:agent_cli/descriptors.dart';
import '../../remote/application/remote_approval_bindings.dart';
import '../../terminal/application/terminal_sessions_controller.dart';
import '../../explorer/application/agent_state_providers.dart';
import '../application/session_message_typist.dart';
import '../application/session_prompt_answers.dart';
import '../application/session_providers.dart';
import '../application/session_status_providers.dart';

/// The pending approval for one session, and the buttons that answer it. It
/// never words the request itself, and offers only keys the agent named.
class ApprovalRequestCard extends ConsumerWidget {
  const ApprovalRequestCard({
    required this.sessionId,
    this.docked = false,
    super.key,
  });

  final String sessionId;

  /// Docked above the terminal pane's status line (spec §5, the ask dock):
  /// the same card, without the way to a terminal it is already under.
  final bool docked;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final report = ref
        .watch(agentSessionStatusProvider(sessionId))
        .asData
        ?.value;
    if (report == null ||
        report.status != AgentActivityStatus.awaitingApproval) {
      return const SizedBox.shrink();
    }

    final waiting = report.waiting;
    // Docked, it is an ask or nothing: an agent that finished a turn and waits
    // for input has nothing to answer here, and an amber card saying so under
    // the prompt was the complaint that removed the first dock.
    if (docked &&
        waiting != AgentWaitKind.approval &&
        waiting != AgentWaitKind.question) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final descriptor = ref.read(agentRegistryProvider).byId(report.agentId);
    final rules = descriptor?.approval ?? const AgentApprovalRules();
    final agentName = descriptor?.displayName ?? report.agentId;
    // A pane we can type into, or a process this machine's host runs and
    // answers in. Without either — an external terminal, a session whose
    // process has gone — the buttons would silently do nothing.
    final canAnswer = ref.read(sessionAnswerableProvider)(sessionId);

    if (docked) {
      return _Docked(
        child: _AskDock(
          sessionId: sessionId,
          report: report,
          agentName: agentName,
          rules: rules,
          menus: descriptor?.menus,
          canAnswer: canAnswer,
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
            rules: rules,
            agentName: agentName,
            canAnswer: canAnswer,
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
      throw GatewayException(refusal.message);
    }
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
        CompanionMenuCard(
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
        CompanionQuestionCard(
          agentName: agentName,
          question: question,
          onAnswer: (answers, {decline = false}) async {
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
  const _Docked({required super.child});

  static bool of(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_Docked>() != null;

  @override
  bool updateShouldNotify(_Docked oldWidget) => false;
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
    required this.rules,
    required this.agentName,
    required this.canAnswer,
  });

  final String sessionId;
  final AgentApprovalRules rules;
  final String agentName;
  final bool canAnswer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    if (!canAnswer) {
      return Text(
        'This session has no live terminal here, so it cannot be answered from '
        'Karmashala.',
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
            ),
          );
    } on SessionPromptRefusal catch (refusal) {
      // Only reported when it did not land: a successful keypress needs no
      // announcement — the agent's own screen is the acknowledgement.
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            refusal.noTerminal || refusal.notFound
                ? 'That session is no longer running, so the key was not sent.'
                : 'Nothing was sent: ${refusal.message}.',
          ),
        ),
      );
    }
  }
}

/// Reveals the pane so the user can answer anything we could not represent.
/// Shared by both halves of the card: the terminal is the complete answer.
void _openTerminal(WidgetRef ref, String sessionId) {
  final paneId = ref.read(sessionsDataProvider).getById(sessionId)?.paneId;
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

/// The ask dock's geometry (board N1), named once so its parts agree: the
/// buttons' height, the corner the buttons and the command box share, and
/// the ten pixels between its parts.
const double _dockButtonHeight = 28;
const double _dockInnerRadius = 7;
const double _dockGap = 10;

/// The board's 12.5px button label, a half step above `labelMedium`.
const double _dockButtonFontSize = 12.5;

/// **The ask dock** (spec §5, board N1): an amber panel above the pane's
/// status line saying who asks, where, in the agent's own words, and the
/// answers one click away — then "Answer in the terminal" for anything the
/// buttons cannot say. When the agent's hook named the call it asks about
/// ([AgentStatusReport.toolAsk], Claude Code), the header says what it wants
/// and what it touches and the box holds the exact command; otherwise it
/// never words the request itself — the header names the kind of ask and the
/// box quotes the agent's screen (Codex, Antigravity). Either way, how long
/// it has waited ticks at the right.
class _AskDock extends ConsumerWidget {
  const _AskDock({
    required this.sessionId,
    required this.report,
    required this.agentName,
    required this.rules,
    required this.menus,
    required this.canAnswer,
  });

  final String sessionId;
  final AgentStatusReport report;
  final String agentName;
  final AgentApprovalRules rules;
  final AgentMenuSupport? menus;
  final bool canAnswer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final tones = SurfaceTones.of(context);
    final density = UiDensity.of(context);
    final attention = SemanticColors.of(context).attention;
    final waiting = report.waiting;
    final project = ref.read(sessionProjectNameProvider)(sessionId);
    // The call the prompt is about, when the agent's hook named it: then the
    // header says what it wants, the box holds the exact command, and the
    // answers are the board's. Otherwise the agent's own screen is quoted.
    final ask = waiting == AgentWaitKind.approval ? report.toolAsk : null;
    final summary = ask == null ? null : summarizeToolAsk(ask);
    final muted = [
      if (summary != null && summary.touches.isNotEmpty)
        summary.touches.join(', '),
      if (project != null) 'in $project',
    ].join(' · ');

    final quoted = _DockQuote(report: report, agentName: agentName);
    final Widget? command = summary == null || summary.subject.isEmpty
        ? null
        : _DockBox(
            text: summary.subject,
            danger: summary.isCommand ? summary.danger : const [],
          );
    Widget askAnswers(
      AgentScreenMenu? menu,
      Future<void> Function(int option)? choose,
    ) => _ToolAskAnswers(
      key: const ValueKey('dock-tool-ask'),
      sessionId: sessionId,
      agentName: agentName,
      rules: rules,
      menus: menus,
      menu: menu,
      choose: choose,
      command: command,
    );
    final Widget body = switch (waiting) {
      AgentWaitKind.approval when canAnswer && summary != null => _MenuOr(
        sessionId: sessionId,
        agentName: agentName,
        docked: true,
        menus: menus,
        rules: rules,
        // Only the prompt a call raises — never folder trust or an MCP
        // server's offer, which draw as their own options.
        dockedAsk: (menu, choose) =>
            (menus?.cancelDeclinesIn(menu) ?? false)
            ? askAnswers(menu, choose)
            : null,
        orElse: askAnswers(null, null),
      ),
      AgentWaitKind.approval when summary != null => _DockColumn(
        children: [
          ?command,
          _DockNote(
            note:
                'This session has no live terminal here, so it cannot be '
                'answered from Karmashala.',
            sessionId: sessionId,
          ),
        ],
      ),
      AgentWaitKind.approval when canAnswer => _MenuOr(
        sessionId: sessionId,
        agentName: agentName,
        docked: true,
        menus: menus,
        rules: rules,
        orElse: _DockColumn(
          children: [
            quoted,
            _DockAnswers(
              sessionId: sessionId,
              rules: rules,
              agentName: agentName,
            ),
          ],
        ),
      ),
      AgentWaitKind.question when canAnswer => _QuestionOr(
        sessionId: sessionId,
        agentName: agentName,
        orElse: _DockColumn(
          children: [
            quoted,
            _DockNote(
              note:
                  'Pick an answer in the terminal, or from the companion app.',
              sessionId: sessionId,
            ),
          ],
        ),
      ),
      _ => _DockColumn(
        children: [
          quoted,
          _DockNote(
            note:
                'This session has no live terminal here, so it cannot be '
                'answered from Karmashala.',
            sessionId: sessionId,
          ),
        ],
      ),
    };

    return Container(
      margin: const EdgeInsets.fromLTRB(Insets.md, 0, Insets.md, _dockGap),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: Insets.md),
      // Amber, the one colour that means "needs you" (spec §5): the ask is
      // the thing on screen that is blocking the session. The edge is drawn
      // inside, as the board's inset ring, so the panel keeps its size.
      decoration: BoxDecoration(
        color: tones.attentionSurface,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(
          color: tones.attentionEdge,
          strokeAlign: BorderSide.strokeAlignInside,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(
                waiting == AgentWaitKind.question
                    ? AppIcons.question
                    : AppIcons.shield,
                size: Chrome.icon,
                color: attention,
              ),
              const SizedBox(width: Insets.sm),
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        summary != null
                            ? '$agentName wants to ${summary.action}'
                            : waiting == AgentWaitKind.question
                            ? '$agentName is asking you a question'
                            : '$agentName is asking permission',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: density.rowTitle(theme, strong: true),
                      ),
                    ),
                    if (muted.isNotEmpty) ...[
                      const SizedBox(width: Insets.sm),
                      Flexible(
                        child: Text(
                          muted,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: density.muted(theme),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: Insets.sm),
              _WaitingFor(since: report.waitingSince),
            ],
          ),
          const SizedBox(height: _dockGap),
          body,
        ],
      ),
    );
  }
}

/// The dock's parts, [_dockGap] apart as the board spaces them.
class _DockColumn extends StatelessWidget {
  const _DockColumn({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      for (var i = 0; i < children.length; i++) ...[
        if (i > 0) const SizedBox(height: _dockGap),
        children[i],
      ],
    ],
  );
}

/// The agent's own words in the terminal's hand, on the terminal's tone — or
/// the admission that we cannot read them.
class _DockQuote extends StatelessWidget {
  const _DockQuote({required this.report, required this.agentName});

  final AgentStatusReport report;
  final String agentName;

  @override
  Widget build(BuildContext context) {
    if (report.evidence.isEmpty) {
      // The honest empty state: a hook that carried no message. "Asking for
      // something" is as far as the evidence goes.
      return Text(
        'We can tell $agentName is asking for something, but not what. '
        'Read the prompt in the terminal.',
        style: UiDensity.of(context).muted(Theme.of(context)),
      );
    }
    return _DockBox(text: report.evidence.join('\n'));
  }
}

/// A block of terminal rows on the terminal's tone: scrolled rather than
/// re-wrapped, because they were drawn aligned to the agent's own columns.
class _DockBox extends StatelessWidget {
  const _DockBox({required this.text, this.danger = const []});

  final String text;

  /// `[start, end)` spans of [text] drawn in the failure colour — the part of
  /// a command that deletes, pushes or elevates (board N1's red `rm -rf`).
  final List<(int, int)> danger;

  /// About seven rows; a longer prompt scrolls inside the dock.
  static const _maxHeight = 132.0;

  @override
  Widget build(BuildContext context) {
    final style = MonoStyles.body.copyWith(
      color: Theme.of(context).colorScheme.onSurface,
    );
    final failure = SemanticColors.of(context).failure;
    final spans = <TextSpan>[];
    var at = 0;
    for (final (start, end) in danger) {
      // Spans come from the text they mark; a stale one is simply not drawn.
      if (start < at || end > text.length || start >= end) continue;
      if (start > at) spans.add(TextSpan(text: text.substring(at, start)));
      spans.add(
        TextSpan(
          text: text.substring(start, end),
          style: TextStyle(color: failure),
        ),
      );
      at = end;
    }
    if (at < text.length) spans.add(TextSpan(text: text.substring(at)));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: Insets.sm),
      decoration: BoxDecoration(
        color: SurfaceTones.of(context).term,
        borderRadius: BorderRadius.circular(_dockInnerRadius),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: _maxHeight),
        child: SingleChildScrollView(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: danger.isEmpty
                ? SelectableText(text, style: style)
                : SelectableText.rich(TextSpan(style: style, children: spans)),
          ),
        ),
      ),
    );
  }
}

/// The keys the agent named, as the board's buttons: yes filled amber with
/// the key it sends, no on the raised tone with its key, and the way to the
/// terminal at the end. What each key does, in the agent's words, is the
/// button's tooltip.
class _DockAnswers extends ConsumerWidget {
  const _DockAnswers({
    required this.sessionId,
    required this.rules,
    required this.agentName,
  });

  final String sessionId;
  final AgentApprovalRules rules;
  final String agentName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final approve = rules.approve;
    final deny = rules.deny;
    final note = rules.isEmpty
        ? '$agentName has not told us which keys answer its prompts, so '
              'answer it in the terminal.'
        : deny == null
        ? "$agentName's prompt names no way to decline. To refuse, use the "
              'terminal.'
        : null;
    return _DockColumn(
      children: [
        _DockButtonRow(
          sessionId: sessionId,
          buttons: [
            if (approve != null)
              _DockButton(
                label: approve.label,
                keyHint: _keyName(approve.keys),
                tooltip: approve.effect,
                primary: true,
                onPressed: () => _press(context, ref, approve: true),
              ),
            if (deny != null)
              _DockButton(
                label: deny.label,
                keyHint: _keyName(deny.keys),
                tooltip: deny.effect,
                onPressed: () => _press(context, ref, approve: false),
              ),
          ],
        ),
        if (note != null)
          Text(note, style: UiDensity.of(context).muted(Theme.of(context))),
      ],
    );
  }

  Future<void> _press(
    BuildContext context,
    WidgetRef ref, {
    required bool approve,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(sessionPromptAnswersProvider)
          .answer(
            ApprovalAnswerRequest(sessionId: sessionId, approve: approve),
          );
    } on SessionPromptRefusal catch (refusal) {
      // Only reported when it did not land: the agent's own screen is the
      // acknowledgement of one that did.
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            refusal.noTerminal || refusal.notFound
                ? 'That session is no longer running, so the key was not sent.'
                : 'Nothing was sent: ${refusal.message}.',
          ),
        ),
      );
    }
  }
}

/// How long the dock waits for the prompt to close after a deny before it
/// types the reason — the words belong in the composer the deny returns to,
/// never in the menu.
const Duration _promptClosePatience = Duration(milliseconds: 1500);

/// **The answers to a structured ask** (board N1): the exact command, then
/// Allow once, Always allow `<prefix>` when the agent's menu offers it, Deny,
/// Deny and say why…, and the way to the terminal. Every answer goes through
/// the paths the rest of the dock uses — approve and deny by the agent's own
/// keys (a menu by the option they mean), Always allow by the option chosen,
/// the reason typed as any message is — so nothing here types a key of its
/// own.
class _ToolAskAnswers extends ConsumerStatefulWidget {
  const _ToolAskAnswers({
    required this.sessionId,
    required this.agentName,
    required this.rules,
    required this.menus,
    required this.menu,
    required this.choose,
    required this.command,
    super.key,
  });

  final String sessionId;
  final String agentName;
  final AgentApprovalRules rules;
  final AgentMenuSupport? menus;

  /// The prompt on the screen, when it can be read — the only source of the
  /// "always" option.
  final AgentScreenMenu? menu;
  final Future<void> Function(int option)? choose;

  /// The exact command or path, or null when the call names none.
  final Widget? command;

  @override
  ConsumerState<_ToolAskAnswers> createState() => _ToolAskAnswersState();
}

class _ToolAskAnswersState extends ConsumerState<_ToolAskAnswers> {
  final _reason = TextEditingController();
  final _reasonFocus = FocusNode();
  bool _sayingWhy = false;
  bool _busy = false;

  @override
  void dispose() {
    _reason.dispose();
    _reasonFocus.dispose();
    super.dispose();
  }

  Future<void> _answer({required bool approve}) async {
    if (_busy) return;
    final answers = ref.read(sessionPromptAnswersProvider);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await answers.answer(
        ApprovalAnswerRequest(sessionId: widget.sessionId, approve: approve),
      );
    } on SessionPromptRefusal catch (refusal) {
      // Only a refusal is reported: the agent's own screen is the
      // acknowledgement of one that landed.
      messenger.showSnackBar(SnackBar(content: Text(_refused(refusal))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _always(int option) async {
    final choose = widget.choose;
    if (_busy || choose == null) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await choose(option);
    } on GatewayException catch (refusal) {
      messenger.showSnackBar(SnackBar(content: Text(refusal.message)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Denies with the agent's own deny, then types [why] into the composer
  /// the deny hands back and presses Enter — through the one typist every
  /// message goes through, which reads the send back off the screen. Read
  /// before the first await: a deny ends the ask, and this dock with it.
  Future<void> _denyAndSay() async {
    final why = _reason.text.trim();
    if (_busy || why.isEmpty) return;
    final sessionId = widget.sessionId;
    final answers = ref.read(sessionPromptAnswersProvider);
    final typist = ref.read(sessionMessageTypistProvider);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await answers.answer(
        ApprovalAnswerRequest(sessionId: sessionId, approve: false),
      );
    } on SessionPromptRefusal catch (refusal) {
      messenger.showSnackBar(SnackBar(content: Text(_refused(refusal))));
      if (mounted) setState(() => _busy = false);
      return;
    }
    final deadline = DateTime.now().add(_promptClosePatience);
    while (answers.menuOnScreen(sessionId) != null &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    try {
      if (!await typist.send(sessionId, why)) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text(
              'Denied, but the session has no live terminal to type the '
              'reason into.',
            ),
          ),
        );
      }
    } on SessionPromptRefusal catch (refusal) {
      messenger.showSnackBar(
        SnackBar(content: Text('Denied, but ${refusal.message}')),
      );
    }
    if (mounted) setState(() => _busy = false);
  }

  static String _refused(SessionPromptRefusal refusal) =>
      refusal.noTerminal || refusal.notFound
      ? 'That session is no longer running, so the key was not sent.'
      : 'Nothing was sent: ${refusal.message}.';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final approve = widget.rules.approve;
    final deny = widget.rules.deny;
    final menu = widget.menu;
    final always = menu == null || widget.choose == null
        ? null
        : _alwaysOption(menu, widget.menus);
    final idle = !_busy;
    return _DockColumn(
      children: [
        ?widget.command,
        _DockButtonRow(
          sessionId: widget.sessionId,
          buttons: [
            if (approve != null)
              _DockButton(
                key: const ValueKey('dock-allow-once'),
                label: 'Allow once',
                keyHint: _keyName(approve.keys),
                tooltip: approve.effect,
                primary: true,
                onPressed: idle ? () => _answer(approve: true) : null,
              ),
            if (always != null)
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 320),
                child: _DockButton(
                  key: const ValueKey('dock-always-allow'),
                  label: always.label,
                  detail: always.detail,
                  tooltip: menu!.options[always.index],
                  onPressed: idle ? () => _always(always.index) : null,
                ),
              ),
            if (deny != null) ...[
              _DockButton(
                key: const ValueKey('dock-deny'),
                label: 'Deny',
                keyHint: _keyName(deny.keys),
                tooltip: deny.effect,
                onPressed: idle ? () => _answer(approve: false) : null,
              ),
              _DockButton(
                key: const ValueKey('dock-deny-say-why'),
                label: 'Deny and say why…',
                tooltip:
                    'Denies, then types your reason into ${widget.agentName} '
                    'and sends it',
                onPressed: idle
                    ? () {
                        setState(() => _sayingWhy = true);
                        _reasonFocus.requestFocus();
                      }
                    : null,
              ),
            ],
          ],
        ),
        if (_sayingWhy && deny != null)
          CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.escape): () =>
                  setState(() => _sayingWhy = false),
            },
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('dock-deny-reason'),
                    controller: _reason,
                    focusNode: _reasonFocus,
                    autofocus: true,
                    enabled: idle,
                    style: theme.textTheme.bodyMedium,
                    decoration: InputDecoration(
                      isDense: true,
                      hintText:
                          'Tell ${widget.agentName} what to do instead',
                    ),
                    onSubmitted: (_) => _denyAndSay(),
                  ),
                ),
                const SizedBox(width: Insets.sm),
                _DockButton(
                  key: const ValueKey('dock-deny-send'),
                  label: 'Deny and send',
                  keyHint: 'Enter',
                  primary: true,
                  onPressed: idle ? _denyAndSay : null,
                ),
                const SizedBox(width: Insets.sm),
                _DockButton(
                  label: 'Cancel',
                  keyHint: 'Esc',
                  onPressed: () => setState(() => _sayingWhy = false),
                ),
              ],
            ),
          ),
        if (widget.rules.isEmpty)
          Text(
            '${widget.agentName} has not told us which keys answer its '
            'prompts, so answer it in the terminal.',
            style: UiDensity.of(context).muted(theme),
          ),
      ],
    );
  }
}

/// The option of [menu] that approves **and keeps approving** — a second
/// "yes" beside the one Allow once picks (Claude Code's "Yes, and don't ask
/// again for `git push` commands in …") — with the button's words for it, or
/// null when the menu offers none.
({int index, String label, String? detail})? _alwaysOption(
  AgentScreenMenu menu,
  AgentMenuSupport? menus,
) {
  if (menus == null) return null;
  final once = menus.affirmativeIn(menu);
  bool any(List<String> patterns, String option) => patterns.any(
    (p) => RegExp(p, caseSensitive: false).hasMatch(option),
  );
  for (var i = 0; i < menu.options.length; i++) {
    final option = menu.options[i];
    if (i == once ||
        !any(menus.affirmative, option) ||
        any(menus.negative, option)) {
      continue;
    }
    final prefix = RegExp(
      r"don.t ask again for (.+?) commands?\b",
      caseSensitive: false,
    ).firstMatch(option)?.group(1);
    if (prefix != null) {
      final cleaned = prefix
          .replaceAll('`', '')
          .replaceAll(RegExp(r':\*$'), '')
          .trim();
      return (
        index: i,
        label: 'Always allow',
        detail: cleaned == 'this' ? 'this command' : cleaned,
      );
    }
    if (RegExp(r'accept edits|all edits', caseSensitive: false)
        .hasMatch(option)) {
      return (index: i, label: 'Always allow', detail: 'edits');
    }
    // Some other standing yes: in the agent's own words.
    return (index: i, label: option, detail: null);
  }
  return null;
}

/// "waiting 42s", counted from when the wait began — or, when the status
/// could not say, from when this dock first showed it — and ticking.
class _WaitingFor extends StatefulWidget {
  const _WaitingFor({required this.since});

  final DateTime? since;

  @override
  State<_WaitingFor> createState() => _WaitingForState();
}

class _WaitingForState extends State<_WaitingFor> {
  final DateTime _shown = DateTime.now().toUtc();
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final since = widget.since ?? _shown;
    var waited = DateTime.now().toUtc().difference(since.toUtc());
    if (waited.isNegative) waited = Duration.zero;
    final seconds = waited.inSeconds % 60;
    final minutes = waited.inMinutes % 60;
    final age = waited.inHours > 0
        ? '${waited.inHours}h ${minutes}m'
        : waited.inMinutes > 0
        ? '${waited.inMinutes}m ${seconds}s'
        : '${waited.inSeconds}s';
    return Text(
      'waiting $age',
      key: const ValueKey('dock-waiting'),
      maxLines: 1,
      style: UiDensity.of(context).muted(Theme.of(context)),
    );
  }
}

/// A menu the agent drew, as one button per option in its own words: the
/// option that means yes filled amber, the rest on the raised tone. One
/// press answers — the button names the option, and the answer path moves
/// to it, checks it is highlighted, then confirms — so nothing is typed
/// that the user did not point at.
class _DockMenu extends StatefulWidget {
  const _DockMenu({
    required this.menu,
    required this.affirmative,
    required this.sessionId,
    required this.onChoose,
    this.affirmativeKey,
    this.negative,
    this.negativeKey,
  });

  final AgentScreenMenu menu;

  /// The option that means yes, drawn filled; null when none can be named.
  final int? affirmative;

  /// The key cap on [affirmative], when that key alone would pick it.
  final String? affirmativeKey;

  /// The option that means no, and the key cap on it when the agent's cancel
  /// is the same answer.
  final int? negative;
  final String? negativeKey;
  final String sessionId;
  final Future<void> Function(int option) onChoose;

  @override
  State<_DockMenu> createState() => _DockMenuState();
}

class _DockMenuState extends State<_DockMenu> {
  bool _busy = false;

  /// The widest an option's button grows before its words end; the tooltip
  /// keeps the whole of them.
  static const _optionMaxWidth = 320.0;

  Future<void> _choose(int option) async {
    if (_busy) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await widget.onChoose(option);
    } on GatewayException catch (refusal) {
      messenger.showSnackBar(SnackBar(content: Text(refusal.message)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final menu = widget.menu;
    return _DockColumn(
      children: [
        if (menu.prompt.isNotEmpty) _DockBox(text: menu.prompt.join('\n')),
        _DockButtonRow(
          sessionId: widget.sessionId,
          buttons: [
            for (var i = 0; i < menu.options.length; i++)
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: _optionMaxWidth),
                child: _DockButton(
                  key: ValueKey('dock-menu-option-$i'),
                  label: menu.options[i],
                  keyHint: i == widget.affirmative
                      ? widget.affirmativeKey
                      : i == widget.negative
                      ? widget.negativeKey
                      : null,
                  // An option in the agent's own words can run long; it
                  // wraps rather than ending mid-word (the tooltip keeps it).
                  wrap: true,
                  tooltip: i == menu.highlighted
                      ? '${menu.options[i]}\nHighlighted in the terminal — '
                            'what Enter alone would pick'
                      : menu.options[i],
                  primary: i == widget.affirmative,
                  onPressed: _busy ? null : () => _choose(i),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// The notice for an ask the dock cannot answer, and the way to the one
/// place that can.
class _DockNote extends StatelessWidget {
  const _DockNote({required this.note, required this.sessionId});

  final String note;
  final String sessionId;

  @override
  Widget build(BuildContext context) => _DockButtonRow(
    sessionId: sessionId,
    buttons: [
      Text(note, style: UiDensity.of(context).muted(Theme.of(context))),
    ],
  );
}

/// The answers, wrapping as the pane narrows, then "Answer in the terminal"
/// at the row's end (board N1's spacer).
class _DockButtonRow extends StatelessWidget {
  const _DockButtonRow({required this.sessionId, required this.buttons});

  final String sessionId;
  final List<Widget> buttons;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(
        child: Wrap(
          spacing: Insets.sm,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: buttons,
        ),
      ),
      const SizedBox(width: Insets.sm),
      _AnswerInTerminal(sessionId: sessionId),
    ],
  );
}

/// The way to the terminal from the dock: in the terminal view it focuses the
/// pane the dock is under; in the chat it brings that pane back.
class _AnswerInTerminal extends ConsumerWidget {
  const _AnswerInTerminal({required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) => TextButton(
    style: TextButton.styleFrom(
      foregroundColor: Theme.of(context).colorScheme.onSurfaceVariant,
      minimumSize: const Size(0, _dockButtonHeight),
      padding: const EdgeInsets.symmetric(horizontal: 6),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(_dockInnerRadius),
      ),
    ),
    onPressed: () => _openTerminal(ref, sessionId),
    child: const Text('Answer in the terminal'),
  );
}

/// One of the dock's answers: 28px, a 7px corner, amber for [primary] and
/// the raised tone otherwise, with the key it sends set as a key cap.
class _DockButton extends StatelessWidget {
  const _DockButton({
    required this.label,
    required this.onPressed,
    this.keyHint,
    this.detail,
    this.tooltip,
    this.primary = false,
    this.wrap = false,
    super.key,
  });

  final String label;
  final String? keyHint;

  /// A literal after the label in the terminal's hand — the command prefix
  /// "Always allow" would stop asking about.
  final String? detail;
  final String? tooltip;
  final bool primary;

  /// Whether a long label wraps to a second line rather than ending in "…".
  final bool wrap;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tones = SurfaceTones.of(context);
    final attention = SemanticColors.of(context).attention;
    // Ink on amber: near-black with a trace of the amber in it (the board's
    // #1a1405), in either theme — the amber is a light enough fill in both.
    final ink = Color.alphaBlend(
      Colors.black.withValues(alpha: 0.88),
      attention,
    );
    final hint = keyHint;
    final more = detail;
    final button = FilledButton(
      style: FilledButton.styleFrom(
        backgroundColor: primary ? attention : tones.selected,
        foregroundColor: primary ? ink : scheme.onSurface,
        minimumSize: const Size(0, _dockButtonHeight),
        padding: const EdgeInsets.symmetric(
          horizontal: Insets.md,
          vertical: Insets.xs,
        ),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        // Standard, not compact: compact takes eight pixels off the minimum
        // height, which drew the board's 28px buttons at about 22.
        visualDensity: VisualDensity.standard,
        textStyle: theme.textTheme.labelMedium?.copyWith(
          fontSize: _dockButtonFontSize,
          fontWeight: FontWeight.w500,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_dockInnerRadius),
        ),
      ),
      onPressed: onPressed,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              label,
              maxLines: wrap ? 2 : 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (more != null && more.isNotEmpty) ...[
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                more,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: MonoStyles.small.copyWith(
                  color: primary ? ink : scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
          if (hint != null) ...[
            const SizedBox(width: 6),
            _KeyCap(
              label: hint,
              color: primary ? ink.withValues(alpha: 0.7) : scheme.outline,
              edge: primary ? ink.withValues(alpha: 0.35) : tones.floatingLine,
            ),
          ],
        ],
      ),
    );
    final message = tooltip;
    return message == null || message.isEmpty
        ? button
        : Tooltip(message: message, child: button);
  }
}

/// A key's name in a small outlined cap — what a dock button types.
class _KeyCap extends StatelessWidget {
  const _KeyCap({required this.label, required this.color, required this.edge});

  final String label;
  final Color color;
  final Color edge;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: Insets.xs),
    decoration: BoxDecoration(
      border: Border.all(color: edge),
      borderRadius: BorderRadius.circular(Insets.xs),
    ),
    child: Text(
      label,
      style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
    ),
  );
}

/// The name of the key [keys] sends, for its cap — or null for a sequence
/// that has no one-word name, which then goes unlabelled rather than guessed.
String? _keyName(String keys) => switch (keys) {
  '\r' || '\n' => 'Enter',
  '\x1b' => 'Esc',
  '\t' => 'Tab',
  _ when keys.length == 1 && keys.codeUnitAt(0) > 0x20 => keys.toUpperCase(),
  _ => null,
};
