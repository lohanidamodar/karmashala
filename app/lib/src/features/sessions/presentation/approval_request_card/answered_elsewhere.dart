part of '../approval_request_card.dart';

/// A phone's dock once its ask closed without this phone: "Answered
/// elsewhere" where the dock was, for [kAnsweredElsewhereShown], then
/// nothing. This phone's own answers keep their "Allowed.", and an ask the
/// session's ending closed says nothing ([askAnsweredElsewhereProvider]).
class _AnsweredElsewhere extends ConsumerStatefulWidget {
  const _AnsweredElsewhere({
    required this.sessionId,
    required this.asking,
    required this.child,
  });

  final String sessionId;

  /// The ask the dock shows, or null while it shows none.
  final AgentStatusReport? asking;
  final Widget child;

  @override
  ConsumerState<_AnsweredElsewhere> createState() =>
      _AnsweredElsewhereState();
}

class _AnsweredElsewhereState extends ConsumerState<_AnsweredElsewhere> {
  /// When this phone first showed the open ask, on its own clock: an answer
  /// it sent after that is its own.
  DateTime? _shownAt;
  DateTime? _waitingSince;
  String? _said;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _track(widget.asking);
  }

  @override
  void didUpdateWidget(_AnsweredElsewhere old) {
    super.didUpdateWidget(old);
    if (old.sessionId != widget.sessionId) {
      _timer?.cancel();
      _said = null;
      _shownAt = null;
      _track(widget.asking);
      return;
    }
    final asking = widget.asking;
    if (asking != null) {
      // The next ask takes the line's place.
      _timer?.cancel();
      _said = null;
      _track(asking);
    } else if (old.asking case final was?) {
      _closed(was);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _track(AgentStatusReport? asking) {
    if (asking == null) return;
    final since = asking.waitingSince;
    if (_shownAt == null ||
        since?.millisecondsSinceEpoch != _waitingSince?.millisecondsSinceEpoch) {
      _shownAt = ref.read(clockProvider).nowUtc();
      _waitingSince = since;
    }
  }

  void _closed(AgentStatusReport was) {
    final shownAt = _shownAt ?? ref.read(clockProvider).nowUtc();
    _shownAt = null;
    _waitingSince = null;
    _timer?.cancel();
    _timer = Timer(kAskClosingSettle, () {
      if (!mounted || widget.asking != null) return;
      final said = ref.read(askAnsweredElsewhereProvider)(
        widget.sessionId,
        shownAt: shownAt,
        waitingSince: was.waitingSince,
      );
      if (said == null) return;
      setState(() => _said = said);
      _timer = Timer(kAnsweredElsewhereShown, () {
        if (mounted) setState(() => _said = null);
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final said = _said;
    if (widget.asking != null || said == null) return widget.child;
    final theme = Theme.of(context);
    return Semantics(
      liveRegion: true,
      child: ConstrainedBox(
        key: const ValueKey('dock-answered-elsewhere'),
        constraints: const BoxConstraints(minHeight: Touch.target),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Insets.md),
          child: Row(
            children: [
              Icon(
                AppIcons.checkCircle,
                size: Chrome.iconSmall,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: Insets.sm),
              Expanded(
                child: Text(
                  said,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: UiDensity.of(context).muted(theme),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
