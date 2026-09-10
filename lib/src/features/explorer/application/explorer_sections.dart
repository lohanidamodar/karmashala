import 'package:riverpod/riverpod.dart';

import '../../../core/util/id_generator_provider.dart';
import '../../cli_detection/application/cli_detection_providers.dart';
import 'package:agent_cli/read.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_git/github.dart';
import '../../notifications/application/delivery_attention.dart';
import '../../notifications/application/notification_providers.dart';
import '../../notifications/domain/session_attention.dart';
import '../../repositories/application/repository_providers.dart';
import '../../sessions/application/delivery_providers.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_signals.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session/delivery.dart';
import '../../settings/application/settings_controller.dart';
import '../data/explorer_section_dao.dart';
import '../domain/explorer_section.dart';
import 'checkout.dart';
import 'explorer_agent_filter.dart';

/// The saved sections, in sidebar order, and every write to them. Every
/// mutator writes to the DAO first and publishes second.
class ExplorerSectionsController extends Notifier<List<ExplorerSection>> {
  @override
  List<ExplorerSection> build() =>
      List.unmodifiable(ref.read(explorerSectionDaoProvider).getAll());

  ExplorerSectionDao get _dao => ref.read(explorerSectionDaoProvider);

  /// Adds a section at the *bottom*: position is priority (see
  /// [assignSections]), so arriving last it takes rows from nothing.
  ExplorerSection add({required String name, required SectionRule rule}) {
    final section = ExplorerSection(
      id: ref.read(idGeneratorProvider).newId(),
      name: name,
      rule: rule,
      position: state.isEmpty ? 0 : state.last.position + 1,
    );
    _dao.insert(section);
    state = List.unmodifiable([...state, section]);
    return section;
  }

  /// Renames a section and/or replaces its rule.
  void edit(String id, {String? name, SectionRule? rule}) {
    final section = _byId(id);
    if (section == null || !section.isEditable) return;
    final next = section.copyWith(name: name, rule: rule);
    _dao.update(next);
    _replace(next);
  }

  void remove(String id) {
    final section = _byId(id);
    if (section == null || !section.isEditable) return;
    _dao.delete(id);
    state = List.unmodifiable([
      for (final s in state)
        if (s.id != id) s,
    ]);
  }

  void setCollapsed(String id, bool collapsed) {
    final section = _byId(id);
    if (section == null || section.collapsed == collapsed) return;
    _dao.setCollapsed(id, collapsed);
    _replace(section.copyWith(collapsed: collapsed));
  }

  void toggleCollapsed(String id) {
    final section = _byId(id);
    if (section != null) setCollapsed(id, !section.collapsed);
  }

  /// Moves the section at [from] to index [to], renumbering the rest. Pinned
  /// never moves and nothing may move above it — it is the top of the order.
  void move(int from, int to) {
    if (from < 0 || from >= state.length) return;
    final moving = state[from];
    if (!moving.isEditable) return;
    final ordered = [...state]..removeAt(from);
    final floor = ordered.indexWhere((s) => s.isEditable);
    final target = to.clamp(floor < 0 ? 0 : floor, ordered.length);
    ordered.insert(target, moving);
    _dao.reorder([for (final s in ordered) s.id]);
    state = List.unmodifiable([
      for (var i = 0; i < ordered.length; i++) ordered[i].copyWith(position: i),
    ]);
  }

  /// Puts [sessionId] in a hand-filled group. Pinning is not routed here: the
  /// Pinned section's membership is `Settings.pinnedSessionIds`.
  void addMember(String sectionId, String sessionId) {
    final section = _byId(sectionId);
    if (section == null || section.rule.kind != SectionRuleKind.manual) return;
    if (section.members.contains(sessionId)) return;
    _dao.addMember(sectionId, sessionId);
    _replace(section.copyWith(members: {...section.members, sessionId}));
  }

  void removeMember(String sectionId, String sessionId) {
    final section = _byId(sectionId);
    if (section == null || !section.members.contains(sessionId)) return;
    _dao.removeMember(sectionId, sessionId);
    _replace(
      section.copyWith(
        members: {
          for (final id in section.members)
            if (id != sessionId) id,
        },
      ),
    );
  }

  ExplorerSection? _byId(String id) {
    for (final section in state) {
      if (section.id == id) return section;
    }
    return null;
  }

  void _replace(ExplorerSection next) => state = List.unmodifiable([
    for (final section in state)
      if (section.id == next.id) next else section,
  ]);
}

final explorerSectionsProvider =
    NotifierProvider<ExplorerSectionsController, List<ExplorerSection>>(
      ExplorerSectionsController.new,
    );

/// Whether any section is open. Everything below this line is `autoDispose`
/// and reachable only from an expanded section's body, so a folded sidebar
/// runs none of it.
final anySectionExpandedProvider = Provider<bool>(
  (ref) => ref.watch(
    explorerSectionsProvider.select(
      (sections) => sections.any((section) => !section.collapsed),
    ),
  ),
);

