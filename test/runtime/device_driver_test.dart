import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ihm/core/comm/comm_error.dart';
import 'package:ihm/core/modbus/modbus_client.dart';
import 'package:ihm/models/device.dart';
import 'package:ihm/models/tag.dart';
import 'package:ihm/services/runtime/device_session.dart';
import 'package:ihm/services/runtime/drivers/device_driver.dart';
import 'package:ihm/services/runtime/tag_store.dart';

/// Queda de um protocolo qualquer (não Modbus).
class _Queda extends CommError {
  const _Queda() : super('broker sumiu');
  @override
  String get userMessage => 'sem resposta do broker';
}

/// Driver de mentira: prova que a sessão não depende de Modbus.
class _FakeDriver extends DeviceDriver {
  final _state = ValueNotifier(ModbusLinkState.disconnected);
  bool falhar = false;
  int varreduras = 0;
  final gravados = <String, Object>{};

  @override
  ValueListenable<ModbusLinkState> get state => _state;

  @override
  Future<void> connect() async => _state.value = ModbusLinkState.connected;

  @override
  Future<void> disconnect() async => _state.value = ModbusLinkState.disconnected;

  @override
  Future<int> scan(List<Tag> tags, TagStore store, {required bool Function() stillCurrent}) async {
    varreduras++;
    if (falhar) throw const _Queda();
    await connect();
    for (final t in tags) {
      store.publish(t.id, TagReading(value: 42, quality: TagQuality.good, at: DateTime.now()));
    }
    return 1;
  }

  @override
  Future<Object> readOnce(Tag tag) async => 7;

  @override
  Future<void> write(Tag tag, Object value) async => gravados[tag.id] = value;

  @override
  Future<void> ping() async {}

  @override
  Future<void> dispose() async {}
}

void main() {
  const device = Device(id: 'd1', name: 'Sensor MQTT', host: '192.168.1.5', pollMs: 50);
  const tag = Tag(id: 't1', deviceId: 'd1', name: 'Temperatura');

  test('sessão publica o que o driver lê, grava por ele e marca queda como sem comunicação', () async {
    final store = TagStore();
    final fake = _FakeDriver();
    final s = DeviceSession(device: device, store: store, driverFactory: (_) => fake);
    s.setTags(const [tag]);
    s.start();
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(store.read('t1').value, 42);
    expect(store.read('t1').quality, TagQuality.good);
    expect(s.health.value.online, isTrue);
    expect(await s.readOnce(tag), 7);

    await s.write(tag, 1);
    expect(fake.gravados['t1'], 1);

    fake.falhar = true;
    s.wake();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final r = store.read('t1');
    expect(r.quality, TagQuality.commLost);
    expect(r.value, 42, reason: 'queda mantém o último valor, esmaecido');
    expect(s.health.value.message, 'sem resposta do broker');

    await s.dispose();
  });
}
