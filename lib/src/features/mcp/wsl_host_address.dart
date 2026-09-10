import 'dart:io';

/// One host network adapter, reduced to what choosing between them needs. A
/// record rather than a [NetworkInterface] because that class cannot be
/// constructed, so the choice below would otherwise only be testable on a
/// machine that happens to have the adapter.
typedef HostInterface = ({String name, List<InternetAddress> addresses});

/// The alias Windows gives the WSL2 virtual switch, lower-cased, as a prefix.
///
/// A prefix and not an equality test: the name has a second bracket on current
/// Windows 11 builds — `vEthernet (WSL (Hyper-V firewall))` — and had none
/// before, so an exact match would silently stop finding it on the next rename.
/// Narrow at the other end too: `vEthernet (Default Switch)` carries ordinary
/// virtual machines this app has no relationship with.
const String _wslAdapterPrefix = 'vethernet (wsl';

/// The address a process **inside a WSL2 distribution** can dial to reach a
/// server on this Windows host, or `null` when this machine has no such switch.
///
/// A distribution has its own network namespace and nothing forwards inbound:
/// measured here, `curl` from WSL to `127.0.0.1:<port>` is refused where the
/// switch's host address is served. Not `0.0.0.0`, which also works and would
/// put the whole privileged tool surface on the LAN and any VPN adapter.
///
/// No adapter means `null`, not a loopback fallback: mirrored networking and
/// WSL 1 would work on `127.0.0.1`, but neither has been dialled from here.
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
