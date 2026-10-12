// Cabo USB (adaptador RS-485/RS-232 no USB-OTG do celular): qual adaptador,
// como os bits andam no fio e o que fala por ele.
//
// Como no S7 e no MQTT, fica fora de Device para quem não usa: só vai para o
// JSON quando o equipamento é do tipo cabo USB, e só com o que difere do
// padrão (Modbus RTU, 9600 8N1).

import 'package:flutter/foundation.dart';

import '../core/modbus/modbus_framing.dart';
import '../core/serial/serial_params.dart';
import '../core/serial/usb_serial.dart';

/// O que fala pelo cabo.
enum SerialProtocol {
  /// Modbus RTU: inversor, CLP, medidor na RS-485 — o comum.
  rtu('Modbus RTU', 'RTU'),

  /// Modbus ASCII: linhas antigas, quase sempre 7E1.
  ascii('Modbus ASCII', 'ASCII'),

  /// Arduino ou leitor com a própria mensagem (`T=25.3;P=1`), lida pelo
  /// perfil do protocolo cru.
  raw('Arduino / mensagem própria', 'Arduino');

  const SerialProtocol(this.label, this.short);
  final String label;
  final String short;

  static SerialProtocol fromName(String? n) => values.firstWhere((p) => p.name == n, orElse: () => rtu);
}

@immutable
class SerialConfig {
  const SerialConfig({this.port, this.params = const SerialParams(), this.protocol = SerialProtocol.rtu, this.discardEcho = false});

  /// O adaptador escolhido. Nulo = o único adaptador serial plugado.
  final UsbPortRef? port;
  final SerialParams params;
  final SerialProtocol protocol;

  /// Modbus: descartar desde o primeiro pedido o eco do adaptador RS-485 de
  /// 2 fios. Sem isto o eco é percebido na primeira leitura e descartado
  /// sozinho dali em diante.
  final bool discardEcho;

  bool get isRaw => protocol == SerialProtocol.raw;

  /// O envelope do Modbus (sem sentido no Arduino).
  ModbusFraming get framing => protocol == SerialProtocol.ascii ? ModbusFraming.ascii : ModbusFraming.rtu;

  /// DTR ligado só no Arduino: o Leonardo e o Micro só começam a mandar com
  /// ele (o Uno reinicia, como no Monitor Serial). Em adaptador RS-485 o sinal
  /// fica como o adaptador quer — alguns usam RTS/DTR para virar a linha.
  bool get dtr => isRaw;

  /// "CH340 · RTU · 9600 8N1".
  String get label => [port?.label ?? 'USB', protocol.short, params.label].join(' · ');

  SerialConfig copyWith({SerialParams? params, SerialProtocol? protocol, bool? discardEcho}) => SerialConfig(
        port: port,
        params: params ?? this.params,
        protocol: protocol ?? this.protocol,
        discardEcho: discardEcho ?? this.discardEcho,
      );

  /// Troca o adaptador — inclusive para nulo, o que o [copyWith] não consegue.
  SerialConfig withPort(UsbPortRef? port) => SerialConfig(port: port, params: params, protocol: protocol, discardEcho: discardEcho);

  Map<String, dynamic> toJson() => {
        if (port != null) 'usb': port!.toJson(),
        ...params.toJson(),
        if (protocol != SerialProtocol.rtu) 'protocol': protocol.name,
        if (discardEcho) 'discardEcho': true,
      };

  factory SerialConfig.fromJson(Map<String, dynamic> j) => SerialConfig(
        port: UsbPortRef.fromJson(j['usb']),
        params: SerialParams.fromJson(j),
        protocol: SerialProtocol.fromName(j['protocol'] as String?),
        discardEcho: j['discardEcho'] == true,
      );

  @override
  bool operator ==(Object other) =>
      other is SerialConfig && other.port == port && other.params == params && other.protocol == protocol && other.discardEcho == discardEcho;

  @override
  int get hashCode => Object.hash(port, params, protocol, discardEcho);
}
