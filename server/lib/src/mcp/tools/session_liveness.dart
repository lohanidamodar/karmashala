import 'package:karmashala_session/session.dart';

/// Whether an agent is running in a session right now, as the server can
/// tell: a session it runs itself ([runs], its registry), or a row whose
/// recorded status says so — which is how a session in one of the app's own
/// panes is known here. A row that claims too much is reconciled to
/// `unknown` elsewhere; claiming too little would let work be destroyed.
class SessionLiveness {
  const SessionLiveness(this._runs);

  /// Every session is idle: nothing runs here, and a row's status decides.
  static bool _none(String _) => false;

  /// Liveness from the rows alone.
  static const rowsOnly = SessionLiveness(_none);

  final bool Function(String sessionId) _runs;

  bool isLive(Session session) =>
      _runs(session.id) || session.status.claimsLive;
}
