part of '../remote_payloads.dart';

/// What a stopped session is waiting on — the wire's copy of `AgentWaitKind`.
/// Only [approval] may be answered with a keystroke: Claude Code fires the same
/// notification for an open prompt and for a merely finished turn.
enum RemoteWaitKind {
  /// A prompt with options is open. Only here may a key be pressed for the
  /// user, and only here does the host name answers.
  approval('approval'),

  /// The agent is at its own input with nothing to confirm — reply to it, do
  /// not answer it.
  input('input'),

  /// No source could tell, or the host is older than this field. Treated like
  /// [input] wherever a key would be pressed.
  unrecorded('unrecorded'),

  /// A multiple-choice question is open. Never answered with approve/deny —
  /// only with question.answer, naming the option chosen.
  question('question');

  const RemoteWaitKind(this.wire);

  final String wire;

  /// An absent or unknown word reads as [unrecorded]: the fail-safe direction
  /// is always "we cannot tell whether a prompt is open".
  static RemoteWaitKind parse(Object? wire) =>
      _byWire[wire] ?? RemoteWaitKind.unrecorded;

  static final Map<Object?, RemoteWaitKind> _byWire = {
    for (final k in RemoteWaitKind.values) k.wire: k,
  };
}

/// One option of an agent's question, in its own words.
class RemoteQuestionOption {
  const RemoteQuestionOption({
    required this.label,
    this.description = '',
    this.preview = '',
  });

  final String label;
  final String description;

  /// A mockup or snippet the agent drew for this option; empty when none.
  final String preview;

  Map<String, Object?> toJson() => {
    'label': label,
    if (description.isNotEmpty) 'description': description,
    if (preview.isNotEmpty) 'preview': preview,
  };
}

/// One question.
class RemoteQuestionItem {
  const RemoteQuestionItem({
    required this.question,
    required this.options,
    this.header = '',
    this.multiSelect = false,
  });

  final String question;
  final String header;
  final List<RemoteQuestionOption> options;
  final bool multiSelect;

  Map<String, Object?> toJson() => {
    'question': question,
    if (header.isNotEmpty) 'header': header,
    if (multiSelect) 'multiSelect': true,
    'options': [for (final o in options) o.toJson()],
  };
}

/// A multiple-choice question an agent is asking (Claude Code's
/// `AskUserQuestion`), carried with the approval request for its session.
class RemoteQuestion {
  const RemoteQuestion({required this.toolUseId, required this.questions});

  /// Which call this is. The answer names it, so an answer meant for a question
  /// that has since closed cannot land on the next one.
  final String toolUseId;

  final List<RemoteQuestionItem> questions;

  Map<String, Object?> toJson() => {
    'toolUseId': toolUseId,
    'questions': [for (final q in questions) q.toJson()],
  };

  /// The question, or null for anything not wholly readable: a half-read
  /// question is one the phone could answer wrongly.
  static RemoteQuestion? tryFromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['toolUseId'];
    final raw = json['questions'];
    if (id is! String || raw is! List || raw.isEmpty) return null;
    final questions = <RemoteQuestionItem>[];
    for (final entry in raw) {
      if (entry is! Map) return null;
      final question = entry['question'];
      final options = entry['options'];
      if (question is! String || options is! List || options.isEmpty) {
        return null;
      }
      final read = <RemoteQuestionOption>[];
      for (final option in options) {
        final label = option is Map ? option['label'] : null;
        if (label is! String) return null;
        final description = (option as Map)['description'];
        final preview = option['preview'];
        read.add(
          RemoteQuestionOption(
            label: label,
            description: description is String ? description : '',
            preview: preview is String ? preview : '',
          ),
        );
      }
      questions.add(
        RemoteQuestionItem(
          question: question,
          header: entry['header'] is String ? entry['header']! as String : '',
          multiSelect: entry['multiSelect'] == true,
          options: read,
        ),
      );
    }
    return RemoteQuestion(toolUseId: id, questions: questions);
  }
}

/// What the user chose for one question: option indexes, or their own words.
class RemoteQuestionAnswer {
  const RemoteQuestionAnswer.options(this.options) : text = null;

  const RemoteQuestionAnswer.text(String this.text) : options = const [];

  final List<int> options;
  final String? text;

  Map<String, Object?> toJson() =>
      text != null ? {'text': text} : {'options': options};

  static RemoteQuestionAnswer fromJson(Object? json) {
    if (json is Map) {
      final text = json['text'];
      if (text is String) return RemoteQuestionAnswer.text(text);
      final options = json['options'];
      if (options is List && options.every((o) => o is int)) {
        return RemoteQuestionAnswer.options(options.cast<int>());
      }
    }
    throw const ProtocolException('bad question answer');
  }
}

