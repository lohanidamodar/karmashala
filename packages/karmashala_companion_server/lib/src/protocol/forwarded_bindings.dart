import 'dart:convert';

import 'package:karmashala_remote/host.dart';
import 'package:karmashala_remote/remote.dart';

import '../service/companion_app_link.dart';
import 'companion_method.dart';

/// The companion bindings as calls to the desktop app: each encodes its
/// arguments, forwards them over [link], and decodes the app's answer into the
/// type the host session api serves. The inverse of `CompanionCallDispatcher`,
/// which runs these calls in the app.
class ForwardedBindings {
  const ForwardedBindings(this.link);

  final CompanionAppLink link;

  Future<Map<String, Object?>> _call(
    CompanionMethod method, [
    Map<String, Object?> arguments = const {},
  ]) async {
    try {
      return await link.call(method, arguments);
    } on ProtocolException catch (error) {
      throw RemoteApiRefusal(ErrorCode.internal, error.message);
    }
  }

  static Map<String, Object?> _map(Object? value, String what) {
    if (value is Map<String, Object?>) return value;
    if (value is Map) return value.cast<String, Object?>();
    throw ProtocolException('the app answered no $what');
  }

  static List<Map<String, Object?>> _maps(Object? value, String what) {
    if (value is! List) throw ProtocolException('the app answered no $what');
    return [for (final entry in value) _map(entry, what)];
  }

  Future<List<RemoteSessionSnapshot>> listSessions() async {
    final answer = await _call(CompanionMethod.listSessions);
    return [
      for (final row in _maps(answer['sessions'], 'sessions'))
        RemoteSessionSnapshot.fromJson(row),
    ];
  }

  Future<RemoteSessionSnapshot?> sessionById(String sessionId) async {
    final answer = await _call(CompanionMethod.sessionById, {
      'sessionId': sessionId,
    });
    final session = answer['session'];
    return session == null
        ? null
        : RemoteSessionSnapshot.fromJson(_map(session, 'session'));
  }

  Future<String?> deliveryStage(String sessionId) async {
    final answer = await _call(CompanionMethod.deliveryStage, {
      'sessionId': sessionId,
    });
    final stage = answer['stage'];
    return stage is String ? stage : null;
  }

  Future<RemoteSessionRecord> transcript(String sessionId) async {
    final answer = await _call(CompanionMethod.transcript, {
      'sessionId': sessionId,
    });
    return (
      page: RemoteTranscriptPage.fromJson(_map(answer['page'], 'page')),
      activity: RemoteSessionActivity.fromJson(
        _map(answer['activity'], 'activity'),
      ),
    );
  }

  Future<RemoteRecordReading> recordState(String sessionId) async {
    final answer = await _call(CompanionMethod.recordState, {
      'sessionId': sessionId,
    });
    final revision = answer['revision'];
    final activity = answer['activity'];
    return (
      revision: revision is String ? revision : null,
      activity: activity == null
          ? null
          : RemoteSessionActivity.fromJson(_map(activity, 'activity')),
    );
  }

  Future<RemotePromptDelivery> sendPrompt(
    String sessionId,
    String text, {
    RemoteAttachmentRef? attachment,
  }) async {
    final answer = await _call(CompanionMethod.sendPrompt, {
      'sessionId': sessionId,
      'text': text,
      if (attachment != null)
        'attachment': {
          'deviceId': attachment.deviceId,
          'uploadId': attachment.uploadId,
        },
    });
    return RemotePromptDelivery.parse(answer['delivery']);
  }

  Future<String> answerApproval(String sessionId, String decision) async {
    final answer = await _call(CompanionMethod.answerApproval, {
      'sessionId': sessionId,
      'decision': decision,
    });
    return '${answer['pressed'] ?? ''}';
  }

  Future<RemoteApprovalRequest> approvalEvidence(String sessionId) async {
    final answer = await _call(CompanionMethod.approvalEvidence, {
      'sessionId': sessionId,
    });
    return RemoteApprovalRequest.fromJson(_map(answer['request'], 'request'));
  }

  Future<String> answerQuestion(RemoteQuestionAnswerRequest request) async {
    final answer = await _call(
      CompanionMethod.answerQuestion,
      request.toJson(),
    );
    return '${answer['done'] ?? ''}';
  }

  Future<String> answerMenu(RemoteMenuAnswerRequest request) async {
    final answer = await _call(CompanionMethod.answerMenu, request.toJson());
    return '${answer['chosen'] ?? ''}';
  }

  Future<RemoteUsageSnapshot> usage() async =>
      RemoteUsageSnapshot.fromJson(await _call(CompanionMethod.usage));

  Future<List<RemoteWorkspaceProject>> listWorkspace() =>
      _projects(CompanionMethod.listWorkspace);

  Future<List<RemoteWorkspaceProject>> listProjects() =>
      _projects(CompanionMethod.listProjects);

  Future<List<RemoteWorkspaceProject>> _projects(CompanionMethod method) async {
    final answer = await _call(method);
    return [
      for (final row in _maps(answer['projects'], 'projects'))
        RemoteWorkspaceProject.fromJson(row),
    ];
  }

  Future<RemoteSessionStarted> startSession(
    RemoteSessionStartRequest request,
  ) async => RemoteSessionStarted.fromJson(
    await _call(CompanionMethod.startSession, {
      'repositoryId': request.repositoryId,
      'installationId': request.installationId,
      'permissionMode': request.permissionMode,
      'title': ?request.title,
      'message': ?request.message,
    }),
  );

  Future<RemoteWorkspaceProject> addProject(String name, String path) async =>
      RemoteWorkspaceProject.fromJson(
        await _call(CompanionMethod.addProject, {'name': name, 'path': path}),
      );

  Future<RemoteSessionStarted> resumeSession(String sessionId) async =>
      RemoteSessionStarted.fromJson(
        await _call(CompanionMethod.resumeSession, {'sessionId': sessionId}),
      );

  Future<RemoteAttachmentOffer> beginAttachment(
    String deviceId,
    RemoteAttachmentBegin request,
  ) async => RemoteAttachmentOffer.fromJson(
    await _call(CompanionMethod.beginAttachment, {
      'deviceId': deviceId,
      'request': request.toJson(),
    }),
  );

  Future<void> writeAttachmentChunk(
    String deviceId,
    String uploadId,
    int seq,
    List<int> data,
  ) => _call(CompanionMethod.writeAttachmentChunk, {
    'deviceId': deviceId,
    'uploadId': uploadId,
    'seq': seq,
    'data': base64Encode(data),
  });

  Future<void> discardAttachment(String deviceId) =>
      _call(CompanionMethod.discardAttachment, {'deviceId': deviceId});

  Future<RemoteSessionOptions> sessionOptions(String sessionId) async =>
      RemoteSessionOptions.fromJson(
        await _call(CompanionMethod.sessionOptions, {'sessionId': sessionId}),
      );

  Future<RemoteConfigureOutcome> configureSession(
    String sessionId, {
    ({String? id})? model,
    ({String? id})? permission,
  }) async {
    final answer = await _call(CompanionMethod.configureSession, {
      'sessionId': sessionId,
      if (model != null) 'model': {'id': model.id},
      if (permission != null) 'permission': {'id': permission.id},
    });
    return RemoteConfigureOutcome.parse(answer['outcome']);
  }
}
