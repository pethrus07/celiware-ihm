import '../../core/modbus/modbus_memory.dart';
import '../../models/device.dart';
import '../../models/hmi_screen.dart';
import '../../models/project.dart';
import '../../models/tag.dart';
import 'demo_process.dart';

/// Projeto que o app abre na primeira vez — e que "Restaurar demonstração"
/// recria.
///
/// Uma cortadora de rótulos simulada ([DemoProcess]) e duas telas: a de
/// **operação**, que usa todos os tipos de elemento, e o **resumo do líder**,
/// compacto. Serve de vitrine (Play Store, vídeo, feira) e de exemplo vivo:
/// quem abre o editor vê como cada elemento foi configurado.
///
/// IDs fixos de propósito: o tutorial aponta para esses elementos.
class DemoProject {
  DemoProject._();

  static const deviceId = 'demo_cortadora';
  static const operationScreenId = 'demo_tela_operacao';
  static const leaderScreenId = 'demo_tela_lider';

  static Project build() {
    const dev = Device(id: deviceId, name: 'Cortadora de rótulos', kind: DeviceKind.demo, pollMs: 300);

    Tag t(String id, String name, ModbusArea area, int address,
            {TagDataType type = TagDataType.uint16,
            bool writable = false,
            String unit = '',
            int decimals = 0,
            int length = 1,
            int bit = 0,
            String description = ''}) =>
        Tag(
          id: id,
          name: name,
          deviceId: deviceId,
          area: area,
          address: address,
          dataType: area.isBit ? TagDataType.bool : type,
          writable: writable,
          unit: unit,
          decimals: decimals,
          length: length,
          bitIndex: bit,
          description: description,
        );

    const hr = ModbusArea.holdingRegister;
    const coil = ModbusArea.coil;
    const di = ModbusArea.discreteInput;

    final tags = [
      t('demo_liga', 'Liga máquina', coil, DemoMap.coilRun, writable: true, description: 'Comando de partida/parada'),
      t('demo_reset', 'Reset de alarme', coil, DemoMap.coilResetAlarm, writable: true, description: 'Pulso: limpa o alarme depois que a causa sumiu'),
      t('demo_faca', 'Faca acionada', coil, DemoMap.coilKnife),
      t('demo_alarme', 'Alarme ativo', coil, DemoMap.coilAlarm),
      t('demo_porta', 'Porta fechada', di, DemoMap.diDoorClosed),
      t('demo_papel', 'Papel presente', di, DemoMap.diPaperPresent),
      t('demo_status', 'Status da máquina', hr, DemoMap.hrStatus, description: '0 parada · 1 em ciclo · 2 alarme'),
      t('demo_sp', 'Velocidade desejada', hr, DemoMap.hrSpeedSetpoint, writable: true, unit: 'm/min'),
      t('demo_vel', 'Velocidade', hr, DemoMap.hrSpeed, unit: 'm/min'),
      t('demo_prod', 'Rótulos cortados', hr, DemoMap.hrProduction, type: TagDataType.uint32, unit: 'un'),
      t('demo_comp', 'Comprimento do rótulo', hr, DemoMap.hrLabelLength, writable: true, unit: 'mm'),
      t('demo_temp', 'Temperatura do motor', hr, DemoMap.hrMotorTemp, type: TagDataType.float32, unit: '°C', decimals: 1),
      t('demo_tensao', 'Tensão do papel', hr, DemoMap.hrTension, unit: '%'),
      t('demo_hora', 'Produção por hora', hr, DemoMap.hrHourly, length: DemoMap.hourlyBuckets, unit: 'un',
          description: 'Lista: 8 registradores seguidos, um por hora do turno'),
      t('demo_codalarme', 'Código do alarme', hr, DemoMap.hrAlarmCode),
      t('demo_bit_ciclo', 'Em ciclo (bit da palavra)', hr, DemoMap.hrStatusWord, type: TagDataType.bool, bit: 0,
          description: 'Exemplo de bit dentro de registrador: HR 30, bit 0'),
    ];

    const statusStates = [
      {'value': 0, 'text': 'PARADA', 'color': 'neutral'},
      {'value': 1, 'text': 'EM CICLO', 'color': 'green'},
      {'value': 2, 'text': 'ALARME', 'color': 'red'},
    ];

    HmiElement e(String id, ElementType type, int x, int y, int w, int h, Map<String, dynamic> props) =>
        HmiElement(id: id, type: type, x: x, y: y, w: w, h: h, props: props);

    final operation = HmiScreen(
      id: operationScreenId,
      name: 'Cortadora — operação',
      // 14 elementos, em blocos de leitura natural: estado → comando →
      // ajuste → saúde da máquina → histórico. Sem título repetido (o nome da
      // tela já está no topo) e sem dado redundante.
      elements: [
        e('op_status', ElementType.multistate, 0, 0, 3, 2, {'tagId': 'demo_status', 'label': 'Status', 'states': statusStates}),
        e('op_vel', ElementType.value, 3, 0, 3, 2, {'tagId': 'demo_vel', 'label': 'Velocidade'}),
        e('op_liga', ElementType.button, 0, 2, 2, 2, {'tagId': 'demo_liga', 'label': 'Liga', 'mode': 'toggle', 'color': 'green'}),
        e('op_reset', ElementType.button, 2, 2, 2, 2, {'tagId': 'demo_reset', 'label': 'Reset', 'mode': 'momentary', 'color': 'amber'}),
        e('op_alarme', ElementType.lamp, 4, 2, 2, 2, {'tagId': 'demo_alarme', 'label': 'Alarme', 'onText': 'ATIVO', 'offText': 'OK', 'color': 'red'}),
        e('op_sp', ElementType.input, 0, 4, 3, 2, {'tagId': 'demo_sp', 'label': 'Ajuste de velocidade', 'min': 0, 'max': 150}),
        e('op_prod', ElementType.value, 3, 4, 3, 2, {'tagId': 'demo_prod', 'label': 'Produção'}),
        e('op_temp', ElementType.gauge, 0, 6, 3, 3, {'tagId': 'demo_temp', 'label': 'Motor', 'min': 0, 'max': 100, 'warn': 75, 'alarm': 85}),
        e('op_porta', ElementType.lamp, 3, 6, 3, 1, {'tagId': 'demo_porta', 'label': 'Porta', 'onText': 'FECHADA', 'offText': 'ABERTA', 'color': 'green'}),
        e('op_faca', ElementType.lamp, 3, 7, 3, 1, {'tagId': 'demo_faca', 'label': 'Faca', 'onText': 'CORTANDO', 'offText': 'PARADA', 'color': 'green'}),
        e('op_papel', ElementType.lamp, 3, 8, 3, 1, {'tagId': 'demo_papel', 'label': 'Papel', 'onText': 'PRESENTE', 'offText': 'FALTA', 'color': 'green'}),
        // Barra pede largura: numa coluna de 3 células ela virava um toquinho.
        e('op_tensao', ElementType.bar, 0, 9, 6, 1, {'tagId': 'demo_tensao', 'label': 'Tensão do papel', 'min': 0, 'max': 100}),
        e('op_trend', ElementType.trend, 0, 10, 6, 4, {'tagIds': ['demo_vel', 'demo_temp'], 'label': 'Últimos 2 minutos', 'windowSec': 120}),
        e('op_hora', ElementType.barChart, 0, 14, 6, 3, {'tagId': 'demo_hora', 'label': 'Produção por hora'}),
      ],
    );

    final leader = HmiScreen(
      id: leaderScreenId,
      name: 'Resumo do líder',
      readOnly: true,
      elements: [
        e('li_status', ElementType.multistate, 0, 0, 3, 2, {'tagId': 'demo_status', 'label': 'Cortadora', 'states': statusStates}),
        e('li_vel', ElementType.value, 3, 0, 3, 2, {'tagId': 'demo_vel', 'label': 'Velocidade'}),
        e('li_prod', ElementType.value, 0, 2, 3, 2, {'tagId': 'demo_prod', 'label': 'Produção'}),
        e('li_temp', ElementType.value, 3, 2, 3, 2, {'tagId': 'demo_temp', 'label': 'Motor'}),
        e('li_alarme', ElementType.lamp, 0, 4, 3, 1, {'tagId': 'demo_alarme', 'label': 'Alarme', 'onText': 'ATIVO', 'offText': 'OK', 'color': 'red'}),
        e('li_ciclo', ElementType.lamp, 3, 4, 3, 1, {'tagId': 'demo_bit_ciclo', 'label': 'Ciclo', 'onText': 'SIM', 'offText': 'NÃO', 'color': 'green'}),
      ],
    );

    return Project(name: 'Demonstração', devices: const [dev], tags: tags, screens: [operation, leader]);
  }
}