/// One session, reduced to the facts that cannot change without the session
/// *list* changing; the volatile half is folded in by
/// [explorerSectionFactsProvider].
class SectionCandidate {
  const SectionCandidate({
    required this.id,
    required this.title,
    this.native,
    this.imported,
    this.status,
    this.archived = false,
    this.projectId,
    this.repositoryPath,
    this.worktree,
  });

  final String id;
  final String title;

  /// The workspace row itself, carried rather than looked up again — the
  /// sidebar re-reading a row by id would be a per-item database read.
  final Session? native;
  final ImportedSession? imported;

  final SessionStatus? status;
  final bool archived;

  /// The project this session's repository belongs to, for the rows that draw
  /// a cross-project list and therefore have to say *where*.
  final String? projectId;

  /// Where the session's repository is. Null means the repository was retired
  /// under the session, not an error.
  final EnvironmentPath? repositoryPath;

  /// The worktree the session works in, when it has one.
  final EnvironmentPath? worktree;

  bool get isImported => imported != null;

  /// The directory whose pull request describes this session — the spelling
  /// `sessionDeliveryProvider` uses, so the two share one `gh` answer.
  EnvironmentPath? get directory => worktree ?? repositoryPath;
}

/// Every session in the workspace, in the terms a rule can be applied to.
/// Three statements, on change only, and none at all while every section is
/// collapsed.
final sectionCandidatesProvider = Provider.autoDispose<List<SectionCandidate>>((
  ref,
) {
  ref.watchSessionKinds(const {
    SessionChangeKind.membership,
    SessionChangeKind.title,
    SessionChangeKind.status,
    SessionChangeKind.placement,
    SessionChangeKind.workspace,
  });
  final repositories = {
    for (final repository in ref.read(repositoryDaoProvider).getAll())
      repository.id: repository,
  };
  return List.unmodifiable(<SectionCandidate>[
    for (final session in ref.read(sessionDaoProvider).getAll())
      SectionCandidate(
        id: session.id,
        title: session.title,
        native: session,
        status: session.status,
        archived: session.isArchived,
        projectId: repositories[session.repositoryId]?.projectId,
        repositoryPath: repositories[session.repositoryId]?.path,
        worktree: session.worktree,
      ),
    for (final session in ref.read(importedSessionDaoProvider).getAll())
      SectionCandidate(
        id: session.id,
        title: session.displayTitle,
        imported: session,
        projectId: repositories[session.repositoryId]?.projectId,
        repositoryPath: repositories[session.repositoryId]?.path,
      ),
  ]);
});

/// The same sweep, narrowed to the agents the Explorer is showing — the one
/// place the agent filter meets sections. The unfiltered path is the identity:
/// it hands back [sectionCandidatesProvider]'s own list, mounting nothing.
final visibleSectionCandidatesProvider =
    Provider.autoDispose<List<SectionCandidate>>((ref) {
      final candidates = ref.watch(sectionCandidatesProvider);
      final filter = ref.watch(explorerAgentFilterProvider);
      if (filter.isUnfiltered) return candidates;
      final agents = ref.watch(sessionAgentsProvider);
      String? agentOf(SectionCandidate candidate) {
        final imported = candidate.imported;
        if (imported != null) return agents.forImported(imported);
        final native = candidate.native;
        return native == null ? null : agents.forNative(native);
      }

      return List.unmodifiable(<SectionCandidate>[
        for (final candidate in candidates)
          if (filter.allows(agentOf(candidate))) candidate,
      ]);
    });

/// Every session, with everything a rule may ask about it — **read, never
/// measured**: it may look in caches other surfaces filled and may not fill
/// one, so a section reports only what the app already had reason to measure.
final explorerSectionFactsProvider = Provider.autoDispose<List<SectionFacts>>((
  ref,
) {
  if (ref.watch(anySectionExpandedProvider)) ref.watch(deliveryPollProvider);
  final candidates = ref.watch(visibleSectionCandidatesProvider);
  // One read of each ambient map, outside the loop: reading whole-app state
  // per candidate would turn a fold into a quadratic one.
  final observed = ref.watch(deliveryAttentionProvider);
  final waiting = <String>{
    for (final attention in ref.watch(sessionAttentionProvider))
      if (attention.kind == AttentionKind.needsInput) attention.session.openId,
  };

  return List.unmodifiable(<SectionFacts>[
    for (final candidate in candidates)
      _factsFor(ref, candidate, observed: observed, waiting: waiting),
  ]);
});

SectionFacts _factsFor(
  Ref ref,
  SectionCandidate candidate, {
  required Map<String, SessionDelivery> observed,
  required Set<String> waiting,
}) {
  // The strip's own last reading first: it is the only source carrying the
  // pull request *and* the branch together, so there is nothing to reconcile.
  final strip = observed[candidate.id];
  final local = strip ?? _localDelivery(ref, candidate);
  final directory = candidate.directory;
  final pullRequest =
      strip?.pullRequest ??
      _warm<PullRequestSnapshot?>(
        ref,
        directory == null
            ? null
            : checkoutPullRequestProvider(Checkout(directory)),
      );

  return SectionFacts(
    id: candidate.id,
    title: candidate.title,
    imported: candidate.isImported,
    status: candidate.status,
    archived: candidate.archived,
    branch: local?.branch,
    // The stage only when a reading exists: `SessionDelivery.unknown.stage`
    // answers `working` for every unopened session in the workspace.
    stage: local?.stage,
    pullRequestState: pullRequest?.state,
    checks: pullRequest?.checks.state,
    awaitingInput: waiting.contains(candidate.id),
  );
}

