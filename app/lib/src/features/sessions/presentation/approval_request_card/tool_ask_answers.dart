part of '../approval_request_card.dart';

/// How long the dock waits for the prompt to close after a deny before it
/// gives up on typing the reason — the words belong in the composer the deny
/// returns to, never in the menu.
const Duration _promptClosePatience = Duration(seconds: 3);

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
    required this.report,
    required this.agentName,
    required this.rules,
    required this.menus,
    required this.menu,
    required this.choose,
    required this.command,
    super.key,
  });

  final String sessionId;

  /// The status the answers were drawn from: with [menu], the prompt they
  /// answer.
  final AgentStatusReport report;
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
    final said = _AnswerSaid.of(context);
    setState(() => _busy = true);
    try {
      await answers.answer(
        ApprovalAnswerRequest(
          sessionId: widget.sessionId,
          approve: approve,
          ask: _ask,
        ),
      );
      said?.say(approve ? 'Allowed once.' : 'Denied.');
    } on SessionPromptRefusal catch (refusal) {
      // Only a refusal is reported: the agent's own screen is the
      // acknowledgement of one that landed.
      messenger.showSnackBar(
        SnackBar(content: Text(_refused(refusal, touch: said != null))),
      );
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
  /// [ask] is the prompt the reason was written for, when it was taken
  /// before the dock could change under it.
  Future<void> _denyAndSay([String? typed, PromptAsk? ask]) async {
    final why = (typed ?? _reason.text).trim();
    if (_busy || why.isEmpty) return;
    final sessionId = widget.sessionId;
    final answers = ref.read(sessionPromptAnswersProvider);
    final statusOf = ref.read(sessionStatusLookupProvider);
    final typist = ref.read(sessionInputProvider);
    final messenger = ScaffoldMessenger.of(context);
    final touch = _Docked.touchOf(context);
    setState(() => _busy = true);
    try {
      await answers.answer(
        ApprovalAnswerRequest(
          sessionId: sessionId,
          approve: false,
          ask: ask ?? _ask,
        ),
      );
    } on SessionPromptRefusal catch (refusal) {
      messenger.showSnackBar(
        SnackBar(content: Text(_refused(refusal, touch: touch))),
      );
      if (mounted) setState(() => _busy = false);
      return;
    }
    // Typed while any prompt shows — this one not yet gone, or the next
    // already open — the reason would land in its menu, and its Return
    // would pick that menu's default.
    bool promptShows() {
      final status = statusOf(sessionId);
      return answers.menuOnScreen(sessionId) != null ||
          (status?.hasOpenPrompt ?? false) ||
          (status?.hasOpenQuestion ?? false);
    }

    final deadline = DateTime.now().add(_promptClosePatience);
    while (promptShows() && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (promptShows()) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Denied. Your reason was not sent: a prompt is still open in the '
            'session, and typing now would answer it. Send it from the chat '
            'once the prompt is gone.',
          ),
        ),
      );
      if (mounted) setState(() => _busy = false);
      return;
    }
    try {
      if (!await typist.send(sessionId, why, requestId: newSessionInputId())) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text(
              'Denied, but the session has no live terminal to type the '
              'reason into.',
            ),
          ),
        );
      } else if (touch) {
        messenger.showSnackBar(
          const SnackBar(content: Text('Denied, and your reason was sent.')),
        );
      }
    } on SessionPromptRefusal catch (refusal) {
      messenger.showSnackBar(
        SnackBar(content: Text('Denied, but ${refusal.message}')),
      );
    }
    if (mounted) setState(() => _busy = false);
  }

  /// The menu is named only where it was read at the session's own grid: a
  /// pane at another grid hashes different rows, and a right answer would be
  /// refused. Elsewhere the wait and the call name the prompt.
  PromptAsk get _ask => PromptAsk.drawnFrom(
    widget.report,
    menu: ref.read(promptMenuAtSessionGridProvider)(widget.sessionId)
        ? widget.menu
        : null,
  );

  static String _refused(SessionPromptRefusal refusal, {bool touch = false}) =>
      _approvalRefusalText(refusal, touch: touch);

  /// *Deny and say why…* on a phone: the reason is typed in a sheet over the
  /// keyboard, not in a field squeezed into the dock. The sheet only collects
  /// the words; the deny is sent from here, with this dock's `ask`.
  Future<void> _sayWhyInSheet() async {
    final messenger = ScaffoldMessenger.of(context);
    // Taken now: this dock outlives one prompt, and the next one's status can
    // arrive while the sheet is up.
    final shown = _ask;
    final why = await showAdaptiveModal<String>(
      context: context,
      title: 'Deny and say why',
      builder: (_) => _DenyReasonSheet(agentName: widget.agentName),
    );
    if (why == null || why.trim().isEmpty) return;
    if (!mounted || !_samePrompt(shown, _ask)) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'That prompt changed before you denied it — nothing was sent.',
          ),
        ),
      );
      return;
    }
    await _denyAndSay(why, shown);
  }

  /// Whether [now] is still the prompt [shown] named. A menu read on one side
  /// only is no difference: it can become readable while the sheet is up.
  static bool _samePrompt(PromptAsk shown, PromptAsk now) =>
      shown.waitingSince?.millisecondsSinceEpoch ==
          now.waitingSince?.millisecondsSinceEpoch &&
      shown.toolUseId == now.toolUseId &&
      (shown.menuId == null || now.menuId == null || shown.menuId == now.menuId);

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
    final touch = _Docked.touchOf(context);
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
                constraints: BoxConstraints(
                  maxWidth: touch ? double.infinity : 320,
                ),
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
                onPressed: !idle
                    ? null
                    : touch
                    ? _sayWhyInSheet
                    : () {
                        setState(() => _sayingWhy = true);
                        _reasonFocus.requestFocus();
                      },
              ),
            ],
          ],
        ),
        if (_sayingWhy && deny != null && !touch)
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

/// The phone's sheet for *Deny and say why…*: the reason, then *Deny and
/// send*, which closes the sheet with the words. Sends nothing itself.
class _DenyReasonSheet extends StatefulWidget {
  const _DenyReasonSheet({required this.agentName});

  final String agentName;

  @override
  State<_DenyReasonSheet> createState() => _DenyReasonSheetState();
}

class _DenyReasonSheetState extends State<_DenyReasonSheet> {
  final _reason = TextEditingController();

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ready = _reason.text.trim().isNotEmpty;
    return Padding(
      // Above the keyboard, which the sheet does not make room for itself.
      padding: EdgeInsets.fromLTRB(
        Insets.lg,
        0,
        Insets.lg,
        MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const ValueKey('dock-deny-reason'),
            controller: _reason,
            autofocus: true,
            minLines: 2,
            maxLines: 6,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              hintText: 'Tell ${widget.agentName} what to do instead',
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: Insets.md),
          FilledButton(
            key: const ValueKey('dock-deny-send'),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(Touch.target),
            ),
            onPressed: ready
                ? () => Navigator.of(context).pop(_reason.text.trim())
                : null,
            child: const Text('Deny and send'),
          ),
        ],
      ),
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
