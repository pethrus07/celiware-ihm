import 'dart:typed_data';

/// Envelope das mensagens Modbus fora do TCP: RTU (binário + CRC16) e ASCII
/// (texto hexadecimal + LRC). A PDU é a mesma do Modbus TCP; só muda a
/// embalagem e como se sabe onde a mensagem termina.
///
/// ```
/// RTU:   [unit][PDU…][CRC lo][CRC hi]
/// ASCII: ':' + hex(unit PDU… LRC) + '\r\n'
/// ```
enum ModbusFraming {
  /// Binário com CRC16 — o padrão em RS-485 (inversores, CLPs, medidores).
  rtu,

  /// Texto com LRC — linhas antigas e alguns CLPs (tipicamente 7E1).
  ascii,
}

extension ModbusFramingMeta on ModbusFraming {
  String get label => this == ModbusFraming.rtu ? 'RTU' : 'ASCII';

  static ModbusFraming fromName(String? n) => n == 'ascii' ? ModbusFraming.ascii : ModbusFraming.rtu;
}

class ModbusFrames {
  ModbusFrames._();

  // ── RTU ─────────────────────────────────────────────────────────────────────

  /// CRC16 Modbus (polinômio 0xA001, semente 0xFFFF).
  static int crc16(List<int> bytes, [int start = 0, int? end]) {
    var crc = 0xFFFF;
    for (var i = start; i < (end ?? bytes.length); i++) {
      crc ^= bytes[i] & 0xFF;
      for (var b = 0; b < 8; b++) {
        crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1;
      }
    }
    return crc;
  }

  static Uint8List rtu(int unit, Uint8List pdu) {
    final out = Uint8List(pdu.length + 3)
      ..[0] = unit & 0xFF
      ..setRange(1, 1 + pdu.length, pdu);
    final crc = crc16(out, 0, pdu.length + 1);
    out[pdu.length + 1] = crc & 0xFF; // byte baixo primeiro
    out[pdu.length + 2] = (crc >> 8) & 0xFF;
    return out;
  }

  /// Quantos bytes tem a resposta RTU que começa em [buf], ou nulo se ainda
  /// não dá para saber. Serial não tem cabeçalho de tamanho: o fim vem do
  /// código da função (o silêncio de 3,5 caracteres da norma não é confiável
  /// atrás de USB e de gateways).
  static int? rtuResponseLength(List<int> buf) {
    if (buf.length < 2) return null;
    final fc = buf[1];
    if (fc & 0x80 != 0) return 5; // unit, fc|0x80, código, CRC×2
    switch (fc) {
      case 0x01:
      case 0x02:
      case 0x03:
      case 0x04:
        if (buf.length < 3) return null;
        return 3 + buf[2] + 2; // unit, fc, contagem, dados, CRC×2
      case 0x05:
      case 0x06:
      case 0x0F:
      case 0x10:
        return 8; // eco: unit, fc, endereço×2, valor/quantidade×2, CRC×2
      default:
        return null;
    }
  }

  /// Confere o CRC e devolve (unit, PDU).
  static (int, Uint8List) parseRtu(List<int> frame) {
    if (frame.length < 5) throw const FormatException('quadro RTU curto demais');
    final n = frame.length;
    final crc = crc16(frame, 0, n - 2);
    if ((frame[n - 2] | (frame[n - 1] << 8)) != crc) throw const FormatException('CRC não confere');
    return (frame[0], Uint8List.fromList(frame.sublist(1, n - 2)));
  }

  // ── ASCII ───────────────────────────────────────────────────────────────────

  /// LRC: complemento de dois da soma dos bytes.
  static int lrc(List<int> bytes) {
    var sum = 0;
    for (final b in bytes) {
      sum = (sum + (b & 0xFF)) & 0xFF;
    }
    return (-sum) & 0xFF;
  }

  static Uint8List ascii(int unit, Uint8List pdu) {
    final body = [unit & 0xFF, ...pdu];
    final hex = StringBuffer(':');
    for (final b in [...body, lrc(body)]) {
      hex.write(b.toRadixString(16).toUpperCase().padLeft(2, '0'));
    }
    hex.write('\r\n');
    return Uint8List.fromList(hex.toString().codeUnits);
  }

  /// Índice logo após o '\n' do primeiro quadro ASCII completo, ou nulo.
  static int? asciiFrameEnd(List<int> buf) {
    final i = buf.indexOf(0x0A);
    return i < 0 ? null : i + 1;
  }

  /// Confere o LRC e devolve (unit, PDU). Tolera lixo antes do ':'.
  static (int, Uint8List) parseAscii(List<int> frame) {
    final text = String.fromCharCodes(frame).trim();
    final start = text.indexOf(':');
    if (start < 0) throw const FormatException('quadro ASCII sem ":"');
    final hex = text.substring(start + 1);
    if (hex.length < 6 || hex.length.isOdd) throw const FormatException('quadro ASCII malformado');
    final bytes = <int>[];
    for (var i = 0; i < hex.length; i += 2) {
      final v = int.tryParse(hex.substring(i, i + 2), radix: 16);
      if (v == null) throw const FormatException('quadro ASCII com caractere inválido');
      bytes.add(v);
    }
    final body = bytes.sublist(0, bytes.length - 1);
    if (lrc(body) != bytes.last) throw const FormatException('LRC não confere');
    return (body.first, Uint8List.fromList(body.sublist(1)));
  }
}
