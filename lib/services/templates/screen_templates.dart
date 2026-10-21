// Modelos prontos de tela (itens 28, 161, 162, 165, 166 e 167 da lista do
// cliente; Máquina com modo e OEE e o I/O de CLP pedidos na reunião de
// 19/10/2026): "Nova tela" começa de um destes, ou em branco. Os projetos
// prontos (`ready_projects.dart`) montam as telas deles com as mesmas peças.
//
// Só dados. Cada modelo diz **quais variáveis** a tela usa e **onde cada
// elemento fica** na grade fina (12 colunas); quem transforma isso em tela e
// variáveis de verdade, num equipamento, é o `TemplateBuilder`
// (`template_builder.dart`). Para acrescentar um modelo: um `ScreenTemplate`
// novo aqui e a entrada em [ScreenTemplates.all] — os testes conferem
// sozinhos que ele cabe na grade, não sobrepõe nada e que cada elemento aceita
// a variável que recebeu (`test/services/screen_templates_test.dart`), e que a
// tela aparece inteira, legível e tocável de 320 dp ao tablet, claro e escuro,
// em todos os estados (`test/widgets/screen_templates_render_test.dart`).
//
// Regras de quem monta um modelo:
//   • posição e tamanho em células da grade fina (12 colunas);
//   • quem grava (botão, ajuste) tem pelo menos 3×3 — 68 dp no celular de
//     320 dp, acima dos 48 dp de alvo de toque;
//   • elemento de meia largura com rótulo tem 4 de altura: com 3, no celular
//     de 320 dp o rótulo vai para o lado e não cabe ("VELOC…");
//   • cor só para estado (ISA-101): verde = em operação, vermelho = falha ou
//     alarme, amarelo = atenção; comando que não mostra estado fica neutro;
//   • **nenhum endereço inventado**: o endereço só vem do mapa da marca
//     ([TemplateTag.map] → `VendorProfile.templates`); sem mapa, a variável
//     nasce com o endereço a configurar (`Tag.addressPending`).

import 'package:flutter/material.dart' show IconData, Icons;

import '../../core/modbus/modbus_memory.dart';
import '../../models/alarm.dart';
import '../../models/hmi_screen.dart';
import '../../models/tag.dart';

/// Como o modelo comanda o acionamento (inversor, servo).
enum CommandStyle {
  /// Bits separados — liga, sentido, reset — com o endereço a configurar.
  /// Serve para qualquer equipamento: é o CLP que repassa ao acionamento.
  bits,

  /// Palavra de comando do inversor ("Comando": 1 avante, 2 reverso…) com os
  /// endereços do mapa da marca. Só com perfil de inversor que tenha o mapa
  /// e os códigos em [ScreenTemplates.driveCodes].
  word,
}

/// O que o botão grava na palavra de comando; o número de cada marca vem de
/// [DriveCodes].
enum DriveCommand { forward, reverse, stop, reset }

/// Alarme que a variável nova já traz (variável reaproveitada fica como está).
class TemplateAlarm {
  const TemplateAlarm(this.kind, this.message, {this.limit = 0, this.priority = AlarmPriority.medium});
  final AlarmKind kind;
  final String message;
  final double limit;
  final AlarmPriority priority;
}

/// Uma variável que o modelo cria — ou reaproveita, se o equipamento já tem.
class TemplateTag {
  const TemplateTag(
    this.key,
    this.name, {
    this.type = TagDataType.float32,
    this.writable = false,
    this.unit = '',
    this.decimals = 0,
    this.length = 1,
    this.description = '',
    this.map,
    this.alarms = const [],
    this.only,
    this.area,
  });

  /// Como os elementos do modelo se referem a ela.
  final String key;
  final String name;
  final TagDataType type;
  final bool writable;
  final String unit;
  final int decimals;

  /// Registradores (só texto: 2 letras em cada).
  final int length;
  final String description;

