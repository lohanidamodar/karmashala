// The terminal link, the docked marker and the dock's bounded column.
part of '../approval_request_card.dart';

class _TerminalLink extends ConsumerWidget {
  const _TerminalLink({required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      !_hasTerminal(ref, sessionId)
      ? const SizedBox.shrink()
      // Docked, the dock's own quiet "Answer in the terminal" (board N1).
      : _Docked.of(context)
      ? Align(
          alignment: AlignmentDirectional.centerEnd,
          child: _AnswerInTerminal(sessionId: sessionId),
        )
      : TextButton.icon(
          onPressed: () => _openTerminal(ref, sessionId),
          icon: const Icon(AppIcons.terminal, size: Chrome.iconSmall),
          label: const Text('Terminal view'),
        );
}

/// Marks a card docked under its terminal (see [ApprovalRequestCard.docked]).
class _Docked extends InheritedWidget {
  const _Docked({required super.child, this.touch = false});

  /// See [ApprovalRequestCard.touch].
  final bool touch;

  static bool of(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_Docked>() != null;

  static bool touchOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_Docked>()?.touch ?? false;

  @override
  bool updateShouldNotify(_Docked oldWidget) => touch != oldWidget.touch;
}

/// The most of the page's height the dock takes on a phone before it scrolls.
const double _touchDockShare = 0.55;

/// Below this a bounded dock would hold its answers and nothing else.
const double _minBoundedDock = 200;

/// A column whose child at [flexible] takes only the room the rest leave it
/// when the column is held to a height, and is laid out plainly otherwise.
class _FlexColumn extends StatelessWidget {
  const _FlexColumn({
    required this.children,
    required this.flexible,
    this.crossAxisAlignment = CrossAxisAlignment.start,
  });

  final List<Widget> children;
  final int flexible;
  final CrossAxisAlignment crossAxisAlignment;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) => Column(
      crossAxisAlignment: crossAxisAlignment,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < children.length; i++)
          i == flexible && box.hasBoundedHeight
              ? Flexible(child: children[i])
              : children[i],
      ],
    ),
  );
}

/// On the phone, a word that an answer landed — the companion's "Approved." —
/// because a dock that simply vanishes reads as a dropped tap. Null elsewhere,
/// where the agent's own screen is the acknowledgement. Read before the await.
class _AnswerSaid {
  const _AnswerSaid(this._messenger);

  final ScaffoldMessengerState _messenger;

  static _AnswerSaid? of(BuildContext context) {
    if (!_Docked.touchOf(context)) return null;
    final messenger = ScaffoldMessenger.maybeOf(context);
    return messenger == null ? null : _AnswerSaid(messenger);
  }

  void say(String words) => _messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(content: Text(words), duration: const Duration(seconds: 2)),
    );
}
