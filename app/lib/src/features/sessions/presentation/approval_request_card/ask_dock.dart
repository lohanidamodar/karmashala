part of '../approval_request_card.dart';

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
    required this.cannot,
    this.inline = false,
  });

  final String sessionId;
  final AgentStatusReport report;
  final String agentName;
  final AgentApprovalRules rules;
  final AgentMenuSupport? menus;
  final bool canAnswer;

  /// Said in place of the answers when not [canAnswer].
  final String cannot;

  /// Under its call in the chat, whose own card already insets it.
  final bool inline;

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
      report: report,
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
        dockedAsk: (menu, choose) => (menus?.cancelDeclinesIn(menu) ?? false)
            ? askAnswers(menu, choose)
            : null,
        orElse: askAnswers(null, null),
      ),
      AgentWaitKind.approval when summary != null => _DockColumn(
        children: [
          ?command,
          _DockNote(note: cannot, sessionId: sessionId),
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
              report: report,
              rules: rules,
              agentName: agentName,
            ),
          ],
        ),
      ),
      AgentWaitKind.question when canAnswer => _DockColumn(
        children: [
          quoted,
          _DockNote(
            note: 'Pick an answer in the terminal, or from the companion app.',
            sessionId: sessionId,
          ),
        ],
      ),
      _ => _DockColumn(
        children: [
          quoted,
          _DockNote(note: cannot, sessionId: sessionId),
        ],
      ),
    };

    final header = Row(
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
    );
    // Held to a height, the header stays and the body scrolls under it.
    final plain = _FlexColumn(
      flexible: 2,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        const SizedBox(height: _dockGap),
        SingleChildScrollView(primary: false, child: body),
      ],
    );
    final question = waiting == AgentWaitKind.question && canAnswer;

    return Container(
      margin: question && inline
          ? const EdgeInsets.only(bottom: _dockGap)
          : const EdgeInsets.fromLTRB(Insets.md, 0, Insets.md, _dockGap),
      padding: question
          ? const EdgeInsets.symmetric(
              horizontal: Insets.md,
              vertical: Insets.sm,
            )
          : const EdgeInsets.symmetric(
              horizontal: Insets.md + Insets.xxs,
              vertical: Insets.md,
            ),
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
      // A readable question draws its own slim header in place of this one.
      child: question
          ? _QuestionOr(
              sessionId: sessionId,
              agentName: agentName,
              where: project == null ? null : 'in $project',
              trailing: _WaitingFor(since: report.waitingSince),
              orElse: plain,
            )
          : plain,
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
    Widget rows({double? maxHeight}) => ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight ?? double.infinity),
      child: SingleChildScrollView(
        primary: false,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: danger.isEmpty
              ? SelectableText(text, style: style)
              : SelectableText.rich(TextSpan(style: style, children: spans)),
        ),
      ),
    );
    final box = Container(
      padding: const EdgeInsets.symmetric(
        horizontal: Insets.smd,
        vertical: Insets.sm,
      ),
      decoration: BoxDecoration(
        color: SurfaceTones.of(context).term,
        borderRadius: BorderRadius.circular(_dockInnerRadius),
      ),
      child: rows(maxHeight: _maxHeight),
    );
    // A scroll inside a scroll is a poor thing to drag with a thumb, so a
    // phone reads a long prompt whole in a sheet, as the companion did.
    if (!_Docked.touchOf(context) ||
        '\n'.allMatches(text).length < _touchRowsBeforeShowAll) {
      return box;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        box,
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton(
            key: const ValueKey('dock-show-all'),
            style: TextButton.styleFrom(
              minimumSize: const Size(Touch.target, Touch.target),
            ),
            onPressed: () => showAdaptiveModal<void>(
              context: context,
              title: 'The whole prompt',
              builder: (_) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: Insets.lg),
                child: rows(),
              ),
            ),
            child: const Text('Show all'),
          ),
        ),
      ],
    );
  }

  /// Rows a phone shows in place before it offers the whole prompt in a sheet.
  static const _touchRowsBeforeShowAll = 8;
}

/// The keys the agent named, as the board's buttons: yes filled amber with
/// the key it sends, no on the raised tone with its key, and the way to the
/// terminal at the end. What each key does, in the agent's words, is the
/// button's tooltip.
class _DockAnswers extends ConsumerWidget {
  const _DockAnswers({
    required this.sessionId,
    required this.report,
    required this.rules,
    required this.agentName,
  });

  final String sessionId;

  /// The status the buttons were drawn from: the prompt they answer.
  final AgentStatusReport report;
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
    final said = _AnswerSaid.of(context);
    try {
      await ref
          .read(sessionPromptAnswersProvider)
          .answer(
            ApprovalAnswerRequest(
              sessionId: sessionId,
              approve: approve,
              ask: PromptAsk.drawnFrom(report),
            ),
          );
    } on SessionPromptRefusal catch (refusal) {
      // Only reported when it did not land: the agent's own screen is the
      // acknowledgement of one that did.
      messenger.showSnackBar(
        SnackBar(
          content: Text(_approvalRefusalText(refusal, touch: said != null)),
        ),
      );
      return;
    }
    said?.say(approve ? 'Allowed.' : 'Denied.');
  }
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