  /// Chave do modelo de variável do perfil de inversor (`TagTemplate.key`:
  /// 'comando', 'referencia', 'estado', 'falha'…). Quando o perfil do
  /// equipamento tem essa chave, a variável vem de lá, com o endereço do
  /// manual; senão, nasce com o endereço a configurar. Chave que nenhum perfil
  /// tem ainda ('frequencia', 'corrente'…) passa a valer sozinha no dia em que
  /// o mapa ganhar a entrada.
  final String? map;
  final List<TemplateAlarm> alarms;

  /// Só existe num dos jeitos de comandar (nulo = nos dois).
  final CommandStyle? only;

  /// Onde a variável sem mapa nasce. Nulo = o mais provável pelo tipo (coil
  /// para liga/desliga, holding para número); entrada física de CLP pede
  /// `discreteInput`. Só o tipo de memória: o endereço continua a configurar.
  final ModbusArea? area;
}

/// Um elemento do modelo, em células da grade fina.
class TemplateElement {
  const TemplateElement(
    this.type,
    this.x,
    this.y,
    this.w,
    this.h, {
    this.tag,
    this.feedback,
    this.tags = const [],
    this.props = const {},
    this.command,
    this.driveStates = false,
    this.only,
  });

  final ElementType type;
  final int x;
  final int y;
  final int w;
  final int h;

  /// Variável principal ([TemplateTag.key]) → `tagId`.
  final String? tag;

  /// Retorno do botão → `feedbackTagId`.
  final String? feedback;

  /// Curvas da tendência → `tagIds`.
  final List<String> tags;

  /// O resto da configuração, como no `ElementCatalog` (rótulo, modo, faixas…).
  final Map<String, Object> props;

  /// Botão "grava um valor" na palavra de comando: o valor da marca.
  final DriveCommand? command;

  /// Indicador de estado com os estados da marca ([DriveCodes.states]).
  final bool driveStates;
  final CommandStyle? only;

  int get right => x + w;
  int get bottom => y + h;
}

/// Um modelo de tela.
class ScreenTemplate {
  const ScreenTemplate({
    required this.id,
    required this.name,
    required this.description,
    required this.icon,
    this.tags = const [],
    this.elements = const [],
    this.driveMap = false,
  });

  /// Estável (testes, chaves da interface). Nunca muda.
  final String id;
  final String name;

  /// Uma frase: o que vem na tela.
  final String description;
  final IconData icon;
  final List<TemplateTag> tags;
  final List<TemplateElement> elements;

  /// Usa o mapa de inversor do perfil do equipamento. Fica de fora do servo:
  /// os perfis de hoje são de inversor (MD500, GD20), e o endereço de um não
  /// serve no outro.
  final bool driveMap;

  bool get isBlank => elements.isEmpty;

  /// Tem o jeito de comandar pela palavra do inversor.
  bool get hasWordStyle => elements.any((e) => e.only == CommandStyle.word);

  /// Grade dos modelos: a fina.
  static const columns = HmiScreen.fineColumns;
}

/// Palavra de comando e estados de um inversor com mapa — do mesmo manual do
/// mapa (`docs/pesquisa-etapa4/2-mapas-de-memoria-e-importacao.md` §1.7, e a
/// descrição de cada modelo de variável em `VendorProfiles`).
class DriveCodes {
  const DriveCodes({required this.forward, required this.reverse, required this.stop, required this.reset, required this.states});
  final int forward;
  final int reverse;

  /// Parada em rampa (a livre deixa o motor girar solto).
  final int stop;
  final int reset;

  /// Estados da variável "Estado", no formato do indicador de estado.
  final List<Map<String, Object>> states;

  int valueOf(DriveCommand c) => switch (c) {
        DriveCommand.forward => forward,
        DriveCommand.reverse => reverse,
        DriveCommand.stop => stop,
        DriveCommand.reset => reset,
      };
}

// ── Peças comuns ───────────────────────────────────────────────────────────────

const _bool = TagDataType.bool;
const _code = TagDataType.uint16;
const _count = TagDataType.uint32;
const _number = TagDataType.float32;

const _neutral = 'neutral';

const _faultStates = [
  {'value': 0, 'text': 'SEM FALHA', 'color': _neutral},
];

