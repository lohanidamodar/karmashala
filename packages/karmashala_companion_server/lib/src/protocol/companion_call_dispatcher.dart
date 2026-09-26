import 'dart:convert';

import 'package:karmashala_remote/host.dart';
import 'package:karmashala_remote/remote.dart';

import 'companion_method.dart';

/// Runs a companion call the session host forwarded, against the desktop
/// app's own bindings, and answers it as JSON — the inverse of
/// `ForwardedBindings`. Throws [RemoteApiRefusal] for anything the phone
/// should be refused with, the app's own refusals included.
class CompanionCallDispatcher {
  const CompanionCallDispatcher(this._bindings);

  /// Read per call, so a binding rebuilt since the last one is the one used.
  final RemoteHostBindings Function() _bindings;

  Future<Map<String, Object?>> run(
    String methodName,
    Map<String, Object?> arguments,
  ) async {
    final method = CompanionMethod.tryParse(methodName);
    if (method == null) {
      throw RemoteApiRefusal(
        ErrorCode.unknownType,
        'this app does not answer $methodName',
      );
    }
    final bindings = _bindings();
    String text(String key) {
      final value = arguments[key];
      if (value is! String) {
        throw RemoteApiRefusal(ErrorCode.badRequest, 'missing $key');
      }
      return value;
    }

    Map<String, Object?> map(String key) {
      final value = arguments[key];
      if (value is Map) return value.cast<String, Object?>();
      throw RemoteApiRefusal(ErrorCode.badRequest, 'missing $key');
    }

    ({String? id})? choice(String key) {
      if (!arguments.containsKey(key)) return null;
      final id = map(key)['id'];
      return (id: id is String ? id : null);
    }

    switch (method) {
      case CompanionMethod.listSessions:
        return {
          'sessions': [
            for (final session in await bindings.listSessions())
              session.toJson(),
          ],
        };
      case CompanionMethod.sessionById:
        return {
          'session': (await bindings.sessionById(text('sessionId')))?.toJson(),
        };
      case CompanionMethod.deliveryStage:
        return {'stage': await bindings.deliveryStageFor(text('sessionId'))};
      case CompanionMethod.transcript:
        final record = await bindings.transcriptFor(text('sessionId'));
        return {
          'page': record.page.toJson(),
          'activity': record.activity.toJson(),
        };
      case CompanionMethod.recordState:
        final reading = await bindings.readRecordState(text('sessionId'));
        return {
          'revision': reading.revision,
          'activity': reading.activity?.toJson(),
        };
      case CompanionMethod.sendPrompt:
        final attachment = arguments['attachment'];
        final RemoteAttachmentRef? ref;
        if (attachment is Map) {
          final deviceId = attachment['deviceId'];
          final uploadId = attachment['uploadId'];
          if (deviceId is! String || uploadId is! String) {
            throw const RemoteApiRefusal(
              ErrorCode.badRequest,
              'bad attachment',
            );
          }
          ref = (deviceId: deviceId, uploadId: uploadId);
        } else {
          ref = null;
        }
        final delivery = await bindings.sendPrompt(
          text('sessionId'),
          text('text'),
          attachment: ref,
        );
        return {'delivery': delivery.wire};
      case CompanionMethod.answerApproval:
        return {
          'pressed': await bindings.answerApproval(
            text('sessionId'),
            text('decision'),
          ),
        };
      case CompanionMethod.approvalEvidence:
        return {
          'request': (await bindings.approvalEvidenceFor(
            text('sessionId'),
          )).toJson(),
        };
      case CompanionMethod.answerQuestion:
        return {
          'done': await bindings.answerQuestion(
            _decode(() => RemoteQuestionAnswerRequest.fromJson(arguments)),
          ),
        };
      case CompanionMethod.answerMenu:
        return {
          'chosen': await bindings.answerMenu(
            _decode(() => RemoteMenuAnswerRequest.fromJson(arguments)),
          ),
        };
      case CompanionMethod.usage:
        return (await bindings.usage()).toJson();
      case CompanionMethod.listWorkspace:
        return {
          'projects': [
            for (final project in await bindings.listWorkspace())
              project.toJson(),
          ],
        };
      case CompanionMethod.listProjects:
        return {
          'projects': [
            for (final project in await bindings.listProjects())
              project.toJson(),
          ],
        };
      case CompanionMethod.startSession:
        final title = arguments['title'];
        final message = arguments['message'];
        return (await bindings.startSession(
          RemoteSessionStartRequest(
            repositoryId: text('repositoryId'),
            installationId: text('installationId'),
            permissionMode: text('permissionMode'),
            title: title is String ? title : null,
            message: message is String ? message : null,
            worktree: arguments['worktree'] == true,
          ),
        )).toJson();
      case CompanionMethod.addProject:
        return (await bindings.addProject(text('name'), text('path'))).toJson();
      case CompanionMethod.resumeSession:
        return (await bindings.resumeSession(text('sessionId'))).toJson();
      case CompanionMethod.beginAttachment:
        return (await bindings.beginAttachment(
          text('deviceId'),
          _decode(() => RemoteAttachmentBegin.fromJson(map('request'))),
        )).toJson();
      case CompanionMethod.writeAttachmentChunk:
        final seq = arguments['seq'];
        if (seq is! int) {
          throw const RemoteApiRefusal(ErrorCode.badRequest, 'missing seq');
        }
        final List<int> data;
        try {
          data = base64Decode(text('data'));
        } on FormatException {
          throw const RemoteApiRefusal(
            ErrorCode.badRequest,
            'a chunk must be base64',
          );
        }
        await bindings.writeAttachmentChunk(
          text('deviceId'),
          text('uploadId'),
          seq,
          data,
        );
        return const {};
      case CompanionMethod.discardAttachment:
        await bindings.discardAttachment(text('deviceId'));
        return const {};
      case CompanionMethod.sessionOptions:
        return (await bindings.sessionOptions(text('sessionId'))).toJson();
      case CompanionMethod.configureSession:
        final outcome = await bindings.configureSession(
          text('sessionId'),
          model: choice('model'),
          permission: choice('permission'),
        );
        return {'outcome': outcome.wire};
    }
  }

  static T _decode<T>(T Function() read) {
    try {
      return read();
    } on ProtocolException catch (error) {
      throw RemoteApiRefusal(ErrorCode.badRequest, error.message);
    }
  }
}
