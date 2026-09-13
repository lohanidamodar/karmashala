import 'package:test/test.dart';
import 'package:karmashala_remote/pairing.dart';

/// **Two phones must never arrive at the desktop reading the same word.**
///
/// Reported 2026-09-13: a Pixel and an Oppo both paired as `Companion`, because
/// nothing ever overrode the default, and the desktop's list could not say
/// which row was which. The model is the answer when it can be read; what
/// matters here is the case where it cannot.
void main() {
  test('the model is the name', () {
    expect(
      companionDeviceName(model: 'Pixel 7 Pro', deviceId: 'a1b2c3d4e5'),
      'Pixel 7 Pro',
    );
  });

  test('a model spread over whitespace is one line', () {
    expect(
      companionDeviceName(model: '  OPPO   Reno11 \n', deviceId: 'ff00'),
      'OPPO Reno11',
    );
  });

  test('an unreadable model still tells two phones apart', () {
    final pixel = companionDeviceName(model: null, deviceId: 'a1b2c3d4e5f6');
    final oppo = companionDeviceName(model: '', deviceId: '99887766554433');

    expect(pixel, isNot(oppo));
    expect(pixel, 'Companion · a1b2c3');
    expect(
      oppo,
      startsWith('Companion · '),
      reason: 'the word alone is what made the two rows indistinguishable',
    );
  });

  test('a vendor being expansive is cut to a row', () {
    final name = companionDeviceName(
      model: 'Some Vendor Incorporated Ultra Max Pro Plus Edition 5G XL',
      deviceId: 'abc',
    );

    expect(name.length, maxCompanionDeviceName);
    expect(name, startsWith('Some Vendor'));
  });

  test('no id and no model is the only case that answers the bare word', () {
    expect(companionDeviceName(model: null, deviceId: '  '), 'Companion');
  });
}