/// Acionamento (inversor ou servo), parte básica: estado e falha no alto,
/// comandos, referência ao lado do valor real, corrente embaixo — a ordem
/// de leitura de quem opera (como está → o que faço → como responde).
List<TemplateTag> _driveBasicTags({required String what, required String running, required String refName, required String realName, required String realKey, required String unit, required int decimals}) => [
      // Comando por bits (genérico).
      TemplateTag('liga', 'Liga $what', type: _bool, writable: true, description: 'Comando de partida e parada', only: CommandStyle.bits),
      TemplateTag('emOperacao', '${_capital(what)} em operação', type: _bool, description: 'Retorno: o $what confirma que está $running', only: CommandStyle.bits),
      const TemplateTag('sentido', 'Sentido reverso', type: _bool, writable: true, description: 'Ligado = reverso; desligado = avante', only: CommandStyle.bits),
      const TemplateTag('reset', 'Reset de falha', type: _bool, writable: true, description: 'Pulso: limpa a falha depois que a causa sumiu', only: CommandStyle.bits),
      TemplateTag('falha', 'Falha do $what', type: _bool, alarms: [TemplateAlarm(AlarmKind.on, 'Falha no $what', priority: AlarmPriority.high)], only: CommandStyle.bits),
      // Comando pela palavra do inversor (mapa da marca).
      const TemplateTag('comando', 'Comando', type: _code, writable: true, map: 'comando', only: CommandStyle.word),
      const TemplateTag('estado', 'Estado', type: _code, map: 'estado', only: CommandStyle.word),
      const TemplateTag('codigoFalha', 'Falha', type: _code, map: 'falha',
          alarms: [TemplateAlarm(AlarmKind.above, 'Falha no inversor', priority: AlarmPriority.high)], only: CommandStyle.word),
      // Nos dois.
      TemplateTag('referencia', refName, type: _number, writable: true, unit: unit, decimals: decimals, map: 'referencia'),
      TemplateTag(realKey, realName, type: _number, unit: unit, decimals: decimals, map: realKey),
      const TemplateTag('corrente', 'Corrente do motor', type: _number, unit: 'A', decimals: 1, map: 'corrente'),
    ];

List<TemplateElement> _driveBasicElements({required String motorLabel, required String onText, required String realKey, required String realLabel}) => [
      // Como está.
      const TemplateElement(ElementType.multistate, 0, 0, 6, 4, tag: 'estado', driveStates: true, props: {'label': 'Estado'}, only: CommandStyle.word),
      const TemplateElement(ElementType.multistate, 6, 0, 6, 4, tag: 'codigoFalha', props: {'label': 'Falha', 'states': _faultStates}, only: CommandStyle.word),
      TemplateElement(ElementType.lamp, 0, 0, 6, 4,
          tag: 'emOperacao', props: {'label': motorLabel, 'onText': onText, 'offText': 'PARADO', 'color': 'green'}, only: CommandStyle.bits),
      const TemplateElement(ElementType.lamp, 6, 0, 6, 4,
          tag: 'falha', props: {'label': 'Falha', 'onText': 'ATIVA', 'offText': 'OK', 'color': 'red'}, only: CommandStyle.bits),
      // O que faço.
      for (final (i, cmd, label) in [(0, DriveCommand.forward, 'Avante'), (1, DriveCommand.reverse, 'Reverso'), (2, DriveCommand.stop, 'Parar'), (3, DriveCommand.reset, 'Reset')])
        TemplateElement(ElementType.button, i * 3, 4, 3, 3,
            tag: 'comando', command: cmd, props: {'label': label, 'mode': 'value', 'color': cmd == DriveCommand.reset ? 'amber' : _neutral}, only: CommandStyle.word),
      const TemplateElement(ElementType.button, 0, 4, 4, 3,
          tag: 'liga', feedback: 'emOperacao', props: {'label': 'Liga', 'mode': 'toggle', 'color': 'green'}, only: CommandStyle.bits),
      const TemplateElement(ElementType.button, 4, 4, 4, 3, tag: 'sentido', props: {'label': 'Reverso', 'mode': 'toggle', 'color': _neutral}, only: CommandStyle.bits),
      const TemplateElement(ElementType.button, 8, 4, 4, 3, tag: 'reset', props: {'label': 'Reset', 'mode': 'momentary', 'color': 'amber'}, only: CommandStyle.bits),
      // Como responde.
      const TemplateElement(ElementType.input, 0, 7, 6, 4, tag: 'referencia', props: {'label': 'Referência', 'min': 0}),
      TemplateElement(ElementType.value, 6, 7, 6, 4, tag: realKey, props: {'label': realLabel}),
      const TemplateElement(ElementType.value, 0, 11, 12, 3, tag: 'corrente', props: {'label': 'Corrente'}),
    ];

