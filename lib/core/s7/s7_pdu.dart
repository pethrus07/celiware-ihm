import 'dart:typed_data';

import 's7_address.dart';

/// Montagem e leitura das mensagens S7 do lado do cliente — funções puras,
/// testáveis sem rede (como `ModbusPdu`).
///
/// Uma mensagem na rede tem três camadas:
///
/// ```
///  TPKT (RFC 1006)   [03][00][tamanho total hi][lo]
///  COTP (ISO 8073)   CR/CC na abertura; depois DT: [02][F0][80]
///  S7comm            [32][ROSCTR][00 00][ref hi][lo][param hi][lo][dados hi][lo]
///                    (+ [classe][código] de erro nas respostas) + parâmetros + dados
/// ```
///
/// O "tamanho de PDU" negociado no Setup Communication vale para a camada
/// S7 (cabeçalho + parâmetros + dados), sem TPKT e COTP.
abstract final class S7Pdu {
  // ── Constantes do protocolo ──────────────────────────────────────────────────

  static const int protocolId = 0x32;

  /// ROSCTR: tipo da mensagem S7.
  static const int job = 0x01;
  static const int ack = 0x02;
  static const int ackData = 0x03;

  static const int fnSetup = 0xF0;
  static const int fnRead = 0x04;
  static const int fnWrite = 0x05;

  /// Tamanho de transporte no item do pedido.
  static const int tsBit = 0x01;
  static const int tsByte = 0x02;

  /// Tamanho de transporte na parte de dados (pedido de escrita e resposta
  /// de leitura). BIT, BYTE e INT contam o tamanho em **bits**; REAL e
  /// OCTET STRING, em bytes.
  static const int dataBit = 0x03;
  static const int dataByte = 0x04;
  static const int dataInt = 0x05;
  static const int dataReal = 0x07;
  static const int dataOctet = 0x09;

  /// Código de retorno de item bem-sucedido.
  static const int itemOk = 0xFF;

  /// Cabeçalho do pedido (Job) e da resposta (Ack_Data, com erro).
  static const int jobHeader = 10;
  static const int ackHeader = 12;

  // ── TPKT + COTP ──────────────────────────────────────────────────────────────

  /// Envelope TPKT: versão 3, tamanho total incluindo os 4 bytes dele.
  static Uint8List tpkt(List<int> payload) {
    final total = payload.length + 4;
    return Uint8List(total)
      ..[0] = 0x03
      ..[1] = 0x00
      ..[2] = (total >> 8) & 0xFF
      ..[3] = total & 0xFF
      ..setRange(4, total, payload);
  }

  /// COTP Connection Request com os TSAPs de origem e destino. O TSAP de
  /// destino diz ao CLP com qual CPU conversar (rack/slot) e o tipo da
  /// conexão; TPDU de 1024 bytes (código 0x0A = 2^10).
  static Uint8List connectionRequest({required int localTsap, required int remoteTsap, int tpduSizeCode = 0x0A}) {
    return tpkt([
      0x11, // tamanho do cabeçalho COTP (sem este byte)
      0xE0, // CR
      0x00, 0x00, // referência de destino
      0x00, 0x01, // referência de origem
      0x00, // classe 0
      0xC0, 0x01, tpduSizeCode, // tamanho da TPDU
      0xC1, 0x02, (localTsap >> 8) & 0xFF, localTsap & 0xFF, // TSAP de origem
      0xC2, 0x02, (remoteTsap >> 8) & 0xFF, remoteTsap & 0xFF, // TSAP de destino
    ]);
  }

  /// Mensagem S7 dentro de um COTP DT (último fragmento, EOT).
  static Uint8List dataFrame(Uint8List s7) => tpkt([0x02, 0xF0, 0x80, ...s7]);

  // ── Pedidos S7 ───────────────────────────────────────────────────────────────

  static Uint8List _job(int ref, List<int> param, List<int> data) {
    return Uint8List.fromList([
      protocolId, job, 0x00, 0x00,
      (ref >> 8) & 0xFF, ref & 0xFF,
      (param.length >> 8) & 0xFF, param.length & 0xFF,
      (data.length >> 8) & 0xFF, data.length & 0xFF,
      ...param,
      ...data,
    ]);
  }

