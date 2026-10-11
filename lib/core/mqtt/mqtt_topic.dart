import 'dart:convert';

/// Regras de tópico do MQTT 3.1.1 (§4.7): validar e casar com curingas.
///
/// O driver casa cada mensagem que chega com as variáveis por aqui, e não
/// pela biblioteca: a assinatura é por filtro (`fabrica/+/temperatura`), mas
/// cada variável precisa saber se aquela mensagem é dela.
class MqttTopic {
  MqttTopic._();

  /// Filtro de assinatura válido: `#` só no último nível e sozinho nele, `+`
  /// sozinho no nível, sem caractere nulo, até 65535 bytes.
  static bool isValidFilter(String filter) {
    if (filter.isEmpty || filter.contains('\u0000') || utf8.encode(filter).length > 65535) return false;
    final levels = filter.split('/');
    for (var i = 0; i < levels.length; i++) {
      final l = levels[i];
      if (l.contains('#') && (l != '#' || i != levels.length - 1)) return false;
      if (l.contains('+') && l != '+') return false;
    }
    return true;
  }

  /// Tópico onde se pode publicar: sem curinga (a norma proíbe).
  static bool isValidTopic(String topic) =>
      topic.isNotEmpty && !hasWildcard(topic) && !topic.contains('\u0000') && utf8.encode(topic).length <= 65535;

  static bool hasWildcard(String filter) => filter.contains('+') || filter.contains('#');

  /// A mensagem publicada em [topic] casa com a assinatura [filter]?
  ///
  /// `+` vale exatamente um nível; `#` vale o resto, inclusive nenhum nível
  /// (`a/#` casa com `a`). Tópico que começa com `$` (`$SYS/...`) não casa
  /// com filtro que começa com curinga — regra da norma, e é o que impede o
  /// "ouvir tudo" de se encher das estatísticas do broker.
  static bool matches(String filter, String topic) {
    if (topic.startsWith(r'$') && (filter.startsWith('+') || filter.startsWith('#'))) return false;
    final f = filter.split('/'), t = topic.split('/');
    for (var i = 0; i < f.length; i++) {
      if (f[i] == '#') return true;
      if (i >= t.length) return false;
      if (f[i] != '+' && f[i] != t[i]) return false;
    }
    return f.length == t.length;
  }
}
