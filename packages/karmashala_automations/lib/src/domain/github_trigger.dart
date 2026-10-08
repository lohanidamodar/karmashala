import 'dart:convert';

import 'automation_trigger.dart';
import 'webhook_template.dart';

/// What happens on GitHub that an automation can answer. Each is something
/// the poller can see in GitHub's REST API with one or two reads.
enum GithubTriggerKind {
  prComment('pr_comment'),
  prReview('pr_review'),
  checkFailed('check_failed'),
  prMerged('pr_merged'),
  issueLabeled('issue_labeled'),
  issueAssigned('issue_assigned');

  const GithubTriggerKind(this.storedName);

  final String storedName;

  static GithubTriggerKind? fromStored(String? stored) {
    for (final kind in values) {
      if (kind.storedName == stored) return kind;
    }
    return null;
  }

  bool get isPullRequest => switch (this) {
    GithubTriggerKind.issueLabeled || GithubTriggerKind.issueAssigned => false,
    _ => true,
  };

  String get label => switch (this) {
    GithubTriggerKind.prComment => 'A comment on a pull request',
    GithubTriggerKind.prReview => 'A review on a pull request',
    GithubTriggerKind.checkFailed => 'A check fails on a pull request',
    GithubTriggerKind.prMerged => 'A pull request is merged',
    GithubTriggerKind.issueLabeled => 'An issue is labelled',
    GithubTriggerKind.issueAssigned => 'An issue is assigned',
  };

  /// "someone comments on a pull request" — completes "When ".
  String get phrase => switch (this) {
    GithubTriggerKind.prComment => 'someone comments on a pull request',
    GithubTriggerKind.prReview => 'someone reviews a pull request',
    GithubTriggerKind.checkFailed => 'a check fails on a pull request',
    GithubTriggerKind.prMerged => 'a pull request is merged',
    GithubTriggerKind.issueLabeled => 'an issue is labelled',
    GithubTriggerKind.issueAssigned => 'an issue is assigned',
  };
}

/// Whose acts a GitHub automation answers.
enum GithubAuthors {
  /// Owners, members and collaborators of the repository — the default.
  collaborators,
  anyone,

  /// Only the logins listed.
  listed;

  static GithubAuthors fromName(String? name) => values.firstWhere(
    (a) => a.name == name,
    orElse: () => GithubAuthors.collaborators,
  );

  String get label => switch (this) {
    GithubAuthors.collaborators => 'Collaborators',
    GithubAuthors.anyone => 'Anyone',
    GithubAuthors.listed => 'These people',
  };
}

/// The default and the shortest gap between two looks at GitHub.
const Duration kGithubPollDefault = Duration(minutes: 2);
const Duration kGithubPollMinimum = Duration(minutes: 1);

/// An automation that answers GitHub: what it watches, whose acts, and what
/// it does. Polled, never pushed, so it needs no public URL.
class AutomationGithubTrigger {
  const AutomationGithubTrigger({
    required this.kind,
    required this.repository,
    this.action = AutomationEventAction.startSession,
    this.branch = '',
    this.authors = GithubAuthors.collaborators,
    this.logins = const [],
    this.label = '',
    this.assignee = '',
    this.pollSeconds = 120,
  });

  final GithubTriggerKind kind;

  /// `owner/name`, read off the checkout's GitHub remote.
  final String repository;

  /// For a pull request: a new agent in a worktree on its branch, the
  /// session that owns the branch told (or that agent when none does), or
  /// only the steps.
  final AutomationEventAction action;

  /// A branch, or a prefix ending in `*`. Empty is any.
  final String branch;
  final GithubAuthors authors;
  final List<String> logins;

  /// The label an issue must be given (labelled), or carry (the rest).
  final String label;

  /// Whom an issue must be assigned to; empty is anyone.
  final String assignee;
  final int pollSeconds;

  Duration get pollEvery {
    final every = Duration(seconds: pollSeconds);
    return every < kGithubPollMinimum ? kGithubPollMinimum : every;
  }

