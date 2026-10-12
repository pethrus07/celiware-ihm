import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:ihm/core/modbus/modbus_framing.dart';
import 'package:ihm/core/modbus/modbus_memory.dart';
import 'package:ihm/core/serial/serial_params.dart';
import 'package:ihm/core/serial/usb_serial.dart';

/// O lado Android do cabo USB, de mentira: adaptadores plugados, a linha
/// serial com o tempo de cada caractere pela velocidade, o eco do RS-485 de
/// 2 fios, os pacotes do USB (a resposta chega em pedaços), o cabo puxado e
/// a permissão do Android.
///
/// Fica em `test/` porque nada do app usa. Tudo acima dele — achar o
/// adaptador, dividir a porta, o Modbus RTU/ASCII, a mensagem do Arduino, a
/// sessão, o HmiRuntime e as telas — é o código de produção.
///
/// Tempo: cada pedaço sai com um carimbo no "relógio do Android" que só anda
/// com o fio — caracteres × tempo de um caractere, a pausa entre os pacotes do
/// USB, o escravo pensando — e é entregue com um atraso real parecido (a
/// resposta de verdade também não chega na hora). As pausas que o app mede
/// vêm do carimbo, então não dependem do relógio do Windows.
class FakeUsbSerial extends UsbSerialPlatform {
  FakeUsbSerial() : _wall = Stopwatch()..start();

  @override
  bool supported = true;

  final List<FakeAdapter> plugged = [];
  final _events = StreamController<UsbSerialEvent>.broadcast();
  final Map<int, FakeAdapter> _open = {};
  final Stopwatch _wall;
  Duration _virtual = Duration.zero;
  int _nextHandle = 1;
  int _nextBus = 2;

  /// Quantas vezes a caixa "Permitir?" apareceu.
  int permissionDialogs = 0;

  /// O que a pessoa responde na caixa.
  bool answerPermission = true;
  final Set<String> _denied = {};

  /// Cada "abrir" que chegou ao Android, para conferir que a porta é dividida.
  int opens = 0;

  @override
  Stream<UsbSerialEvent> get events => _events.stream;

  /// Pluga [a] (ganha um caminho novo no Android, como de verdade).
  FakeAdapter plug(FakeAdapter a) {
    a.deviceName = '/dev/bus/usb/001/${(_nextBus++).toString().padLeft(3, '0')}';
    a.hasPermission = a.grantedOnPlug;
    plugged.add(a);
    _events.add(const UsbDevicesChanged(attached: true));
    return a;
  }

  /// Puxa o cabo: a porta aberta cai e o adaptador some da lista.
  void unplug(FakeAdapter a) {
    plugged.remove(a);
    for (final e in _open.entries.where((e) => identical(e.value, a)).toList()) {
      _open.remove(e.key);
      _events.add(UsbClosed(e.key, 'adaptador USB desconectado'));
    }
    a._stop();
    _denied.remove(a.deviceName);
    _events.add(const UsbDevicesChanged(attached: false));
  }

  Future<void> dispose() async {
    for (final a in plugged) {
      a._stop();
    }
    await _events.close();
  }

  @override
  Future<List<UsbPortInfo>> list() async => [for (final a in plugged) a.info];

  @override
  Future<bool> requestPermission(UsbPortInfo port, {bool insist = false}) async {
    final a = _byName(port.deviceName);
    if (a == null) return false;
    if (a.hasPermission) return true;
    if (_denied.contains(a.deviceName) && !insist) return false;
    permissionDialogs++;
    if (answerPermission) {
      a.hasPermission = true;
      _denied.remove(a.deviceName);
    } else {
      _denied.add(a.deviceName);
    }
    return answerPermission;
  }

  @override
  Future<int> open(UsbPortInfo port, SerialParams params, {bool dtr = false}) async {
    final a = _byName(port.deviceName);
    if (a == null) throw const UsbSerialError('sumiu', UsbProblem.noAdapter);
    if (!a.hasPermission) throw const UsbSerialError('sem permissão', UsbProblem.permission);
    // O Android abre um adaptador uma vez só.
    if (_open.containsValue(a)) throw const UsbSerialError('já aberto', UsbProblem.openFailed);
    opens++;
    final h = _nextHandle++;
    _open[h] = a;
    a._platform = this;
    a._handle = h;
    a.appParams = params;
    a.dtr = dtr;
    a._start();
    return h;
  }

  @override
  Future<void> setParams(int handle, SerialParams params) async {
    final a = _open[handle];
    if (a == null) throw const UsbSerialError('fechado', UsbProblem.lost);
    a.appParams = params;
    a.paramChanges++;
  }

  @override
  Future<void> write(int handle, Uint8List bytes) async {
    final a = _open[handle];
    if (a == null) throw const UsbSerialError('fechado', UsbProblem.lost);
    a.written.add(Uint8List.fromList(bytes));
    a.writtenAt.add(_wall.elapsed);
    a.onWrite?.call(bytes);
    final wire = a.appParams.charTime * bytes.length;
    // O eco do RS-485 de 2 fios volta enquanto o pedido sai.
    if (a.echo) a._toApp(bytes, garble: false);
    final heard = a.lineMatches ? bytes : FakeAdapter._garble(bytes);
    Future<void>.delayed(wire, () {
      if (!identical(_open[handle], a)) return;
      for (final eq in a.equipment) {
        eq.receive(heard, a);
      }
    });
  }

