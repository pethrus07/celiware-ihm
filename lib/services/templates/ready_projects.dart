// Projetos prontos (reunião de 19/10/2026, decisão do Pedro em 21/10): no
// lugar de mais telas soltas em "Nova tela", projetos já montados que se
// SOMAM à planta pela tela de Projetos → Novo projeto → De um projeto pronto.
//
// Cada um traz um equipamento de exemplo (Modbus TCP, IP a configurar), as
// variáveis com o endereço a configurar (`Tag.addressPending`) e as telas,
// montadas pelo mesmo `TemplateBuilder` dos modelos de tela — as regras da
// grade, dos tipos e do "nenhum endereço inventado" valem igual. Só dados:
// quem grava é o `ProjectController.createProject` (nome único, nunca
// substitui outro projeto).
//
// O do Tex G4 usa os nomes e as descrições dos sinais do Padrão TEX
// (material do cliente, `fabrica-de-conteudo/pilotos/padrao-tex`); os
// endereços Modbus do G4 não estão no material, então ficam todos a
// configurar, com o manual Modbus do Tex G4 como fonte. Nada da marca Tex
// (logo ou cores) entra aqui.

import 'package:flutter/material.dart' show IconData, Icons;

import '../../core/modbus/modbus_memory.dart';
import '../../core/utils/ids.dart';
import '../../models/alarm.dart';
import '../../models/device.dart';
import '../../models/hmi_screen.dart';
import '../../models/project.dart';
import '../../models/tag.dart';
import 'screen_templates.dart';
import 'template_builder.dart';

/// Uma tela do projeto pronto: o modelo, o nome e se é só de acompanhamento.
class ReadyScreen {
  const ReadyScreen(this.template, this.name, {this.readOnly = false});
  final ScreenTemplate template;
  final String name;

  /// Tela só de acompanhamento (`HmiScreen.readOnly`): nada grava por ela.
  final bool readOnly;
}

/// Um projeto pronto: o que aparece na lista (título, uma linha, ícone) e o
/// que ele cria.
class ReadyProject {
  const ReadyProject({
    required this.id,
    required this.title,
    required this.description,
    required this.icon,
    required this.projectName,
    required this.deviceName,
    required this.screens,
    this.hint = 'Preencha o IP em Equipamentos e os endereços em Variáveis.',
  });

  /// Estável (testes, chaves da interface). Nunca muda.
  final String id;
  final String title;

  /// Uma linha: o que vem no projeto.
  final String description;
  final IconData icon;

  /// Nome do projeto criado (ganha "(2)" se já existir na planta).
  final String projectName;
  final String deviceName;
  final List<ReadyScreen> screens;

  /// O próximo passo, no aviso depois de criar.
  final String hint;

  /// Monta o projeto: um equipamento sem IP e as telas, uma depois da outra
  /// — a segunda tela reaproveita as variáveis de mesmo nome da primeira.
  Project build() {
    final device = Device(id: newId('d'), name: deviceName);
    var p = Project(name: projectName, devices: [device]);
    for (final s in screens) {
      final r = TemplateBuilder.build(s.template, project: p, device: device, screenId: newId('s'), name: s.name);
      p = p.upsertTags(r.created).upsertScreen(r.screen.copyWith(readOnly: s.readOnly));
    }
    return p;
  }
}

/// A biblioteca, na ordem da lista.
abstract final class ReadyProjects {
  /// As telas do Tex G4, também oferecidas soltas em Nova tela → Começar de
  /// (`ScreenTemplates.texOperation`/`texIo`), com as mesmas variáveis.
  static ScreenTemplate get texOperation => _Screens.texOperation;
  static ScreenTemplate get texIo => _Screens.texIo;