  AutomationGithubTrigger copyWith({
    GithubTriggerKind? kind,
    String? repository,
    AutomationEventAction? action,
    String? branch,
    GithubAuthors? authors,
    List<String>? logins,
    String? label,
    String? assignee,
    int? pollSeconds,
  }) => AutomationGithubTrigger(
    kind: kind ?? this.kind,
    repository: repository ?? this.repository,
    action: action ?? this.action,
    branch: branch ?? this.branch,
    authors: authors ?? this.authors,
    logins: logins ?? this.logins,
    label: label ?? this.label,
    assignee: assignee ?? this.assignee,
    pollSeconds: pollSeconds ?? this.pollSeconds,
  );

  /// Why this cannot be saved, or null.
  String? get refusal {
    if (!RegExp(r'^[\w.-]+/[\w.-]+$').hasMatch(repository.trim())) {
      return 'Name the repository as owner/name.';
    }
    if (kind == GithubTriggerKind.issueLabeled && label.trim().isEmpty) {
      return 'Choose the label.';
    }
    if (authors == GithubAuthors.listed && logins.isEmpty) {
      return 'List at least one GitHub login.';
    }
    if (!kind.isPullRequest && action == AutomationEventAction.messageSession) {
      return 'An issue has no session of its own to tell.';
    }
    return null;
  }

  Map<String, Object?> toJson() => {
    'kind': kind.storedName,
    'repository': repository,
    'action': action.storedName,
    if (branch.isNotEmpty) 'branch': branch,
    'authors': authors.name,
    if (logins.isNotEmpty) 'logins': logins,
    if (label.isNotEmpty) 'label': label,
    if (assignee.isNotEmpty) 'assignee': assignee,
    'pollSeconds': pollSeconds,
  };

  /// Null for a shape this build cannot read, which keeps the row inert.
  static AutomationGithubTrigger? fromJson(Object? json) {
    if (json is! Map) return null;
    final kind = GithubTriggerKind.fromStored(json['kind'] as String?);
    final action = AutomationEventAction.fromStored(json['action'] as String?);
    final repository = json['repository'];
    if (kind == null || action == null || repository is! String) return null;
    return AutomationGithubTrigger(
      kind: kind,
      repository: repository,
      action: action,
      branch: json['branch'] as String? ?? '',
      authors: GithubAuthors.fromName(json['authors'] as String?),
      logins: [
        for (final login in json['logins'] as List? ?? const [])
          if (login is String) login,
      ],
      label: json['label'] as String? ?? '',
      assignee: json['assignee'] as String? ?? '',
      pollSeconds: json['pollSeconds'] as int? ?? 120,
    );
  }

  static AutomationGithubTrigger? fromColumn(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      return fromJson(jsonDecode(raw));
    } on FormatException {
      return null;
    }
  }

  String toColumn() => jsonEncode(toJson());

  @override
  bool operator ==(Object other) =>
      other is AutomationGithubTrigger && other.toColumn() == toColumn();

  @override
  int get hashCode => toColumn().hashCode;

  @override
  String toString() => 'github ${kind.storedName} in $repository';
}

/// The repository associations GitHub reports that count as collaborators.
const Set<String> kCollaboratorAssociations = {
  'OWNER',
  'MEMBER',
  'COLLABORATOR',
};

/// One thing that happened on GitHub, as the poller read it.
class GithubEvent {
  const GithubEvent({
    required this.kind,
    required this.itemId,
    required this.number,
    required this.url,
    this.title = '',
    this.body = '',
    this.branch = '',
    this.author = '',
    this.association,
    this.labels = const [],
    this.label = '',
    this.assignee = '',
    this.checkName = '',
    this.checkSummary = '',
    this.fork = false,
  });

  final GithubTriggerKind kind;

  /// The comment, review, check run or issue event's own id; for a merge, the
  /// pull request's number.
  final String itemId;

  /// The pull request's or the issue's number.
  final int number;

