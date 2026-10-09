import 'package:agent_cli/descriptors.dart';
import 'package:flutter/foundation.dart' show immutable;
import 'package:riverpod/riverpod.dart';

/// The sessions picked on the dashboard to answer together, and the one the
/// last plain pick was on, which a Shift-click extends from.
@immutable
class OverviewSelection {
  const OverviewSelection({this.ids = const {}, this.anchor});

  final Set<String> ids;
  final String? anchor;

  bool get isEmpty => ids.isEmpty;

  bool contains(String id) => ids.contains(id);

  @override
  bool operator ==(Object other) =>
      other is OverviewSelection &&
      other.anchor == anchor &&
      other.ids.length == ids.length &&
      other.ids.containsAll(ids);

  @override
  int get hashCode => Object.hash(anchor, Object.hashAllUnordered(ids));
}

class OverviewSelectionController extends Notifier<OverviewSelection> {
  @override
  OverviewSelection build() => const OverviewSelection();

  void toggle(String id) {
    final ids = {...state.ids};
    if (!ids.remove(id)) ids.add(id);
    state = OverviewSelection(ids: ids, anchor: id);
  }

  /// Adds every session from the anchor to [id], as [order] draws them.
  void extendTo(String id, List<String> order) {
    final from = order.indexOf(state.anchor ?? '');
    final to = order.indexOf(id);
    if (from < 0 || to < 0) return toggle(id);
    final (start, end) = from <= to ? (from, to) : (to, from);
    state = OverviewSelection(
      ids: {...state.ids, ...order.sublist(start, end + 1)},
      anchor: state.anchor,
    );
  }

  /// Picks every one of [ids] too: Ctrl+A in a lane.
  void selectAll(Iterable<String> ids) {
    if (ids.isEmpty) return;
    state = OverviewSelection(
      ids: {...state.ids, ...ids},
      anchor: state.anchor ?? ids.first,
    );
  }

  void clear() => state = const OverviewSelection();
}

final overviewSelectionProvider =
    NotifierProvider.autoDispose<
      OverviewSelectionController,
      OverviewSelection
    >(OverviewSelectionController.new);

/// A command approval as a batch compares it: the tool, the exact command
/// and the folder it would run in.
@immutable
class BatchApproval {
  const BatchApproval({
    required this.toolName,
    required this.subject,
    required this.folder,
  });

  final String toolName;
  final String subject;
  final String folder;

  @override
  bool operator ==(Object other) =>
      other is BatchApproval &&
      other.toolName == toolName &&
      other.subject == subject &&
      other.folder == folder;

  @override
  int get hashCode => Object.hash(toolName, subject, folder);
}

/// The approval [report] holds open, read for batching; null when it holds
/// none, or one whose command or folder nothing named.
BatchApproval? batchApprovalOf(AgentStatusReport? report, {String? folder}) {
  if (report == null || !report.hasOpenPrompt) return null;
  final ask = report.toolAsk;
  if (ask == null) return null;
  final subject = summarizeToolAsk(ask).subject;
  final where = ask.cwd ?? folder;
  if (subject.isEmpty || where == null || where.isEmpty) return null;
  return BatchApproval(toolName: ask.toolName, subject: subject, folder: where);
}

/// The one approval every one of [ids] waits on, or null. Approvals that
/// differ in command or folder are never answered together.
BatchApproval? sharedBatchApproval(
  Iterable<String> ids, {
  required AgentStatusReport? Function(String id) statusOf,
  String? Function(String id)? folderOf,
}) {
  BatchApproval? shared;
  for (final id in ids) {
    final approval = batchApprovalOf(statusOf(id), folder: folderOf?.call(id));
    if (approval == null) return null;
    if (shared != null && shared != approval) return null;
    shared = approval;
  }
  return shared;
}
