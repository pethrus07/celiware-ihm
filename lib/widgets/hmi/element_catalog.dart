import 'package:flutter/material.dart';

import '../../models/hmi_screen.dart';
import '../../models/tag.dart';

/// Que tipo de variável um elemento aceita.
enum TagFit {
  /// Nenhuma (texto, imagem).
  none,

  /// Liga/desliga.
  boolean,

  /// Número único (inteiro ou com vírgula).
  number,

  /// Número ou liga/desliga (ex.: mostrador, indicador de estado).
  scalar,

  /// Lista de números (memória inicial + tamanho).
  numberList,
}

extension TagFitCheck on TagFit {
  bool accepts(Tag t) {
    switch (this) {
      case TagFit.none:
        return false;
      case TagFit.boolean:
        return t.dataType == TagDataType.bool && !t.isArray;
      case TagFit.number:
        return t.dataType.isNumeric && !t.isArray;
      case TagFit.scalar:
        return !t.isArray;
      case TagFit.numberList:
        return t.dataType.isNumeric && t.isArray;
    }
  }

  String get requirement {
    switch (this) {
      case TagFit.none:
        return '';
      case TagFit.boolean:
        return 'variável liga/desliga';
      case TagFit.number:
        return 'variável numérica';
      case TagFit.scalar:
        return 'variável de valor único';
      case TagFit.numberList:
        return 'variável do tipo lista (tamanho maior que 1)';
    }
  }
}

/// Ficha de um tipo de elemento.
class ElementInfo {
  const ElementInfo({
    required this.type,
    required this.name,
    required this.description,
    required this.icon,
    required this.fit,
    required this.defaultW,
    required this.defaultH,
    this.minW = 1,
    this.minH = 1,
    this.writes = false,
    this.multiTag = false,
  });

  final ElementType type;

  /// Nome na paleta, para leigo.
  final String name;

  /// Uma frase: para que serve.
  final String description;
  final IconData icon;
  final TagFit fit;
  final int defaultW;
  final int defaultH;
  final int minW;
  final int minH;

  /// Escreve no equipamento (respeita "só leitura" e confirmação da tela).
  final bool writes;

  /// Aceita mais de uma variável (gráfico de tendência).
  final bool multiTag;
}

/// Catálogo de elementos — **único lugar que interpreta `HmiElement.props`**.
///
/// Propriedades por tipo (chave → significado):
///
/// | tipo        | props                                                                                   |
/// |-------------|-----------------------------------------------------------------------------------------|
/// | button      | tagId, label, mode (toggle·momentary·set·reset·value), value (num, modo value), color   |
/// | lamp        | tagId, label, onText, offText, color                                                    |
/// | value       | tagId, label                                                                            |
/// | input       | tagId, label, min, max                                                                  |
/// | multistate  | tagId, label, states: [{value, text, color}]                                            |
/// | bar         | tagId, label, min, max, color                                                           |
/// | gauge       | tagId, label, min, max, warn, alarm                                                     |
/// | trend       | tagIds (até 3), label, windowSec, min?, max? (sem min/max = escala automática)           |
/// | barChart    | tagId (lista), label                                                                    |
/// | label       | text, size (s·m·l), align (left·center)                                                 |
/// | image       | data (PNG/JPG em base64), fit (contain·cover)                                           |
///
/// `color` é o nome de um [StateColor]. Chaves ausentes usam o padrão do
/// renderizador; chaves desconhecidas são preservadas (arquivo de versão
/// mais nova abre sem perder nada).
class ElementCatalog {
  ElementCatalog._();

