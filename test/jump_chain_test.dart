import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/models/host_profile.dart';
import 'package:sshbox/src/session/dartssh2_transport.dart';
import 'package:sshbox/src/session/terminal_session.dart';

HostProfile _host(String id, {String jump = ''}) => HostProfile(
  id: id,
  label: id,
  host: '$id.example',
  username: 'me',
  jumpHostId: jump,
);

void main() {
  test('a host without a jump host connects directly', () {
    expect(jumpChain(_host('box'), [_host('gw')]), isEmpty);
  });

  test('jump hosts come first dialled first', () {
    final hosts = [_host('edge'), _host('gw', jump: 'edge')];
    final chain = jumpChain(_host('box', jump: 'gw'), hosts);
    expect(chain.map((host) => host.id), ['edge', 'gw']);
  });

  test('a deleted jump host is named', () {
    expect(
      () => jumpChain(_host('box', jump: 'gone'), [_host('gw')]),
      throwsA(
        isA<SshSessionException>().having(
          (error) => error.message,
          'message',
          contains('jump host of box was deleted'),
        ),
      ),
    );
  });

  test('a loop of jump hosts fails instead of dialling forever', () {
    final hosts = [_host('a', jump: 'b'), _host('b', jump: 'a')];
    expect(
      () => jumpChain(_host('box', jump: 'a'), hosts),
      throwsA(isA<SshSessionException>()),
    );
    expect(
      () => jumpChain(_host('a', jump: 'b'), hosts),
      throwsA(isA<SshSessionException>()),
    );
  });

  test('the jump host survives a save', () {
    final saved = HostProfile.fromJson(_host('box', jump: 'gw').toJson());
    expect(saved.jumpHostId, 'gw');
    expect(HostProfile.fromJson({'id': 'old'}).jumpHostId, '');
  });
}
