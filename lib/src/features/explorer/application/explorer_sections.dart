import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/util/id_generator_provider.dart';
import '../../cli_detection/application/cli_detection_providers.dart';
import '../../cli_detection/domain/imported_session.dart';
import '../../environments/domain/environment_path.dart';
import '../../github/domain/pull_request_snapshot.dart';
import '../../notifications/application/delivery_attention.dart';
import '../../notifications/application/notification_providers.dart';
import '../../notifications/domain/session_attention.dart';
import '../../repositories/application/repository_providers.dart';
import '../../sessions/application/delivery_providers.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_signals.dart';
import '../../sessions/domain/session.dart';
import '../../sessions/domain/session_delivery.dart';
import '../../sessions/domain/session_status.dart';
import '../../settings/application/settings_controller.dart';
import '../data/explorer_section_dao.dart';
import '../domain/explorer_section.dart';
import 'checkout.dart';

/// The saved sections, in sidebar order, and every write to them.
///
/// A `Notifier` over the DAO rather than a provider that re-reads on a
/// revision: sections change only when the user changes them, and there is
/// exactly one writer. Every mutator writes first and publishes second, so a
/// failed write never leaves the sidebar showing something the database does
/// not hold.
class ExplorerSectionsController extends Notifier<List<ExplorerSection>> {
  @override
  List<ExplorerSection> build() =>
      List.unmodifiable(ref.read(explorerSectionDaoProvider).getAll());

  ExplorerSectionDao get _dao => ref.read(explorerSectionDaoProvider);

  /// Adds a section at the bottom of the list.
  ///
  /// The bottom, not the top, and that is a priority decision as much as a
  /// layout one: position is priority (see [assignSections]), so a new section
  /// that landed at the top would silently take rows away from every section
  /// the user already had. Arriving last, it claims only what nothing else
  /// wanted, and the user promotes it by dragging.
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

  /// Moves the section at [from] to index [to], renumbering the rest.
  ///
  /// Pinned never moves and nothing may move above it: it is the top of the
  /// priority order by definition, and a Pinned section at position 3 would
  /// mean a pinned session appearing somewhere else.
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

  /// Puts [sessionId] in a hand-filled group.
  ///
  /// Pinning is not routed through here: the Pinned section's membership is
  /// `Settings.pinnedSessionIds`, which the pin glyph on every row already
  /// writes. See [PinnedRule].
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

/// Whether any section is open, and therefore whether a section has rows on
/// screen.
///
/// The gate the scale claim rests on. With [Settings.hideEmptySections] off,
/// everything below this line — the candidate sweep, the fact table, the
/// assignment — is `autoDispose` and reachable only from an expanded section's
/// body, so a sidebar whose sections are all folded shut runs none of it. It is
/// the same bargain the Explorer already makes with a collapsed project, and
/// `explorer_panel_scale_test.dart` holds it to the same standard.
///
/// With the filter on, [explorerSectionLayoutProvider] mounts that graph to ask
/// which sections are empty — and this is then what keeps the *heartbeat* out
/// of it. See [explorerSectionFactsProvider]: matching to draw rows refreshes
/// on the delivery poll; matching to decide whether a folded header is worth a
/// row does not.
final anySectionExpandedProvider = Provider<bool>(
  (ref) => ref.watch(
    explorerSectionsProvider.select(
      (sections) => sections.any((section) => !section.collapsed),
    ),
  ),
);

/// One session, reduced to the facts that cannot change without the session
/// *list* changing.
///
/// Everything volatile — the branch, the pull request, whether an agent is
/// waiting — is read elsewhere, from caches, and folded in by
/// [explorerSectionFactsProvider]. This is the half that legitimately comes
/// from the database, and it is read once per change to the list rather than
/// once per section, once per row or once per frame.
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

  /// The workspace row itself, carried rather than looked up again.
  ///
  /// The sweep below reads every session anyway; handing the object on costs
  /// nothing, and the alternative — the sidebar re-reading a row by id to draw
  /// it — would be exactly the per-item database read this feature is not
  /// allowed to make. `SessionLocation` carries them for the same reason.
  final Session? native;
  final ImportedSession? imported;

  final SessionStatus? status;
  final bool archived;

  /// The project this session's repository belongs to, for the rows that draw
  /// a cross-project list and therefore have to say *where*.
  final String? projectId;

  /// Where the session's repository is, when the workspace still has a row for
  /// it. Null means the repository was retired under the session, which is a
  /// session with nothing to say about a branch rather than an error.
  final EnvironmentPath? repositoryPath;

  /// The worktree the session works in, when it has one.
  final EnvironmentPath? worktree;

  bool get isImported => imported != null;

