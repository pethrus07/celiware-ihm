import 'dart:io';

import 'package:flutter/services.dart';
import 'package:logging/logging.dart';

/// Uma rede local (Wi-Fi ou cabo) em que o celular está conectado.
class LocalNet {
  const LocalNet({
    required this.type,
    required this.ip,
    required this.prefix,
    this.internet = false,
    this.isDefault = false,
    this.bound = false,
  });

  /// 'wifi' ou 'cabo'.
  final String type;
  final String ip;
  final int prefix;

  /// O Android validou internet nesta rede (a da máquina quase nunca tem).
  final bool internet;

  /// É a rede padrão do celular (por onde sai o que não tem vínculo).
  final bool isDefault;

  /// As conexões do app estão vinculadas a ela.
  final bool bound;

  static LocalNet? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final ip = raw['ip'];
    final prefix = raw['prefixo'];
    if (ip is! String || prefix is! int) return null;
    return LocalNet(
      type: raw['tipo'] == 'cabo' ? 'cabo' : 'wifi',
      ip: ip,
      prefix: prefix,
      internet: raw['internet'] == true,
      isDefault: raw['padrao'] == true,
      bound: raw['vinculada'] == true,
    );
  }

  bool contains(String host) => LocalNetwork.sameSubnet(ip, host, prefix);

  /// "Wi-Fi 192.168.1.23/24 · sem internet".
  String get label => '${type == 'cabo' ? 'Cabo' : 'Wi-Fi'} $ip/$prefix${internet ? '' : ' · sem internet'}';

  /// "192.168.0.x" numa /24; senão "192.168.0.0/16".
  String get rangeLabel {
    final p = LocalNetwork._parts(ip);
    if (p == null) return ip;
    if (prefix == 24) return '${p[0]}.${p[1]}.${p[2]}.x';
    return '${LocalNetwork._fromInt(LocalNetwork._toInt(p) & LocalNetwork._mask(prefix))}/$prefix';
  }
}

/// Rede local do celular: em que Wi-Fi ele está e por onde as conexões saem.
///
/// **Por que existe.** A rede da máquina quase nunca tem internet. Com os
/// dados móveis ligados, o Android usa o 4G como rede padrão e o socket para
/// 192.168.x.x sai pela operadora — "tempo esgotado", sem pista do porquê.
/// [prepare] vincula as conexões do app à rede local que contém o IP do
/// equipamento (canal `celiware/rede`, `RedeLocal.kt`). Fora do Android (testes,
/// Windows) tudo aqui é inofensivo: não faz nada e [list] devolve nulo.
class LocalNetwork {
  LocalNetwork._();

  static final Logger _log = Logger('LocalNetwork');
  static const _channel = MethodChannel('celiware/rede');

  static bool get _supported => Platform.isAndroid;

  /// Redes locais conectadas, ou nulo quando a plataforma não informa (aí não
  /// dá para diagnosticar nada — melhor calar do que acusar sem saber).
  static Future<List<LocalNet>?> list() async {
    if (!_supported) return null;
    try {
      final raw = await _channel.invokeMethod<List<Object?>>('listar');
      return [for (final r in raw ?? const []) ?LocalNet.fromMap(r)];
    } on MissingPluginException {
      return null;
    } on PlatformException catch (e) {
      _log.warning('Não leu as redes: ${e.message}');
      return null;
    }
  }

  /// Antes de conectar em [host]: se ele está na faixa de uma rede local,
  /// vincula as conexões a ela. Equipamento remoto (VPN, 4G) não mexe em nada.
  static Future<LocalNet?> prepare(String host) async {
    if (!_supported || !isPrivateIPv4(host)) return null;
    try {
      return LocalNet.fromMap(await _channel.invokeMethod<Object?>('vincular', {'ip': host}));
    } on MissingPluginException {
      return null;
    } on PlatformException catch (e) {
      _log.warning('Não vinculou à rede local: ${e.message}');
      return null;
    }
  }

  /// Diagnóstico para o "Testar conexão" que falhou. Nulo = nada a acrescentar
  /// (plataforma não informa, ou equipamento fora de rede privada).
  static String? diagnose(String host, List<LocalNet>? nets) {
    if (nets == null || !isPrivateIPv4(host)) return null;
    if (nets.isEmpty) return 'O celular não está em nenhum Wi-Fi. Conecte ao Wi-Fi da máquina.';
    if (nets.any((n) => n.contains(host))) {
      return 'O celular está na mesma rede do equipamento, mas ele não respondeu.';
    }
    final n = nets.first;
    return 'O celular está em ${n.rangeLabel} e o equipamento em $host: são redes diferentes. '
        'Confira o Wi-Fi do celular ou o IP do equipamento.';
  }

  /// A rede que leva até [host], para mostrar ao técnico ("Wi-Fi … · sem internet").
  static LocalNet? routeTo(String host, List<LocalNet>? nets) {
    if (nets == null) return null;
    for (final n in nets) {
      if (n.contains(host)) return n;
    }
    return null;
  }

  // ── Faixas de IP (puro, testável) ───────────────────────────────────────────

  /// 10/8, 172.16/12, 192.168/16, 169.254/16 e 100.64/10 — o que o Android
  /// trata como rede local.
  static bool isPrivateIPv4(String host) {
    final p = _parts(host);
    if (p == null) return false;
    return p[0] == 10 ||
        (p[0] == 172 && p[1] >= 16 && p[1] <= 31) ||
        (p[0] == 192 && p[1] == 168) ||
        (p[0] == 169 && p[1] == 254) ||
        (p[0] == 100 && p[1] >= 64 && p[1] <= 127);
  }

  static bool sameSubnet(String a, String b, int prefix) {
    final pa = _parts(a), pb = _parts(b);
    if (pa == null || pb == null || prefix < 1 || prefix > 32) return false;
    final m = _mask(prefix);
    return (_toInt(pa) & m) == (_toInt(pb) & m);
  }

  static List<int>? _parts(String ip) {
    final s = ip.trim().split('.');
    if (s.length != 4) return null;
    final out = <int>[];
    for (final x in s) {
      final v = int.tryParse(x);
      if (v == null || v < 0 || v > 255) return null;
      out.add(v);
    }
    return out;
  }

  static int _toInt(List<int> p) => (p[0] << 24) | (p[1] << 16) | (p[2] << 8) | p[3];
  static int _mask(int prefix) => prefix == 0 ? 0 : (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF;
  static String _fromInt(int v) => '${(v >> 24) & 255}.${(v >> 16) & 255}.${(v >> 8) & 255}.${v & 255}';
}
