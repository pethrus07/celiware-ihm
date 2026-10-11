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
