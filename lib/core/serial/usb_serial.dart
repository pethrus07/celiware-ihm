import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';

import '../comm/comm_error.dart';
import 'serial_params.dart';

/// Um adaptador (ou uma das portas dele) que o Android enxerga no USB.
@immutable
class UsbPortInfo {
  const UsbPortInfo({
    required this.deviceName,
    required this.vendorId,
    required this.productId,
    this.portIndex = 0,
    this.portCount = 1,
    this.serialNumber,
    this.chip,
    this.product,
    this.manufacturer,
    this.hasPermission = false,
  });

  /// Caminho no Android ("/dev/bus/usb/001/002"). Muda a cada vez que o
  /// adaptador é plugado: serve para abrir agora, nunca para guardar.
  final String deviceName;
  final int vendorId;
  final int productId;

  /// Adaptador com várias portas (FT2232, FT4232, CP2105): qual delas.
  final int portIndex;
  final int portCount;

  /// Número de série gravado no chip (FTDI e CP210x têm; CH340 quase nunca).
  /// Só aparece com a permissão dada.
  final String? serialNumber;

  /// O chip pelo driver que o reconheceu ("CH340", "FTDI", "CP210x",
  /// "PL2303", "CDC"); nulo = aparelho USB sem driver serial.
  final String? chip;

  /// O nome que o próprio adaptador informa ("USB2.0-Serial", "FT232R USB UART").
  final String? product;
  final String? manufacturer;

  /// O Android já deixou o app usar este adaptador.
  final bool hasPermission;

  /// Tem driver serial. Os outros aparelhos USB aparecem só para o
  /// diagnóstico ("há algo no cabo, mas não é um adaptador serial").
  bool get supported => chip != null;

  /// "1A86:7523".
  String get ids => usbIds(vendorId, productId);

  /// "CH340 · USB2.0-Serial" (e "· porta 2" no adaptador de várias portas).
  String get title => [
        chip ?? 'Aparelho USB',
        if (product != null && product!.trim().isNotEmpty) product!.trim(),
        if (portCount > 1) 'porta ${portIndex + 1}',
      ].join(' · ');

  /// A porta aberta é a mesma para quem chegar pelo mesmo caminho.
  String get key => '$deviceName#$portIndex';

  static UsbPortInfo? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final name = raw['nome'];
    final vid = raw['vid'];
    final pid = raw['pid'];
    if (name is! String || vid is! int || pid is! int) return null;
    String? text(Object? v) => v is String && v.trim().isNotEmpty ? v.trim() : null;
    return UsbPortInfo(
      deviceName: name,
      vendorId: vid,
      productId: pid,
      portIndex: (raw['porta'] as int?) ?? 0,
      portCount: (raw['portas'] as int?) ?? 1,
      serialNumber: text(raw['serie']),
      chip: text(raw['chip']),
      product: text(raw['produto']),
      manufacturer: text(raw['fabricante']),
      hasPermission: raw['permissao'] == true,
    );
  }

  UsbPortInfo withPermission(bool granted) => UsbPortInfo(
        deviceName: deviceName,
        vendorId: vendorId,
        productId: productId,
        portIndex: portIndex,
        portCount: portCount,
        serialNumber: serialNumber,
        chip: chip,
        product: product,
        manufacturer: manufacturer,
        hasPermission: granted,
      );

  @override
  String toString() => '$title ($ids, $deviceName)';
}

String usbIds(int vendorId, int productId) =>
    '${vendorId.toRadixString(16).toUpperCase().padLeft(4, '0')}:${productId.toRadixString(16).toUpperCase().padLeft(4, '0')}';

/// O adaptador escolhido no cadastro, como vai para o arquivo do projeto.
///
/// O caminho no Android muda a cada vez que o adaptador é plugado; o que
/// fica é o que o adaptador é: fabricante e modelo do chip (VID:PID), a porta
/// e, quando o chip tem, o número de série — com dois adaptadores iguais no
/// mesmo hub, é ele que diz qual é qual.
@immutable
class UsbPortRef {
  const UsbPortRef({required this.vendorId, required this.productId, this.portIndex = 0, this.serialNumber, this.chip, this.product});

  factory UsbPortRef.of(UsbPortInfo p) => UsbPortRef(
        vendorId: p.vendorId,
        productId: p.productId,
        portIndex: p.portIndex,
        serialNumber: p.serialNumber,
        chip: p.chip,
        product: p.product,
      );

  final int vendorId;
  final int productId;
  final int portIndex;
  final String? serialNumber;

  /// Para mostrar enquanto o adaptador não está plugado.
  final String? chip;
  final String? product;

  String get ids => usbIds(vendorId, productId);

  /// "CH340" (ou "1A86:7523" sem o nome do chip).
  String get label => chip ?? ids;

  /// "CH340 · USB2.0-Serial".
  String get title => [label, ?product].join(' · ');

  bool matches(UsbPortInfo p) =>
      p.vendorId == vendorId &&
      p.productId == productId &&
      p.portIndex == portIndex &&
      (serialNumber == null || p.serialNumber == null || p.serialNumber == serialNumber);

