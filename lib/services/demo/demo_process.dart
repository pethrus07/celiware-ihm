import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import '../../core/modbus/modbus_memory.dart';

/// Mapa de memória da máquina de demonstração ("Cortadora de rótulos").
///
/// É o contrato entre o [DemoProcess] (o "programa do CLP") e o projeto de
/// demonstração ([DemoProject]). Mantido num lugar só para os dois lados não
/// divergirem.
class DemoMap {
  DemoMap._();

  // Coils (comandos e estados)
  static const coilRun = 0; // Liga/desliga a máquina (comando)
  static const coilResetAlarm = 1; // Reset de alarme (pulso)
  static const coilKnife = 3; // Faca acionada (estado, pisca em ciclo)
  static const coilInCycle = 10; // Em ciclo
  static const coilAlarm = 11; // Alarme ativo

  // Entradas discretas (sensores)
  static const diDoorClosed = 0;
  static const diEmergencyOk = 1;
  static const diPaperPresent = 2;

  // Holding registers
  static const hrStatus = 0; // 0 parada · 1 em ciclo · 2 alarme
  static const hrSpeedSetpoint = 1; // m/min (gravável)
  static const hrSpeed = 2; // m/min
  static const hrProduction = 3; // UINT32 (3..4), rótulos cortados
  static const hrLabelLength = 5; // mm (gravável)
  static const hrMotorTemp = 6; // FLOAT32 (6..7), °C
  static const hrTension = 8; // % tensão do papel
  static const hrHourly = 10; // 8 registradores (10..17), produção por hora
  static const hrAlarmCode = 20; // 0 nenhum · 1 sobretemperatura · 2 porta aberta
  static const hrStatusWord = 30; // bits: 0 em ciclo · 1 alarme · 2 porta fechada

  // Input registers
  static const irUptimeMinutes = 0;

  static const hourlyBuckets = 8;
  static const tempAlarm = 85.0;
  static const tempReset = 80.0;
}

/// O "programa do CLP" da máquina de demonstração.
///
/// Roda num timer enquanto a sessão da máquina estiver ativa e mexe na
/// [ModbusMemory] como um CLP real mexeria nos próprios dados. Os comandos
/// chegam pelo protocolo (o app escreve coils/registradores) e as reações
/// aparecem na próxima leitura — o mesmo ciclo de uma máquina de verdade.
///
/// Comportamento:
///   • "Liga" (coil 0) + porta fechada + sem alarme → a velocidade sobe em
///     rampa até o setpoint (HR 1) e a produção conta conforme velocidade e
///     comprimento do rótulo (HR 5);
///   • o motor esquenta com a velocidade; passando de 85 °C dispara o alarme
///     de sobretemperatura e a máquina para sozinha;
///   • o reset (coil 1) só limpa o alarme depois que esfriou abaixo de 80 °C —
///     dá para demonstrar o fluxo completo de alarme só com o celular.
class DemoProcess {
  DemoProcess(this.memory, {Random? random, this.tick = const Duration(milliseconds: 200)})
      : _rng = random ?? Random();

  final ModbusMemory memory;
  final Duration tick;
  final Random _rng;

  Timer? _timer;
  double _speed = 0;
  double _temp = 32;
  double _production = 0;
  double _hourFraction = 0;
  double _uptimeSeconds = 0;
  double _tension = 50;
  int _knifeTicks = 0;

  bool get isRunning => _timer != null;

  /// Valores iniciais plausíveis — a demonstração abre com cara de fábrica.
  void seed() {
    memory.pokeRegister(ModbusArea.holdingRegister, DemoMap.hrSpeedSetpoint, 80);
    memory.pokeRegister(ModbusArea.holdingRegister, DemoMap.hrLabelLength, 120);
    memory.pokeBit(ModbusArea.discreteInput, DemoMap.diDoorClosed, true);
    memory.pokeBit(ModbusArea.discreteInput, DemoMap.diEmergencyOk, true);
    memory.pokeBit(ModbusArea.discreteInput, DemoMap.diPaperPresent, true);
    _production = 18240;
    for (var i = 0; i < DemoMap.hourlyBuckets - 1; i++) {
      memory.pokeRegister(ModbusArea.holdingRegister, DemoMap.hrHourly + i,
          2300 + _rng.nextInt(600));
    }
    _writeOutputs();
  }