  @override
  Future<void> close(int handle) async {
    final a = _open.remove(handle);
    a?._stop();
  }

  FakeAdapter? _byName(String name) => plugged.where((a) => a.deviceName == name).firstOrNull;

  /// Relógio do Android, só do fio: anda o tempo de cada caractere e as
  /// pausas pedidas, nunca o tempo real. Assim a pausa que o app mede é a da
  /// linha simulada, mesmo nos testes de tela, em que o relógio do teste anda
  /// aos saltos.
  Duration _stamp(Duration advance) {
    _virtual += advance;
    return _virtual;
  }

  bool isOpen(FakeAdapter a) => _open.containsValue(a);
}

/// Um adaptador USB-serial e o que está ligado nele.
class FakeAdapter {
  FakeAdapter({
    this.vendorId = 0x1A86,
    this.productId = 0x7523,
    this.chip = 'CH340',
    this.product = 'USB2.0-Serial',
    this.serialNumber,
    this.portIndex = 0,
    this.grantedOnPlug = true,
    this.lineParams = const SerialParams(),
    List<FakeSerialEquipment>? equipment,
    this.echo = false,
    this.packetBytes = 8,
    this.packetGap = const Duration(milliseconds: 1),
  }) : equipment = equipment ?? [];

  final int vendorId;
  final int productId;

  /// Nulo = aparelho USB sem driver serial (pendrive, teclado).
  final String? chip;
  final String? product;
  final String? serialNumber;
  final int portIndex;

  /// Permissão já dada ao plugar (o app abriu pelo filtro de adaptadores e a
  /// pessoa marcou "usar sempre").
  bool grantedOnPlug;

  /// Como o equipamento do outro lado está configurado.
  SerialParams lineParams;

  /// Quem está na linha (vários escravos na mesma RS-485).
  final List<FakeSerialEquipment> equipment;

  /// Adaptador RS-485 de 2 fios que devolve o que o app manda.
  bool echo;

  /// Tamanho dos pacotes do USB: a resposta chega em pedaços deste tamanho.
  int packetBytes;

  /// Pausa entre dois pacotes da mesma resposta (latência do USB).
  Duration packetGap;

  String deviceName = '';
  bool hasPermission = false;
  SerialParams appParams = const SerialParams();
  bool dtr = false;
  int paramChanges = 0;
  final List<Uint8List> written = [];
  final List<Duration> writtenAt = [];

  /// Gancho de teste: o app acabou de mandar [bytes].
  void Function(Uint8List bytes)? onWrite;

  FakeUsbSerial? _platform;
  int? _handle;

  bool get lineMatches => appParams == lineParams;

  UsbPortInfo get info => UsbPortInfo(
        deviceName: deviceName,
        vendorId: vendorId,
        productId: productId,
        portIndex: portIndex,
        serialNumber: hasPermission ? serialNumber : null,
        chip: chip,
        product: product,
        hasPermission: hasPermission,
      );

  void _start() {
    for (final e in equipment) {
      e.started(this);
    }
  }

  void _stop() {
    _handle = null;
    for (final e in equipment) {
      e.stopped();
    }
  }

  /// Bytes que o equipamento manda ao app, em pacotes do USB.
  void send(List<int> bytes, {Duration delay = Duration.zero}) => _toApp(bytes, garble: !lineMatches, delay: delay);

  /// Bytes quaisquer chegando ao app depois de [gap] de silêncio na linha
  /// (ruído, outro equipamento, quadro cortado).
  void inject(List<int> bytes, {Duration gap = Duration.zero}) => _toApp(bytes, garble: false, gapBefore: gap);

  void _toApp(List<int> raw, {required bool garble, Duration delay = Duration.zero, Duration gapBefore = Duration.zero}) {
    final p = _platform;
    final h = _handle;
    if (p == null || h == null) return;
    final bytes = garble ? _garble(raw) : raw;
    final char = appParams.charTime;
    var pause = gapBefore + delay;
    final packets = <(Uint8List, Duration)>[];
    for (var i = 0; i < bytes.length; i += packetBytes) {
      final part = Uint8List.fromList(bytes.sublist(i, i + packetBytes > bytes.length ? bytes.length : i + packetBytes));
      packets.add((part, pause + char * part.length));
      pause = packetGap;
    }
    Future<void>(() async {
      var first = true;
      for (final (part, wait) in packets) {
        // Antes do primeiro pacote, o atraso de verdade do equipamento
        // ([delay]: o escravo pensando) mais um pouco do fio; os seguintes
        // vêm em voltas separadas do laço de eventos — o quadro chega
        // partido. A pausa que o app mede é a do carimbo.
        final at = p._stamp(wait);
        final wire = wait - delay - gapBefore;
        final real = first ? delay + (wire > const Duration(milliseconds: 4) ? const Duration(milliseconds: 4) : wire) : Duration.zero;
        first = false;
        await Future<void>.delayed(real);
        if (!identical(p._open[h], this)) return;
        p._events.add(UsbData(h, part, at));
      }
    });
  }

