/// An ACP agent asked to be logged in before a session, and no remembered or
/// sole method could do it. The data channel refuses it `loginRequired`, so a
/// client can offer the agent's login.
class AcpLoginRequired extends StateError {
  AcpLoginRequired(super.message);

  @override
  String toString() => message;
}
