part of 'terminal_sessions_controller.dart';

/// The longest an [TerminalBesidePlacement.openBeside] request waits for its
/// tab. A session resume is the slow case — the tab appears only once the host
/// has answered — and a request left armed any longer would catch a tab the
/// user brought forward for some other reason.
const Duration kBesideRequestLifetime = Duration(seconds: 5);

/// "The next tab brought to the front goes beside group [groupId]" — what
/// quick open's Ctrl+Enter asks for, held until a tab answers it or it expires.
class _BesideRequest {
  _BesideRequest({
    required this.groupId,
    required this.activeBefore,
    required this.expiresAt,
  });

  /// The group the keyboard was in when it was asked: the one to split.
  final String groupId;

  /// The tab in front when it was asked; another one coming forward is what
  /// answers the request, and this one stays in front of [groupId].
  final String? activeBefore;

  /// On the controller's own monotonic clock.
  final Duration expiresAt;
}

/// **Opening to the side**: one request any open verb honours, rather than a
/// `beside:` flag threaded through every one of them. The verbs differ —
/// a document tab, a resumed session, a terminal, a tab already open
/// elsewhere — but all of them end by bringing a tab to the front and
/// publishing, and that is the one place this looks.
extension TerminalBesidePlacement on TerminalSessionsController {
  /// Runs [open] with a beside request armed, and disarms it when [open] —
  /// and the future it returns, if any — has finished. A tab [open] brings to
  /// the front of the focused group, among others, is moved into a new group
  /// split off to the right of it. A tab already in another group is only
  /// revealed there; one that would leave the focused group empty, or a group
  /// too small to halve, opens as it would have anyway.
  void openBeside(FutureOr<void> Function() open) {
    final request = _armBeside();
    if (request == null) {
      open();
      return;
    }
    void settle() {
      if (identical(_beside, request)) _beside = null;
    }

    final FutureOr<void> opened;
    try {
      opened = open();
    } catch (_) {
      settle();
      rethrow;
    }
    if (opened is Future<void>) {
      // An error still reaches the zone, as it did before anything waited on it.
      unawaited(opened.whenComplete(settle));
    } else {
      settle();
    }
  }

  /// Whether a beside request is armed and unexpired.
  @visibleForTesting
  bool get besideRequested {
    final request = _beside;
    return request != null && _uptime.elapsed <= request.expiresAt;
  }

  /// Arms a request against the focused group, or null when there is nothing to
  /// be beside: no group yet, or only the empty room a split left, which an
  /// opened tab fills where it is.
  _BesideRequest? _armBeside() {
    final group = _focusedGroup;
    if (group == null || _isEmptyGroup(group)) {
      _beside = null;
      return null;
    }
    return _beside = _BesideRequest(
      groupId: group.id,
      activeBefore: _activeTabId,
      expiresAt: _uptime.elapsed + kBesideRequestLifetime,
    );
  }

  /// [activateTab] on the tab already in front: nothing publishes, so the
  /// request is answered here — the tab the user asked for is the one in front.
  void _besideOnActiveTab() {
    if (_beside == null || !_placeBesideIfRequested(alreadyInFront: true)) {
      return;
    }
    _publish();
    persistStructure();
    _focusActivePane();
  }

  /// Answers the armed request, if a tab has come forward since: called from
  /// [_publish] once the tree holds every tab. True when the tree changed.
  ///
  /// The first tab to come forward **consumes** the request whatever happens
  /// to it, so one Ctrl+Enter can never move two tabs.
  bool _placeBesideIfRequested({bool alreadyInFront = false}) {
    final request = _beside;
    if (request == null) return false;
    if (_uptime.elapsed > request.expiresAt) {
      _beside = null;
      return false;
    }
    final active = _activeTabId;
    if (active == null) return false;
    if (!alreadyInFront && active == request.activeBefore) return false;
    _beside = null;

    final tree = _workspace;
    final group = tree?.groupOf(active);
    // Already in another group: VS Code reveals it there, and so does this.
    if (tree == null || group == null || group.id != request.groupId) {
      return false;
    }
    // Alone in its group: moving it would leave the room it came from empty.
    if (group.panes.length < 2) return false;
    if (!groupHasRoomToSplit(tree, active, SplitAxis.horizontal)) return false;

    final without = tree.close(active);
    if (without == null) return false;
    // What the group showed before stays in front of it.
    final stay = request.activeBefore;
    final kept =
        stay != null &&
            stay != active &&
            without.groupOf(stay)?.id == request.groupId
        ? without.activate(stay)
        : without;
    final anchor = kept.groupById(request.groupId)?.activePaneId;
    if (anchor == null) return false;
    _workspace = kept.splitWithNode(
      anchor,
      SplitAxis.horizontal,
      PaneGroup(_newId(), panes: [active]),
      _newId(),
    );
    return true;
  }
}