  /// O adaptador conectado que corresponde a este — o de mesmo número de
  /// série primeiro.
  UsbPortInfo? find(List<UsbPortInfo> ports) {
    final same = ports.where(matches).toList();
    if (same.isEmpty) return null;
    return same.where((p) => serialNumber != null && p.serialNumber == serialNumber).firstOrNull ?? same.first;
  }

  Map<String, dynamic> toJson() => {
        'vendorId': vendorId,
        'productId': productId,
        if (portIndex != 0) 'portIndex': portIndex,
        if (serialNumber != null) 'serialNumber': serialNumber,
        if (chip != null) 'chip': chip,
        if (product != null) 'product': product,
      };

  static UsbPortRef? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final vid = raw['vendorId'];
    final pid = raw['productId'];
    if (vid is! int || pid is! int) return null;
    return UsbPortRef(
      vendorId: vid,
      productId: pid,
      portIndex: ((raw['portIndex'] as int?) ?? 0).clamp(0, 15),
      serialNumber: raw['serialNumber'] as String?,
      chip: raw['chip'] as String?,
      product: raw['product'] as String?,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is UsbPortRef &&
      other.vendorId == vendorId &&
      other.productId == productId &&
      other.portIndex == portIndex &&
      other.serialNumber == serialNumber &&
      other.chip == chip &&
      other.product == product;

  @override
  int get hashCode => Object.hash(vendorId, productId, portIndex, serialNumber, chip, product);
}

// ── Eventos do lado nativo ─────────────────────────────────────────────────────

sealed class UsbSerialEvent {
  const UsbSerialEvent();
}

/// Bytes que chegaram numa porta aberta. [at] é o relógio do Android na
/// leitura do USB (só a diferença entre dois importa).
class UsbData extends UsbSerialEvent {
  const UsbData(this.handle, this.bytes, this.at);
  final int handle;
  final Uint8List bytes;
  final Duration at;
}

/// A porta aberta caiu sozinha: cabo puxado, adaptador desligado.
class UsbClosed extends UsbSerialEvent {
  const UsbClosed(this.handle, this.reason);
  final int handle;
  final String reason;
}

/// Um adaptador foi plugado ou tirado — a lista do cadastro se atualiza.
class UsbDevicesChanged extends UsbSerialEvent {
  const UsbDevicesChanged({required this.attached});
  final bool attached;
}

/// A fronteira com o Android, pequena de propósito: listar, pedir permissão,
/// abrir, configurar, escrever, fechar e ouvir. Tudo o mais (achar o
/// adaptador escolhido, dividir a porta, medir as pausas, o Modbus e a
/// mensagem do Arduino) é Dart e roda nos testes contra uma porta simulada.
abstract class UsbSerialPlatform {
  /// Este aparelho fala USB-OTG (só o Android, por enquanto).
  bool get supported;

  /// Os aparelhos no USB agora — com e sem driver serial.
  Future<List<UsbPortInfo>> list();

  /// A pergunta do Android ("Permitir que o Ware IoT acesse…?"). Devolve se
  /// a pessoa deixou. Sem [insist], quem já negou desde que o adaptador foi
  /// plugado não é perguntado de novo — a reconexão automática a cada
  /// poucos segundos não pode virar uma caixa de diálogo atrás da outra.
  Future<bool> requestPermission(UsbPortInfo port, {bool insist = false});

  /// Abre e configura a porta. Devolve o número dela para as outras chamadas.
  /// [dtr]: liga o sinal DTR — o Arduino Leonardo/Micro só começa a mandar
  /// com ele; o Uno reinicia ao recebê-lo, como no Monitor Serial.
  Future<int> open(UsbPortInfo port, SerialParams params, {bool dtr = false});

  Future<void> setParams(int handle, SerialParams params);

  Future<void> write(int handle, Uint8List bytes);

  Future<void> close(int handle);

  Stream<UsbSerialEvent> get events;
}

/// Onde o app pega o USB. Nos testes, uma porta simulada entra no lugar.
class UsbSerial {
  UsbSerial._();

  static UsbSerialPlatform _platform = MethodChannelUsbSerial();

  static UsbSerialPlatform get platform => _platform;

  @visibleForTesting
  static set platform(UsbSerialPlatform p) => _platform = p;
}

/// O lado Android: canal `celiware/usb` (`PortaSerialUsb.kt`, sobre a
/// biblioteca usb-serial-for-android). Fora do Android não há USB-OTG: a
/// lista vem vazia e abrir diz isso.
class MethodChannelUsbSerial extends UsbSerialPlatform {
  static final Logger _log = Logger('UsbSerial');
  static const _channel = MethodChannel('celiware/usb');
  static const _eventChannel = EventChannel('celiware/usb/eventos');

  @override
  bool get supported => !kIsWeb && Platform.isAndroid;

  @override
  late final Stream<UsbSerialEvent> events = supported
      ? _eventChannel.receiveBroadcastStream().map(_event).where((e) => e != null).cast<UsbSerialEvent>()
      : const Stream<UsbSerialEvent>.empty();