/// The local delivery reading for [candidate]'s checkout, if some row already
/// paid for it.
SessionDelivery? _localDelivery(Ref ref, SectionCandidate candidate) {
  final repository = candidate.repositoryPath;
  if (repository == null) return null;
  final worktree = candidate.worktree;
  // A worktree session's branch is its worktree's, not its repository's, and
  // these are two different family entries.
  if (worktree != null) {
    return _warm(
          ref,
          worktreeDeliveryProvider((repo: repository, worktree: worktree)),
        ) ??
        // Named with its repository, as `worktreeDeliveryProvider` does, so
        // `repositoryOriginProvider` answers once per clone not per `wt-*`.
        _warm(
          ref,
          checkoutDeliveryProvider(
            Checkout(worktree, repository: repository),
          ),
        );
  }
  return _warm(ref, checkoutDeliveryProvider(Checkout(repository)));
}

/// The value [provider] already holds, or null when nothing has mounted it.
/// `ref.exists` before `ref.watch`, always — watching *creates* — and `.value`
/// rather than `.asData?.value`, since a refresh carries the previous value.
T? _warm<T>(Ref ref, FutureProvider<T>? provider) {
  if (provider == null || !ref.exists(provider)) return null;
  return ref.watch(provider).value;
}

/// Which section claims each session, resolved once for the whole sidebar:
/// priority is a question about all the sections at once, so it cannot be
/// answered per section.
final explorerSectionAssignmentProvider =
    Provider.autoDispose<Map<String, List<SectionFacts>>>((ref) {
      final sections = ref.watch(explorerSectionsProvider);
      // Selected rather than watched whole so an unrelated settings write does
      // not re-file the sidebar. `toSet()` is *outside* the selector on
      // purpose: `select` compares with `==`, and a fresh set never is.
      final pinned = ref
          .watch(settingsControllerProvider.select((s) => s.pinnedSessionIds))
          .toSet();
      return Map.unmodifiable(
        assignSections(
          sections,
          ref.watch(explorerSectionFactsProvider),
          pinnedIds: pinned,
        ),
      );
    });

/// What one section holds right now, selected out of the shared assignment so
/// a section does not rebuild when a neighbour's contents move.
final explorerSectionMembersProvider = Provider.autoDispose
    .family<List<SectionFacts>, String>(
      (ref, sectionId) => ref.watch(
        explorerSectionAssignmentProvider.select(
          (assignment) => assignment[sectionId] ?? const <SectionFacts>[],
        ),
      ),
    );

/// What the sidebar draws, and how many it folded away — the count the
/// header's filter reports, so nothing vanishes silently. Only a *collapsed*
/// empty section hides: an open one shows [emptySectionMessage] instead.
class ExplorerSectionLayout {
  const ExplorerSectionLayout({required this.shown, required this.hidden});

  /// The sections to draw, in sidebar order.
  final List<ExplorerSection> shown;

  /// How many were folded away for being empty.
  final int hidden;

  /// Value equality is the point of this class rather than a record: the
  /// assignment underneath is rebuilt on every delivery heartbeat.
  @override
  bool operator ==(Object other) {
    if (other is! ExplorerSectionLayout) return false;
    if (other.hidden != hidden || other.shown.length != shown.length) {
      return false;
    }
    for (var i = 0; i < shown.length; i++) {
      if (other.shown[i] != shown[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(hidden, Object.hashAll(shown));
}

/// Which sections survive the empty filter, and the one place its cost is
/// paid: asking whether a section is empty *is* matching it, so the setting on
/// keeps the matching graph mounted (`explorer_sections_cost_test.dart`).
final explorerSectionLayoutProvider =
    Provider.autoDispose<ExplorerSectionLayout>((ref) {
      final sections = ref.watch(explorerSectionsProvider);
      final hideEmpty = ref.watch(
        settingsControllerProvider.select((s) => s.hideEmptySections),
      );
      if (!hideEmpty || sections.isEmpty) {
        return ExplorerSectionLayout(shown: sections, hidden: 0);
      }
      final assignment = ref.watch(explorerSectionAssignmentProvider);
      final shown = <ExplorerSection>[];
      var hidden = 0;
      for (final section in sections) {
        final members = assignment[section.id];
        if (section.collapsed && (members == null || members.isEmpty)) {
          hidden++;
          continue;
        }
        shown.add(section);
      }
      return ExplorerSectionLayout(
        shown: List.unmodifiable(shown),
        hidden: hidden,
      );
    });
