import 'package:karmashala_relay_protocol/karmashala_relay_protocol.dart';
import 'package:test/test.dart';

const _id = '0123456789abcdef0123456789abcdef';
const _tag = 'fedcba9876543210fedcba9876543210';

void main() {
  group('routes', () {
    test('a rendezvous is v1/<32 lowercase hex>', () {
      expect(rendezvousPath(_id), 'v1/$_id');
      expect(rendezvousIdOf('v1/$_id'), _id);
      expect(rendezvousIdPattern.hasMatch(_id), isTrue);
    });

    test('anything else names no rendezvous', () {
      expect(rendezvousIdOf('v1/${_id.toUpperCase()}'), isNull);
      expect(rendezvousIdOf('v1/${_id.substring(1)}'), isNull);
      expect(rendezvousIdOf('v2/$_id'), isNull);
      expect(rendezvousIdOf('/v1/$_id'), isNull);
      expect(rendezvousIdOf(kRelayPushPath), isNull);
    });

    test('the push and health routes', () {
      expect(kRelayPushRegisterPath, 'v1/push/register');
      expect(kRelayPushPath, 'v1/push');
      expect(kRelayHealthPath, 'healthz');
      expect(kDefaultRelayPort, 8787);
    });

    test('an access token is 32+ url-safe characters under k/', () {
      final token = 'A-_z' * 8;
      expect(isUsableRelayToken(token), isTrue);
      expect(isUsableRelayToken(token.substring(1)), isFalse);
      expect(isUsableRelayToken('${token.substring(1)}/'), isFalse);
      expect(relayAccessTokenPrefix(token), 'k/$token');
    });

    test('a route joins a base path keeping its prefix', () {
      expect(joinRelayPath('', 'v1/$_id'), '/v1/$_id');
      expect(joinRelayPath('/', 'v1/$_id'), '/v1/$_id');
      expect(joinRelayPath('/k/t', 'v1/push'), '/k/t/v1/push');
      expect(joinRelayPath('/relay/', 'healthz'), '/relay/healthz');
    });
  });

  group('push bodies', () {
    test('a registration round-trips', () {
      const registration = PushRegistration(
        tag: _tag,
        token: 'fcm-token',
        platform: 'android',
      );
      final read = PushRegistration.tryParse(registration.toJson())!;
      expect(read.tag, _tag);
      expect(read.token, 'fcm-token');
      expect(read.platform, 'android');
    });

    test('a registration breaking a rule is refused', () {
      Map<String, Object?> body({
        Object? tag = _tag,
        Object? token = 't',
        Object? platform = 'ios',
      }) => {'tag': tag, 'token': token, 'platform': platform};
      expect(PushRegistration.tryParse(body()), isNotNull);
      expect(PushRegistration.tryParse(body(tag: 'x')), isNull);
      expect(PushRegistration.tryParse(body(token: '')), isNull);
      expect(PushRegistration.tryParse(body(token: 't' * 4097)), isNull);
      expect(PushRegistration.tryParse(body(platform: 'web')), isNull);
      expect(PushRegistration.tryParse(body(platform: 1)), isNull);
    });

    test('a push request round-trips and refuses non-base64url', () {
      const request = PushRequest(tag: _tag, payload: 'AbC-_=');
      expect(PushRequest.tryParse(request.toJson())!.payload, 'AbC-_=');
      expect(PushRequest.tryParse({'tag': _tag, 'payload': 'a b'}), isNull);
      expect(PushRequest.tryParse({'tag': _tag, 'payload': ''}), isNull);
      expect(PushRequest.tryParse({'tag': 'no', 'payload': 'a'}), isNull);
    });

    test('statuses and close codes are the wire values', () {
      expect(RelayStatus.pushRegistered, 204);
      expect(RelayStatus.pushAccepted, 202);
      expect(RelayStatus.notFound, 404);
      expect(RelayStatus.tokenGone, 410);
      expect(RelayStatus.unavailable, 503);
      expect(kCloseNoPeer, 4408);
      expect(kCloseBusy, 4409);
      expect(kCloseFrameTooLarge, 4413);
      expect(kCloseImpatient, 4429);
    });
  });
}