/// What `question.answer` carries: an answer per question, or a decline.
class RemoteQuestionAnswerRequest {
  const RemoteQuestionAnswerRequest({
    required this.sessionId,
    required this.toolUseId,
    this.answers = const [],
    this.decline = false,
    this.chat = false,
  });

  final String sessionId;
  final String toolUseId;
  final List<RemoteQuestionAnswer> answers;

  /// Dismiss the question without answering it.
  final bool decline;

  /// Leave the question to talk it over ("Chat about this").
  final bool chat;

  Map<String, Object?> toJson() => {
    'sessionId': sessionId,
    'toolUseId': toolUseId,
    if (decline)
      'decline': true
    else if (chat)
      'chat': true
    else
      'answers': [for (final a in answers) a.toJson()],
  };

  static RemoteQuestionAnswerRequest fromJson(Map<String, Object?> json) {
    final sessionId = json['sessionId'];
    final toolUseId = json['toolUseId'];
    if (sessionId is! String || toolUseId is! String) {
      throw const ProtocolException('bad question answer');
    }
    final decline = json['decline'] == true;
    final chat = !decline && json['chat'] == true;
    final answers = json['answers'];
    if (!decline && !chat && (answers is! List || answers.isEmpty)) {
      throw const ProtocolException(
        'a question answer needs answers, a decline or a chat',
      );
    }
    return RemoteQuestionAnswerRequest(
      sessionId: sessionId,
      toolUseId: toolUseId,
      decline: decline,
      chat: chat,
      answers: decline || chat
          ? const []
          : [
              for (final a in answers! as List)
                RemoteQuestionAnswer.fromJson(a),
            ],
    );
  }
}

/// A menu the agent drew on its own screen — folder trust, a permission
/// prompt, a startup offer — as the host read it off the pane.
class RemoteMenu {
  const RemoteMenu({
    required this.menuId,
    required this.options,
    required this.highlighted,
    this.prompt = const [],
  });

  /// Names this menu. The answer carries it, so an answer meant for one
  /// prompt cannot land on the one that replaced it.
  final String menuId;

  /// The rows above the options that say what is asked, verbatim.
  final List<String> prompt;

  /// The options in the agent's words, top first.
  final List<String> options;

  /// What Enter alone would choose — shown, never assumed to be the answer.
  final int highlighted;

  Map<String, Object?> toJson() => {
    'menuId': menuId,
    'prompt': prompt,
    'options': options,
    'highlighted': highlighted,
  };

  /// The menu, or null for anything not wholly readable.
  static RemoteMenu? tryFromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['menuId'];
    final options = json['options'];
    final highlighted = json['highlighted'];
    final prompt = json['prompt'];
    if (id is! String ||
        options is! List ||
        options.length < 2 ||
        !options.every((o) => o is String) ||
        highlighted is! int ||
        highlighted < 0 ||
        highlighted >= options.length) {
      return null;
    }
    return RemoteMenu(
      menuId: id,
      options: options.cast<String>(),
      highlighted: highlighted,
      prompt: [
        if (prompt is List)
          for (final row in prompt)
            if (row is String) row,
      ],
    );
  }
}

/// What `menu.answer` carries: which option of which menu.
class RemoteMenuAnswerRequest {
  const RemoteMenuAnswerRequest({
    required this.sessionId,
    required this.menuId,
    required this.option,
  });

  final String sessionId;
  final String menuId;

  /// The chosen option's index, top first.
  final int option;

  Map<String, Object?> toJson() => {
    'sessionId': sessionId,
    'menuId': menuId,
    'option': option,
  };

  static RemoteMenuAnswerRequest fromJson(Map<String, Object?> json) {
    final sessionId = json['sessionId'];
    final menuId = json['menuId'];
    final option = json['option'];
    if (sessionId is! String || menuId is! String || option is! int) {
      throw const ProtocolException('bad menu answer');
    }
    return RemoteMenuAnswerRequest(
      sessionId: sessionId,
      menuId: menuId,
      option: option,
    );
  }
}

/// One answer an agent spoken to over ACP offers its own approval: [kind] is
/// the protocol's word — `allow_once`, `allow_always`, `reject_once`,
/// `reject_always` — or whatever else it said.
class RemoteApprovalOption {
  const RemoteApprovalOption({
    required this.id,
    required this.name,
    required this.kind,
  });

  final String id;

  /// The agent's own words for it.
  final String name;
  final String kind;

  bool get allows => kind.startsWith('allow');

  Map<String, Object?> toJson() => {'id': id, 'name': name, 'kind': kind};

  /// Null for a shape this build cannot read.
  static RemoteApprovalOption? tryFromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    if (id is! String || id.isEmpty) return null;
    final name = json['name'];
    final kind = json['kind'];
    return RemoteApprovalOption(
      id: id,
      name: name is String ? name : id,
      kind: kind is String ? kind : '',
    );
  }

  @override
  bool operator ==(Object other) =>
      other is RemoteApprovalOption &&
      other.id == id &&
      other.name == name &&
      other.kind == kind;

  @override
  int get hashCode => Object.hash(id, name, kind);
}