  /// The pull request's or the issue's page.
  final String url;
  final String title;

  /// The comment's or review's text; for an issue, its body.
  final String body;

  /// A pull request's head branch.
  final String branch;

  /// Who did it: the commenter, the reviewer, the one who labelled.
  final String author;

  /// [author]'s `author_association`, or null when GitHub gives none — for a
  /// label or an assignment, which already take write access.
  final String? association;
  final List<String> labels;

  /// The label just given, for a labelled issue.
  final String label;

  /// Who an issue was just assigned to.
  final String assignee;
  final String checkName;
  final String checkSummary;

  /// Whether a pull request's branch lives on a fork, not the repository.
  final bool fork;

  /// The key that makes this event fire once per automation.
  String dedupeKey(String automationId) =>
      '$automationId:${kind.storedName}:$number:$itemId';

  /// Its values, as the `{{github.…}}` variables steps and prompts name.
  Map<String, String> get variables => kind.isPullRequest
      ? {
          'github.pr.number': '$number',
          'github.pr.title': title,
          'github.pr.url': url,
          'github.pr.branch': branch,
          'github.pr.fork': fork ? 'yes' : 'no',
          'github.comment.body': body,
          'github.comment.author': author,
          'github.check.name': checkName,
          'github.check.summary': checkSummary,
        }
      : {
          'github.issue.title': title,
          'github.issue.body': body,
          'github.issue.url': url,
          'github.comment.author': author,
        };

  /// A sentence for the run's reason.
  String get describe => switch (kind) {
    GithubTriggerKind.prComment => '$author commented on #$number',
    GithubTriggerKind.prReview => '$author reviewed #$number',
    GithubTriggerKind.checkFailed => '"$checkName" failed on #$number',
    GithubTriggerKind.prMerged => '#$number was merged',
    GithubTriggerKind.issueLabeled => 'issue #$number was labelled "$label"',
    GithubTriggerKind.issueAssigned =>
      'issue #$number was assigned to $assignee',
  };
}

/// The `{{github.…}}` variables, each with what it stands for.
const Map<String, String> kGithubVariables = {
  'github.pr.number': 'The pull request\'s number',
  'github.pr.title': 'Its title',
  'github.pr.url': 'Its page',
  'github.pr.branch': 'Its branch',
  'github.pr.fork': 'Whether its branch is on a fork: yes or no',
  'github.comment.body': 'The comment or review',
  'github.comment.author': 'Who wrote it',
  'github.check.name': 'The check that failed',
  'github.check.summary': 'What the check said',
  'github.issue.title': 'The issue\'s title',
  'github.issue.body': 'The issue\'s text',
  'github.issue.url': 'The issue\'s page',
};

/// The variables nobody else writes, so they may stand in an agent's text
/// as they are. Every other `github.` value is someone else's words.
const Set<String> kGithubTrustedVariables = {
  'github.pr.number',
  'github.pr.url',
  'github.pr.fork',
  'github.issue.url',
};

/// Where a pull request's run checks out its branch: the branch itself, or —
/// for one on a fork, which no remote of the checkout has — the base
/// repository's `refs/pull/<n>/head`, fetched into `pr/<n>-<branch>`.
class PullRequestCheckout {
  const PullRequestCheckout({
    required this.number,
    required this.branch,
    required this.repository,
    this.fork = false,
  });

  /// A pull request run's checkout from its [variables], or null when they
  /// name no branch (a Run now's sample) or [github] watches no pull requests.
  static PullRequestCheckout? of(
    AutomationGithubTrigger? github,
    Map<String, String> variables,
  ) {
    if (github == null || !github.kind.isPullRequest) return null;
    final branch = variables['github.pr.branch'] ?? '';
    if (branch.isEmpty) return null;
    final number = int.tryParse(variables['github.pr.number'] ?? '');
    return PullRequestCheckout(
      number: number ?? 0,
      branch: branch,
      repository: github.repository,
      // Without its number there is no pull ref to fetch.
      fork: number != null && variables['github.pr.fork'] == 'yes',
    );
  }

