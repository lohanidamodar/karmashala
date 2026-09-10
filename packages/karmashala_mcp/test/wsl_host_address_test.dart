import 'dart:io';

import 'package:karmashala_mcp/access.dart';
import 'package:test/test.dart';

/// Which address a WSL-hosted agent is told to dial.
///
/// Measured on this machine (Windows 11, WSL2 in NAT mode) with a Dart
/// `HttpServer` on an ephemeral port and `curl` from inside the distribution:
///
/// | bound to | from WSL | from the LAN address | from the VPN address |
/// | --- | --- | --- | --- |
/// | `127.0.0.1` | refused | — | — |
/// | `172.18.240.1` (`vEthernet (WSL …)`) | **served** | refused | refused |
/// | `0.0.0.0` | served | **served** | **served** |
///
/// So the adapter address is the only one of the three that is both reachable
/// from the distribution and absent from every other interface, which is what
/// these cases pin down.
void main() {
  ({String name, List<InternetAddress> addresses}) iface(
    String name,
    List<String> addresses,
  ) => (
    name: name,
    addresses: [for (final a in addresses) InternetAddress(a)],
  );

  test('the Hyper-V firewall spelling of the adapter is found', () {
    // What `NetworkInterface.list()` really reports on Windows 11 — the alias
    // carries the firewall's name in a second bracket.
    expect(
      wslHostAddressAmong([
        iface('Wi-Fi', ['192.168.68.59']),
        iface('vEthernet (WSL (Hyper-V firewall))', ['172.18.240.1']),
      ])?.address,
      '172.18.240.1',
    );
  });

  test('the older spelling is found too', () {
    expect(
      wslHostAddressAmong([
        iface('vEthernet (WSL)', ['172.20.16.1']),
      ])?.address,
      '172.20.16.1',
    );
  });

  test('a machine with no WSL switch has no address to offer', () {
    // Mirrored networking and WSL 1 both leave no such adapter. They also both
    // share the host's loopback, so `127.0.0.1` would in fact work there — but
    // neither has been measured here, and a URL that has not been dialled is
    // exactly what this codebase refuses to write down.
    expect(
      wslHostAddressAmong([
        iface('Wi-Fi', ['192.168.68.59']),
        iface('Loopback Pseudo-Interface 1', ['127.0.0.1']),
      ]),
      isNull,
    );
  });

  test('an adapter that is up but unaddressed is not offered', () {
    expect(wslHostAddressAmong([iface('vEthernet (WSL)', [])]), isNull);
  });

  test('no other adapter can pass for the WSL one', () {
    // `vEthernet (Default Switch)` is the Hyper-V switch ordinary VMs sit on,
    // and reaches machines this app has no business serving.
    expect(
      wslHostAddressAmong([
        iface('vEthernet (Default Switch)', ['172.29.64.1']),
        iface('CloudflareWARP', ['172.16.0.2']),
      ]),
      isNull,
    );
  });

  test('loopback on the WSL adapter is not an answer', () {
    // A loopback address would be reachable from the host and from nowhere
    // else, which is the exact failure this whole file exists to avoid.
    expect(
      wslHostAddressAmong([
        iface('vEthernet (WSL)', ['127.0.0.1', '172.18.240.1']),
      ])?.address,
      '172.18.240.1',
    );
  });
}
