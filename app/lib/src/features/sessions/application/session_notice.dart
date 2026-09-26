import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Something to tell the user about **one** session — a snackbar is app chrome
/// and says nothing about which session it is about; this sits in that bar.
@immutable
class SessionNotice {
  const SessionNotice({
    required this.message,
    this.action,
    this.secondaryAction,
    this.tone = SessionNoticeTone.neutral,
    this.sticky = false,
  });

  final String message;

  /// The one thing the message offers to do, if it offers anything.
  final SessionNoticeAction? action;

  /// The way into the same offer's options, drawn after [action].
  final SessionNoticeAction? secondaryAction;

  /// Stays until dismissed or taken up: it describes something still true,
  /// and the person it is for may be away for hours.
  final bool sticky;

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

/// How long a notice stays on screen. Counted by the bar, not here: a clock
/// against an unwatched notice would throw it away before it was read.
const sessionNoticeLifetime = Duration(seconds: 20);

/// Every session's current notice, keyed by session id. A map, not a family:
/// the poster may be rebuilt before the reader's bar ever watches its entry.
class SessionNotices extends Notifier<Map<String, SessionNotice>> {
  @override
  Map<String, SessionNotice> build() => const {};

  /// Shows [notice] for [sessionId], replacing what that session was showing:
  /// these describe current state, so the newest is the only true one.
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

/// What one session has to say, or null — separate from the map so a bar
/// rebuilds only when *its* session's notice changes.
final sessionNoticeProvider = Provider.family<SessionNotice?, String>(
  (ref, sessionId) =>
      ref.watch(sessionNoticesProvider.select((all) => all[sessionId])),
);