  /// Velocidade ou paridade diferente: o que chega do outro lado é lixo.
  static Uint8List _garble(List<int> bytes) => Uint8List.fromList([for (final b in bytes) (b * 7 + 0x35) & 0xFF]);
}

/// Algo ligado na linha serial.
abstract class FakeSerialEquipment {
  /// Bytes que chegaram do app (já embaralhados se a linha não bate).
  void receive(Uint8List bytes, FakeAdapter line);

  void started(FakeAdapter line) {}
  void stopped() {}
}

/// Escravo Modbus RTU/ASCII na RS-485, com a mesma lógica de memória do
/// escravo TCP dos testes.
class FakeModbusSlave extends FakeSerialEquipment {
  FakeModbusSlave(this.memory, {this.unitId = 1, this.framing = ModbusFraming.rtu, this.turnaround = const Duration(milliseconds: 3)})
      : _logic = ModbusServerLogic(memory);

  final ModbusMemory memory;
  final int unitId;
  final ModbusFraming framing;
  final ModbusServerLogic _logic;

  /// Quanto o escravo demora para começar a responder.
  Duration turnaround;

  /// Corrompe o CRC/LRC da próxima resposta.
  bool corruptNext = false;

  /// Byte espúrio antes da próxima resposta (transceptor virando a linha).
  bool glitchNext = false;

  /// Desligado: não responde nada.
  bool silent = false;

  int requests = 0;
  final List<int> _buf = [];

  @override
  void stopped() => _buf.clear();

  @override
  void receive(Uint8List bytes, FakeAdapter line) {
    _buf.addAll(bytes);
    while (true) {
      final end = framing == ModbusFraming.rtu ? _rtuRequestLength(_buf) : ModbusFrames.asciiFrameEnd(_buf);
      if (end == null || _buf.length < end) return;
      final frame = _buf.sublist(0, end);
      _buf.removeRange(0, end);
      _answer(frame, line);
    }
  }

  static int? _rtuRequestLength(List<int> b) {
    if (b.length < 2) return null;
    if (b[1] == 0x0F || b[1] == 0x10) return b.length < 7 ? null : 7 + b[6] + 2;
    return 8;
  }

  void _answer(List<int> frame, FakeAdapter line) {
    final int unit;
    final Uint8List pdu;
    try {
      (unit, pdu) = framing == ModbusFraming.rtu ? ModbusFrames.parseRtu(frame) : ModbusFrames.parseAscii(frame);
    } on FormatException {
      _buf.clear(); // quadro estragado (velocidade errada): escravo de verdade fica quieto
      return;
    }
    if (unit != unitId || silent) return;
    requests++;
    final reply = _logic.handle(pdu);
    final out = framing == ModbusFraming.rtu ? ModbusFrames.rtu(unit, reply) : ModbusFrames.ascii(unit, reply);
    if (corruptNext) {
      corruptNext = false;
      out[out.length - (framing == ModbusFraming.rtu ? 1 : 3)] ^= 0x01;
    }
    final glitch = glitchNext;
    glitchNext = false;
    line.send([if (glitch) 0x00, ...out], delay: turnaround);
  }
}

/// Arduino no USB mandando `T=25.3;P=1\n` sozinho e aceitando `SET P=1\n`.
class FakeSerialArduino extends FakeSerialEquipment {
  FakeSerialArduino({this.every = const Duration(milliseconds: 60)});

  final Duration every;
  final Map<String, String> values = {'T': '25.3', 'P': '0'};
  final List<String> commands = [];
  Timer? _timer;
  FakeAdapter? _line;
  final List<int> _buf = [];

  @override
  void started(FakeAdapter line) {
    _line = line;
    _timer?.cancel();
    _timer = Timer.periodic(every, (_) => _emit());
  }

  void _emit() {
    final line = _line;
    if (line == null) return;
    line.send(utf8.encode('${values.entries.map((e) => '${e.key}=${e.value}').join(';')}\n'));
  }

  @override
  void stopped() {
    _timer?.cancel();
    _timer = null;
    _line = null;
    _buf.clear();
  }

  @override
  void receive(Uint8List bytes, FakeAdapter line) {
    _buf.addAll(bytes);
    while (true) {
      final i = _buf.indexOf(0x0A);
      if (i < 0) return;
      final text = utf8.decode(_buf.sublist(0, i), allowMalformed: true).trim();
      _buf.removeRange(0, i + 1);
      commands.add(text);
      final m = RegExp(r'^SET (\w+)=(.*)$').firstMatch(text);
      if (m != null) {
        values[m.group(1)!] = m.group(2)!;
        _emit();
      }
    }
  }
}
