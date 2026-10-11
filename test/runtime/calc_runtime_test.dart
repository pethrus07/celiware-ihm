import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ihm/app/project_controller.dart';
import 'package:ihm/core/modbus/modbus_client_simulated.dart';
import 'package:ihm/models/alarm.dart';
import 'package:ihm/models/calc.dart';
import 'package:ihm/models/project.dart';
import 'package:ihm/models/tag.dart';
import 'package:ihm/services/alarms/alarm_engine.dart';
import 'package:ihm/services/demo/demo_process.dart';
import 'package:ihm/services/demo/demo_project.dart';
import 'package:ihm/services/runtime/hmi_runtime.dart';
import 'package:ihm/services/runtime/tag_codec.dart';
import 'package:ihm/services/runtime/tag_store.dart';
import 'package:ihm/services/storage/project_repository.dart';

/// Variáveis calculadas pelo caminho de produção (LG-1 a LG-3): máquina de
/// demonstração → sessão → driver Modbus → TagStore → sessão das calculadas
/// (CalcDriver) → TagStore → alarme. Nada de avaliador chamado na mão.
void main() {
  late Directory dir;
  late SimulatedModbusClient client;
  late HmiRuntime runtime;
  late ProjectController controller;

  Tag calc(String id, String name, String expr, {List<AlarmRule> alarms = const [], Map<String, String> names = const {}}) => Tag(
      id: id, name: name, deviceId: CalcDevice.id, dataType: TagDataType.float32, decimals: 1, alarms: alarms, calc: CalcSpec(expression: expr, names: names));

  // "Velocidade desejada" e "Comprimento do rótulo" só mudam quando o app grava.
  final perMinute = calc('c_min', 'Rótulos por minuto', '{demo_sp} * 1000 / {demo_comp}',
      names: const {'demo_sp': 'Velocidade desejada', 'demo_comp': 'Comprimento do rótulo'});
  final doubled = calc('c_dobro', 'Dobro', '{c_min} * 2');
  final fahrenheit = calc('c_f', 'Motor em °F', '{demo_temp} * 1,8 + 32', alarms: const [
    AlarmRule(id: 'al_f', kind: AlarmKind.above, limit: 80, priority: AlarmPriority.high, message: 'Motor quente'),
  ]);

  Project withCalcs(List<Tag> calcs) {
    final demo = DemoProject.build();
    return demo.copyWith(devices: [...demo.devices, CalcDevice.device], tags: [...demo.tags, ...calcs]);
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ihm_calc');
    client = SimulatedModbusClient(memory: DemoRegistry.forDevice(DemoProject.deviceId).memory, latency: Duration.zero);
    runtime = HmiRuntime(clientFactory: (_) => client);
    controller = ProjectController(repository: ProjectRepository(directory: dir), runtime: runtime);
    await controller.replace(withCalcs([perMinute, doubled, fahrenheit]));
  });

  tearDown(() async {
    await runtime.dispose();
    controller.dispose();
    DemoRegistry.discard(DemoProject.deviceId);
    try {
      await dir.delete(recursive: true);
    } on FileSystemException {/* Windows segurando o arquivo — é só a pasta temporária */}
  });

  Future<TagReading> until(String tagId, bool Function(TagReading) test, {int seconds = 4}) async {
    final n = runtime.watch(tagId);
    if (test(n.value)) return n.value;
    final c = Completer<TagReading>();
    void l() {
      if (test(n.value) && !c.isCompleted) c.complete(n.value);
    }

    n.addListener(l);
    try {
      return await c.future.timeout(Duration(seconds: seconds));
    } finally {
      n.removeListener(l);
    }
  }

  Future<void> untilAlarm(AlarmEngine engine, bool Function(AlarmEngine) test) async {
    if (test(engine)) return;
    final c = Completer<void>();
    void l() {
      if (test(engine) && !c.isCompleted) c.complete();
    }

    engine.addListener(l);
    try {
      await c.future.timeout(const Duration(seconds: 5));
    } finally {
      engine.removeListener(l);
    }
  }

  test('calculada em uso põe as entradas em uso e acompanha a gravação de uma delas', () async {
    runtime.subscribe(['c_min']);
    final first = await until('c_min', (r) => r.isGood);
    expect(first.value as double, closeTo(80 * 1000 / 120, 1e-9));
    expect(runtime.watch('demo_sp').value.isGood, isTrue, reason: 'a entrada foi lida sem ninguém pedir');
    expect(runtime.watch('demo_vel').value.quality, TagQuality.waiting, reason: 'o que a conta não usa continua sem ler');

    await runtime.write('demo_sp', 120);
    expect((await until('c_min', (r) => r.value == 1000.0)).value, 1000.0);
  });

  test('calculada que cita calculada: as duas calculam, na ordem certa', () async {
    runtime.subscribe(['c_dobro']);
    final r = await until('c_dobro', (r) => r.isGood);
    expect(r.value as double, closeTo(2 * 80 * 1000 / 120, 1e-9));
    expect(runtime.watch('c_min').value.isGood, isTrue);
  });

  test('alarme numa calculada dispara como em qualquer variável', () async {
    final engine = AlarmEngine(controller: controller, runtime: runtime, onDelay: const Duration(milliseconds: 200));
    addTearDown(engine.dispose);
    // 32 °C da demonstração = 89,6 °F, acima do limite de 80.
    await untilAlarm(engine, (e) => e.entries.any((a) => a.key == 'regra:c_f:al_f'));
    final a = engine.forTag('c_f')!;
    expect(a.message, 'Motor quente');
    expect(a.priority, AlarmPriority.high);
  });

  test('entrada sem comunicação → calculada sem comunicação, com o último valor; o alarme é do equipamento de verdade', () async {
    final engine = AlarmEngine(controller: controller, runtime: runtime, onDelay: const Duration(milliseconds: 100));
    addTearDown(engine.dispose);
    final good = await until('c_f', (r) => r.isGood);

    client.failureRate = 1;
    final lost = await until('c_f', (r) => r.quality == TagQuality.commLost);
    expect(lost.message, 'sem comunicação com Cortadora de rótulos');
    expect(lost.value, isA<double>(), reason: 'o último valor fica, esmaecido');
    expect((lost.value as double) - (good.value as double), lessThan(5), reason: 'nenhum número inventado');
    await untilAlarm(engine, (e) => e.entries.any((a) => a.key == 'com:${DemoProject.deviceId}'));
    expect(engine.entries.where((a) => a.key == 'com:${CalcDevice.id}'), isEmpty, reason: '"sem comunicação com Cálculos" não diria nada');
    expect(engine.entries.firstWhere((a) => a.isComm).message, 'Sem comunicação com Cortadora de rótulos');

    client.failureRate = 0;
    await until('c_f', (r) => r.isGood, seconds: 8);
    await untilAlarm(engine, (e) => e.entries.firstWhere((a) => a.isComm).phase == AlarmPhase.returnedUnack);
  });

  test('calculada é só leitura; "Lendo agora" calcula com as leituras do momento', () async {
    await expectLater(runtime.write('c_min', 3), throwsA(isA<TagValueError>().having((e) => e.message, 'msg', contains('só leitura'))));
    final sub = runtime.subscribe(['demo_sp', 'demo_comp']);
    await until('demo_comp', (r) => r.isGood);
    await until('demo_sp', (r) => r.isGood);
    expect(await runtime.readNow(perMinute.normalized()) as double, closeTo(666.67, 0.01));
    sub.cancel();
  });

  test('conta em círculo vinda de arquivo editado à mão vira erro, não trava', () async {
    await controller.replace(withCalcs([calc('p', 'P', '{q} + 1'), calc('q', 'Q', '{p} + 1')]));
    runtime.subscribe(['p']);
    final r = await until('p', (r) => r.quality == TagQuality.configError);
    expect(r.message, 'a conta fica em círculo');
  });

  test('variável que entra na conta é apagada: a calculada diz qual era', () async {
    runtime.subscribe(['c_min']);
    await until('c_min', (r) => r.isGood);
    controller.deleteTag('demo_comp');
    final r = await until('c_min', (r) => r.quality == TagQuality.configError);
    expect(r.message, 'A variável "Comprimento do rótulo" foi apagada');
  });
}