  final int number;
  final String branch;

  /// The base repository, `owner/name`.
  final String repository;
  final bool fork;

  /// The ref a fork's pull request is fetched from.
  String get pullRef => 'refs/pull/$number/head';

  /// The local branch the run works on. A fork's name is someone else's
  /// words, so only what a ref name safely holds is kept.
  String get localBranch {
    if (!fork) return branch;
    final safe = branch
        .replaceAll(RegExp(r'[^A-Za-z0-9._/-]'), '-')
        .replaceAll(RegExp(r'\.{2,}|/{2,}'), '-')
        .replaceAll(RegExp(r'^[./-]+|[./-]+$|\.lock$'), '');
    return safe.isEmpty ? 'pr/$number' : 'pr/$number-$safe';
  }

  /// What the run says about pushing, for a fork's branch.
  String? get pushNote => fork
      ? 'Its branch is on a fork, so it was fetched from $repository\'s '
            '$pullRef into $localBranch, which is read-only for pushes: '
            'nothing pushed from this run reaches the pull request.'
      : null;
}

/// Whether [branch] passes [pattern]: equal, or a prefix before a `*`.
bool githubBranchMatches(String pattern, String branch) {
  final wanted = pattern.trim();
  if (wanted.isEmpty) return true;
  if (wanted.endsWith('*')) {
    return branch.startsWith(wanted.substring(0, wanted.length - 1));
  }
  return branch == wanted;
}

/// Why [event] does not reach [trigger]'s automation, or null when it does.
String? githubEventRefusal(AutomationGithubTrigger trigger, GithubEvent event) {
  if (event.kind != trigger.kind) return 'Another kind of event.';
  if (trigger.kind.isPullRequest &&
      !githubBranchMatches(trigger.branch, event.branch)) {
    return 'Branch "${event.branch}" is not "${trigger.branch}".';
  }
  final login = event.author.toLowerCase();
  switch (trigger.authors) {
    case GithubAuthors.anyone:
      break;
    case GithubAuthors.collaborators:
      final association = event.association;
      if (association != null &&
          !kCollaboratorAssociations.contains(association)) {
        return '${event.author} is not a collaborator.';
      }
    case GithubAuthors.listed:
      if (!trigger.logins.any((l) => l.trim().toLowerCase() == login)) {
        return '${event.author} is not on the list.';
      }
  }
  final label = trigger.label.trim().toLowerCase();
  if (label.isNotEmpty) {
    final has = event.kind == GithubTriggerKind.issueLabeled
        ? event.label.toLowerCase() == label
        : event.labels.any((l) => l.toLowerCase() == label);
    if (!has) return 'It does not carry "${trigger.label}".';
  }
  final assignee = trigger.assignee.trim().toLowerCase();
  if (event.kind == GithubTriggerKind.issueAssigned &&
      assignee.isNotEmpty &&
      event.assignee.toLowerCase() != assignee) {
    return 'Assigned to ${event.assignee}, not ${trigger.assignee}.';
  }
  return null;
}

/// [text] for an agent: trusted `{{…}}` values in place, and every other
/// `github.` value — someone else's words — referenced and quoted below as
/// data, cut to size, as a webhook's fields are.
String fillAgentText(String text, Map<String, String> values, {String? nonce}) {
  bool untrusted(String name) =>
      name.startsWith('github.') && !kGithubTrustedVariables.contains(name);
  final trusted = text.replaceAllMapped(
    RegExp(r'\{\{\s*([a-zA-Z0-9_.\-]+)\s*\}\}'),
    (m) => untrusted(m[1]!) ? m[0]! : values[m[1]!] ?? m[0]!,
  );
  return quoteAsData(
    trusted,
    {
      for (final MapEntry(:key, :value) in values.entries)
        if (untrusted(key)) key: value,
    },
    from: 'GitHub, written by other people',
    nonce: nonce,
  );
}