  void start() {
    _timer ??= Timer.periodic(tick, (_) => step(tick.inMicroseconds / 1e6));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Um ciclo de varredura do "CLP". Público para os testes avançarem o tempo
  /// sem esperar o relógio.
  void step(double dt) {
    final m = memory;
    final run = m.bit(ModbusArea.coil, DemoMap.coilRun);
    final doorClosed = m.bit(ModbusArea.discreteInput, DemoMap.diDoorClosed);
    var alarmCode = m.register(ModbusArea.holdingRegister, DemoMap.hrAlarmCode);

    // Reset de alarme: pulso — o programa consome o bit.
    if (m.bit(ModbusArea.coil, DemoMap.coilResetAlarm)) {
      if (alarmCode == 1 && _temp < DemoMap.tempReset) alarmCode = 0;
      if (alarmCode == 2 && doorClosed) alarmCode = 0;
      m.pokeBit(ModbusArea.coil, DemoMap.coilResetAlarm, false);
    }
    if (!doorClosed && run) alarmCode = 2;

    final inCycle = run && doorClosed && alarmCode == 0;
    final setpoint = m.register(ModbusArea.holdingRegister, DemoMap.hrSpeedSetpoint).clamp(0, 200);
    final target = inCycle ? setpoint.toDouble() : 0.0;
    const ramp = 25.0; // m/min por segundo
    _speed += (target - _speed).clamp(-ramp * dt, ramp * dt);
    if (_speed.abs() < 0.05) _speed = 0;

    final length = m.register(ModbusArea.holdingRegister, DemoMap.hrLabelLength).clamp(10, 2000);
    final cut = _speed * 1000 / length / 60 * dt; // rótulos neste ciclo
    _production += cut;
    _hourFraction += cut;
    if (_hourFraction >= 1) {
      final whole = _hourFraction.floor();
      _hourFraction -= whole;
      final hourIdx = DemoMap.hrHourly + DemoMap.hourlyBuckets - 1;
      m.pokeRegister(ModbusArea.holdingRegister, hourIdx,
          m.register(ModbusArea.holdingRegister, hourIdx) + whole);
    }

    final tempTarget = 32 + _speed * 0.62;
    // Constante de tempo ~45 s: aquece devagar como motor de verdade, e a curva
    // no gráfico de tendência fica visível em vez de um degrau.
    _temp += (tempTarget - _temp) * (dt / 45) + (_rng.nextDouble() - 0.5) * 0.08;
    if (_temp > DemoMap.tempAlarm) alarmCode = 1;

    _tension += ((inCycle ? 62 : 48) - _tension) * 0.05 + (_rng.nextDouble() - 0.5) * 1.2;
    if (inCycle) {
      _uptimeSeconds += dt;
      _knifeTicks++;
    }

    m.pokeRegister(ModbusArea.holdingRegister, DemoMap.hrAlarmCode, alarmCode);
    _writeOutputs(inCycle: inCycle, alarm: alarmCode != 0, doorClosed: doorClosed);
  }

  void _writeOutputs({bool inCycle = false, bool alarm = false, bool doorClosed = true}) {
    final m = memory;
    m.pokeRegister(ModbusArea.holdingRegister, DemoMap.hrStatus, alarm ? 2 : (inCycle ? 1 : 0));
    m.pokeRegister(ModbusArea.holdingRegister, DemoMap.hrSpeed, _speed.round());
    final prod = _production.floor();
    m.pokeRegisters(ModbusArea.holdingRegister, DemoMap.hrProduction, [(prod >> 16) & 0xFFFF, prod & 0xFFFF]);
    final f = ByteData(4)..setFloat32(0, _temp);
    m.pokeRegisters(ModbusArea.holdingRegister, DemoMap.hrMotorTemp, [f.getUint16(0), f.getUint16(2)]);
    m.pokeRegister(ModbusArea.holdingRegister, DemoMap.hrTension, _tension.round().clamp(0, 100));
    m.pokeRegister(ModbusArea.holdingRegister, DemoMap.hrStatusWord,
        (inCycle ? 1 : 0) | (alarm ? 2 : 0) | (doorClosed ? 4 : 0));
    m.pokeRegister(ModbusArea.inputRegister, DemoMap.irUptimeMinutes, (_uptimeSeconds / 60).floor());
    m.pokeBit(ModbusArea.coil, DemoMap.coilInCycle, inCycle);
    m.pokeBit(ModbusArea.coil, DemoMap.coilAlarm, alarm);
    m.pokeBit(ModbusArea.coil, DemoMap.coilKnife, inCycle && _speed > 1 && (_knifeTicks ~/ 2).isEven);
    m.pokeBit(ModbusArea.discreteInput, DemoMap.diPaperPresent, true);
  }
}

/// Uma memória + processo por máquina de demonstração, vivos enquanto o app
/// estiver aberto — sair e voltar da tela não zera a produção.
class DemoRegistry {
  DemoRegistry._();

  static final Map<String, DemoProcess> _processes = {};

  static DemoProcess forDevice(String deviceId) => _processes.putIfAbsent(deviceId, () {
        final p = DemoProcess(ModbusMemory(
            coils: 1000, discreteInputs: 1000, holdingRegisters: 1000, inputRegisters: 1000));
        p.seed();
        return p;
      });

  static void discard(String deviceId) => _processes.remove(deviceId)?.stop();
}
