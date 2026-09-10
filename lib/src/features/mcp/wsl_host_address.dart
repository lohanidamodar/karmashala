import 'dart:io';

/// One host network adapter, reduced to what choosing between them needs — a
/// record because [NetworkInterface] cannot be constructed in a test.
typedef HostInterface = ({String name, List<InternetAddress> addresses});

/// The alias Windows gives the WSL2 virtual switch, lower-cased, as a prefix —
/// the name gained a bracket once, and `(Default Switch)` must not match.
const String _wslAdapterPrefix = 'vethernet (wsl';

/// The address a process **inside a WSL2 distribution** can dial to reach this
/// host, or `null` — never a loopback fallback nobody has dialled from there.
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
