import 'package:flutter_test/flutter_test.dart';
import 'package:ihm/services/net/local_network.dart';

void main() {
  group('faixa de IP', () {
    test('mesma /24 casa; vizinha não', () {
      expect(LocalNetwork.sameSubnet('192.168.1.23', '192.168.1.10', 24), isTrue);
      expect(LocalNetwork.sameSubnet('192.168.0.23', '192.168.1.10', 24), isFalse);
    });

    test('prefixos diferentes de /24', () {
      expect(LocalNetwork.sameSubnet('10.0.5.1', '10.0.200.9', 16), isTrue);
      expect(LocalNetwork.sameSubnet('172.16.0.1', '172.31.255.1', 12), isTrue);
      expect(LocalNetwork.sameSubnet('192.168.1.1', '192.168.1.1', 32), isTrue);
      expect(LocalNetwork.sameSubnet('192.168.1.1', '192.168.1.2', 32), isFalse);
    });

    test('texto que não é IP não casa (nome de host, lixo, prefixo inválido)', () {
      expect(LocalNetwork.sameSubnet('clp.local', '192.168.1.10', 24), isFalse);
      expect(LocalNetwork.sameSubnet('192.168.1.300', '192.168.1.10', 24), isFalse);
      expect(LocalNetwork.sameSubnet('192.168.1.1', '192.168.1.10', 0), isFalse);
    });
  });

  test('rede privada = o que o Android trata como local', () {
    for (final ip in ['10.1.2.3', '172.16.0.1', '172.31.9.9', '192.168.0.10', '169.254.1.1', '100.64.0.1']) {
      expect(LocalNetwork.isPrivateIPv4(ip), isTrue, reason: ip);
    }
    for (final ip in ['8.8.8.8', '172.32.0.1', '127.0.0.1', '100.128.0.1', 'clp.fabrica']) {
      expect(LocalNetwork.isPrivateIPv4(ip), isFalse, reason: ip);
    }
  });

  group('diagnóstico do teste de conexão', () {
    const casa = LocalNet(type: 'wifi', ip: '192.168.0.23', prefix: 24, internet: true);
    const maquina = LocalNet(type: 'wifi', ip: '192.168.1.40', prefix: 24);

    test('sem informação da plataforma: cala', () {
      expect(LocalNetwork.diagnose('192.168.1.10', null), isNull);
    });

    test('equipamento fora de rede privada (VPN, internet): cala', () {
      expect(LocalNetwork.diagnose('8.8.8.8', const [casa]), isNull);
    });

    test('nenhum Wi-Fi conectado', () {
      expect(LocalNetwork.diagnose('192.168.1.10', const []), contains('nenhum Wi-Fi'));
    });

    test('Wi-Fi em outra faixa: aponta as duas', () {
      final d = LocalNetwork.diagnose('192.168.1.10', const [casa])!;
      expect(d, contains('192.168.0.x'));
      expect(d, contains('192.168.1.10'));
      expect(d, contains('redes diferentes'));
    });

    test('mesma faixa: a rede está certa, o equipamento é que não respondeu', () {
      expect(LocalNetwork.diagnose('192.168.1.10', const [casa, maquina]), contains('mesma rede'));
    });

    test('rota e rótulo', () {
      expect(LocalNetwork.routeTo('192.168.1.10', const [casa, maquina]), same(maquina));
      expect(maquina.label, 'Wi-Fi 192.168.1.40/24 · sem internet');
      expect(casa.label, 'Wi-Fi 192.168.0.23/24');
      const larga = LocalNet(type: 'cabo', ip: '10.20.30.40', prefix: 16);
      expect(larga.rangeLabel, '10.20.0.0/16');
    });
  });

  test('mapa vindo do Android', () {
    final n = LocalNet.fromMap({'tipo': 'wifi', 'ip': '192.168.1.40', 'prefixo': 24, 'internet': false, 'padrao': false, 'vinculada': true})!;
    expect(n.bound, isTrue);
    expect(n.isDefault, isFalse);
    expect(LocalNet.fromMap({'tipo': 'wifi', 'ip': null}), isNull);
    expect(LocalNet.fromMap('lixo'), isNull);
  });
}
