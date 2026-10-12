import 'package:flutter/foundation.dart';

import '../../../core/modbus/modbus_client.dart';
import '../../../models/device.dart';
import '../../../models/tag.dart';
import '../tag_codec.dart';
import '../tag_store.dart';
import 'modbus_driver.dart';
import 'mqtt_driver.dart';
import 's7_driver.dart';
import 'raw_driver.dart';

/// O que muda de um protocolo para outro, atrás de um contrato só.
///
/// A [DeviceSession] continua dona do laço, da espera crescente depois de
/// uma queda e da saúde da conexão; o driver só sabe falar com o equipamento:
/// conectar, ler as variáveis em uso e publicar no [TagStore], ler uma
/// avulsa, gravar e provar que há alguém do outro lado.
///
/// Erro de comunicação sai como `CommError` (a sessão marca tudo "sem
/// comunicação" e tenta de novo). Erro de uma variável só — endereço que não
/// existe, pedido fora do limite — o driver resolve publicando a qualidade
/// daquela variável, sem derrubar as outras.
abstract class DeviceDriver {
  /// Estado da ligação, para o selo na interface.
  ValueListenable<ModbusLinkState> get state;

  bool get isConnected => state.value == ModbusLinkState.connected;

  /// O tempo de uma varredura mede a rede (vai para o selo: "Online · 42 ms").
  /// Driver de assinatura não pergunta nada na varredura — o número seria 0.
  bool get reportsScanTime => true;

  /// O driver pede uma varredura já (ex.: separou um bloco para achar o
  /// endereço errado). A sessão liga isto ao próprio "acordar".
  VoidCallback? onWake;

  Future<void> connect();
  Future<void> disconnect();

  /// Lê as variáveis em uso e publica no [store]. Devolve quantas leituras fez
  /// (vai para o selo). Para no meio se [stillCurrent] ficar falso.
  Future<int> scan(List<Tag> tags, TagStore store, {required bool Function() stillCurrent});

  /// Lê uma variável agora, fora da varredura ("lendo agora" do cadastro).
  Future<Object> readOnce(Tag tag);

  /// Grava [value]. Lança `TagValueError` (valor inválido) ou `CommError`.
  Future<void> write(Tag tag, Object value);

  /// Prova mínima de que há um equipamento respondendo (teste de conexão sem
  /// variável).
  Future<void> ping();

  /// As variáveis em uso mudaram (ex.: endereço corrigido).
  void tagsChanged(List<Tag> previous, List<Tag> current) {}

  Future<void> dispose();

  /// O driver certo para o tipo de equipamento. [clientFactory] fica exposto
  /// para os testes trocarem o transporte Modbus.
  static DeviceDriver forDevice(Device device, {required ModbusClient Function(Device) clientFactory}) {
    switch (device.kind) {
      case DeviceKind.modbusTcp:
      case DeviceKind.modbusRtuTcp:
      case DeviceKind.demo:
        return ModbusDriver(clientFactory(device));
      case DeviceKind.mqtt:
        return MqttDriver(device);
      case DeviceKind.s7:
        return S7Driver(device);
      case DeviceKind.raw:
        return RawDriver(device);
      case DeviceKind.usbSerial:
        // Pelo cabo fala Modbus (RTU/ASCII) ou a mensagem de um Arduino.
        return device.serial.isRaw ? RawDriver(device) : ModbusDriver(clientFactory(device));
      case DeviceKind.calc:
        // As contas leem o projeto e o TagStore: quem monta o CalcDriver é o
        // HmiRuntime, que tem os dois. Aqui só chega um "Testar conexão".
        throw const TagValueError('Variáveis calculadas não têm conexão para testar');
    }
  }
}