  static final all = <ReadyProject>[
    ReadyProject(
      id: 'diretoria',
      title: 'Diretoria',
      description: 'Só acompanhamento: estado, produção, alarme e OEE.',
      icon: Icons.insights_rounded,
      projectName: 'Diretoria',
      deviceName: 'Máquina',
      screens: [ReadyScreen(_Screens.overview, 'Visão geral', readOnly: true)],
    ),
    ReadyProject(
      id: 'supervisao',
      title: 'Supervisão',
      description: 'Estado, modo, produção com tendência e alarme, sem comandos.',
      icon: Icons.monitor_heart_outlined,
      projectName: 'Supervisão',
      deviceName: 'Máquina',
      screens: [ReadyScreen(_Screens.supervision, 'Supervisão', readOnly: true)],
    ),
    const ReadyProject(
      id: 'operador',
      title: 'Operador',
      description: 'Liga com retorno, reset, ajuste de velocidade, alarme e OEE.',
      icon: Icons.touch_app_outlined,
      projectName: 'Operador',
      deviceName: 'Máquina',
      screens: [ReadyScreen(ScreenTemplates.machine, 'Operação')],
    ),
    ReadyProject(
      id: 'monitoramento',
      title: 'Monitoramento rápido',
      description: 'Tabela com 12 memórias e tendência, para o técnico em campo.',
      icon: Icons.table_rows_outlined,
      projectName: 'Monitoramento rápido',
      deviceName: 'CLP',
      screens: [ReadyScreen(_Screens.quickMonitor, 'Memórias')],
    ),
    ReadyProject(
      id: 'tex-g4',
      title: 'Tex G4 (teste de estanqueidade)',
      description: 'Operação e diagnóstico. Confira os endereços no manual Modbus do Tex G4.',
      icon: Icons.compress_rounded,
      projectName: 'Tex G4',
      deviceName: 'Tex G4',
      screens: [ReadyScreen(_Screens.texOperation, 'Operação'), ReadyScreen(_Screens.texIo, 'Entradas e saídas')],
      hint: 'Confira os endereços no manual Modbus do Tex G4 e preencha em Variáveis; o IP, em Equipamentos.',
    ),
  ];

  static ReadyProject? byId(String id) => all.where((p) => p.id == id).firstOrNull;
}

// ── Telas ──────────────────────────────────────────────────────────────────────

const _bool = TagDataType.bool;
const _code = TagDataType.uint16;
const _number = TagDataType.float32;
const _neutral = 'neutral';

/// Variável do modelo Máquina, para as telas de acompanhamento usarem os
/// mesmos nomes (aplicar o modelo depois, no mesmo equipamento, reaproveita).
TemplateTag _machine(String key) => ScreenTemplates.machine.tags.firstWhere((t) => t.key == key);

abstract final class _Screens {
  static const _oeeTags = ['disponibilidade', 'desempenho', 'qualidade'];

  /// Diretoria: só acompanhamento, do mesmo jeito do "Resumo do líder" da
  /// demonstração.
  static final overview = ScreenTemplate(
    id: 'pronto-visao-geral',
    name: 'Visão geral',
    description: 'Estado, produção, alarme e OEE.',
    icon: Icons.insights_rounded,
    tags: [for (final k in ['estado', 'producao', 'alarme', ..._oeeTags]) _machine(k)],
    elements: const [
      TemplateElement(ElementType.multistate, 0, 0, 12, 3, tag: 'estado', props: {'label': 'Estado', 'states': ScreenTemplates.machineStates}),
      TemplateElement(ElementType.value, 0, 3, 6, 4, tag: 'producao', props: {'label': 'Produção'}),
      TemplateElement(ElementType.lamp, 6, 3, 6, 4, tag: 'alarme', props: {'label': 'Alarme', 'onText': 'ATIVO', 'offText': 'OK', 'color': 'red'}),
      TemplateElement(ElementType.oee, 0, 7, 12, 6, tags: _oeeTags, props: ScreenTemplates.oeeProps),
    ],
  );

