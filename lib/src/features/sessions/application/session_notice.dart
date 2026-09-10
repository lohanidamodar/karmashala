import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Something to tell the user about **one** session. A snackbar is app chrome —
/// it covers the bottom of the window whichever session it is about — and most
/// of what these messages report is true of exactly one session and false of
/// every other one open, so it belongs in that session's own bar, beside the
/// control the user just used.
@immutable
class SessionNotice {
  const SessionNotice({
    required this.message,
    this.action,
    this.tone = SessionNoticeTone.neutral,
  });

  final String message;

  /// The one thing the message offers to do, if it offers anything.
  final SessionNoticeAction? action;

  final SessionNoticeTone tone;
}

/// A labelled callback, held in state rather than expressed as an enum the bar
/// interprets: the bar's job is to draw a message it did not write.
@immutable
class SessionNoticeAction {
  const SessionNoticeAction({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;
}

enum SessionNoticeTone { neutral, warning }

/// How long a notice stays on screen before clearing itself. Longer than a
/// snackbar's four seconds because it covers nothing and can be read twice;
/// short enough that a stale "applies the next time this session is launched"
/// is not still sitting there minutes later. Counted by the bar, not here: a
/// clock running against an unwatched notice would throw it away before it was
/// shown.
const sessionNoticeLifetime = Duration(seconds: 20);

/// Every session's current notice, keyed by session id. One notifier over a map
/// rather than a family, because the poster and the reader are not the same
/// widget and need not overlap in time: the chip posts through `ref.read` and
/// may be rebuilt for another session immediately, which would dispose an
/// auto-disposing family entry before its bar ever watched it.
class SessionNotices extends Notifier<Map<String, SessionNotice>> {
  @override
  Map<String, SessionNotice> build() => const {};

  /// Shows [notice] for [sessionId], replacing whatever that session was
  /// showing: these messages describe the session's current state, so the
  /// newest is the only true one.
  void post(String sessionId, SessionNotice notice) =>
      state = {...state, sessionId: notice};

  /// Takes a notice down, however it went — dismissed, taken up, or timed out.
  /// There is nothing to remember about a message that is gone.
  void dismiss(String sessionId) {
    if (!state.containsKey(sessionId)) return;
    state = {...state}..remove(sessionId);
  }
}

final sessionNoticesProvider =
    NotifierProvider<SessionNotices, Map<String, SessionNotice>>(
      SessionNotices.new,
    );

/// What one session has to say, or null. Separate from the map so a bar
/// rebuilds only when *its* session's notice changes, not when any other
/// session posts.
final sessionNoticeProvider = Provider.family<SessionNotice?, String>(
  (ref, sessionId) =>
      ref.watch(sessionNoticesProvider.select((all) => all[sessionId])),
);