  /// The directory whose pull request describes this session — the same
  /// spelling `sessionDeliveryProvider` uses, so the two land on the same
  /// family entry and share one `gh` answer rather than starting a second.
  EnvironmentPath? get directory => worktree ?? repositoryPath;
}

/// Every session in the workspace, in the terms a rule can be applied to.
///
/// **Three statements, on change only.** Exactly the shape
/// `sessionProjectIdsProvider` already has, and narrowed to the same concerns:
/// a row appearing, going away, moving or changing status can change what is
/// in a section; a permission mode cannot. `title` is on the list because a
/// section draws the row's name.
///
/// It is `autoDispose` and nothing reaches it while every section is
/// collapsed, so the three statements are not merely rare — on a sidebar
/// nobody has opened they never run at all.
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

/// Every session, with everything a rule may ask about it — **read, never
/// measured**.
///
/// This is the provider the whole feature's cost claim lives in, so what it is
/// allowed to do is worth stating flatly: it may look in caches other surfaces
/// filled, and it may not fill one. The three volatile facts and where each
/// comes from:
///
/// * **the branch, and how far the work has travelled** — from
///   `checkoutDeliveryProvider` / `worktreeDeliveryProvider`, guarded by
///   `ref.exists`. That guard is not a nicety. `ref.watch` on an `autoDispose`
///   family does not *read* a provider, it **creates** one — which is how
///   `projectSummaryProvider` once ran 345 git subprocesses to draw a header
///   nobody had expanded. A section over five hundred sessions would have been
///   the same mistake at three times the size.
/// * **the pull request and its checks** — from `checkoutPullRequestProvider`
///   under the same guard, and from `deliveryAttentionProvider`, which is the
///   last full reading the delivery strip took and is already in memory. Keyed
///   by *checkout*, so twenty sessions in one repository read one answer.
/// * **whether an agent is waiting** — from `sessionAttentionProvider`, the
///   ambient waiting list the one status watcher publishes. Not the attention
///   inbox: the inbox retires an item when its session is looked at, and a
///   group you can empty by glancing at it is not a work list.
///
/// **What that honestly costs the user.** A section can only report what the
/// app has already had reason to measure. A pull request nobody has opened the
/// strip for has not been fetched, so its session sits outside "Checks
/// failing" until something asks — the same limit `DeliveryAttentionController`
/// states for delivery news, for the same reason, and the alternative is a
/// second `gh` poller running over every row in the workspace. The sidebar
/// says what is known; it never goes and finds out. It is the same bargain
/// `projectSummaryProvider` struck when it stopped starting 345 git
/// subprocesses to fill in a header nobody had expanded, and it is stated here
/// in the same words because it is the same trade.
///
/// **And the one place that bargain has an edge.** `ref.exists` is a question,
/// not a subscription: a checkout measured *after* this provider was built is
/// invisible to it until something rebuilds it. So a section with rows on
/// screen also watches [deliveryPollProvider] — the app's existing delivery
/// heartbeat, one timer for the whole app, two minutes while the window has
/// focus and a bump when focus comes back. Not a timer of this feature's own,
/// and the right cadence by construction: it is exactly how often the facts
/// underneath a section can change at all.
///
/// **Only for a section with rows on screen**, though, and that gate matters
/// now that [explorerSectionLayoutProvider] reaches this to ask whether a
/// *folded* section is empty. Merely having the Explorer open must not start
/// the app's delivery heartbeat — it never has, and a widget test that pumps
/// the panel would be left holding a two-minute periodic timer. Emptiness
/// stays fresh without it: [deliveryAttentionProvider] is a notifier that every
/// delivery strip writes its reading into (see `sessionDeliveryProvider`), so
/// a checkout going red wakes this whether or not the heartbeat is running.
/// What the folded case gives up is the re-read of a `_warm` entry that
/// changed with nothing to announce it — a staler answer to "is this empty",
/// corrected the moment anything else moves.
final explorerSectionFactsProvider = Provider.autoDispose<List<SectionFacts>>((
  ref,
) {
  if (ref.watch(anySectionExpandedProvider)) ref.watch(deliveryPollProvider);
  final candidates = ref.watch(sectionCandidatesProvider);
  // One read of each ambient map, outside the loop: these are whole-app state,
  // not per-session state, and reading them per candidate would turn a fold
  // into a quadratic one.
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
  // The strip's own last reading first: it is the only source that carries the
  // pull request *and* the branch together, so where it exists there is nothing
  // to reconcile.
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
    // The stage only when a reading exists. `SessionDelivery.unknown.stage`
    // answers `working` for everything, and a section drawn from that would
    // claim a fact about every unopened session in the workspace.
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
  // these are two different family entries. Asking the wrong one would file
  // every worktree session under the repository's branch, which on a workspace
  // built out of `wt-*` folders is every session in it.
  if (worktree != null) {
    return _warm(
          ref,
          worktreeDeliveryProvider((repo: repository, worktree: worktree)),
        ) ??
        _warm(ref, checkoutDeliveryProvider(Checkout(worktree)));
  }
  return _warm(ref, checkoutDeliveryProvider(Checkout(repository)));
}

/// The value [provider] already holds, or null when nothing has mounted it.
///
/// `ref.exists` before `ref.watch`, always: watching creates. And `.value`
/// rather than `.asData?.value`, for the reason `sessionDeliveryActionsProvider`
/// gives — a refresh is an `AsyncLoading` carrying the previous value, and
/// reading it as null would empty every section for as long as a `gh` call
/// takes.
T? _warm<T>(Ref ref, FutureProvider<T>? provider) {
  if (provider == null || !ref.exists(provider)) return null;
  return ref.watch(provider).value;
}

/// Which section claims each session, resolved once for the whole sidebar.
///
/// One pass, shared: every expanded section reads *this* and selects its own
/// list, because priority is a question about all the sections at once — you
/// cannot know whether "Checks failing" takes a row without knowing whether
/// Pinned took it first. Computing it per section would be that same pass once
/// per group.
///
/// `autoDispose`, and reached only from an expanded section's body: with the
/// sidebar folded shut this provider does not exist, [sectionCandidatesProvider]
/// does not exist, and no rule runs.
final explorerSectionAssignmentProvider =
    Provider.autoDispose<Map<String, List<SectionFacts>>>((ref) {
      final sections = ref.watch(explorerSectionsProvider);
      // The pin set is the built-in Pinned section's membership, selected
      // rather than watched whole so an unrelated settings change — a theme, a
      // pane width — does not re-file the sidebar. The `toSet()` is *outside*
      // the selector on purpose: `select` compares with `==`, a fresh
      // `LinkedHashSet` is never equal to the last one, and building it inside
      // would rebuild this on every settings write instead of none of them.
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

/// What one section holds right now.
///
/// Selected out of the shared assignment, so a section whose contents did not
/// move does not rebuild when a neighbour's did.
final explorerSectionMembersProvider = Provider.autoDispose
    .family<List<SectionFacts>, String>(
      (ref, sectionId) => ref.watch(
        explorerSectionAssignmentProvider.select(
          (assignment) => assignment[sectionId] ?? const <SectionFacts>[],
        ),
      ),
    );

/// **What the sidebar actually draws, and what it is holding back.**
///
/// A section that matches nothing still costs a full row, and a row that says
/// "Checks failing" beside no failing checks is the sidebar spending the user's
/// vertical space to tell them nothing. So an empty section folds away — and
/// [ExplorerSectionLayout.hidden] is what the header's filter toggle counts, so
/// the feature says out loud that it is holding something back rather than
/// vanishing silently.
///
/// **Only a *collapsed* empty section is hidden.** An open one is a section the
/// user is looking at, and [emptySectionMessage] is the answer to the question
/// they opened it to ask — "nothing matches" and "nothing has been measured
/// yet" are different situations, and a group that disappeared mid-glance would
/// answer neither.
class ExplorerSectionLayout {
  const ExplorerSectionLayout({required this.shown, required this.hidden});

  /// The sections to draw, in sidebar order.
  final List<ExplorerSection> shown;

  /// How many were folded away for being empty.
  final int hidden;

  /// Value equality, and it is the point of this class rather than a record:
  /// the assignment underneath is rebuilt on every delivery heartbeat, and a
  /// layout that was never equal to the last one would rebuild the whole
  /// Explorer every two minutes to draw the same sidebar.
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

/// Which sections survive the empty filter.
///
/// **The one place the cost of this filter is paid.** Asking whether a section
/// is empty *is* matching it — there is no cheaper question, which is why a
/// collapsed header has never shown a count — so with
/// [Settings.hideEmptySections] on, [explorerSectionAssignmentProvider] and the
/// graph under it are mounted for as long as the Explorer is on screen. What
/// that costs is pinned by `explorer_sections_cost_test.dart` and is the same
/// bill an open section already paid: three unfiltered sweeps on a change to
/// the session list, none per rebuild, and no subprocess ever.
///
/// With the setting **off** the provider never reads the assignment, so the
/// original bargain is intact and unchanged: a sidebar folded shut mounts none
/// of the matching graph.
///
/// `autoDispose`, so a workspace whose Explorer pane is closed pays nothing at
/// all.
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
