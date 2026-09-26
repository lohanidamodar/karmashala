part of '../data_request.dart';

/// Every client preference the server keeps (`PreferenceKeys`): the app's
/// settings, its small remembered choices and one-off stamps.
final class PreferencesGet extends DataRequest<Map<String, String>> {
  const PreferencesGet();

  static const String name = 'preferences.get';

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => const {};

  @override
  Object? resultToJson(Map<String, String> result) => result;

  @override
  Map<String, String> resultFromJson(Object? json) => _decode(kind, () {
    final map = _object(json, kind);
    return {for (final entry in map.entries) entry.key: entry.value! as String};
  });
}

/// Keeps [value] under [key]. Refused [DataRefusalCode.reserved] for a key
/// the server or another domain owns, [DataRefusalCode.invalid] for one out
/// of shape or a value over the size bound.
final class PreferenceSet extends DataRequest<DataAck> {
  const PreferenceSet(this.key, this.value);

  static const String name = 'preferences.set';

  final String key;
  final String value;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'key': key, 'value': value};

  @override
  Object? resultToJson(DataAck result) => null;

  @override
  DataAck resultFromJson(Object? json) => const DataAck();
}

/// Forgets [key]; nothing to forget is not an error.
final class PreferenceRemove extends DataRequest<DataAck> {
  const PreferenceRemove(this.key);

  static const String name = 'preferences.remove';

  final String key;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'key': key};

  @override
  Object? resultToJson(DataAck result) => null;

  @override
  DataAck resultFromJson(Object? json) => const DataAck();
}