  /// Supervisão: estado, modo e produção com a tendência; nenhum comando.
  static final supervision = ScreenTemplate(
    id: 'pronto-supervisao',
    name: 'Supervisão',
    description: 'Estado, modo, velocidade, produção com tendência e alarme.',
    icon: Icons.monitor_heart_outlined,
    tags: [for (final k in ['estado', 'emAutomatico', 'alarme', 'velocidade', 'producao']) _machine(k)],
    elements: const [
      TemplateElement(ElementType.multistate, 0, 0, 12, 3, tag: 'estado', props: {'label': 'Estado', 'states': ScreenTemplates.machineStates}),
      TemplateElement(ElementType.multistate, 0, 3, 6, 4, tag: 'emAutomatico', props: {'label': 'Modo', 'states': ScreenTemplates.modeStates}),
      TemplateElement(ElementType.lamp, 6, 3, 6, 4, tag: 'alarme', props: {'label': 'Alarme', 'onText': 'ATIVO', 'offText': 'OK', 'color': 'red'}),
      TemplateElement(ElementType.value, 0, 7, 6, 4, tag: 'velocidade', props: {'label': 'Velocidade'}),
      TemplateElement(ElementType.value, 6, 7, 6, 4, tag: 'producao', props: {'label': 'Produção'}),
      TemplateElement(ElementType.trend, 0, 11, 12, 8, tags: ['producao'], props: {'label': 'Últimos 10 minutos', 'windowSec': 600}),
    ],
  );

  /// Monitoramento rápido: muitas memórias numa tabela (só as linhas à vista
  /// são lidas) e a tendência das três primeiras.
  static const _memories = 12;
  static final quickMonitor = ScreenTemplate(
    id: 'pronto-monitoramento',
    name: 'Memórias',
    description: 'Tabela de valores e tendência.',
    icon: Icons.table_rows_outlined,
    tags: [
      for (var i = 1; i <= _memories; i++) TemplateTag('m$i', 'Memória $i', type: _code, description: 'Troque o nome pelo da memória do CLP (ex.: D100)'),
    ],
    elements: [
      TemplateElement(ElementType.table, 0, 0, 12, 16, tags: [for (var i = 1; i <= _memories; i++) 'm$i'], props: const {'label': '', 'onText': 'LIGADO', 'offText': 'DESLIGADO'}),
      const TemplateElement(ElementType.trend, 0, 16, 12, 8, tags: ['m1', 'm2', 'm3'], props: {'label': 'Últimos 2 minutos', 'windowSec': 120}),
    ],
  );

  // ── Tex G4 ───────────────────────────────────────────────────────────────────
  // Nome da variável = o nome do sinal no Padrão TEX (o técnico acha no
  // manual); o rótulo na tela, em português simples. "número" do material
  // vira inteiro de 16 bits e "decimal" vira número com vírgula — o tipo
  // também se confere no manual Modbus.

  static const _yes = {'onText': 'SIM', 'offText': 'NÃO'};

