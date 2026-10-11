// Variável: o nome de um dado do equipamento.
//
// É a "variável intermediária" pedida na reunião de 24/09/2026: os elementos
// da tela nunca apontam para um endereço cru, apontam para uma variável. Isso
// dá três coisas: (1) o mesmo dado pode aparecer em vários elementos com uma
// leitura só; (2) mudar o endereço é mexer num lugar só; (3) o usuário lê
// "Velocidade da faca", não "HR 40012".

import '../core/modbus/modbus_memory.dart';
import 'alarm.dart';
import 'narration.dart';
import 'mqtt_config.dart';
import 's7_config.dart';
import 'raw_config.dart';

/// Formato do dado dentro da memória.
enum TagDataType {
  /// Liga/desliga. Em coil/entrada discreta é o próprio bit; em registrador
  /// é um bit escolhido ([Tag.bitIndex]) dentro da palavra de 16 bits.
  bool,

  /// Inteiro de 16 bits sem sinal (0..65535) — o registrador cru.
  uint16,

  /// Inteiro de 16 bits com sinal (-32768..32767).
  int16,

  /// Inteiro de 32 bits sem sinal, em 2 registradores seguidos.
  uint32,

  /// Inteiro de 32 bits com sinal, em 2 registradores seguidos.
  int32,

  /// Número com vírgula IEEE-754 (32 bits), em 2 registradores seguidos.
  float32,

  /// Texto ASCII: 2 letras por registrador, [Tag.length] registradores
  /// seguidos (nome da máquina, receita, lote). Para no primeiro byte zero.
  string,
}

extension TagDataTypeMeta on TagDataType {
  /// Quantos registradores de 16 bits um valor ocupa.
  int get registerCount {
    switch (this) {
      case TagDataType.uint32:
      case TagDataType.int32:
      case TagDataType.float32:
        return 2;
      default:
        return 1;
    }
  }

  bool get isNumeric => this != TagDataType.bool && this != TagDataType.string;
  bool get is32Bit => registerCount == 2;

  /// Nome para leigo — o que aparece no botão de escolha.
  String get label {
    switch (this) {
      case TagDataType.bool:
        return 'Liga / desliga';
      case TagDataType.uint16:
        return 'Número inteiro';
      case TagDataType.int16:
        return 'Inteiro com sinal';
      case TagDataType.uint32:
        return 'Inteiro grande';
      case TagDataType.int32:
        return 'Inteiro grande c/ sinal';
      case TagDataType.float32:
        return 'Número com vírgula';
      case TagDataType.string:
        return 'Texto';
    }
  }

  /// Nome técnico, mostrado ao lado para quem conhece.
  String get technical {
    switch (this) {
      case TagDataType.bool:
        return 'BOOL';
      case TagDataType.uint16:
        return 'UINT16';
      case TagDataType.int16:
        return 'INT16';
      case TagDataType.uint32:
        return 'UINT32';
      case TagDataType.int32:
        return 'INT32';
      case TagDataType.float32:
        return 'FLOAT32';
      case TagDataType.string:
        return 'STRING';
    }
  }

  static TagDataType fromName(String? n) => TagDataType.values
      .firstWhere((t) => t.name == n, orElse: () => TagDataType.uint16);
}

/// Ordem dos bytes dentro de um valor.
///
/// A norma Modbus só define a ordem **dentro** de um registrador (big-endian).
/// Para 32 bits cada fabricante escolhe qual palavra vem primeiro — e alguns
/// ainda trocam os bytes. As quatro combinações possíveis, com os bytes do
/// valor numerados A (mais significativo) a D:
///
/// | ordem  | registrador 1 | registrador 2 | onde aparece                    |
/// |--------|---------------|---------------|---------------------------------|
/// | ABCD   | A B           | C D           | padrão "big-endian"             |
/// | CDAB   | C D           | A B           | muito comum em CLP (word swap)  |
/// | BADC   | B A           | D C           | byte swap                       |
/// | DCBA   | D C           | B A           | little-endian completo          |
///
/// Para 16 bits só importa se os bytes estão trocados: ABCD/CDAB = normal,
/// BADC/DCBA = trocado.
enum ByteOrder { abcd, cdab, badc, dcba }

extension ByteOrderMeta on ByteOrder {
  bool get swapsBytes => this == ByteOrder.badc || this == ByteOrder.dcba;
  bool get swapsWords => this == ByteOrder.cdab || this == ByteOrder.dcba;
  String get label => name.toUpperCase();

  String get hint {
    switch (this) {
      case ByteOrder.abcd:
        return 'Padrão';
      case ByteOrder.cdab:
        return 'Palavras trocadas (comum em CLP)';
      case ByteOrder.badc:
        return 'Bytes trocados';
      case ByteOrder.dcba:
        return 'Tudo invertido';
    }
  }

