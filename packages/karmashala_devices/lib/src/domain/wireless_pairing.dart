import 'dart:math';

/// The two mDNS service types Android's wireless debugging advertises.
///
/// **They are different ports on the same phone.** `adb pair` wants the
/// pairing one and `adb connect` the connect one, and each refuses the other's
/// — reusing the pairing port for `connect` is the classic mistake here.
const String kAdbPairingServiceType = '_adb-tls-pairing._tcp';
const String kAdbConnectServiceType = '_adb-tls-connect._tcp';

/// Whether `adb mdns services` produced a reading at all.
///
/// Three values because "nothing is advertising" and "nobody could look" are
/// different sentences (§19). Collapsing them would report a phone that is
/// waiting to be paired as absent.
enum MdnsAvailability {
  /// The daemon answered; the service list is what it says it is.
  available,

  /// adb has mDNS discovery switched off, so it will never see the phone.
  disabled,

  /// The check could not be taken — adb did not run, or said something nobody
  /// here recognises.
  unknown,
}

/// One row of `adb mdns services`.
class MdnsService {
  const MdnsService({
    required this.name,
    required this.type,
    required this.host,
    required this.port,
  });

  /// The mDNS instance name. For a pairing service this is the name *we*
  /// chose and put in the QR; for a connect service it is adb's own guid.
  final String name;

  /// One of [kAdbPairingServiceType] / [kAdbConnectServiceType].
  final String type;

  final String host;
  final int port;

  String get address => '$host:$port';

  @override
  bool operator ==(Object other) =>
      other is MdnsService &&
      other.name == name &&
      other.type == type &&
      other.host == host &&
      other.port == port;

  @override
  int get hashCode => Object.hash(name, type, host, port);

  @override
  String toString() => 'MdnsService($name $type $address)';
}

/// One reading of `adb mdns services`, with whether it is a reading.
class MdnsScan {
  const MdnsScan({required this.availability, this.services = const []});

  const MdnsScan.unknown()
    : availability = MdnsAvailability.unknown,
      services = const [];

  final MdnsAvailability availability;
  final List<MdnsService> services;

  /// Whether the empty list below means "nothing is advertising".
  bool get isReading => availability == MdnsAvailability.available;

  Iterable<MdnsService> ofType(String type) =>
      services.where((s) => s.type == type);

  /// The service of [type] advertising itself under [name], or null.
  ///
  /// Both halves are required because a phone advertises the *same* instance
  /// name under neither type by accident and under one type deliberately: the
  /// pairing service carries the name we put in the QR, the connect service
  /// carries adb's guid. Matching on the name alone would find the pairing port
  /// when the connect port was asked for.
  MdnsService? find({required String type, required String name}) {
    for (final service in services) {
      if (service.type == type && service.name == name) return service;
    }
    return null;
  }
}

/// The QR that Android's *Pair device with QR code* screen scans.
///
/// A Wi-Fi-provisioning string with `T:ADB`: this side invents both halves and
/// draws the code, the phone advertises `_adb-tls-pairing._tcp` under
/// [serviceName], and mDNS discovery is how the port to pair against is found.
class AdbPairingInvite {
  const AdbPairingInvite({required this.serviceName, required this.password});

  /// A fresh name and password. [random] is a seam for tests; the app leaves it
  /// null and gets `Random.secure`.
  factory AdbPairingInvite.generate({Random? random}) {
    final source = random ?? Random.secure();
    return AdbPairingInvite(
      serviceName: 'karmashala-${_draw(source, 8)}',
      password: _draw(source, 12),
    );
  }

  /// The name the phone will advertise, and how this attempt is recognised
  /// among every other service on the network.
  final String serviceName;

  /// The shared secret the phone proves it scanned. Never logged.
  final String password;

  /// Alphanumeric only, and deliberately so: the payload below delimits with
  /// `:` and `;` and escapes with `\`, so a password containing one of those
  /// would be read as structure by the phone rather than as the secret.
  static const String _alphabet =
      'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789';

  static String _draw(Random source, int length) => String.fromCharCodes([
    for (var i = 0; i < length; i++)
      _alphabet.codeUnitAt(source.nextInt(_alphabet.length)),
  ]);

  String encode() => 'WIFI:T:ADB;S:$serviceName;P:$password;;';

  /// Names the attempt without its secret — this is what a log line gets.
  @override
  String toString() => 'AdbPairingInvite($serviceName)';
}

/// Why `adb pair` refused, in the terms the user can act on.
enum AdbPairFailure {
  /// The code did not match, or the handshake was cut short.
  wrongCode,

  /// Nothing answered on the pairing port. One adb message, two situations.
  unreachable,

  /// The host:port could not be read as an address at all.
  malformedAddress,

  /// adb was given no code and wanted to prompt for one.
  noCode,

  /// adb said something nobody here recognises. Never read as success.
  unknown,
}

/// The outcome of one `adb pair`.
sealed class AdbPairResult {
  const AdbPairResult();
}

/// Paired. [guid] is the mDNS name the phone will advertise its *connect*
/// service under, which is how the second half of the flow finds it.
final class AdbPaired extends AdbPairResult {
  const AdbPaired({required this.host, required this.port, required this.guid});

  final String host;
  final int port;
  final String guid;

  @override
  String toString() => 'AdbPaired($host:$port $guid)';
}

final class AdbPairRefused extends AdbPairResult {
  const AdbPairRefused({required this.cause, required this.message});

  final AdbPairFailure cause;

  /// One sentence for the dialog. Built here rather than in the widget so the
  /// wording is asserted by a unit test.
  final String message;

  @override
  String toString() => 'AdbPairRefused($cause)';
}

/// What `adb connect` did. `unknown` exists because an exit code of 0 with
/// output nobody recognises is not evidence of a connection.
enum AdbConnectOutcome { connected, refused, unknown }

/// A host and a port that were read off something, together.
class PairingAddress {
  const PairingAddress({required this.host, required this.port});

  final String host;
  final int port;

  /// How adb wants it on the command line. An IPv6 host keeps its brackets so
  /// its own colons are not read as the port separator.
  String get argument => host.contains(':') ? '[$host]:$port' : '$host:$port';

  @override
  bool operator ==(Object other) =>
      other is PairingAddress && other.host == host && other.port == port;

  @override
  int get hashCode => Object.hash(host, port);

  @override
  String toString() => argument;
}

/// How many `adb mdns services` spawns one pairing attempt may cost.
///
/// A **count**, not a deadline: the poll runs while a QR is on screen, and what
/// has to be bounded is the number of processes it creates. At
/// [kMdnsPollInterval] apiece this covers about two minutes, which is longer
/// than anyone holds a phone up to a screen.
const int kMdnsPollBudget = 60;

/// Between two polls. Long enough that the spawns are not a burst, short enough
/// that a scan feels immediate; nothing asserts on it.
const Duration kMdnsPollInterval = Duration(seconds: 2);

/// How many of the budget are spent looking for the *connect* service after a
/// successful pair, before the flow says it paired but could not connect.
const int kConnectDiscoveryBudget = 10;