  static final texOperation = ScreenTemplate(
    id: 'pronto-tex-operacao',
    name: 'Operação',
    description: 'Comandos, resultado, pressão, vazamento e BCD.',
    icon: Icons.compress_rounded,
    tags: const [
      TemplateTag('connected', 'Connected', type: _bool, description: 'O equipamento Tex está conectado.'),
      TemplateTag('ready', 'ReadyToTest', type: _bool, description: 'O equipamento está pronto para iniciar um teste.'),
      TemplateTag('busy', 'Busy', type: _bool,
          description: 'O equipamento está ocupado: testando, com alguém mexendo na tela dele, ou comandado pelo próprio equipamento. Não aceita um teste novo agora.'),
      TemplateTag('actualBcd', 'ActualBCD', type: _code, description: 'O número da peça chamada agora no equipamento.'),
      TemplateTag('start', 'Start', type: _bool, writable: true, description: 'Inicia o teste de estanqueidade. Só envie com ReadyToTest ligado.'),
      TemplateTag('stop', 'Stop', type: _bool, writable: true, description: 'Para o teste em andamento.'),
      TemplateTag('blockExhaust', 'BlockExhaust', type: _bool, writable: true, description: 'Ativa ou não a exaustão (escape) depois do teste, quando a situação pedir.'),
      TemplateTag('bcd', 'BCD', type: _code, writable: true, description: 'O número da peça configurada no Tex. Para testar a peça 3, coloque 3.'),
      TemplateTag('resultOk', 'ResultOK', type: _bool, description: 'O último teste deu resultado OK.'),
      TemplateTag('resultNok', 'ResultNOK', type: _bool, description: 'O último teste não deu resultado OK.',
          alarms: [TemplateAlarm(AlarmKind.on, 'Peça reprovada no teste de estanqueidade')]),
      TemplateTag('rework', 'Rework', type: _bool, description: 'Fica ligado quando a peça está marcada como retrabalho.'),
      TemplateTag('pressure', 'Pressure', type: _number, decimals: 1,
          description: 'A pressão atual no equipamento. A IHM do Padrão TEX mostra em Pa; confira a unidade da peça.'),
      TemplateTag('leak', 'Leak', type: _number, decimals: 1,
          description: 'O vazamento calculado pelo Tex neste momento. A IHM do Padrão TEX mostra em mL/min; confira a unidade da peça.'),
      TemplateTag('chamber', 'ChamberNum', type: _code, description: 'A câmara que está testando agora.'),
      TemplateTag('test', 'TestNum', type: _code, description: 'O teste que está sendo feito agora.'),
    ],
    elements: const [
      // Como está.
      TemplateElement(ElementType.lamp, 0, 0, 6, 4, tag: 'connected', props: {'label': 'Conectado', ..._yes, 'color': 'green'}),
      TemplateElement(ElementType.lamp, 6, 0, 6, 4, tag: 'ready', props: {'label': 'Pronto', ..._yes, 'color': 'green'}),
      TemplateElement(ElementType.lamp, 0, 4, 6, 4, tag: 'busy', props: {'label': 'Ocupado', ..._yes, 'color': 'green'}),
      TemplateElement(ElementType.value, 6, 4, 6, 4, tag: 'actualBcd', props: {'label': 'BCD atual'}),
      // O que faço. Comando sem retorno fica neutro (ISA-101).
      TemplateElement(ElementType.button, 0, 8, 6, 4, tag: 'start', props: {'label': 'Iniciar', 'mode': 'momentary', 'color': _neutral}),
      TemplateElement(ElementType.button, 6, 8, 6, 4, tag: 'stop', props: {'label': 'Parar', 'mode': 'momentary', 'color': _neutral}),
      TemplateElement(ElementType.button, 0, 12, 6, 4, tag: 'blockExhaust', props: {'label': 'Bloquear escape', 'mode': 'toggle', 'color': _neutral}),
      TemplateElement(ElementType.input, 6, 12, 6, 4, tag: 'bcd', props: {'label': 'Peça (BCD)', 'min': 0}),
      // Como responde. Meia largura no mínimo: três por linha (4×4), no
      // celular de 320 dp, "RETRABALHO" e "A configurar" encolhiam demais.
      TemplateElement(ElementType.lamp, 0, 16, 6, 4, tag: 'resultOk', props: {'label': 'OK', ..._yes, 'color': 'green'}),
      TemplateElement(ElementType.lamp, 6, 16, 6, 4, tag: 'resultNok', props: {'label': 'NOK', ..._yes, 'color': 'red'}),
      TemplateElement(ElementType.lamp, 0, 20, 12, 3, tag: 'rework', props: {'label': 'Retrabalho', ..._yes, 'color': 'amber'}),
      TemplateElement(ElementType.value, 0, 23, 6, 4, tag: 'pressure', props: {'label': 'Pressão'}),
      TemplateElement(ElementType.value, 6, 23, 6, 4, tag: 'leak', props: {'label': 'Vazamento'}),
      TemplateElement(ElementType.value, 0, 27, 6, 4, tag: 'chamber', props: {'label': 'Câmara'}),
      TemplateElement(ElementType.value, 6, 27, 6, 4, tag: 'test', props: {'label': 'Teste'}),
    ],
  );

