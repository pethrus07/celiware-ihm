/// Validações de formulário, com mensagem para leigo.
class Validators {
  Validators._();

  static final RegExp _ipv4 = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$');
  static final RegExp _hostname = RegExp(r'^[a-zA-Z0-9]([a-zA-Z0-9\-\.]{0,251}[a-zA-Z0-9])?$');

  /// IP (192.168.0.10) ou nome na rede (clp-linha2.local).
  static String? host(String? value) {
    final v = (value ?? '').trim();
    if (v.isEmpty) return 'Informe o IP do equipamento (ex.: 192.168.0.10)';
    final m = _ipv4.firstMatch(v);
    if (m != null) {
      for (var i = 1; i <= 4; i++) {
        if (int.parse(m.group(i)!) > 255) return 'Cada parte do IP vai de 0 a 255';
      }
      if (v == '0.0.0.0' || v.startsWith('255.')) return 'Esse IP não é de equipamento';
      return null;
    }
    if (RegExp(r'^[\d\.]+$').hasMatch(v)) return 'IP incompleto: são 4 números separados por ponto';
    if (!_hostname.hasMatch(v)) return 'Use o IP ou um nome sem espaços';
    return null;
  }

  static String? name(String? value) =>
      (value ?? '').trim().isEmpty ? 'Dê um nome' : null;
}
