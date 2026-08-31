import 'dart:io';

/// One host network adapter, reduced to what choosing between them needs.
///
/// A record rather than a [NetworkInterface] because the class cannot be
/// constructed, so the choice below would otherwise only be testable on a
/// machine that happens to have the adapter.
typedef HostInterface = ({String name, List<InternetAddress> addresses});

/// The alias Windows gives the WSL2 virtual switch, lower-cased, as a prefix.
///
/// A prefix and not an equality test because the name has a second bracket on
/// current Windows 11 builds — `vEthernet (WSL (Hyper-V firewall))` — and had
/// none before that. Matching the whole string would silently stop finding it
/// the next time Microsoft renames the adapter, and silently is the failure
/// mode that matters here: nothing breaks, agents simply stop being told the
/// tools exist.
///
/// It is deliberately narrow at the other end too. `vEthernet (Default Switch)`
/// is the Hyper-V switch ordinary virtual machines sit on, and a server bound
/// there would be reachable by guests this app has no relationship with.
const String _wslAdapterPrefix = 'vethernet (wsl';

/// The address a process **inside a WSL2 distribution** can dial to reach a
/// server on this Windows host, or `null` when this machine has no such switch.
///
/// ## Why an address at all, when the server is already on loopback
///
/// A WSL2 distribution is a separate Linux VM with its own network namespace,
/// so `127.0.0.1` inside it is the *distribution's* loopback and not the
/// host's. Windows forwards the other direction — a Windows process reaches a
/// WSL listener on `localhost` — but nothing forwards inbound, and a connection
/// from the distribution to `127.0.0.1:<port>` is refused outright. Measured on
/// this machine against a Dart `HttpServer`:
///
/// ```
/// $ curl http://127.0.0.1:49620/       # from WSL   → connection refused
/// $ curl http://172.18.240.1:49620/    # from WSL   → served
/// ```
///
/// The host side of the virtual switch — the distribution's default gateway —
/// is the address that does work, and it is what this returns.
///
/// ## Why this address and not `0.0.0.0`
///
/// Binding every interface would also work, and would put the app's entire
/// privileged tool surface on the LAN and on whatever VPN adapter is up. The
/// same measurement, with the same server bound three ways:
///
/// | bound to | from WSL | at the Wi-Fi address | at the VPN address |
/// | --- | --- | --- | --- |
/// | `127.0.0.1` | refused | — | — |
/// | `172.18.240.1` | **served** | refused | refused |
/// | `0.0.0.0` | served | **served** | **served** |
///
/// So this is the narrowest interface that reaches a WSL agent, and the set of
/// principals it adds is "a process in a WSL2 distribution on this machine" —
/// which is not wider than the boundary `LauncherControlServer`'s threat model
/// already accepts, since loopback TCP is reachable by every local process
/// regardless of user.
///
/// A machine with **no** such adapter gets `null`, not a loopback fallback.
/// Mirrored networking and WSL 1 both share the host's loopback and would in
/// fact work on `127.0.0.1`, but neither has been dialled from here, and an
/// unverified URL handed to every session is how an agent ends up reporting a
/// broken MCP server on every launch. Nothing is offered instead.
InternetAddress? wslHostAddressAmong(Iterable<HostInterface> interfaces) {
  for (final interface in interfaces) {
    if (!interface.name.toLowerCase().startsWith(_wslAdapterPrefix)) continue;
    for (final address in interface.addresses) {
      if (address.type != InternetAddressType.IPv4) continue;
      if (address.isLoopback) continue;
      return address;
    }
  }
  return null;
}

/// [wslHostAddressAmong], asked of the live machine.
Future<InternetAddress?> resolveWslHostAddress() async {
  final interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
  );
  return wslHostAddressAmong([
    for (final interface in interfaces)
      (name: interface.name, addresses: interface.addresses),
  ]);
}