  /// Entradas e saídas físicas do G4 (as da tela IOS da IHM do Padrão TEX)
  /// e os números do diagnóstico numa tabela. (chave, nome da variável,
  /// rótulo curto na tela).
  static const _texInputs = [
    ('in0', 'Entrada BCD 0', 'BCD 0'),
    ('in1', 'Entrada BCD 1', 'BCD 1'),
    ('in2', 'Entrada parada', 'Parada'),
    ('in3', 'Entrada início', 'Início'),
    ('in4', 'Entrada BCD 2 / sensor de refugo', 'BCD 2 / refugo'),
    ('in5', 'Entrada BCD 3 / peça anterior', 'BCD 3 / anterior'),
    ('in6', 'Entrada BCD 4 / próxima peça', 'BCD 4 / próxima'),
    ('in7', 'Entrada bloqueia escape', 'Bloqueia escape'),
  ];
  static const _texOutputs = [
    ('out0', 'Saída digital 1', 'Digital 1'),
    ('out1', 'Saída aprova', 'Aprova'),
    ('out2', 'Saída reprova teste', 'Reprova teste'),
    ('out3', 'Saída digital 2 / reprova ref.', 'Reprova ref.'),
    ('out4', 'Saída digital 3 / falha', 'Falha'),
    ('out5', 'Saída retrabalho', 'Retrabalho'),
    ('out6', 'Saída escape externo', 'Escape externo'),
    ('out7', 'Saída busy', 'Busy'),
  ];

  static final texIo = ScreenTemplate(
    id: 'pronto-tex-io',
    name: 'Entradas e saídas',
    description: 'Entradas e saídas do equipamento e o diagnóstico.',
    icon: Icons.developer_board_outlined,
    tags: [
      for (final (k, name, _) in _texInputs) TemplateTag(k, name, type: _bool, area: ModbusArea.discreteInput, description: 'Entrada física do Tex G4'),
      for (final (k, name, _) in _texOutputs) TemplateTag(k, name, type: _bool, area: ModbusArea.coil, description: 'Saída física do Tex G4'),
      const TemplateTag('state', 'State', type: _code,
          description: 'A etapa em que o Tex está: esvaziando, enchendo, equalizando ou medindo. Os códigos estão no manual do equipamento Tex.'),
      const TemplateTag('status', 'Status', type: _code, description: 'O status do equipamento, conforme o manual do equipamento Tex.'),
      const TemplateTag('time', 'TimeElapsed', type: _code, description: 'O tempo que passou desde o início do teste. A IHM do Padrão TEX mostra em ms.'),
      const TemplateTag('escape', 'Escape', type: _bool, description: 'Indica se a peça está ativada para o escape depois do teste.'),
      const TemplateTag('diff', 'DiffPressure', type: _number, decimals: 1, description: 'A diferença de pressão, nos equipamentos que fazem esse cálculo.'),
      const TemplateTag('return', 'ReturnPressure', type: _number, decimals: 1, description: 'O retorno da pressão, só nos equipamentos que têm esse dado.'),
      const TemplateTag('autoCheck', 'AutoCheck', type: _code, description: 'O resultado da autoverificação do equipamento.'),
      const TemplateTag('diagnostic', 'Diagnostic', type: _code, description: 'O diagnóstico de cada item testado no equipamento, conforme o manual do equipamento Tex.'),
    ],
    elements: [
      const TemplateElement(ElementType.label, 0, 0, 12, 2, props: {'text': 'Entradas', 'size': 'm', 'align': 'left'}),
      for (final (i, (k, _, label)) in _texInputs.indexed)
        TemplateElement(ElementType.lamp, (i % 2) * 6, 2 + (i ~/ 2) * 4, 6, 4, tag: k, props: {'label': label, 'onText': 'LIGADA', 'offText': 'DESLIGADA', 'color': 'green'}),
      const TemplateElement(ElementType.label, 0, 18, 12, 2, props: {'text': 'Saídas', 'size': 'm', 'align': 'left'}),
      for (final (i, (k, _, label)) in _texOutputs.indexed)
        TemplateElement(ElementType.lamp, (i % 2) * 6, 20 + (i ~/ 2) * 4, 6, 4, tag: k, props: {'label': label, 'onText': 'LIGADA', 'offText': 'DESLIGADA', 'color': 'green'}),
      const TemplateElement(ElementType.table, 0, 36, 12, 12,
          tags: ['state', 'status', 'time', 'escape', 'diff', 'return', 'autoCheck', 'diagnostic'],
          props: {'label': 'Diagnóstico', 'onText': 'LIGADO', 'offText': 'DESLIGADO'}),
    ],
  );
}
