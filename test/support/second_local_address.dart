import 'dart:io';

/// A second address on this machine that a server can actually bind, distinct
/// from `127.0.0.1` — or `null` when the machine has none.
///
/// Several tests stand a *second* listener up to prove two-interface behaviour
/// (the WSL switch listener in `LauncherControlServer`) on a machine that has
/// no WSL. That needs a real second address on a real second socket, and the
/// obvious choice — `127.0.0.2` — is not portable:
///
/// | host | `bind(127.0.0.2)` |
/// | --- | --- |
/// | Windows | succeeds — the whole of `127.0.0.0/8` is local |
/// | Linux | succeeds — same |
/// | macOS | `errno 49, Can't assign requested address` |
///
/// macOS assigns only `127.0.0.1` to `lo0`; the rest of `127/8` is routed there
/// but not *assigned*, and binding an unassigned address fails. Adding an alias
/// needs `sudo ifconfig lo0 alias`, which a test suite has no business doing.
///
/// So the candidates are tried in order of preference and the first that binds
/// wins: `127.0.0.2`, then any other loopback alias the machine already has,
/// then a real LAN address. Callers skip when this is `null`.
Future<InternetAddress?> findSecondLocalAddress() async {
  if (_cached != null) return _cached;
  if (_resolved) return null;

  final candidates = <InternetAddress>[InternetAddress('127.0.0.2')];
  for (final interface in await NetworkInterface.list(
    type: InternetAddressType.IPv4,
    includeLoopback: true,
  )) {
    for (final address in interface.addresses) {
      if (address.address == '127.0.0.1') continue;
      candidates.add(address);
    }
  }

  for (final candidate in candidates) {
    if (await _canBind(candidate)) {
      _resolved = true;
      return _cached = candidate;
    }
  }
  _resolved = true;
  return null;
}

InternetAddress? _cached;
bool _resolved = false;

Future<bool> _canBind(InternetAddress address) async {
  try {
    final server = await HttpServer.bind(address, 0);
    await server.close(force: true);
    return true;
  } on SocketException {
    return false;
  }
}

/// Why a suite skipped itself, phrased for whoever reads the run.
const String noSecondAddressReason =
    'This machine has no second bindable IPv4 address (macOS assigns only '
    '127.0.0.1 to lo0, and no other interface is up), so the two-interface '
    'listener cannot be stood up here.';