/// What `approval.requested` carries: the agent's own words, verbatim, or
/// nothing — never a summary this code wrote.
class RemoteApprovalRequest {
  const RemoteApprovalRequest({
    required this.sessionId,
    this.evidence = const [],
    this.waiting = RemoteWaitKind.unrecorded,
    this.approveLabel,
    this.denyLabel,
    this.question,
    this.menu,
    this.options = const [],
  });

  /// The answers an ACP agent offered, in its order, each chosen by
  /// `approval.answer`'s `optionId`. Empty for any other prompt, and from an
  /// older host.
  final List<RemoteApprovalOption> options;

  final String sessionId;
  final List<String> evidence;

  /// The question itself, when [waiting] is [RemoteWaitKind.question] and the
  /// host could read it. Absent from an older host.
  final RemoteQuestion? question;

  /// The menu on the agent's screen, when the host could read one — answered
  /// by option with `menu.answer`. A host that sends one names no approve or
  /// deny: Enter chooses whatever is highlighted, which on a folder-trust
  /// prompt is "No, exit". Absent from an older host.
  final RemoteMenu? menu;

  /// What the host can tell the session is waiting on. Sent for every request
  /// so the phone can word the card without guessing.
  final RemoteWaitKind waiting;

  /// The answers the agent itself names, and **only** for a prompt the host can
  /// see. A missing label means that answer does not exist here.
  final String? approveLabel;
  final String? denyLabel;

  Map<String, Object?> toJson() => {
    'sessionId': sessionId,
    'evidence': evidence,
    'waiting': waiting.wire,
    if (approveLabel != null) 'approve': approveLabel,
    if (denyLabel != null) 'deny': denyLabel,
    if (question != null) 'question': question!.toJson(),
    if (menu != null) 'menu': menu!.toJson(),
    if (options.isNotEmpty) 'options': [for (final o in options) o.toJson()],
  };

  static RemoteApprovalRequest fromJson(Map<String, Object?> json) {
    final sessionId = json['sessionId'];
    if (sessionId is! String) {
      throw const ProtocolException('bad approval request');
    }
    final evidence = json['evidence'];
    return RemoteApprovalRequest(
      sessionId: sessionId,
      evidence: [
        if (evidence is List)
          for (final line in evidence)
            if (line is String) line,
      ],
      waiting: RemoteWaitKind.parse(json['waiting']),
      approveLabel: json['approve'] is String
          ? json['approve']! as String
          : null,
      denyLabel: json['deny'] is String ? json['deny']! as String : null,
      question: RemoteQuestion.tryFromJson(json['question']),
      menu: RemoteMenu.tryFromJson(json['menu']),
      options: [
        if (json['options'] case final List options)
          for (final option in options)
            ?RemoteApprovalOption.tryFromJson(option),
      ],
    );
  }
}

/// How an approval stopped waiting, as far as the host can honestly say.
/// [approved] and [denied] only when this host pressed the key itself; every
/// other route is [elsewhere], because the decision is not observable.
enum RemoteApprovalOutcome {
  approved('approved'),
  denied('denied'),
  elsewhere('elsewhere'),

  /// A question this host answered with the user's choice.
  answered('answered');

  const RemoteApprovalOutcome(this.wire);

  final String wire;

  /// Unknown wording from a newer host reads as [elsewhere]: something
  /// happened and the card must go, which is the part that matters.
  static RemoteApprovalOutcome parse(Object? wire) =>
      _byWire[wire] ?? RemoteApprovalOutcome.elsewhere;

  static final Map<Object?, RemoteApprovalOutcome> _byWire = {
    for (final o in RemoteApprovalOutcome.values) o.wire: o,
  };
}

/// What `approval.resolved` carries.
/// Correlated by session: `approval.requested` carries no id of its own, and a
/// session has at most one prompt waiting at a time.
class RemoteApprovalResolved {
  const RemoteApprovalResolved({
    required this.sessionId,
    this.outcome = RemoteApprovalOutcome.elsewhere,
  });

  final String sessionId;
  final RemoteApprovalOutcome outcome;

  Map<String, Object?> toJson() => {
    'sessionId': sessionId,
    'outcome': outcome.wire,
  };

  static RemoteApprovalResolved fromJson(Map<String, Object?> json) {
    final sessionId = json['sessionId'];
    if (sessionId is! String) {
      throw const ProtocolException('bad approval resolution');
    }
    return RemoteApprovalResolved(
      sessionId: sessionId,
      outcome: RemoteApprovalOutcome.parse(json['outcome']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is RemoteApprovalResolved &&
      other.sessionId == sessionId &&
      other.outcome == outcome;

  @override
  int get hashCode => Object.hash(sessionId, outcome);
}
