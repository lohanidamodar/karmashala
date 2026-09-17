import 'package:meta/meta.dart';

/// A step only root can take on a machine that wants a password for `sudo`.
///
/// Never run from here: an exec channel has no terminal to type a password
/// into, and the app never asks for one. It is shown to copy, and typed — not
/// submitted — at the prompt of a real terminal on that machine.
@immutable
class PrivilegedCommand {
  const PrivilegedCommand({
    required this.command,
    required this.does,
    required this.why,
  });

  /// One line for the machine's own shell. Holds no secret: a port, a user
  /// name, a package name — never a token, a code or a password.
  final String command;

  /// What running it changes, in one sentence.
  final String does;

  /// Why Karmashala could not do it itself.
  final String why;

  @override
  bool operator ==(Object other) =>
      other is PrivilegedCommand &&
      other.command == command &&
      other.does == does &&
      other.why == why;

  @override
  int get hashCode => Object.hash(command, does, why);

  @override
  String toString() => 'PrivilegedCommand($command)';
}

/// Where a port is opened when nothing on the machine is shutting it. Named
/// consoles, because "your provider" is not somewhere a person can click.
String providerFirewallHint(int port) =>
    'Allow inbound TCP $port in the provider\'s console — DigitalOcean: '
    'Networking › Firewalls; AWS: the instance\'s security group; Google '
    'Cloud: VPC firewall rules; Azure: the network security group; Hetzner, '
    'Vultr and Linode: Firewalls. Nothing run on the machine can change that.';