  /// Setup Communication: pede um tamanho de PDU; o CLP responde com o que
  /// aceita (240 no 300/1200, 480 no 400, 960 no 1500).
  static Uint8List setupCommunication(int ref, int pduSize, {int maxJobs = 1}) {
    return _job(ref, [
      fnSetup, 0x00,
      (maxJobs >> 8) & 0xFF, maxJobs & 0xFF, // trabalhos em paralelo (chamador)
      (maxJobs >> 8) & 0xFF, maxJobs & 0xFF, // trabalhos em paralelo (chamado)
      (pduSize >> 8) & 0xFF, pduSize & 0xFF,
    ], const []);
  }

  /// Read Var com vários itens.
  static Uint8List readRequest(int ref, List<S7ItemSpec> items) {
    return _job(ref, [fnRead, items.length, for (final i in items) ...i.bytes], const []);
  }

  /// Write Var: cada item com os bytes a gravar. Item de bit grava 1 byte
  /// (0 ou 1) com tamanho de transporte BIT; os outros, BYTE.
  static Uint8List writeRequest(int ref, List<S7ItemSpec> items, List<Uint8List> values) {
    final data = <int>[];
    for (var k = 0; k < items.length; k++) {
      final v = values[k];
      final bit = items[k].transportSize == tsBit;
      final length = bit ? 1 : v.length * 8; // em bits
      data
        ..addAll([0x00, bit ? dataBit : dataByte, (length >> 8) & 0xFF, length & 0xFF])
        ..addAll(v);
      // Entre itens, dado de tamanho ímpar leva um byte de enchimento.
      if (v.length.isOdd && k < items.length - 1) data.add(0x00);
    }
    return _job(ref, [fnWrite, items.length, for (final i in items) ...i.bytes], data);
  }

  // ── Tamanhos (para caber na PDU negociada) ───────────────────────────────────

  /// Bytes do pedido de leitura com [items] itens.
  static int readRequestSize(int items) => jobHeader + 2 + 12 * items;

  /// Bytes da resposta de leitura com estes tamanhos de dado.
  static int readResponseSize(List<int> lengths) {
    var size = ackHeader + 2;
    for (var k = 0; k < lengths.length; k++) {
      size += 4 + lengths[k] + (lengths[k].isOdd && k < lengths.length - 1 ? 1 : 0);
    }
    return size;
  }

  /// Bytes do pedido de escrita com estes tamanhos de dado.
  static int writeRequestSize(List<int> lengths) {
    var size = jobHeader + 2 + 12 * lengths.length;
    for (var k = 0; k < lengths.length; k++) {
      size += 4 + lengths[k] + (lengths[k].isOdd && k < lengths.length - 1 ? 1 : 0);
    }
    return size;
  }

  // ── Respostas ────────────────────────────────────────────────────────────────

  /// Separa cabeçalho, parâmetros e dados. Lança [FormatException] se a
  /// mensagem não for S7 ou os tamanhos não baterem.
  static S7Message parse(Uint8List pdu) {
    if (pdu.length < jobHeader || pdu[0] != protocolId) {
      throw const FormatException('mensagem não é S7');
    }
    final rosctr = pdu[1];
    final header = rosctr == ack || rosctr == ackData ? ackHeader : jobHeader;
    if (pdu.length < header) throw const FormatException('cabeçalho S7 incompleto');
    final paramLength = (pdu[6] << 8) | pdu[7];
    final dataLength = (pdu[8] << 8) | pdu[9];
    if (pdu.length < header + paramLength + dataLength) {
      throw FormatException('mensagem S7 cortada: ${pdu.length} de ${header + paramLength + dataLength} bytes');
    }
    return S7Message(
      rosctr: rosctr,
      ref: (pdu[4] << 8) | pdu[5],
      errorClass: header == ackHeader ? pdu[10] : 0,
      errorCode: header == ackHeader ? pdu[11] : 0,
      param: Uint8List.sublistView(pdu, header, header + paramLength),
      data: Uint8List.sublistView(pdu, header + paramLength, header + paramLength + dataLength),
    );
  }

  /// Tamanho de PDU aceito pelo CLP, da resposta ao Setup Communication.
  static int negotiatedPduSize(S7Message m) {
    if (m.param.length < 8 || m.param[0] != fnSetup) {
      throw const FormatException('resposta ao Setup Communication sem os parâmetros');
    }
    return (m.param[6] << 8) | m.param[7];
  }