  static ByteOrder fromName(String? n) => ByteOrder.values
      .firstWhere((o) => o.name == n, orElse: () => ByteOrder.abcd);
}

/// Uma variável cadastrada. Imutável.
class Tag {
  const Tag({
    required this.id,
    required this.name,
    required this.deviceId,
    this.area = ModbusArea.holdingRegister,
    this.address = 0,
    this.dataType = TagDataType.uint16,
    this.byteOrder = ByteOrder.abcd,
    this.bitIndex = 0,
    this.length = 1,
    this.writable = false,
    this.unit = '',
    this.decimals = 0,
    this.scale = 1,
    this.offset = 0,
    this.description = '',
    this.alarms = const [],
    this.narrations = const [],
    this.memory,
    this.mqtt,
    this.s7,
    this.raw,
  });

  final String id;
  final String name;
  final String deviceId;
  final ModbusArea area;

  /// Endereço Modbus base 0 (o que vai no pedido).
  final int address;

  final TagDataType dataType;
  final ByteOrder byteOrder;

  /// Só para [TagDataType.bool] em registrador: qual bit (0..15) da palavra.
  final int bitIndex;

  /// Quantos valores seguidos (1 = valor único). Maior que 1 forma uma
  /// **lista** — é o "memória inicial + tamanho" que o gráfico de barras usa
  /// (ex.: produção de cada hora do turno em 8 registradores seguidos).
  final int length;

  /// Se o operador pode alterar o valor pela tela. Áreas só-leitura (entrada
  /// discreta, input register) nunca são graváveis.
  final bool writable;

  /// Unidade exibida ao lado do número ("°C", "m/min", "pç").
  final String unit;

  /// Casas decimais exibidas. Não altera o valor, só a apresentação.
  final int decimals;

  /// Escala linear do equipamento: **valor na tela = bruto × [scale] + [offset]**.
  ///
  /// Muitos equipamentos mandam número sem vírgula e o manual diz "divida por
  /// 10" (752 = 75,2 °C) — isso é `scale = 0.1`. Vale nos dois sentidos: ao
  /// gravar 75,2 o app manda 752. Tudo que a tela mostra, compara (faixas do
  /// medidor, limites do ajuste) e grava já está na unidade de engenharia.
  final double scale;
  final double offset;

  final String description;

  /// Alarmes desta variável (ver [AlarmRule]). Moram aqui para viajar com o
  /// projeto e sumir junto quando a variável for apagada.
  final List<AlarmRule> alarms;

  /// Narrações por voz (ver [EventNarration]): "quando valer 1, falar 'A
  /// máquina está iniciando'". Moram aqui pelo mesmo motivo dos alarmes.
  final List<EventNarration> narrations;

  /// A memória como no manual do CLP ("D200", "X10", "F3-12"), quando o
  /// equipamento tem perfil de fabricante. É só o texto que a pessoa conhece:
  /// [area] e [address] continuam sendo a verdade da varredura. Nulo no Modbus
  /// genérico.
  final String? memory;

  /// "D200 · HR 200" na lista; sem perfil, só o endereço Modbus.
  String get memoryLabel => memory == null ? addressLabel : '$memory · $addressLabel';
  /// Endereço MQTT (tópico, campo do JSON, comando). Só em variável de
  /// equipamento MQTT; aí área e endereço Modbus ficam no padrão e ninguém lê.
  final MqttAddress? mqtt;

  /// Endereço Siemens S7 como no TIA ("DB1.DBW4", "M10.3"). Só em variável
  /// de CLP S7; aí, como no MQTT, área e endereço Modbus ficam no padrão.
  final S7TagAddress? s7;
  /// Campo da mensagem de um equipamento cru (Arduino): a chave, a validade e
  /// o comando para gravar. Como no MQTT, área e endereço Modbus ficam no
  /// padrão e ninguém lê.
  final RawAddress? raw;

  /// Variável lida de um bit dentro de um registrador.
  bool get isBitOfRegister => dataType == TagDataType.bool && !area.isBit;

  /// Texto ocupa [length] registradores mas é **um** valor, não uma lista.
  bool get isArray => length > 1 && dataType != TagDataType.string;

  bool get isText => dataType == TagDataType.string;

  bool get hasScale => dataType.isNumeric && (scale != 1 || offset != 0);

  /// Casas decimais de fato usadas na tela: as pedidas, ou as que a escala
  /// cria (÷10 → 1 casa) quando ninguém pediu — senão 752 × 0,1 apareceria
  /// arredondado para 75.
  int get displayDecimals {
    if (decimals > 0 || !hasScale) return decimals;
    for (var d = 0; d <= 6; d++) {
      final f = scale * _pow10(d), o = offset * _pow10(d);
      if ((f - f.roundToDouble()).abs() < 1e-9 && (o - o.roundToDouble()).abs() < 1e-9) return d;
    }
    return 6;
  }

