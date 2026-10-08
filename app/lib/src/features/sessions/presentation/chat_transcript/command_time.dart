part of '../chat_transcript.dart';

/// The instant running commands count up to: one per transcript, moved by its
/// one timer while a command runs and the list is on screen.
class _CommandClock extends ChangeNotifier
    implements ValueListenable<DateTime> {
  _CommandClock(this._value);

  DateTime _value;

  @override
  DateTime get value => _value;

  /// Moves the clock without telling anyone: for a build, whose rows read it
  /// as they draw.
  set quietly(DateTime now) => _value = now;

  void tick(DateTime now) {
    _value = now;
    notifyListeners();
  }
}

class _CommandClockScope extends InheritedWidget {
  const _CommandClockScope({required this.clock, required super.child});

  final ValueListenable<DateTime> clock;

  static ValueListenable<DateTime>? of(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_CommandClockScope>()?.clock;

  @override
  bool updateShouldNotify(_CommandClockScope oldWidget) =>
      oldWidget.clock != clock;
}

/// A command's time beside its status: how long it took, or, while it runs,
/// how long so far. Nothing where neither end was recorded.
class _CommandTime extends StatelessWidget {
  const _CommandTime({required this.message, this.style, this.lead = ''});

  final ChatMessage message;
  final TextStyle? style;

  /// Put before the time, so a missing time leaves no stray separator.
  final String lead;

  Widget _text(String text, Key key) =>
      Text('$lead$text', key: key, maxLines: 1, softWrap: false, style: style);

  @override
  Widget build(BuildContext context) {
    if (!isCommandCall(message)) return const SizedBox.shrink();
    if (commandDuration(message) case final took?) {
      return _text(
        formatCommandDuration(took),
        const ValueKey('command-duration'),
      );
    }
    final start = message.at;
    final clock = _CommandClockScope.of(context);
    if (!message.pending || start == null || clock == null) {
      return const SizedBox.shrink();
    }
    return ValueListenableBuilder<DateTime>(
      valueListenable: clock,
      builder: (context, now, _) {
        final so = now.difference(start);
        return _text(
          formatElapsed(so.isNegative ? Duration.zero : so),
          const ValueKey('command-running-time'),
        );
      },
    );
  }
}
