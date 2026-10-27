import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/util/clock_provider.dart';
import '../../explorer/application/workspace_session_entry.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_signals.dart';
import '../../workspaces/data/workspace_data.dart';
import 'overview_board.dart';
import 'overview_providers.dart';

/// The dashboard's waiting drawer: whether it is open, and the one family
/// it is narrowed to.
@immutable
class OverviewDrawer {
  const OverviewDrawer({this.open = false, this.family});

  final bool open;

  /// The root whose family's asks it lists; null lists every ask.
  final String? family;

  @override
  bool operator ==(Object other) =>
      other is OverviewDrawer && other.open == open && other.family == family;

  @override
  int get hashCode => Object.hash(open, family);
}

class OverviewDrawerController extends Notifier<OverviewDrawer> {
  @override
  OverviewDrawer build() => const OverviewDrawer();

  /// Opens it on every ask, or on [family]'s alone.
  void open({String? family}) =>
      state = OverviewDrawer(open: true, family: family);

  /// Lifts the family filter.
  void showAll() => state = OverviewDrawer(open: state.open);

  void close() => state = const OverviewDrawer();

  void toggle() => state.open ? close() : open();
}

final overviewDrawerProvider =
    NotifierProvider<OverviewDrawerController, OverviewDrawer>(
      OverviewDrawerController.new,
    );

/// Whether the phone's search sheet is open over the board.
class OverviewSearchSheetController extends Notifier<bool> {
  @override
  bool build() => false;

  void open() => state = true;

  void close() => state = false;
}

final overviewSearchSheetProvider =
    NotifierProvider<OverviewSearchSheetController, bool>(
      OverviewSearchSheetController.new,
    );

/// What the strip's New and Pinned light up: the rest dims, nothing hides.
enum OverviewHighlight { none, fresh, pinned }

class OverviewHighlightController extends Notifier<OverviewHighlight> {
  @override
  OverviewHighlight build() => OverviewHighlight.none;

  /// Lights [highlight], or puts it out when it is already lit.
  void toggle(OverviewHighlight highlight) =>
      state = state == highlight ? OverviewHighlight.none : highlight;
}

final overviewHighlightProvider =
    NotifierProvider<OverviewHighlightController, OverviewHighlight>(
      OverviewHighlightController.new,
    );

/// Whether the strip's More is unfolded: the heartbeat, glances and the
/// waiting and pipeline lanes under it.
class OverviewMoreController extends Notifier<bool> {
  @override
  bool build() => false;

  void toggle() => state = !state;
}

final overviewMoreProvider = NotifierProvider<OverviewMoreController, bool>(
  OverviewMoreController.new,
);

/// The titles of the sessions archived today, by the key of the lane each
/// was filed in.
final overviewArchivedTodayProvider =
    Provider.autoDispose<Map<String, List<String>>>((ref) {
      ref.watchSessionKinds(const {
        SessionChangeKind.membership,
        SessionChangeKind.title,
        SessionChangeKind.status,
        SessionChangeKind.placement,
        SessionChangeKind.workspace,
      });
      final facts = ref.watch(overviewFactsProvider);
      final groupBy = ref.watch(overviewGroupByProvider);
      final repositories = {
        for (final repository in ref.read(workspaceDataProvider).repositories)
          repository.id: repository,
      };
      final now = ref.read(clockProvider).nowUtc().toLocal();
      final start = DateTime(now.year, now.month, now.day).toUtc();
      final byLane = <String, List<String>>{};
      for (final session in ref.read(sessionsDataProvider).getAll()) {
        final at = session.archivedAt;
        if (at == null || at.isBefore(start)) continue;
        final entry = WorkspaceSessionEntry(
          id: session.id,
          title: session.title,
          createdAt: session.createdAt,
          directory:
              session.worktree ?? repositories[session.repositoryId]?.path,
          native: session,
        );
        (byLane[overviewLaneKeyOf(entry, facts, groupBy)] ??= []).add(
          session.title,
        );
      }
      return byLane;
    });
