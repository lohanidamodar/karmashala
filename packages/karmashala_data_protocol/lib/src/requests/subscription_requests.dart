part of '../data_request.dart';

/// Asks for every change after this one on this link, as [DataChanges]
/// batches — except the ones this link's own requests made, which their
/// answers carry.
final class DataSubscribe extends DataRequest<DataAck> {
  const DataSubscribe();

  static const String name = 'data.subscribe';

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => const {};

  @override
  Object? resultToJson(DataAck result) => null;

  @override
  DataAck resultFromJson(Object? json) => const DataAck();
}