  /// Itens da resposta de leitura, na ordem do pedido: código de retorno e
  /// os bytes (vazio quando o item falhou).
  static List<S7ItemData> parseReadData(S7Message m, int count) {
    if (m.param.length < 2 || m.param[0] != fnRead) throw const FormatException('resposta não é de leitura');
    if (m.param[1] != count) {
      throw FormatException('pedidos $count itens, vieram ${m.param[1]}');
    }
    final d = m.data;
    final out = <S7ItemData>[];
    var p = 0;
    for (var k = 0; k < count; k++) {
      if (p + 4 > d.length) throw FormatException('item ${k + 1} cortado');
      final code = d[p];
      final ts = d[p + 1];
      final raw = (d[p + 2] << 8) | d[p + 3];
      final bits = ts == dataBit || ts == dataByte || ts == dataInt;
      final length = code == itemOk && bits ? (raw + 7) >> 3 : raw;
      p += 4;
      if (code != itemOk) {
        out.add(S7ItemData(code, Uint8List(0)));
        p += length; // normalmente 0
      } else {
        if (p + length > d.length) throw FormatException('item ${k + 1} cortado');
        out.add(S7ItemData(code, Uint8List.fromList(d.sublist(p, p + length)), ts));
        p += length;
      }
      if (length.isOdd && k < count - 1) p++;
    }
    return out;
  }

  /// Códigos de retorno da resposta de escrita, um por item.
  static List<int> parseWriteData(S7Message m, int count) {
    if (m.param.length < 2 || m.param[0] != fnWrite) throw const FormatException('resposta não é de escrita');
    if (m.param[1] != count || m.data.length < count) {
      throw FormatException('escritos $count itens, vieram ${m.param[1]} códigos');
    }
    return List<int>.of(m.data.take(count));
  }
}

/// Item do pedido no formato S7ANY: área, DB, endereço em bits e quantos
/// elementos do tamanho de transporte.
class S7ItemSpec {
  const S7ItemSpec({
    required this.transportSize,
    required this.count,
    required this.dbNumber,
    required this.areaCode,
    required this.bitAddress,
  });

  /// Bit: transporte BIT, 1 elemento. Faixa: transporte BYTE, [byteLength]
  /// elementos — tudo que não é bit vai como bytes e o codec interpreta.
  factory S7ItemSpec.of(S7Address a) => a.isBit
      ? S7ItemSpec(
          transportSize: S7Pdu.tsBit,
          count: 1,
          dbNumber: a.dbNumber,
          areaCode: a.area.code,
          bitAddress: a.byteOffset * 8 + a.bitIndex!)
      : S7ItemSpec(
          transportSize: S7Pdu.tsByte,
          count: a.byteLength,
          dbNumber: a.dbNumber,
          areaCode: a.area.code,
          bitAddress: a.byteOffset * 8);

  final int transportSize;
  final int count;
  final int dbNumber;
  final int areaCode;
  final int bitAddress;

  /// Bytes de dado que este item move.
  int get dataBytes => transportSize == S7Pdu.tsBit ? 1 : count;

  List<int> get bytes => [
        0x12, // especificação de variável
        0x0A, // bytes que seguem
        0x10, // sintaxe S7ANY
        transportSize,
        (count >> 8) & 0xFF, count & 0xFF,
        (dbNumber >> 8) & 0xFF, dbNumber & 0xFF,
        areaCode,
        (bitAddress >> 16) & 0xFF, (bitAddress >> 8) & 0xFF, bitAddress & 0xFF,
      ];
}

/// Mensagem S7 separada nas partes.
class S7Message {
  const S7Message({
    required this.rosctr,
    required this.ref,
    required this.errorClass,
    required this.errorCode,
    required this.param,
    required this.data,
  });

  final int rosctr;
  final int ref;
  final int errorClass;
  final int errorCode;
  final Uint8List param;
  final Uint8List data;

  bool get hasError => errorClass != 0 || errorCode != 0;
}

/// Um item da resposta de leitura.
class S7ItemData {
  const S7ItemData(this.code, this.bytes, [this.transportSize = 0]);
  final int code;
  final Uint8List bytes;

  /// Tamanho de transporte da resposta ([S7Pdu.dataBit], [S7Pdu.dataByte]…).
  final int transportSize;

  bool get ok => code == S7Pdu.itemOk;
}
