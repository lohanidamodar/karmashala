import 'package:karmashala_host_protocol/host_access.dart'
    show ExplainedFailure;

/// Why a server would not do what a data request asked.
enum DataRefusalCode {
  /// The request is malformed or breaks a rule (a blank todo, a taken id).
  invalid,

  /// It names a row, project or key that does not exist.
  notFound,

  /// It names something the client may not write (a key the server owns).
  reserved,

  /// No server answered: it is not running, or the link to it is down.
  unavailable,

  /// It expected something to be as it last saw it, and it is not: a save
  /// over a file changed on disk since it was read (`files.write`).
  conflict,

  /// This link may not ask it: a client on another machine whose pairing
  /// does not grant it (slice 5e).
  denied,

  /// The server tried and failed.
  failed;

  static DataRefusalCode parse(Object? name) => DataRefusalCode.values
      .firstWhere((code) => code.name == name, orElse: () => failed);
}

/// A data request the server refused, with its reason in words — short
/// enough for where it is shown — and, when there is more to it, the whole
/// technical account in [detail].
class DataRefused implements ExplainedFailure {
  const DataRefused(this.code, this.message, {this.detail});

  const DataRefused.invalid(String message)
    : this(DataRefusalCode.invalid, message);

  const DataRefused.notFound(String message)
    : this(DataRefusalCode.notFound, message);

  const DataRefused.unavailable(String message)
    : this(DataRefusalCode.unavailable, message);

  const DataRefused.denied(String message)
    : this(DataRefusalCode.denied, message);

  final DataRefusalCode code;
  @override
  final String message;
  @override
  final String? detail;

  Map<String, Object?> toJson() => {
    'code': code.name,
    'message': message,
    'detail': ?detail,
  };

  static DataRefused fromJson(Map<String, Object?> json) => DataRefused(
    DataRefusalCode.parse(json['code']),
    json['message'] as String? ?? 'refused',
    detail: json['detail'] as String?,
  );

  @override
  String toString() => 'DataRefused(${code.name}): $message';
}
