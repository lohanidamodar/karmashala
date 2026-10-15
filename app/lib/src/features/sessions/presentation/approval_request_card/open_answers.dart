// The answers an open approval offers: one list the dock and the board draw.
part of '../approval_request_card.dart';

/// One answer an open approval offers, in its button's words, and the
/// request that sends it.
class _OpenAnswer {
  const _OpenAnswer({
    required this.id,
    required this.label,
    required this.kind,
    required this.allows,
    required this.request,
    required this.said,
    this.detail,
    this.tooltip,
    this.terminalKey,
    this.primary = false,
    this.menuOption,
  });

  /// The agent's option id, or `approve` / `always` / `deny`.
  final String id;
  final String label;

  /// See [_DockButton.detail].
  final String? detail;
  final String? tooltip;

  /// The ACP kind it answers as (`allow_once`, `allow_always`, `reject_once`,
  /// `reject_always`), or the agent's own for an option of another kind.
  final String kind;
  final bool allows;

  /// The key the terminal takes for it, named for a key cap.
  final String? terminalKey;
  final bool primary;

  /// The screen menu's option it picks, for the Always read off the screen.
  final int? menuOption;
  final PromptAnswerRequest request;

  /// What a phone says once it landed.
  final String said;
}

/// The rules an agent's prompts are answered by: an ACP agent types no keys,
/// so its request is answered by option.
AgentApprovalRules _rulesOf(AgentDescriptor? descriptor) =>
    descriptor?.acp != null
    ? AcpLaunchSpec.permissionAnswers
    : descriptor?.approval ?? const AgentApprovalRules();

/// What [report]'s open approval offers, in order: every option an ACP agent
/// sent, in its words; else the approve key, the [menu]'s option that keeps
/// approving, and the deny key. [menu] is the prompt the ask is about, and
/// [ask] names it for the keys.
List<_OpenAnswer> _openAnswers(
  String sessionId,
  AgentStatusReport report, {
  required AgentApprovalRules rules,
  AgentScreenMenu? menu,
  AgentMenuSupport? menus,
  PromptAsk? ask,
}) {
  final offered = report.toolAsk?.options ?? const <AgentToolAskOption>[];
  if (offered.isNotEmpty) {
    final primary = offered.where((o) => o.kind == 'allow_once').firstOrNull;
    final drawn = PromptAsk.drawnFrom(report);
    return [
      for (final option in offered)
        _OpenAnswer(
          id: option.id,
          label: option.name,
          kind: option.kind,
          allows: option.allows,
          tooltip: _optionEffect(option),
          primary: identical(option, primary),
          said: '${option.name}.',
          request: ApprovalAnswerRequest(
            sessionId: sessionId,
            approve: option.allows,
            optionId: option.id,
            ask: drawn,
          ),
        ),
    ];
  }
  final asked = ask ?? PromptAsk.drawnFrom(report);
  // A structured ask says what it answers; a bare prompt keeps the keys'.
  final call = report.toolAsk != null;
  final approve = rules.approve;
  final deny = rules.deny;
  final always = menu == null ? null : _alwaysOption(menu, menus);
  return [
    if (approve != null)
      _OpenAnswer(
        id: 'approve',
        label: call ? 'Allow once' : approve.label,
        kind: 'allow_once',
        allows: true,
        terminalKey: _keyName(approve.keys),
        tooltip: approve.effect,
        primary: true,
        said: call ? 'Allowed once.' : 'Allowed.',
        request: ApprovalAnswerRequest(
          sessionId: sessionId,
          approve: true,
          ask: asked,
        ),
      ),
    if (always != null && menu != null)
      _OpenAnswer(
        id: 'always',
        label: always.label,
        detail: always.detail,
        kind: 'allow_always',
        allows: true,
        tooltip: menu.options[always.index],
        menuOption: always.index,
        said: 'Chosen.',
        request: MenuAnswerRequest(
          sessionId: sessionId,
          menuId: menu.id,
          option: always.index,
        ),
      ),
    if (deny != null)
      _OpenAnswer(
        id: 'deny',
        label: call ? 'Deny' : deny.label,
        kind: 'reject_once',
        allows: false,
        terminalKey: _keyName(deny.keys),
        tooltip: deny.effect,
        said: 'Denied.',
        request: ApprovalAnswerRequest(
          sessionId: sessionId,
          approve: false,
          ask: asked,
        ),
      ),
  ];
}

String _optionEffect(AgentToolAskOption option) => switch (option.kind) {
  'allow_once' => 'Lets the agent make this call.',
  'allow_always' =>
    'Lets the agent make this call, and calls like it from now on without '
        'asking.',
  'reject_once' => 'Refuses this call; the agent carries on without it.',
  'reject_always' => 'Refuses this call, and calls like it from now on.',
  _ => 'Answers with the agent\'s own "${option.name}".',
};

/// Which of [answers] the board's Y, A and D send. Y is the first allow once,
/// else the only allowing answer; A a real "always", never one of a list
/// where every allowing answer is one (Codex's consent and choices).
Map<BoardApproval, _OpenAnswer> _boardKeys(List<_OpenAnswer> answers) {
  _OpenAnswer? first(String kind) =>
      answers.where((a) => a.kind == kind).firstOrNull;
  final allowing = answers.where((a) => a.allows).toList();
  final once =
      first('allow_once') ?? (allowing.length == 1 ? allowing.single : null);
  final always = allowing.every((a) => a.kind == 'allow_always')
      ? null
      : first('allow_always');
  final deny = first('reject_once');
  return {
    BoardApproval.allow: ?once,
    BoardApproval.always: ?always,
    BoardApproval.deny: ?deny,
  };
}

/// Why [ask] asks and which subagent asks it, in the agent's words, as one
/// line; empty when it said neither.
String _askWhy(AgentToolAsk? ask) => [
  if (ask?.asker case final asker?) 'Asked by $asker',
  ?ask?.reason,
].join(' · ');
