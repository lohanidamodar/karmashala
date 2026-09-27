import 'dart:async';

import 'package:agent_cli/process.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_environments/ssh.dart';
import 'package:karmashala_host/data.dart';
import 'package:karmashala_host/src/ssh/ssh_domain.dart';
import 'package:karmashala_store/database.dart';

import 'fake_box.dart';

export 'fake_box.dart';

/// A server's store and SSH domain over one saved host whose box is a
/// [FakeBox] in this process — no sshd, no key read, no real HOME touched.
class BoxWorld {
  BoxWorld({FakeBundles? bundles, bool probe = false}) {
    db = AppDatabase.memory();
    data = DataService(db, clock: () => boxTime)
      ..ensureEnvironment(localHostEnvironment(boxTime));
    ssh = ServerSshDomain(
      data: data,
      database: db,
      dataDirectory: '/nonexistent-data-dir',
      bundles: bundles ?? FakeBundles(),
      targetFor: (_) => box,
      probe: probe,
    )..attach();
    data.open((_) {}).handle(SshHostPut(host));
  }

  static const hostId = 'h1';

  final host = SshHost(
    id: hostId,
    name: 'do-box',
    host: '203.0.113.9',
    port: 22,
    username: 'dev',
    authMethod: SshAuthMethod.password,
    createdAt: boxTime,
  );

  final box = FakeBox();
  late final AppDatabase db;
  late final DataService data;
  late final ServerSshDomain ssh;

  /// The box's environment, `ssh:h1`.
  ExecutionEnvironment get environment =>
      data.environments.firstWhere((e) => e.kind == EnvironmentKind.ssh);

  /// A client's `ssh.*` request, answered when done.
  Future<R> ask<R>(DataRequest<R> request) async =>
      (await data.open((_) {}).handleLater(request)).value;

  Future<void> close() async {
    await ssh.close();
    await box.close();
    db.close();
  }
}

/// Lets frames cross the in-process links.
Future<void> settle([int turns = 20]) async {
  for (var i = 0; i < turns; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Waits (bounded) until [ready] holds.
Future<void> until(bool Function() ready, {int tries = 200}) async {
  for (var i = 0; i < tries && !ready(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
