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

  /// Número ou liga/desliga (ex.: indicador de estado, imagem por etapa).
  scalar,

  /// Qualquer valor único, inclusive texto (mostrador).
  any,

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
        return !t.isArray && !t.isText;
      case TagFit.any:
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
        return 'variável de número ou liga/desliga';
      case TagFit.any:
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
/// | button      | tagId, label, mode (toggle·momentary·set·reset·value·screen·camera), value (num, modo   |
/// |             | value), color, feedbackTagId (retorno: o que acende o botão), goTo (modo screen),       |
/// |             | cameraId (modo camera: a câmera que abre em tela cheia)                                 |
/// | lamp        | tagId, label, onText, offText, color                                                    |
/// | value       | tagId, label                                                                            |
/// | input       | tagId, label, min, max                                                                  |
/// | multistate  | tagId, label, states: [{value, text, color}]                                            |
/// | bar         | tagId, label, min, max, color                                                           |
/// | gauge       | tagId, label, min, max, warn, alarm                                                     |
/// | trend       | tagIds (até 3), label, windowSec, min?, max? (sem min/max = escala automática)           |
/// | barChart    | tagId (lista), label                                                                    |
/// | label       | text, size (s·m·l), align (left·center)                                                 |
/// | image       | data (PNG em base64), fit (contain·cover), source (fixed·byValue),                      |
/// |             | tagId + images: [{value, data}] (modo byValue: uma imagem por código)                   |
/// | table       | tagIds (até 30, na ordem das linhas), label (título; vazio = sem título),               |
/// |             | onText, offText (texto das linhas liga/desliga)                                         |
/// | oee         | tagIds: [disponibilidade, desempenho, qualidade, oee pronto] (vaga fixa; vazia = null), |
/// |             | source (calc·tag), scale (percent·fraction), warn?, alarm? (% do OEE, "abaixo de"),     |
/// |             | label (placa do OEE; vazio = "OEE") — regras em `Oee` (elements/oee_element.dart)       |
///
/// Em qualquer elemento menos botão e ajuste: `goTo` = id da tela que abre ao
/// tocar (nos dois, o toque já tem dono: gravar).
///
/// `color` é o nome de um [StateColor]. Chaves ausentes usam o padrão do
/// renderizador; chaves desconhecidas são preservadas (arquivo de versão
/// mais nova abre sem perder nada).
class ElementCatalog {
  ElementCatalog._();

  /// Tamanho inicial em células da grade de [columns] colunas. A ficha está
  /// em células da grade normal (6); na fina (12) tudo dobra, para o
  /// elemento nascer com o mesmo tamanho na tela.
  static (int, int) defaultSize(ElementType type, int columns) {
    final info = of(type);
    final k = HmiScreen.scaleOf(columns);
    final (mw, _) = minSize(type, columns);
    return ((info.defaultW * k).clamp(mw, columns), info.defaultH * k);
  }

  /// Posição e tamanho aceitos: dentro da grade, acima do mínimo e sem
  /// sobrepor outro elemento. O arrasto do editor e os botões de ajuste usam
  /// a mesma regra.
  static bool fits(HmiScreen screen, HmiElement c) {
    if (c.x < 0 || c.y < 0 || c.right > screen.columns) return false;
    final (minW, minH) = minSize(c.type, screen.columns);
    if (c.w < minW || c.h < minH) return false;
    return !screen.elements.any((o) => o.id != c.id && o.overlaps(c));
  }

  /// Menor tamanho aceito. Na grade fina o mínimo dobra — exceto a altura de
  /// quem cabe numa linha só (valor, lâmpada, indicador, texto), que pode
  /// descer a uma célula fina para caber mais variáveis por tela. Quem grava
  /// (botão, ajuste) nunca desce de 2×2 na fina: ~60 dp, acima dos 48 dp de
  /// alvo de toque.
  static (int, int) minSize(ElementType type, int columns) {
    final info = of(type);
    final k = HmiScreen.scaleOf(columns);
    if (k == 1) return (info.minW, info.minH);
    final oneLine = !info.writes &&
        (type == ElementType.value || type == ElementType.lamp || type == ElementType.multistate || type == ElementType.label);
    return (info.minW * k, oneLine ? 1 : info.minH * k);
  }

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
      // 3 de largura: com 2, rótulo + bolinha + texto não cabem ("FACA ACIO…").
      defaultW: 3,
      defaultH: 1,
    ),
    ElementInfo(
      type: ElementType.value,
      name: 'Mostrador',
      description: 'Um valor ou texto em destaque.',
      icon: Icons.pin_outlined,
      fit: TagFit.any,
      defaultW: 3,
      defaultH: 2,
    ),
    // Vizinha do mostrador na paleta: "um valor" e "vários valores".
    ElementInfo(
      type: ElementType.table,
      name: 'Tabela de valores',
      description: 'Várias variáveis, uma por linha.',
      icon: Icons.table_rows_outlined,
      fit: TagFit.any,
      // Largura toda e 4 de altura: cabem 5 a 7 linhas no celular. Na fina,
      // 12×8 — o mesmo tamanho na tela.
      defaultW: 6,
      defaultH: 4,
      minW: 3,
      minH: 2,
      multiTag: true,
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
    // Vizinho do medidor: os dois são "indicador com faixas".
    ElementInfo(
      type: ElementType.oee,
      name: 'OEE',
      description: 'Eficiência global da máquina.',
      icon: Icons.space_dashboard_outlined,
      // Quatro variáveis, cada uma num papel: a configuração tem a seção
      // própria (como a imagem por etapa), não a escolha única do topo. O
      // "usada em" vê as vagas pela lista `tagIds` e pede número.
      fit: TagFit.none,
      // Largura toda e 3 de altura: no celular de 320 dp o OEE e as três
      // parcelas cabem lado a lado, com os nomes inteiros. Na fina, 12×6.
      defaultW: 6,
      defaultH: 3,
      minW: 3,
      minH: 3,
    ),
    ElementInfo(
      type: ElementType.trend,
      name: 'Gráfico de tendência',
      // Curta: o nome já ocupa 2 linhas no cartão da paleta e a frase longa
      // aparecia cortada ("Curva dos últimos…").
      description: 'Curva no tempo.',
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
      description: 'Fixa, ou uma por etapa.',
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
      case ElementType.table:
        // Sem título por padrão: o nome da tela já está no topo, e a linha
        // do título vale mais como uma variável a mais.
        return {
          'tagIds': [if (tag != null) tag.id],
          'label': '',
          'onText': 'LIGADO',
          'offText': 'DESLIGADO',
        };
      case ElementType.oee:
        // Uma variável solta não tem papel (disponibilidade? qualidade?):
        // começa sem nenhuma, e a configuração pede uma por vaga.
        return {'label': 'OEE', 'source': 'calc', 'scale': 'percent'};
      case ElementType.unknown:
        return const {};
    }
  }
}