  static double _pow10(int d) => [1.0, 10.0, 100.0, 1000.0, 10000.0, 100000.0, 1000000.0][d];

  /// Pode escrever de fato: marcado pelo usuário **e** a área permite (no
  /// MQTT, **e** há tópico onde publicar — curinga não serve).
  /// No cru, o comando vem da variável ou do perfil do equipamento.
  bool get canWrite => writable && (mqtt?.canPublish ?? s7?.canWrite ?? (raw != null || area.isWritable));

  /// Quantas posições da área a variável ocupa (bits ou registradores).
  int get span => area.isBit ? length : dataType.registerCount * length;

  /// Endereço da última posição ocupada.
  int get lastAddress => address + span - 1;

  /// "HR 100" / "HR 100.3" / "COIL 5" / "HR 10..17" / "cortadora/estado · temp"
  /// / "DB1.DBW4".
  String get addressLabel {
    final m = mqtt;
    if (m != null) return m.label;
    final s = s7;
    if (s != null) return isArray ? '${s.address} · $length valores' : s.address;
    final r = raw;
    if (r != null) return r.label;
    final base = '${area.shortLabel} $address';
    if (isBitOfRegister) return '$base.$bitIndex';
    if (span > 1) return '${area.shortLabel} $address..$lastAddress';
    return base;
  }

  Tag copyWith({
    String? name,
    String? deviceId,
    ModbusArea? area,
    int? address,
    TagDataType? dataType,
    ByteOrder? byteOrder,
    int? bitIndex,
    int? length,
    bool? writable,
    String? unit,
    int? decimals,
    double? scale,
    double? offset,
    String? description,
    List<AlarmRule>? alarms,
    List<EventNarration>? narrations,
    MqttAddress? mqtt,
    S7TagAddress? s7,
    RawAddress? raw,
  }) =>
      Tag(
        id: id,
        name: name ?? this.name,
        deviceId: deviceId ?? this.deviceId,
        area: area ?? this.area,
        address: address ?? this.address,
        dataType: dataType ?? this.dataType,
        byteOrder: byteOrder ?? this.byteOrder,
        bitIndex: bitIndex ?? this.bitIndex,
        length: length ?? this.length,
        writable: writable ?? this.writable,
        unit: unit ?? this.unit,
        decimals: decimals ?? this.decimals,
        scale: scale ?? this.scale,
        offset: offset ?? this.offset,
        description: description ?? this.description,
        alarms: alarms ?? this.alarms,
        mqtt: mqtt ?? this.mqtt,
        s7: s7 ?? this.s7,
        raw: raw ?? this.raw,
        narrations: narrations ?? this.narrations,
        memory: memory,
      );

  /// Troca o texto da memória — inclusive para nulo (endereço digitado à mão),
  /// o que o [copyWith] não consegue.
  Tag withMemory(String? memory) => Tag(
        id: id,
        name: name,
        deviceId: deviceId,
        area: area,
        address: address,
        dataType: dataType,
        byteOrder: byteOrder,
        bitIndex: bitIndex,
        length: length,
        writable: writable,
        unit: unit,
        decimals: decimals,
        scale: scale,
        offset: offset,
        description: description,
        alarms: alarms,
        narrations: narrations,
        memory: memory,
        mqtt: mqtt,
        s7: s7,
        raw: raw,
      );

