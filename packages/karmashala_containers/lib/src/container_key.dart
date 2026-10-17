import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:pinenacl/ed25519.dart' as ed25519;

/// A key pair generated for one container: the private half in OpenSSH form,
/// to be written to an owner-only file, and the `authorized_keys` line.
class ContainerKey {
  const ContainerKey({required this.privatePem, required this.publicLine});

  /// Never logged, never sent anywhere but the key file.
  final String privatePem;

  /// `ssh-ed25519 <base64> <comment>`.
  final String publicLine;

  @override
  String toString() => 'ContainerKey($publicLine)';
}

/// A fresh ed25519 key, from [random] (secure unless a test passes another).
ContainerKey generateContainerKey({required String comment, Random? random}) {
  final source = random ?? Random.secure();
  final seed = Uint8List.fromList([
    for (var i = 0; i < 32; i++) source.nextInt(256),
  ]);
  final signing = ed25519.SigningKey.fromSeed(seed);
  final public = Uint8List.fromList(signing.verifyKey.asTypedList);
  final pair = OpenSSHEd25519KeyPair(
    public,
    Uint8List.fromList(signing.asTypedList),
    comment,
  );
  final encoded = base64.encode(pair.toPublicKey().encode());
  return ContainerKey(
    privatePem: pair.toPem(),
    publicLine: 'ssh-ed25519 $encoded $comment',
  );
}