  static UsbSerialEvent? _event(Object? raw) {
    if (raw is! Map) return null;
    switch (raw['tipo']) {
      case 'dados':
        final h = raw['h'];
        final d = raw['dados'];
        final t = raw['t'];
        if (h is! int || d is! Uint8List) return null;
        return UsbData(h, d, Duration(microseconds: t is int ? t : 0));
      case 'caiu':
        final h = raw['h'];
        return h is int ? UsbClosed(h, (raw['motivo'] as String?) ?? 'adaptador USB desconectado') : null;
      case 'conectado':
        return const UsbDevicesChanged(attached: true);
      case 'desconectado':
        return const UsbDevicesChanged(attached: false);
    }
    return null;
  }

  @override
  Future<List<UsbPortInfo>> list() async {
    if (!supported) return const [];
    try {
      final raw = await _channel.invokeListMethod<Object?>('listar');
      return [for (final r in raw ?? const []) ?UsbPortInfo.fromMap(r)];
    } on PlatformException catch (e) {
      _log.warning('listar: $e');
      return const [];
    }
  }

  @override
  Future<bool> requestPermission(UsbPortInfo port, {bool insist = false}) async {
    if (!supported) return false;
    final r = await _channel.invokeMethod<bool>('pedirPermissao', {'nome': port.deviceName, 'insistir': insist});
    return r ?? false;
  }

  @override
  Future<int> open(UsbPortInfo port, SerialParams params, {bool dtr = false}) async {
    if (!supported) throw const UsbSerialError('USB-OTG fora do Android', UsbProblem.unsupported);
    try {
      final h = await _channel.invokeMethod<int>('abrir', {
        'nome': port.deviceName,
        'porta': port.portIndex,
        ..._params(params),
        'dtr': dtr,
      });
      if (h == null) throw const UsbSerialError('abrir sem resposta', UsbProblem.openFailed);
      return h;
    } on PlatformException catch (e) {
      throw UsbSerialError('abrir ${port.deviceName}: ${e.code} ${e.message}', switch (e.code) {
        'permissao' => UsbProblem.permission,
        'sumiu' => UsbProblem.noAdapter,
        _ => UsbProblem.openFailed,
      });
    }
  }

  static Map<String, Object> _params(SerialParams p) => {
        'baud': p.baud,
        'bits': p.dataBits,
        'paridade': p.parity.name,
        'parada': p.stopBits,
      };

  @override
  Future<void> setParams(int handle, SerialParams params) async {
    try {
      await _channel.invokeMethod<void>('configurar', {'h': handle, ..._params(params)});
    } on PlatformException catch (e) {
      throw UsbSerialError('configurar: ${e.code} ${e.message}', UsbProblem.lost);
    }
  }

  @override
  Future<void> write(int handle, Uint8List bytes) async {
    try {
      await _channel.invokeMethod<void>('escrever', {'h': handle, 'dados': bytes});
    } on PlatformException catch (e) {
      throw UsbSerialError('escrever: ${e.code} ${e.message}', UsbProblem.lost);
    }
  }

  @override
  Future<void> close(int handle) async {
    try {
      await _channel.invokeMethod<void>('fechar', {'h': handle});
    } on PlatformException catch (e) {
      _log.fine('fechar: $e');
    }
  }
}

// ── Erros ──────────────────────────────────────────────────────────────────────

enum UsbProblem {
  /// Fora do Android.
  unsupported,

  /// O adaptador escolhido não está plugado (ou não há nenhum).
  noAdapter,

  /// Há mais de um adaptador e o cadastro não diz qual.
  notChosen,

  /// A pessoa não deixou o app usar o adaptador.
  permission,

  /// O Android achou o adaptador, mas ele não abriu.
  openFailed,

  /// Caiu com a porta aberta (cabo puxado).
  lost,
}

/// Falha do cabo USB, em palavras de operador. É um [CommError]: a sessão
/// trata igual a uma rede que caiu (último valor esmaecido, espera crescente)
/// e o "Testar conexão" diz o que conferir.
class UsbSerialError extends CommError {
  const UsbSerialError(super.message, this.problem);

  final UsbProblem problem;

  @override
  String get userMessage => switch (problem) {
        UsbProblem.unsupported => UsbHint.unsupported,
        UsbProblem.noAdapter => UsbHint.noAdapter,
        UsbProblem.notChosen => UsbHint.notChosen,
        UsbProblem.permission => UsbHint.permission,
        UsbProblem.openFailed => UsbHint.openFailed,
        UsbProblem.lost => UsbHint.lost,
      };
}

/// As mensagens do cabo USB — o cadastro compara com elas para escolher o
/// que mandar conferir.
class UsbHint {
  UsbHint._();

  static const String unsupported = 'o cabo USB só funciona no Android';
  static const String noAdapter = 'adaptador USB não encontrado';
  static const String notChosen = 'escolha o adaptador USB no cadastro do equipamento';
  static const String permission = 'sem permissão para usar o adaptador USB';
  static const String openFailed = 'o adaptador USB não abriu';
  static const String lost = 'adaptador USB desconectado';
}