  /// Corrige combinações impossíveis vindas de edição ou de arquivo antigo:
  /// área de bit força tipo liga/desliga; área só-leitura tira a escrita;
  /// escala zero (que apagaria o valor) volta a 1.
  Tag normalized() {
    var t = this;
    // MQTT, S7 e cru: os campos Modbus voltam ao padrão, para nenhuma regra
    // de área (bit força liga/desliga, entrada tira a escrita) valer sem querer.
    if ((t.mqtt != null || t.s7 != null || t.raw != null) && (t.area != ModbusArea.holdingRegister || t.address != 0 || t.bitIndex != 0 || t.byteOrder != ByteOrder.abcd)) {
      t = t.copyWith(area: ModbusArea.holdingRegister, address: 0, bitIndex: 0, byteOrder: ByteOrder.abcd);
    }
    if (t.area.isBit && t.dataType != TagDataType.bool) {
      t = t.copyWith(dataType: TagDataType.bool);
    }
    if (!t.area.isWritable && t.writable) t = t.copyWith(writable: false);
    if (t.writable && t.s7 != null && !t.s7!.canWrite) t = t.copyWith(writable: false);
    // Texto é só leitura nesta versão (nenhum elemento digita texto).
    if (t.isText && t.writable) t = t.copyWith(writable: false);
    if (t.length < 1) t = t.copyWith(length: 1);
    // Um campo da mensagem crua é um valor só: lista não existe lá.
    if (t.raw != null && t.length != 1) t = t.copyWith(length: 1);
    if (t.bitIndex < 0 || t.bitIndex > 15) t = t.copyWith(bitIndex: 0);
    if (t.scale == 0 || !t.scale.isFinite) t = t.copyWith(scale: 1);
    if (!t.offset.isFinite) t = t.copyWith(offset: 0);
    if (!t.dataType.isNumeric && (t.scale != 1 || t.offset != 0)) t = t.copyWith(scale: 1, offset: 0);
    final fits = t.alarms.where(t.acceptsAlarm).toList();
    if (fits.length != t.alarms.length) t = t.copyWith(alarms: fits);
    // Narração: mesma regra (texto e lista não falam); liga/desliga só
    // "valer 1/0"; sem texto não há o que falar.
    final says = t.narrations
        .where((n) => !t.isArray && !t.isText && n.text.trim().isNotEmpty && (t.dataType != TagDataType.bool || (n.kind == NarrationKind.equals && (n.value == 0 || n.value == 1))))
        .toList();
    if (says.length != t.narrations.length) t = t.copyWith(narrations: says);
    if (t.memory != null && t.memory!.trim().isEmpty) t = t.withMemory(null);
    return t;
  }

  /// Alarme tem que casar com o tipo: limite para número, ligar/desligar para
  /// liga/desliga; texto e lista não alarmam. O cadastro usa para avisar,
  /// na hora da troca de tipo, quais alarmes deixam de valer.
  bool acceptsAlarm(AlarmRule a) =>
      !isArray && !isText && (dataType == TagDataType.bool ? !a.kind.isAnalog : a.kind.isAnalog);

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'deviceId': deviceId,
        'area': area.name,
        'address': address,
        'dataType': dataType.name,
        'byteOrder': byteOrder.name,
        'bitIndex': bitIndex,
        'length': length,
        'writable': writable,
        'unit': unit,
        'decimals': decimals,
        // Só grava quando há escala: arquivo sem escala fica igual ao da 1.0.
        if (scale != 1) 'scale': scale,
        if (offset != 0) 'offset': offset,
        'description': description,
        if (alarms.isNotEmpty) 'alarms': [for (final a in alarms) a.toJson()],
        // Como os alarmes: só vai para o arquivo quando existe (arquivo sem
        // narração fica igual ao de antes).
        if (narrations.isNotEmpty) 'narrations': [for (final n in narrations) n.toJson()],
        // Só com perfil de fabricante: projeto genérico fica igual ao de antes.
        if (memory != null) 'memory': memory,
        if (mqtt != null) 'mqtt': mqtt!.toJson(),
        if (s7 != null) 's7': s7!.toJson(),
        if (raw != null) 'raw': raw!.toJson(),
      };

  factory Tag.fromJson(Map<String, dynamic> j) => Tag(
        id: j['id'] as String,
        name: j['name'] as String,
        deviceId: j['deviceId'] as String,
        area: ModbusArea.values.firstWhere((a) => a.name == j['area'],
            orElse: () => ModbusArea.holdingRegister),
        address: (j['address'] as int?) ?? 0,
        dataType: TagDataTypeMeta.fromName(j['dataType'] as String?),
        byteOrder: ByteOrderMeta.fromName(j['byteOrder'] as String?),
        bitIndex: (j['bitIndex'] as int?) ?? 0,
        length: (j['length'] as int?) ?? 1,
        writable: (j['writable'] as bool?) ?? false,
        unit: (j['unit'] as String?) ?? '',
        decimals: (j['decimals'] as int?) ?? 0,
        scale: (j['scale'] as num?)?.toDouble() ?? 1,
        offset: (j['offset'] as num?)?.toDouble() ?? 0,
        description: (j['description'] as String?) ?? '',
        alarms: [
          for (final a in (j['alarms'] as List? ?? const []))
            if (a is Map) AlarmRule.fromJson(Map<String, dynamic>.from(a)),
        ],
        narrations: [
          for (final n in (j['narrations'] as List? ?? const []))
            if (n is Map) EventNarration.fromJson(Map<String, dynamic>.from(n)),
        ],
        memory: j['memory'] as String?,
        mqtt: j['mqtt'] is Map ? MqttAddress.fromJson(Map<String, dynamic>.from(j['mqtt'] as Map)) : null,
        s7: j['s7'] is Map ? S7TagAddress.fromJson(Map<String, dynamic>.from(j['s7'] as Map)) : null,
        raw: j['raw'] is Map ? RawAddress.fromJson(Map<String, dynamic>.from(j['raw'] as Map)) : null,
      ).normalized();
}
