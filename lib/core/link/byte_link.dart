import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// Um cano de bytes até o equipamento: socket TCP, porta USB-serial, UDP…
///
/// Os protocolos que não têm cabeçalho de tamanho (Modbus RTU/ASCII,
/// mensagens de Arduino) só precisam disto: abrir, mandar bytes, receber
/// bytes, fechar. Quem monta e separa as mensagens é o protocolo.
abstract class ByteLink {
  bool get isOpen;

  /// Bytes que chegam, na ordem, em pedaços de qualquer tamanho.
  Stream<Uint8List> get input;

  /// Abre o cano. Lança `CommError` (ex.: `ModbusConnectionError`) se não der.
  Future<void> open();

  Future<void> write(Uint8List bytes);

  /// Fecha de propósito.
  Future<void> close();

  /// O cano caiu sozinho (equipamento fechou, cabo saiu).
  void Function(String reason)? onClosed;

  /// Cada pedaço de [input] é um pacote inteiro (UDP). Num fluxo (TCP,
  /// serial) os pedaços são arbitrários; num datagrama o fim do pedaço já é
  /// o fim da mensagem — ESP por UDP costuma mandar sem `\n`.
  bool get isDatagram => false;
}

/// TCP: gateway serial→Ethernet falando RTU/ASCII "cru" sobre o socket.
class TcpByteLink extends ByteLink {
  TcpByteLink({
    required this.host,
    required this.port,
    this.connectionTimeout = const Duration(seconds: 5),
    this.beforeConnect,
  });

  final String host;
  final int port;
  final Duration connectionTimeout;

  /// Ver `ModbusClientTcp.beforeConnect` (rede local certa no Android).
  final Future<void> Function(String host)? beforeConnect;

  Socket? _socket;
  final _input = StreamController<Uint8List>.broadcast();

  @override
  bool get isOpen => _socket != null;

  @override
  Stream<Uint8List> get input => _input.stream;

  @override
  Future<void> open() async {
    if (_socket != null) return;
    final hook = beforeConnect;
    if (hook != null) {
      try {
        await hook(host);
      } catch (_) {/* sem vínculo: tenta assim mesmo */}
    }
    final s = await Socket.connect(host, port, timeout: connectionTimeout);
    s.setOption(SocketOption.tcpNoDelay, true);
    _socket = s;
    s.listen(
      _input.add,
      onError: (Object e) => _lost('erro de socket: $e'),
      onDone: () => _lost('conexão encerrada pelo equipamento'),
      cancelOnError: true,
    );
  }

  void _lost(String reason) {
    if (_socket == null) return;
    _socket?.destroy();
    _socket = null;
    onClosed?.call(reason);
  }

  @override
  Future<void> write(Uint8List bytes) async {
    final s = _socket;
    if (s == null) throw const SocketException('não conectado');
    s.add(bytes);
    await s.flush();
  }

  @override
  Future<void> close() async {
    final s = _socket;
    _socket = null;
    try {
      await s?.close();
      s?.destroy();
    } catch (_) {}
  }
}

/// UDP: ESP/Arduino que manda e recebe datagramas.
///
/// UDP não tem conexão: "abrir" é reservar uma porta local ([localPort]; 0 =
/// qualquer uma livre) e lembrar para onde mandar ([host]:[port]). Quando o
/// equipamento transmite sozinho para o celular, é para a [localPort] que ele
/// manda — por isso ela é configurável.
///
/// Só são aceitos datagramas vindos do IP de [host] (outro aparelho
/// mandando para a mesma porta não vira valor nesta tela), a não ser com
/// [acceptAnySource], para equipamento que responde de outro IP (broadcast).
class UdpByteLink extends ByteLink {
  UdpByteLink({
    required this.host,
    required this.port,
    this.localPort = 0,
    this.acceptAnySource = false,
    this.beforeConnect,
  });

  final String host;
  final int port;
  final int localPort;
  final bool acceptAnySource;

  /// Ver `TcpByteLink.beforeConnect`.
  final Future<void> Function(String host)? beforeConnect;

  RawDatagramSocket? _socket;
  InternetAddress? _remote;
  final _input = StreamController<Uint8List>.broadcast();

  @override
  bool get isOpen => _socket != null;

  @override
  bool get isDatagram => true;

  @override
  Stream<Uint8List> get input => _input.stream;

  /// A porta local de fato reservada (útil com [localPort] 0).
  int? get boundPort => _socket?.port;

  @override
  Future<void> open() async {
    if (_socket != null) return;
    final hook = beforeConnect;
    if (hook != null) {
      try {
        await hook(host);
      } catch (_) {/* sem vínculo: tenta assim mesmo */}
    }
    final remote = InternetAddress.tryParse(host) ?? await _lookup(host);
    final any = remote.type == InternetAddressType.IPv6 ? InternetAddress.anyIPv6 : InternetAddress.anyIPv4;
    final s = await RawDatagramSocket.bind(any, localPort);
    s.broadcastEnabled = true; // 255.255.255.255 ou x.x.x.255 como destino
    _remote = remote;
    _socket = s;
    s.listen(
      (event) {
        if (event == RawSocketEvent.read) {
          while (true) {
            final d = s.receive();
            if (d == null) break;
            if (acceptAnySource || d.address.address == remote.address) _input.add(d.data);
          }
        } else if (event == RawSocketEvent.closed) {
          _lost('porta UDP fechada');
        }
      },
      // Erro de um datagrama (ex.: ICMP "porta inacessível" no Windows) não
      // derruba nada: UDP não tem conexão para cair.
      onError: (Object _) {},
    );
  }

  /// Nome na rede → IP, preferindo IPv4: equipamento de chão de fábrica quase
  /// nunca fala IPv6, e "localhost" no Windows resolve primeiro para ::1.
  static Future<InternetAddress> _lookup(String host) async {
    final all = await InternetAddress.lookup(host);
    return all.firstWhere((a) => a.type == InternetAddressType.IPv4, orElse: () => all.first);
  }

  void _lost(String reason) {
    if (_socket == null) return;
    _socket?.close();
    _socket = null;
    onClosed?.call(reason);
  }

  @override
  Future<void> write(Uint8List bytes) async {
    final s = _socket;
    final remote = _remote;
    if (s == null || remote == null) throw const SocketException('UDP não aberto');
    // send devolve 0 quando o buffer do sistema está cheio: tenta de novo
    // algumas vezes antes de desistir.
    for (var i = 0; i < 5; i++) {
      if (s.send(bytes, remote, port) > 0) return;
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    throw const SocketException('datagrama não enviado');
  }

  @override
  Future<void> close() async {
    final s = _socket;
    _socket = null;
    s?.close();
  }
}