/// Parte do completo: rampas, torque, barramento, temperatura, horas e a
/// última falha, abaixo do básico (que acaba na linha 14).
List<TemplateTag> _driveFullTags({required String what, required String rampUnit}) => [
      TemplateTag('aceleracao', 'Tempo de aceleração', type: _number, writable: true, unit: rampUnit, decimals: rampUnit == 's' ? 1 : 0, map: 'aceleracao'),
      TemplateTag('desaceleracao', 'Tempo de desaceleração', type: _number, writable: true, unit: rampUnit, decimals: rampUnit == 's' ? 1 : 0, map: 'desaceleracao'),
      const TemplateTag('torque', 'Torque', type: _number, unit: '%', decimals: 1, map: 'torque'),
      const TemplateTag('barramento', 'Tensão do barramento', type: _number, unit: 'V', map: 'barramento'),
      TemplateTag('temperatura', 'Temperatura do $what', type: _number, unit: '°C', decimals: 1, map: 'temperatura'),
      const TemplateTag('horas', 'Horas de operação', type: _count, unit: 'h', map: 'horas'),
      const TemplateTag('ultimaFalha', 'Código da última falha', type: _code, map: 'ultimaFalha'),
    ];

const _driveFullElements = [
  TemplateElement(ElementType.input, 0, 14, 6, 4, tag: 'aceleracao', props: {'label': 'Aceleração', 'min': 0}),
  TemplateElement(ElementType.input, 6, 14, 6, 4, tag: 'desaceleracao', props: {'label': 'Desaceleração', 'min': 0}),
  TemplateElement(ElementType.value, 0, 18, 6, 4, tag: 'torque', props: {'label': 'Torque'}),
  TemplateElement(ElementType.value, 6, 18, 6, 4, tag: 'barramento', props: {'label': 'Barramento'}),
  TemplateElement(ElementType.value, 0, 22, 6, 4, tag: 'temperatura', props: {'label': 'Temperatura'}),
  TemplateElement(ElementType.value, 6, 22, 6, 4, tag: 'horas', props: {'label': 'Horas'}),
  TemplateElement(ElementType.value, 0, 26, 12, 3, tag: 'ultimaFalha', props: {'label': 'Última falha'}),
];

List<TemplateTag> _inverterTags({required bool full}) => [
      ..._driveBasicTags(what: 'inversor', running: 'girando', refName: 'Referência de frequência', realName: 'Frequência de saída', realKey: 'frequencia', unit: 'Hz', decimals: 2),
      if (full) ..._driveFullTags(what: 'inversor', rampUnit: 's'),
    ];

List<TemplateElement> _inverterElements({required bool full}) => [
      ..._driveBasicElements(motorLabel: 'Motor', onText: 'GIRANDO', realKey: 'frequencia', realLabel: 'Frequência'),
      if (full) ..._driveFullElements,
    ];

List<TemplateTag> _servoTags({required bool full}) => [
      ..._driveBasicTags(what: 'servo', running: 'ligado', refName: 'Referência de velocidade', realName: 'Velocidade real', realKey: 'velocidade', unit: 'rpm', decimals: 0)
          .where((t) => t.only != CommandStyle.word),
      if (full) ..._driveFullTags(what: 'servo', rampUnit: 'ms'),
    ];

