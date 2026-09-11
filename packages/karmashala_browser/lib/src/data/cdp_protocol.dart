import 'dart:convert';

import '../domain/cdp_message.dart';

/// Encodes one CDP command frame. `params` is omitted entirely when empty: a few
/// domains reject an explicit empty object where they expect no field.
String encodeCdpCommand({
  required int id,
  required String method,
  Map<String, Object?>? params,
  String? sessionId,
}) {
  final frame = <String, Object?>{'id': id, 'method': method};
  if (params != null && params.isNotEmpty) frame['params'] = params;
  if (sessionId != null) frame['sessionId'] = sessionId;
  return jsonEncode(frame);
}

/// Decodes one inbound CDP frame. Throws [CdpProtocolException] for anything not
/// recognisably CDP, so a garbled socket surfaces instead of reading as
/// "no reply yet".
CdpMessage decodeCdpMessage(String raw) {
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException catch (e) {
    throw CdpProtocolException('frame is not JSON: ${e.message}', frame: raw);
  }
  if (decoded is! Map<String, Object?>) {
    throw CdpProtocolException('frame is not a JSON object', frame: raw);
  }

  final sessionId = decoded['sessionId'];
  if (sessionId is! String?) {
    throw CdpProtocolException('frame sessionId is not a string', frame: raw);
  }
  final id = decoded['id'];

  if (id != null) {
    if (id is! int) {
      throw CdpProtocolException('frame id is not an integer', frame: raw);
    }
    final error = decoded['error'];
    if (error != null) {
      if (error is! Map<String, Object?>) {
        throw CdpProtocolException('frame error is not an object', frame: raw);
      }
      return CdpErrorMessage(
        id: id,
        code: error['code'] is int ? error['code']! as int : 0,
        message: error['message']?.toString() ?? 'unknown protocol error',
        data: error['data']?.toString(),
        sessionId: sessionId,
      );
    }
    final result = decoded['result'];
    if (result != null && result is! Map<String, Object?>) {
      throw CdpProtocolException('frame result is not an object', frame: raw);
    }
    return CdpResult(
      id: id,
      result: (result as Map<String, Object?>?) ?? const {},
      sessionId: sessionId,
    );
  }

  final method = decoded['method'];
  if (method is String) {
    final params = decoded['params'];
    if (params != null && params is! Map<String, Object?>) {
      throw CdpProtocolException('event params is not an object', frame: raw);
    }
    return CdpEvent(
      method: method,
      params: (params as Map<String, Object?>?) ?? const {},
      sessionId: sessionId,
    );
  }

  throw CdpProtocolException('frame has neither id nor method', frame: raw);
}
