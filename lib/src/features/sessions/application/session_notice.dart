import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Something to tell the user about **one** session.
///
/// The distinction from a snackbar is the whole point. A snackbar is app
/// chrome: it covers the status bar across the bottom of the window no matter
/// which session it is about, and it says nothing about which one that is. Most
/// of what these messages report — a permission mode that applies on the next
/// launch, a restart that failed — is true of exactly one session and false of
/// every other one open at the same time, so it belongs in that session's own
/// bar, beside the control the user just used.
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

/// A labelled callback. Held in state rather than expressed as an enum the bar
/// interprets, so the work stays in the control that knows how to do it: the
/// bar's job is to draw a message it did not write.
@immutable
class SessionNoticeAction {
  const SessionNoticeAction({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;
}

enum SessionNoticeTone { neutral, warning }

/// How long a notice stays on screen before clearing itself.
///
/// Longer than a snackbar's four seconds because this one is not covering
/// anything and can afford to be read twice — and because the messages that
/// carry an action ask the user to weigh a cost before taking it. Short enough
/// that a stale "applies the next time this session is launched" cannot still
/// be sitting there minutes later, describing a decision the user has since
/// changed.
///
/// Counted by the bar, not here: a notice posted for a session nobody is
/// looking at has not been read yet, and a clock running against an unwatched
/// message would throw it away before it was ever shown.
const sessionNoticeLifetime = Duration(seconds: 20);

/// Every session's current notice, keyed by session id.
///
/// One notifier over a map rather than a family, because the poster and the
/// reader are not the same widget and need not overlap in time: the chip posts
/// through `ref.read` and may be rebuilt for another session immediately after,
/// which would dispose an auto-disposing family entry before its bar ever
/// watched it. Entries clear themselves on the timer, so the map empties.
class SessionNotices extends Notifier<Map<String, SessionNotice>> {
  @override
  Map<String, SessionNotice> build() => const {};

  /// Shows [notice] for [sessionId], replacing whatever that session was
  /// showing. Replacing rather than queueing: these messages describe the
  /// session's current state, so the newest is the only true one.
  void post(String sessionId, SessionNotice notice) =>
      state = {...state, sessionId: notice};

  /// Takes a notice down, whether the user dismissed it, took its offer, or
  /// left it up long enough. Identical in all three cases on purpose — there is
  /// nothing to remember about a message that is gone.
  void dismiss(String sessionId) {
    if (!state.containsKey(sessionId)) return;
    state = {...state}..remove(sessionId);
  }
}

final sessionNoticesProvider =
    NotifierProvider<SessionNotices, Map<String, SessionNotice>>(
      SessionNotices.new,
    );

/// What one session has to say, or null. Separate from the map so a bar rebuilds
/// only when *its* session's notice changes, not when any other session posts.
final sessionNoticeProvider = Provider.family<SessionNotice?, String>(
  (ref, sessionId) =>
      ref.watch(sessionNoticesProvider.select((all) => all[sessionId])),
);
