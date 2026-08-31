/// Which relay the remote-access host uses.
enum RelayMode {
  /// The embedded relay this computer runs itself, reachable over the local
  /// network — one click, no server of your own.
  local,

  /// A relay on the internet: the PopupBits default, or a self-hosted URL.
  hosted,
}
