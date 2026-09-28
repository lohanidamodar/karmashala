import 'dart:async';

import 'package:flutter/material.dart';
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
      return _DockMenu(
        menu: menu,
        affirmative: widget.menus?.affirmativeIn(menu),
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

/// **The ask dock** (spec §5, board N1): an amber panel above the pane's
/// status line saying who asks, where, in the agent's own words, and the
/// answers one click away — then "Answer in the terminal" for anything the
/// buttons cannot say. It never words the request itself: the header names
/// the kind of ask, the box quotes the agent.
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

    final quoted = _DockQuote(report: report, agentName: agentName);
    final Widget body = switch (waiting) {
      AgentWaitKind.approval when canAnswer => _MenuOr(
        sessionId: sessionId,
        agentName: agentName,
        docked: true,
        menus: menus,
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
              Flexible(
                child: Text(
                  waiting == AgentWaitKind.question
                      ? '$agentName is asking you a question'
                      : '$agentName is asking permission',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: density.rowTitle(theme, strong: true),
                ),
              ),
              if (project != null) ...[
                const SizedBox(width: Insets.sm),
                Flexible(
                  child: Text(
                    'in $project',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: density.muted(theme),
                  ),
                ),
              ],
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
  const _DockBox({required this.text});

  final String text;

  /// About seven rows; a longer prompt scrolls inside the dock.
  static const _maxHeight = 132.0;

  @override
  Widget build(BuildContext context) => Container(
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
          child: SelectableText(
            text,
            style: MonoStyles.body.copyWith(
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ),
      ),
    ),
  );
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
  });

  final AgentScreenMenu menu;

  /// The option that means yes, drawn filled; null when none can be named.
  final int? affirmative;
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
    this.tooltip,
    this.primary = false,
    super.key,
  });

  final String label;
  final String? keyHint;
  final String? tooltip;
  final bool primary;
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
    final button = FilledButton(
      style: FilledButton.styleFrom(
        backgroundColor: primary ? attention : tones.selected,
        foregroundColor: primary ? ink : scheme.onSurface,
        minimumSize: const Size(0, _dockButtonHeight),
        padding: const EdgeInsets.symmetric(horizontal: Insets.md),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
        textStyle: theme.textTheme.labelMedium?.copyWith(
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
            child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
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