List<TemplateElement> _servoElements({required bool full}) => [
      ..._driveBasicElements(motorLabel: 'Servo', onText: 'LIGADO', realKey: 'velocidade', realLabel: 'Velocidade').where((e) => e.only != CommandStyle.word),
      if (full) ..._driveFullElements,
    ];

String _capital(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

// ── Catálogo ───────────────────────────────────────────────────────────────────

/// Todos os modelos, na ordem da escolha. "Em branco" primeiro: é o de hoje.
abstract final class ScreenTemplates {
  static const blank = ScreenTemplate(
    id: 'em-branco',
    name: 'Em branco',
    description: 'Tela vazia: você põe cada elemento.',
    icon: Icons.crop_square_rounded,
  );

  /// Estados da variável "Estado da máquina" (códigos a ajustar aos do CLP).
  static const machineStates = [
    {'value': 0, 'text': 'PARADA', 'color': _neutral},
    {'value': 1, 'text': 'EM OPERAÇÃO', 'color': 'green'},
    {'value': 2, 'text': 'ALARME', 'color': 'red'},
  ];

  /// "Em automático" (liga/desliga) como estado: desligado = MANUAL. Azul
  /// (informação) no automático: é modo, não falha nem marcha.
  static const modeStates = [
    {'value': 0, 'text': 'MANUAL', 'color': _neutral},
    {'value': 1, 'text': 'AUTOMÁTICO', 'color': 'blue'},
  ];

  /// O OEE como o app já usa (`ElementCatalog.defaultProps`): calculado no
  /// app pelas três parcelas, de 0 a 100, sem faixa inventada.
  static const oeeProps = {'label': 'OEE', 'source': 'calc', 'scale': 'percent'};

  /// Item 28: máquina genérica. Na reunião de 19/10/2026 ganhou o modo
  /// (manual ou automático, só leitura — o comando de troca de modo é do
  /// painel da máquina) e o OEE.
  static const machine = ScreenTemplate(
    id: 'maquina',
    name: 'Máquina',
    description: 'Estado, modo, liga com retorno, velocidade, produção, alarme e OEE.',
    icon: Icons.precision_manufacturing_outlined,
    tags: [
      TemplateTag('estado', 'Estado da máquina', type: _code, description: '0 parada · 1 em operação · 2 alarme — ajuste aos códigos do CLP'),
      TemplateTag('emAutomatico', 'Em automático', type: _bool, description: 'Ligado = automático; desligado = manual'),
      TemplateTag('liga', 'Liga máquina', type: _bool, writable: true, description: 'Comando de partida e parada'),
      TemplateTag('emOperacao', 'Máquina em operação', type: _bool, description: 'Retorno: a máquina confirma que partiu'),
      TemplateTag('reset', 'Reset de alarme', type: _bool, writable: true, description: 'Pulso: limpa o alarme depois que a causa sumiu'),
      TemplateTag('velocidade', 'Velocidade', type: _number, decimals: 1),
      TemplateTag('ajusteVelocidade', 'Ajuste de velocidade', type: _number, writable: true, decimals: 1),
      TemplateTag('producao', 'Produção', type: _count, unit: 'un'),
      TemplateTag('alarme', 'Alarme da máquina', type: _bool, alarms: [TemplateAlarm(AlarmKind.on, 'Máquina em alarme')]),
      TemplateTag('disponibilidade', 'Disponibilidade', unit: '%', decimals: 1, description: 'Parcela do OEE: tempo produzindo ÷ tempo planejado'),
      TemplateTag('desempenho', 'Desempenho', unit: '%', decimals: 1, description: 'Parcela do OEE: produção real ÷ produção no ritmo ideal'),
      TemplateTag('qualidade', 'Qualidade', unit: '%', decimals: 1, description: 'Parcela do OEE: peças boas ÷ peças feitas'),
    ],
    elements: [
      // Como está.
      TemplateElement(ElementType.multistate, 0, 0, 12, 3, tag: 'estado', props: {'label': 'Estado', 'states': machineStates}),
      TemplateElement(ElementType.multistate, 0, 3, 6, 4, tag: 'emAutomatico', props: {'label': 'Modo', 'states': modeStates}),
      TemplateElement(ElementType.lamp, 6, 3, 6, 4, tag: 'alarme', props: {'label': 'Alarme', 'onText': 'ATIVO', 'offText': 'OK', 'color': 'red'}),
      // O que faço.
      TemplateElement(ElementType.button, 0, 7, 6, 4, tag: 'liga', feedback: 'emOperacao', props: {'label': 'Liga', 'mode': 'toggle', 'color': 'green'}),
      TemplateElement(ElementType.button, 6, 7, 6, 4, tag: 'reset', props: {'label': 'Reset', 'mode': 'momentary', 'color': 'amber'}),
      // Como responde.
      TemplateElement(ElementType.value, 0, 11, 6, 4, tag: 'velocidade', props: {'label': 'Velocidade'}),
      TemplateElement(ElementType.input, 6, 11, 6, 4, tag: 'ajusteVelocidade', props: {'label': 'Ajuste', 'min': 0}),
      TemplateElement(ElementType.value, 0, 15, 12, 3, tag: 'producao', props: {'label': 'Produção'}),
      // Largura toda e 6 de altura: o tamanho com que o OEE nasce na grade fina.
      TemplateElement(ElementType.oee, 0, 18, 12, 6, tags: ['disponibilidade', 'desempenho', 'qualidade'], props: oeeProps),
    ],
  );

  /// I/O de CLP (reunião de 19/10/2026): uma lâmpada por entrada e por
  /// saída, só para ligar as memórias e ver o estado. Saída também em
  /// lâmpada, e não em botão: o programa do CLP reescreve a saída a cada
  /// ciclo, e forçar saída é com o CLP em manutenção, não pela tela.
  static final io8 = _io('io-8', 8);
  static final io16 = _io('io-16', 16);

  static ScreenTemplate _io(String id, int n) {
    // Duas por linha, 6×4: com quatro por linha (3×4), no celular de 320 dp,
    // "DESLIGADA" e "A configurar" encolhiam abaixo de 10 dp.
    List<TemplateElement> lamps(String prefix, String key, int top) => [
          for (var i = 0; i < n; i++)
            TemplateElement(ElementType.lamp, (i % 2) * 6, top + (i ~/ 2) * 4, 6, 4,
                tag: '$key$i', props: {'label': '$prefix$i', 'onText': 'LIGADA', 'offText': 'DESLIGADA', 'color': 'green'}),
        ];
    final rows = (n / 2).ceil() * 4;
    return ScreenTemplate(
      id: id,
      name: 'I/O de CLP — $n entradas e $n saídas',
      description: 'Uma lâmpada por entrada (E0…E${n - 1}) e por saída (S0…S${n - 1}).',
      icon: Icons.developer_board_outlined,
      tags: [
        for (var i = 0; i < n; i++) TemplateTag('e$i', 'Entrada E$i', type: _bool, area: ModbusArea.discreteInput, description: 'Entrada física do CLP'),
        for (var i = 0; i < n; i++) TemplateTag('s$i', 'Saída S$i', type: _bool, area: ModbusArea.coil, description: 'Saída física do CLP'),
      ],
      elements: [
        const TemplateElement(ElementType.label, 0, 0, 12, 2, props: {'text': 'Entradas', 'size': 'm', 'align': 'left'}),
        ...lamps('E', 'e', 2),
        TemplateElement(ElementType.label, 0, 2 + rows, 12, 2, props: const {'text': 'Saídas', 'size': 'm', 'align': 'left'}),
        ...lamps('S', 's', 4 + rows),
      ],
    );
  }

  /// Item 162: inversor, básico e completo. Com perfil de inversor (MD500,
  /// GD20), comanda pela palavra de comando com os endereços do manual.
  static final inverterBasic = ScreenTemplate(
    id: 'inversor-basico',
    name: 'Inversor — básico',
    description: 'Liga, sentido, referência, frequência, corrente e falha.',
    icon: Icons.electric_bolt_rounded,
    driveMap: true,
    tags: _inverterTags(full: false),
    elements: _inverterElements(full: false),
  );

  static final inverterFull = ScreenTemplate(
    id: 'inversor-completo',
    name: 'Inversor — completo',
    description: 'O básico mais rampas, torque, barramento, temperatura e horas.',
    icon: Icons.electric_bolt_rounded,
    driveMap: true,
    tags: _inverterTags(full: true),
    elements: _inverterElements(full: true),
  );

  /// Item 162: servo, básico e completo. Sempre por bits: ainda não há perfil
  /// de servo (quando houver, ganha `driveMap` como o inversor).
  static final servoBasic = ScreenTemplate(
    id: 'servo-basico',
    name: 'Servo — básico',
    description: 'Liga, sentido, referência, velocidade, corrente e falha.',
    icon: Icons.settings_rounded,
    tags: _servoTags(full: false),
    elements: _servoElements(full: false),
  );

  static final servoFull = ScreenTemplate(
    id: 'servo-completo',
    name: 'Servo — completo',
    description: 'O básico mais rampas, torque, barramento, temperatura e horas.',
    icon: Icons.settings_rounded,
    tags: _servoTags(full: true),
    elements: _servoElements(full: true),
  );

  /// Item 165: leitor de código de barras.
  static const barcode = ScreenTemplate(
    id: 'leitor-codigo',
    name: 'Leitor de código de barras',
    description: 'Último código lido, leituras e status.',
    icon: Icons.qr_code_scanner_rounded,
    tags: [
      TemplateTag('codigo', 'Último código lido', type: TagDataType.string, length: 16, description: 'Texto: 2 letras por registrador; 16 registradores = até 32 letras'),
      TemplateTag('leituras', 'Leituras', type: _count, unit: 'un'),
      TemplateTag('status', 'Status do leitor', type: _code, description: '0 pronto · 1 lido · 2 erro — ajuste aos códigos do leitor',
          alarms: [TemplateAlarm(AlarmKind.above, 'Erro no leitor de código', limit: 1, priority: AlarmPriority.low)]),
    ],
    elements: [
      TemplateElement(ElementType.value, 0, 0, 12, 4, tag: 'codigo', props: {'label': 'Último código'}),
      TemplateElement(ElementType.multistate, 0, 4, 6, 4, tag: 'status', props: {
        'label': 'Status',
        'states': [
          // Palavras curtas: no celular de 320 dp o indicador tem meia largura.
          {'value': 0, 'text': 'PRONTO', 'color': _neutral},
          {'value': 1, 'text': 'LIDO', 'color': 'green'},
          {'value': 2, 'text': 'ERRO', 'color': 'amber'},
        ],
      }),
      TemplateElement(ElementType.value, 6, 4, 6, 4, tag: 'leituras', props: {'label': 'Leituras'}),
    ],
  );

  /// Item 166: várias temperaturas, cada uma com a faixa (atenção e alarme no
  /// medidor, os mesmos limites dos alarmes da variável), e a tendência.
  static final temperature = ScreenTemplate(
    id: 'temperatura',
    name: 'Monitoramento de temperatura',
    description: 'Três temperaturas com faixa, alarmes e tendência.',
    icon: Icons.thermostat_rounded,
    tags: [
      for (final n in [1, 2, 3])
        TemplateTag('t$n', 'Temperatura $n', unit: '°C', decimals: 1, alarms: [
          TemplateAlarm(AlarmKind.above, 'Temperatura $n alta', limit: 80, priority: AlarmPriority.low),
          TemplateAlarm(AlarmKind.above, 'Temperatura $n muito alta', limit: 100, priority: AlarmPriority.high),
        ]),
    ],
    elements: [
      // Duas em cima e a terceira centralizada: as três do mesmo tamanho.
      for (final (n, x, y) in [(1, 0, 0), (2, 6, 0), (3, 3, 6)])
        TemplateElement(ElementType.gauge, x, y, 6, 6, tag: 't$n', props: {'label': 'Temperatura $n', 'min': 0, 'max': 150, 'warn': 80, 'alarm': 100}),
      TemplateElement(ElementType.trend, 0, 12, 12, 8, tags: ['t1', 't2', 't3'], props: {'label': 'Últimos 10 minutos', 'windowSec': 600}),
    ],
  );

  /// Item 167: célula de carga (balança).
  static const loadCell = ScreenTemplate(
    id: 'celula-carga',
    name: 'Célula de carga',
    description: 'Peso, tara, zero, estabilidade e pesagens.',
    icon: Icons.scale_outlined,
    tags: [
      TemplateTag('peso', 'Peso', unit: 'kg', decimals: 2),
      TemplateTag('estavel', 'Peso estável', type: _bool),
      TemplateTag('tara', 'Tara', unit: 'kg', decimals: 2, description: 'O que é descontado do peso bruto'),
      TemplateTag('tarar', 'Comando de tara', type: _bool, writable: true, description: 'Pulso: o peso de agora vira a tara'),
      TemplateTag('zerar', 'Comando de zero', type: _bool, writable: true, description: 'Pulso: zera a balança vazia'),
      TemplateTag('pesagens', 'Pesagens', type: _count, unit: 'un'),
    ],
    elements: [
      TemplateElement(ElementType.value, 0, 0, 12, 6, tag: 'peso', props: {'label': 'Peso'}),
      TemplateElement(ElementType.lamp, 0, 6, 6, 4, tag: 'estavel', props: {'label': 'Estável', 'onText': 'SIM', 'offText': 'NÃO', 'color': 'green'}),
      TemplateElement(ElementType.value, 6, 6, 6, 4, tag: 'tara', props: {'label': 'Tara'}),
      TemplateElement(ElementType.button, 0, 10, 6, 4, tag: 'tarar', props: {'label': 'Tarar', 'mode': 'momentary', 'color': _neutral}),
      TemplateElement(ElementType.button, 6, 10, 6, 4, tag: 'zerar', props: {'label': 'Zerar', 'mode': 'momentary', 'color': _neutral}),
      TemplateElement(ElementType.value, 0, 14, 12, 3, tag: 'pesagens', props: {'label': 'Pesagens'}),
    ],
  );

  static final List<ScreenTemplate> all = [blank, machine, inverterBasic, inverterFull, servoBasic, servoFull, barcode, temperature, loadCell, io8, io16];

  static ScreenTemplate? byId(String id) => all.where((t) => t.id == id).firstOrNull;

  /// Palavra de comando e estados por perfil de inversor (id do perfil).
  /// Perfil de inversor fora daqui usa o comando por bits.
  static const driveCodes = <String, DriveCodes>{
    // MD500: 0x2000 1 avante · 2 reverso · 5 parada livre · 6 parada em
    // rampa · 7 reset; 0x3000 1 avante · 2 reverso · 3 parado. "Reverso", e
    // não "ré", a pedido do cliente (reunião de 19/10/2026).
    'inovance-md500': DriveCodes(forward: 1, reverse: 2, stop: 6, reset: 7, states: [
      {'value': 1, 'text': 'AVANTE', 'color': 'green'},
      {'value': 2, 'text': 'REVERSO', 'color': 'green'},
      {'value': 3, 'text': 'PARADO', 'color': _neutral},
    ]),
    // GD20: 0x2000 1 avante · 2 reverso · 5 parar · 6 parada livre · 7 reset;
    // 0x2100 1 avante · 2 reverso · 3 parado · 4 falha.
    'invt-gd20': DriveCodes(forward: 1, reverse: 2, stop: 5, reset: 7, states: [
      {'value': 1, 'text': 'AVANTE', 'color': 'green'},
      {'value': 2, 'text': 'REVERSO', 'color': 'green'},
      {'value': 3, 'text': 'PARADO', 'color': _neutral},
      {'value': 4, 'text': 'FALHA', 'color': 'red'},
    ]),
  };
}
