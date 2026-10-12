import 'package:flutter/foundation.dart';

import '../link/byte_link.dart';

/// Paridade da linha serial: o bit a mais que cada caractere leva para
/// conferir se chegou inteiro.
enum SerialParity {
  none('N', 'Nenhuma'),
  even('E', 'Par'),
  odd('O', 'Ímpar');

  const SerialParity(this.letter, this.label);

  /// A letra do "8N1", "7E1".
  final String letter;
  final String label;

  static SerialParity fromName(String? n) => values.firstWhere((p) => p.name == n, orElse: () => none);
}

/// Como os bits andam no fio: velocidade, bits de dados, paridade e parada.
/// Os dois lados precisam estar iguais — diferente, chega lixo ou nada.
@immutable
class SerialParams {
  const SerialParams({this.baud = 9600, this.dataBits = 8, this.parity = SerialParity.none, this.stopBits = 1});

  /// As velocidades que o cadastro oferece (as de manual de CLP e inversor).
  static const List<int> bauds = [1200, 2400, 4800, 9600, 19200, 38400, 57600, 115200];

  /// O padrão do Modbus ASCII (7 bits, paridade par, 1 de parada).
  static const SerialParams ascii = SerialParams(dataBits: 7, parity: SerialParity.even);

  final int baud;
  final int dataBits;
  final SerialParity parity;
  final int stopBits;

  /// Bits que um caractere ocupa no fio: início + dados + paridade + parada.
  int get bitsPerChar => 1 + dataBits + (parity == SerialParity.none ? 0 : 1) + stopBits;

  /// Quanto um caractere leva no fio (9600 8N1: 1,04 ms).
  Duration get charTime => Duration(microseconds: (bitsPerChar * 1000000 / baud).ceil());

  /// O silêncio de 3,5 caracteres da norma Modbus RTU (t3.5): é o que separa
  /// um quadro do outro. Acima de 19200 a norma fixa 1,75 ms.
  Duration get t35 => baud > 19200 ? const Duration(microseconds: 1750) : Duration(microseconds: (charTime.inMicroseconds * 3.5).ceil());

  /// "9600 8N1".
  String get label => '$baud $dataBits${parity.letter}$stopBits';

  SerialParams copyWith({int? baud, int? dataBits, SerialParity? parity, int? stopBits}) => SerialParams(
        baud: baud ?? this.baud,
        dataBits: dataBits ?? this.dataBits,
        parity: parity ?? this.parity,
        stopBits: stopBits ?? this.stopBits,
      );

  /// Só o que difere do padrão (9600 8N1): equipamento de fábrica não grava nada.
  Map<String, dynamic> toJson() => {
        if (baud != 9600) 'baud': baud,
        if (dataBits != 8) 'dataBits': dataBits,
        if (parity != SerialParity.none) 'parity': parity.name,
        if (stopBits != 1) 'stopBits': stopBits,
      };

  /// Arquivo editado à mão não vira configuração impossível: velocidade fora
  /// da faixa volta a 9600, bits só 7 ou 8, parada só 1 ou 2.
  factory SerialParams.fromJson(Map<String, dynamic> j) {
    final baud = j['baud'];
    final bits = j['dataBits'];
    final stop = j['stopBits'];
    return SerialParams(
      baud: baud is int && baud >= 300 && baud <= 921600 ? baud : 9600,
      dataBits: bits == 7 ? 7 : 8,
      parity: SerialParity.fromName(j['parity'] as String?),
      stopBits: stop == 2 ? 2 : 1,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SerialParams && other.baud == baud && other.dataBits == dataBits && other.parity == parity && other.stopBits == stopBits;

  @override
  int get hashCode => Object.hash(baud, dataBits, parity, stopBits);

  @override
  String toString() => label;
}

/// Um pedaço de bytes da linha serial e a pausa que veio antes dele.
///
/// A pausa é medida onde os bytes chegam (no Android, na leitura do USB),
/// não quando o Dart os vê: a interface ocupada atrasaria a entrega e
/// pareceria silêncio na linha.
@immutable
class SerialChunk {
  const SerialChunk(this.bytes, {this.gapBefore});

  final Uint8List bytes;

  /// Tempo entre o pedaço anterior e este; nulo no primeiro.
  final Duration? gapBefore;
}

/// Um cano que é uma linha serial de verdade (adaptador USB-OTG): sabe a
/// velocidade, mede as pausas entre os pedaços e é dividido entre quem fala
/// por ela — numa RS-485, vários escravos (inversor ID 1, ID 2…) ficam no
/// mesmo par de fios e no mesmo adaptador.
abstract class SerialLink extends ByteLink {
  /// Velocidade, bits, paridade e parada de quem pegou este cano.
  SerialParams get params;

  /// Os mesmos bytes de [input], com a pausa antes de cada pedaço.
  Stream<SerialChunk> get chunks;

  /// Roda [action] com a linha só para si, nos parâmetros deste cano: um
  /// pedido Modbus e a resposta dele não podem se misturar com o de outro
  /// equipamento da mesma linha.
  Future<T> exclusive<T>(Future<T> Function() action);
}