  static const List<ElementInfo> all = [
    ElementInfo(
      type: ElementType.button,
      name: 'Botão',
      description: 'Liga, desliga ou pulso.',
      icon: Icons.radio_button_checked_rounded,
      // Liga/desliga nos modos de bit; numérica no modo "grava um valor" —
      // a folha de configuração filtra pelo modo escolhido.
      fit: TagFit.scalar,
      defaultW: 2,
      defaultH: 2,
      writes: true,
    ),
    ElementInfo(
      type: ElementType.lamp,
      name: 'Lâmpada',
      description: 'Acende com o sinal.',
      icon: Icons.lightbulb_outline_rounded,
      fit: TagFit.boolean,
      defaultW: 2,
      defaultH: 1,
    ),
    ElementInfo(
      type: ElementType.value,
      name: 'Mostrador',
      description: 'Um valor em destaque.',
      icon: Icons.pin_outlined,
      fit: TagFit.scalar,
      defaultW: 3,
      defaultH: 2,
    ),
    ElementInfo(
      type: ElementType.input,
      name: 'Ajuste de valor',
      description: 'Digitar e gravar um valor.',
      icon: Icons.dialpad_rounded,
      fit: TagFit.number,
      defaultW: 3,
      defaultH: 2,
      writes: true,
    ),
    ElementInfo(
      type: ElementType.multistate,
      name: 'Indicador de estado',
      description: 'Código vira texto e cor.',
      icon: Icons.traffic_outlined,
      fit: TagFit.scalar,
      defaultW: 3,
      defaultH: 1,
    ),
    ElementInfo(
      type: ElementType.bar,
      name: 'Barra',
      description: 'Nível entre mín. e máx.',
      icon: Icons.linear_scale_rounded,
      fit: TagFit.number,
      defaultW: 6,
      defaultH: 1,
      minW: 2,
    ),
    ElementInfo(
      type: ElementType.gauge,
      name: 'Medidor',
      description: 'Ponteiro com faixas.',
      icon: Icons.speed_rounded,
      fit: TagFit.number,
      defaultW: 3,
      defaultH: 3,
      minW: 2,
      minH: 2,
    ),
    ElementInfo(
      type: ElementType.trend,
      name: 'Gráfico de tendência',
      description: 'Curva dos últimos minutos.',
      icon: Icons.show_chart_rounded,
      fit: TagFit.number,
      defaultW: 6,
      defaultH: 4,
      minW: 3,
      minH: 2,
      multiTag: true,
    ),
    ElementInfo(
      type: ElementType.barChart,
      name: 'Gráfico de barras',
      description: 'Uma barra por valor da lista.',
      icon: Icons.bar_chart_rounded,
      fit: TagFit.numberList,
      defaultW: 6,
      defaultH: 3,
      minW: 3,
      minH: 2,
    ),
    ElementInfo(
      type: ElementType.label,
      name: 'Texto',
      description: 'Título ou observação.',
      icon: Icons.title_rounded,
      fit: TagFit.none,
      defaultW: 6,
      defaultH: 1,
    ),
    ElementInfo(
      type: ElementType.image,
      name: 'Imagem',
      description: 'Foto ou esquema.',
      icon: Icons.image_outlined,
      fit: TagFit.none,
      defaultW: 3,
      defaultH: 3,
    ),
  ];

  static ElementInfo of(ElementType type) => all.firstWhere(
        (i) => i.type == type,
        orElse: () => const ElementInfo(
          type: ElementType.unknown,
          name: 'Elemento desconhecido',
          description: 'Criado numa versão mais nova do app.',
          icon: Icons.help_center_outlined,
          fit: TagFit.none,
          defaultW: 2,
          defaultH: 1,
        ),
      );

  /// Propriedades iniciais de um elemento recém-colocado na tela.
  static Map<String, dynamic> defaultProps(ElementType type, {Tag? tag}) {
    final base = <String, dynamic>{if (tag != null) 'tagId': tag.id};
    final label = tag?.name ?? '';
    switch (type) {
      case ElementType.button:
        return {...base, 'label': label.isEmpty ? 'Botão' : label, 'mode': 'toggle', 'color': 'green'};
      case ElementType.lamp:
        return {...base, 'label': label, 'onText': 'LIGADO', 'offText': 'DESLIGADO', 'color': 'green'};
      case ElementType.value:
      case ElementType.input:
        return {...base, 'label': label};
      case ElementType.multistate:
        return {
          ...base,
          'label': label,
          'states': [
            {'value': 0, 'text': 'DESLIGADO', 'color': 'neutral'},
            {'value': 1, 'text': 'LIGADO', 'color': 'green'},
          ],
        };
      case ElementType.bar:
        return {...base, 'label': label, 'min': 0, 'max': 100, 'color': 'blue'};
      case ElementType.gauge:
        return {...base, 'label': label, 'min': 0, 'max': 100};
      case ElementType.trend:
        return {
          if (tag != null) 'tagIds': [tag.id],
          'label': label,
          'windowSec': 120,
        };
      case ElementType.barChart:
        return {...base, 'label': label};
      case ElementType.label:
        return {'text': 'Título', 'size': 'm', 'align': 'left'};
      case ElementType.image:
        return {'fit': 'contain'};
      case ElementType.unknown:
        return const {};
    }
  }
}
