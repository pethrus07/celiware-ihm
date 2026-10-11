// A linguagem das variáveis calculadas e das condições de regra (LG-1).
//
// Avaliador próprio, sem `eval` nem JavaScript: o texto vira uma árvore que só
// sabe somar, comparar e chamar as seis funções da lista. Não há laço, não há
// variável que se atribui, não há como travar o app com uma conta.
//
//   [Velocidade] * 60                         número
//   [Temperatura do motor] > 80 e [Em ciclo]  liga/desliga
//   se([Em ciclo]; [Velocidade]; 0)           se(condição; se sim; se não)
//   máx([Temp. A]; [Temp. B])  ·  arred([Vazão] / 3,6; 1)  ·  taxa([Peças])
//
// Vírgula decimal (0,5) e ponto e vírgula entre os valores das funções, como no
// Excel em português. Variável com espaço no nome vai entre colchetes; nome
// sem espaço pode ir solto (Temp * 2). Erro sempre em português e com o trecho
// onde está ([CalcError.start]/[CalcError.end]).

import 'dart:math' as math;

import '../../models/calc.dart';

/// Erro de escrita na conta, com o trecho onde está (posições no texto, em
/// caracteres) — a tela sublinha o trecho.
class CalcError implements Exception {
  const CalcError(this.message, this.start, this.end);
  final String message;
  final int start;
  final int end;

  @override
  String toString() => message;
}

/// Erro na hora de calcular (divisão por zero, resultado impossível): a
/// variável fica com erro, nunca com um número inventado.
class CalcRuntimeError implements Exception {
  const CalcRuntimeError(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Ainda não dá para calcular — a taxa precisa de alguns segundos de leitura.
class CalcNotReady extends CalcRuntimeError {
  const CalcNotReady(super.message);
}

/// O que a conta devolve.
enum CalcType { number, boolean }

/// O tipo de uma variável citada, do ponto de vista da conta.
enum CalcRefKind { number, boolean, text, list }

/// Uma variável que a conta pode citar.
class CalcRef {
  const CalcRef({required this.id, required this.name, this.device = '', this.kind = CalcRefKind.number});
  final String id;
  final String name;

  /// Nome do equipamento — desempata nomes repetidos: [Prensa: Temperatura].
  final String device;
  final CalcRefKind kind;
}

/// Onde a conta procura as variáveis citadas.
class CalcScope {
  CalcScope(Iterable<CalcRef> refs, {this.knownNames = const {}}) : _all = List.unmodifiable(refs) {
    for (final r in _all) {
      _byId[r.id] = r;
    }
  }

  final List<CalcRef> _all;
  final Map<String, CalcRef> _byId = {};

  /// Nome de quando a conta foi salva, para variável apagada depois.
  final Map<String, String> knownNames;

  List<CalcRef> get all => _all;
  CalcRef? byId(String id) => _byId[id];

  /// Variáveis com esse nome (sem diferenciar maiúscula, acento ou espaço
  /// sobrando).
  List<CalcRef> named(String name) {
    final p = plain(name);
    return [for (final r in _all) if (plain(r.name) == p) r];
  }

  List<CalcRef> inDevice(String device, String name) {
    final d = plain(device), n = plain(name);
    return [for (final r in _all) if (plain(r.device) == d && plain(r.name) == n) r];
  }

  static const _accents = {
    'á': 'a', 'à': 'a', 'â': 'a', 'ã': 'a', 'ä': 'a', 'é': 'e', 'è': 'e', 'ê': 'e', 'ë': 'e', 'í': 'i', 'ì': 'i', //
    'î': 'i', 'ï': 'i', 'ó': 'o', 'ò': 'o', 'ô': 'o', 'õ': 'o', 'ö': 'o', 'ú': 'u', 'ù': 'u', 'û': 'u', 'ü': 'u', //
    'ç': 'c', 'ñ': 'n',
  };

  /// Minúscula, sem acento, espaços juntados: "Temperatura  do Motor" =
  /// "temperatura do motor".
  static String plain(String s) {
    final b = StringBuffer();
    for (final c in s.trim().toLowerCase().split('')) {
      b.write(_accents[c] ?? c);
    }
    return b.toString().replaceAll(RegExp(r'\s+'), ' ');
  }
}

/// Uma citação de variável na conta: qual e em que trecho do texto.
class CalcRefUse {
  const CalcRefUse(this.ref, this.start, this.end);
  final CalcRef ref;
  final int start;
  final int end;
}

/// Os valores do momento, para [CalcProgram.run].
abstract interface class CalcEnv {
  /// Valor de agora da variável: `bool` ou número (quem chama já conferiu que
  /// a leitura está boa).
  Object? valueOf(String id);

  /// Quanto a variável sobe por hora (`taxa`); nulo enquanto não dá para saber.
  double? perHour(String id);
}

/// As funções da linguagem — nem mais, nem menos.
enum CalcFunction {
  se('se', 'se(condição; se sim; se não)'),
  min('mín', 'mín(a; b)'),
  max('máx', 'máx(a; b)'),
  abs('abs', 'abs(x)'),
  arred('arred', 'arred(x; casas)'),
  taxa('taxa', 'taxa([Contador])');

  const CalcFunction(this.label, this.example);
  final String label;
  final String example;

  static CalcFunction? byWord(String w) => switch (CalcScope.plain(w)) {
        'se' => CalcFunction.se,
        'min' => CalcFunction.min,
        'max' => CalcFunction.max,
        'abs' => CalcFunction.abs,
        'arred' || 'arredondar' => CalcFunction.arred,
        'taxa' => CalcFunction.taxa,
        _ => null,
      };
}

/// Uma conta lida e conferida: pronta para rodar.
class CalcProgram {
  CalcProgram._(this.source, this._root, this.type, this.uses);

  /// O texto como a pessoa escreveu.
  final String source;
  final _Node _root;

  /// Número ou liga/desliga.
  final CalcType type;

  /// Cada variável citada, com o trecho.
  final List<CalcRefUse> uses;

  Set<String> get inputIds => {for (final u in uses) u.ref.id};

  /// Variáveis usadas na `taxa( )` — precisam de histórico.
  Set<String> get rateIds => _rateIds(_root);

  /// O texto canônico: cada citação vira `{id}` (o que vai para o arquivo).
  String get canonical {
    var s = source;
    for (final u in [...uses]..sort((a, b) => b.start.compareTo(a.start))) {
      s = s.replaceRange(u.start, u.end, '{${u.ref.id}}');
    }
    return s.trim();
  }

  /// O que vai na variável: texto canônico + nome de cada citada.
  CalcSpec get spec => CalcSpec(expression: canonical, names: {for (final u in uses) u.ref.id: u.ref.name});

  /// Lê e confere [source] contra as variáveis de [scope]. Lança [CalcError]
  /// com a mensagem e o trecho do primeiro problema.
  static CalcProgram compile(String source, CalcScope scope) {
    final toks = _lex(source);
    final root = _Parser(source, toks).parse();
    final uses = <CalcRefUse>[];
    final type = _Resolver(scope, uses).type(root);
    return CalcProgram._(source, root, type, uses);
  }

  /// Calcula com os valores de agora. Devolve `bool` (condição) ou `double`.
  /// Lança [CalcRuntimeError] (divisão por zero, resultado impossível) ou
  /// [CalcNotReady] (taxa ainda sem histórico).
  Object run(CalcEnv env) {
    final v = _eval(_root, env);
    if (v is double && !v.isFinite) throw const CalcRuntimeError('resultado inválido');
    return v;
  }
}

// ── Léxico ─────────────────────────────────────────────────────────────────────

enum _K { number, word, name, id, op, open, close, semi, end }

class _Tok {
  const _Tok(this.kind, this.text, this.start, this.end, {this.number = 0});
  final _K kind;

  /// Operador já canônico (`>=`, `<>`, `*`), palavra, nome entre colchetes ou id.
  final String text;
  final int start;
  final int end;
  final double number;
}

final RegExp _letter = RegExp(r'[\p{L}_]', unicode: true);
bool _isDigit(String c) => c.codeUnitAt(0) >= 0x30 && c.codeUnitAt(0) <= 0x39;
bool _isLetter(String c) => _letter.hasMatch(c);

const _twoCharOps = {'>=': '>=', '<=': '<=', '<>': '<>', '!=': '<>', '==': '='};
const _oneCharOps = {
  '+': '+', '-': '-', '−': '-', '*': '*', '×': '*', '/': '/', '÷': '/', //
  '=': '=', '<': '<', '>': '>', '≥': '>=', '≤': '<=', '≠': '<>',
};

/// Como o operador aparece numa mensagem.
String _show(String op) => switch (op) {
      '*' => '×',
      '/' => '÷',
      '-' => '−',
      '>=' => '≥',
      '<=' => '≤',
      '<>' => '≠',
      _ => op,
    };

List<_Tok> _lex(String s) {
  final out = <_Tok>[];
  var i = 0;
  while (i < s.length) {
    final c = s[i];
    if (c.trim().isEmpty) {
      i++;
      continue;
    }
    if (_isDigit(c)) {
      var j = i;
      while (j < s.length && _isDigit(s[j])) {
        j++;
      }
      // Vírgula (ou ponto) seguida de dígito é decimal: 0,5. Vírgula solta
      // é separador errado (abaixo).
      if (j + 1 < s.length && (s[j] == ',' || s[j] == '.') && _isDigit(s[j + 1])) {
        j++;
        while (j < s.length && _isDigit(s[j])) {
          j++;
        }
      }
      final text = s.substring(i, j);
      out.add(_Tok(_K.number, text, i, j, number: double.parse(text.replaceAll(',', '.'))));
      i = j;
      continue;
    }
    if (c == '[') {
      final close = s.indexOf(']', i + 1);
      if (close < 0) throw CalcError('Falta fechar o colchete: ${s.substring(i).trim()}]', i, s.length);
      final name = s.substring(i + 1, close).trim();
      if (name.isEmpty) throw CalcError('Colchetes vazios: o nome da variável vai dentro, como em [Velocidade]', i, close + 1);
      out.add(_Tok(_K.name, name, i, close + 1));
      i = close + 1;
      continue;
    }
    if (c == ']') throw CalcError('Colchete fechado sem ter aberto', i, i + 1);
    if (c == '{') {
      final close = s.indexOf('}', i + 1);
      if (close < 0) throw CalcError('Falta fechar a chave', i, s.length);
      out.add(_Tok(_K.id, s.substring(i + 1, close).trim(), i, close + 1));
      i = close + 1;
      continue;
    }
    if (_isLetter(c)) {
      var j = i + 1;
      while (j < s.length && (_isLetter(s[j]) || _isDigit(s[j]))) {
        j++;
      }
      out.add(_Tok(_K.word, s.substring(i, j), i, j));
      i = j;
      continue;
    }
    if (c == '(') {
      out.add(_Tok(_K.open, c, i, i + 1));
    } else if (c == ')') {
      out.add(_Tok(_K.close, c, i, i + 1));
    } else if (c == ';') {
      out.add(_Tok(_K.semi, c, i, i + 1));
    } else if (c == ',') {
      throw CalcError('Separe os valores com ponto e vírgula (;), como em máx(a; b)', i, i + 1);
    } else {
      final two = i + 1 < s.length ? s.substring(i, i + 2) : '';
      final op2 = _twoCharOps[two];
      if (op2 != null) {
        out.add(_Tok(_K.op, op2, i, i + 2));
        i += 2;
        continue;
      }
      final op1 = _oneCharOps[c];
      if (op1 == null) throw CalcError('Não entendi "$c" aqui', i, i + 1);
      out.add(_Tok(_K.op, op1, i, i + 1));
    }
    i++;
  }
  out.add(_Tok(_K.end, '', s.length, s.length));
  return out;
}

// ── Árvore ─────────────────────────────────────────────────────────────────────

sealed class _Node {
  _Node(this.start, this.end);
  final int start;
  final int end;
}

final class _Num extends _Node {
  _Num(this.value, super.start, super.end);
  final double value;
}

final class _Bool extends _Node {
  _Bool(this.value, super.start, super.end);
  final bool value;
}

/// Variável citada: pelo nome (com ou sem colchete) ou pelo id (`{id}`, o
/// texto canônico). [ref] é preenchido na conferência.
final class _RefNode extends _Node {
  _RefNode(this.text, super.start, super.end, {this.byId = false, this.bracket = false});
  final String text;
  final bool byId;
  final bool bracket;
  CalcRef? ref;
}

final class _Unary extends _Node {
  _Unary(this.op, this.child, super.start, super.end);
  final String op; // '-' ou 'não'
  final _Node child;
}

final class _Binary extends _Node {
  _Binary(this.op, this.left, this.right) : super(left.start, right.end);
  final String op;
  final _Node left;
  final _Node right;
}

final class _Call extends _Node {
  _Call(this.fn, this.args, super.start, super.end);
  final CalcFunction fn;
  final List<_Node> args;
}

const _comparisons = {'=', '<>', '<', '>', '<=', '>='};

// ── Sintaxe ────────────────────────────────────────────────────────────────────
//
// Da ligação mais fraca para a mais forte:
//   ou  ·  e  ·  não  ·  comparação (uma por vez)  ·  + −  ·  × ÷  ·  − de sinal

class _Parser {
  _Parser(this.src, this.toks);
  final String src;
  final List<_Tok> toks;
  int _p = 0;

  _Tok get _t => toks[_p];
  _Tok? get _prev => _p > 0 ? toks[_p - 1] : null;
  _Tok _next() => toks[_p++];

  static String _word(_Tok t) => t.kind == _K.word ? CalcScope.plain(t.text) : '';
  bool _isOr(_Tok t) => _word(t) == 'ou';
  bool _isAnd(_Tok t) => _word(t) == 'e';
  bool _isNot(_Tok t) => _word(t) == 'nao';
  bool _isOp(_Tok t, Set<String> ops) => t.kind == _K.op && ops.contains(t.text);

  _Node parse() {
    if (_t.kind == _K.end) throw const CalcError('Escreva a conta', 0, 0);
    final n = _or();
    if (_t.kind != _K.end) throw _unexpected(n);
    return n;
  }

  _Node _or() {
    var l = _and();
    while (_isOr(_t)) {
      _next();
      l = _Binary('ou', l, _and());
    }
    return l;
  }

  _Node _and() {
    var l = _not();
    while (_isAnd(_t)) {
      _next();
      l = _Binary('e', l, _not());
    }
    return l;
  }

  _Node _not() {
    if (_isNot(_t)) {
      final op = _next();
      final c = _not();
      return _Unary('não', c, op.start, c.end);
    }
    return _cmp();
  }

  _Node _cmp() {
    final l = _sum();
    if (!_isOp(_t, _comparisons)) return l;
    final op = _next();
    final n = _Binary(op.text, l, _sum());
    if (_isOp(_t, _comparisons)) {
      throw CalcError('Compare dois valores de cada vez: junte com "e", como em a < b e b < c', _t.start, _t.end);
    }
    return n;
  }

  _Node _sum() {
    var l = _prod();
    while (_isOp(_t, const {'+', '-'})) {
      final op = _next();
      l = _Binary(op.text, l, _prod());
    }
    return l;
  }

  _Node _prod() {
    var l = _unary();
    while (_isOp(_t, const {'*', '/'})) {
      final op = _next();
      l = _Binary(op.text, l, _unary());
    }
    return l;
  }

  _Node _unary() {
    if (_isOp(_t, const {'-', '+'})) {
      final op = _next();
      final c = _unary();
      return op.text == '-' ? _Unary('-', c, op.start, c.end) : c;
    }
    return _primary();
  }

  _Node _primary() {
    final t = _t;
    switch (t.kind) {
      case _K.number:
        _next();
        return _Num(t.number, t.start, t.end);
      case _K.name:
        _next();
        return _RefNode(t.text, t.start, t.end, bracket: true);
      case _K.id:
        _next();
        return _RefNode(t.text, t.start, t.end, byId: true);
      case _K.open:
        final open = _next();
        if (_t.kind == _K.close) throw CalcError('Parênteses vazios: falta o valor dentro', open.start, _t.end);
        final inner = _or();
        if (_t.kind == _K.end) throw CalcError('Falta fechar o parêntese', open.start, open.end);
        if (_t.kind != _K.close) throw _unexpected(inner);
        _next();
        return inner;
      case _K.word:
        final w = _word(t);
        if (w == 'verdadeiro' || w == 'falso') {
          _next();
          return _Bool(w == 'verdadeiro', t.start, t.end);
        }
        if (_isNot(t)) {
          // "não" no meio de uma conta ([A] = não [B]): vale para o que vem logo depois.
          _next();
          final c = _unary();
          return _Unary('não', c, t.start, c.end);
        }
        if (_isAnd(t) || _isOr(t)) throw CalcError('Falta um valor antes de "${t.text}"', t.start, t.end);
        if (toks[_p + 1].kind == _K.open) {
          final fn = CalcFunction.byWord(t.text);
          if (fn == null) {
            throw CalcError('Não conheço a função "${t.text}". Use se, mín, máx, abs, arred ou taxa', t.start, t.end);
          }
          return _call(t, fn);
        }
        _next();
        return _RefNode(t.text, t.start, t.end);
      case _K.op:
        final p = _prev;
        if (p != null && p.kind == _K.op) {
          throw CalcError('Falta um valor entre "${_show(p.text)}" e "${_show(t.text)}"', p.start, t.end);
        }
        throw CalcError('Falta um valor antes de "${_show(t.text)}"', t.start, t.end);
      case _K.close:
        throw _missingAfter(_prev, t, 'Parêntese fechado sem ter aberto');
      case _K.semi:
        throw _missingAfter(_prev, t, 'Falta um valor antes de ";"');
      case _K.end:
        final p = _prev;
        if (p == null) throw const CalcError('Escreva a conta', 0, 0);
        if (p.kind == _K.open) throw CalcError('Falta fechar o parêntese', p.start, p.end);
        throw _missingAfter(p, t, 'Falta um valor no fim');
    }
  }

  /// Faltou o valor depois de um operador, de ";" ou de "e"/"ou".
  CalcError _missingAfter(_Tok? p, _Tok t, String otherwise) {
    if (p != null && (p.kind == _K.op || p.kind == _K.semi || _isAnd(p) || _isOr(p) || _isNot(p))) {
      final what = p.kind == _K.op ? _show(p.text) : p.text;
      return CalcError('Falta um valor depois de "$what"', p.start, p.end);
    }
    return CalcError(otherwise, t.start, t.end);
  }

  _Node _call(_Tok word, CalcFunction fn) {
    final open = toks[_p + 1];
    _p += 2;
    final args = <_Node>[];
    if (_t.kind != _K.close) {
      while (true) {
        args.add(_or());
        if (_t.kind == _K.semi) {
          _next();
          continue;
        }
        if (_t.kind == _K.close) break;
        if (_t.kind == _K.end) throw CalcError('Falta fechar o parêntese de ${fn.label}(', open.start, open.end);
        throw CalcError('Falta ";" entre os valores de ${fn.label}( ), ou ")" no fim', _t.start, _t.end);
      }
    }
    final close = _next();
    final call = _Call(fn, args, word.start, close.end);
    _checkArity(call);
    return call;
  }

  void _checkArity(_Call c) {
    final n = c.args.length;
    String? problem;
    switch (c.fn) {
      case CalcFunction.se:
        if (n != 3) problem = 'se( ) tem 3 partes: se(condição; valor se sim; valor se não)';
      case CalcFunction.min || CalcFunction.max:
        if (n < 2) problem = '${c.fn.label}( ) compara 2 ou mais valores, separados por ";": ${c.fn.example}';
      case CalcFunction.abs:
        if (n != 1) problem = 'abs( ) recebe um valor só: abs(x)';
      case CalcFunction.arred:
        if (n < 1 || n > 2) {
          problem = 'arred( ) recebe o valor e, se quiser, as casas: arred(x; 1)';
        } else if (n == 2) {
          final d = c.args[1];
          if (d is! _Num || d.value != d.value.roundToDouble() || d.value < 0 || d.value > 6) {
            throw CalcError('As casas do arred( ) são um número de 0 a 6', d.start, d.end);
          }
        }
      case CalcFunction.taxa:
        if (n != 1 || c.args.first is! _RefNode) problem = 'taxa( ) recebe uma variável contador, como em taxa([Rótulos cortados])';
    }
    if (problem != null) throw CalcError(problem, c.start, c.end);
  }

  /// O que veio depois de uma conta completa não se encaixa: faltou um sinal
  /// entre os dois — ou é um nome com espaço sem colchetes.
  CalcError _unexpected(_Node before) {
    final t = _t;
    switch (t.kind) {
      case _K.close:
        return CalcError('Parêntese fechado sem ter aberto', t.start, t.end);
      case _K.semi:
        return CalcError('";" só separa valores dentro de uma função, como em máx(a; b)', t.start, t.end);
      default:
        if (before is _RefNode && !before.bracket && !before.byId && (t.kind == _K.word || t.kind == _K.number)) {
          // "Velocidade da faca": junta as palavras seguidas num nome só.
          var last = t;
          for (var i = _p; i < toks.length && (toks[i].kind == _K.word || toks[i].kind == _K.number); i++) {
            last = toks[i];
          }
          final name = src.substring(before.start, last.end);
          return CalcError('Nome com espaço vai entre colchetes: [$name]', before.start, last.end);
        }
        final a = _clip(src.substring(before.start, before.end)), b = _clip(src.substring(t.start, t.end));
        return CalcError('Falta um sinal (+ − × ÷ = …) entre "$a" e "$b"', t.start, t.end);
    }
  }

  static String _clip(String s) => s.length <= 24 ? s : '${s.substring(0, 23)}…';
}

// ── Conferência: variáveis existem? tipos combinam? ────────────────────────────

class _Resolver {
  _Resolver(this.scope, this.uses);
  final CalcScope scope;
  final List<CalcRefUse> uses;

  CalcType type(_Node n) {
    switch (n) {
      case _Num():
        return CalcType.number;
      case _Bool():
        return CalcType.boolean;
      case _RefNode():
        final r = _resolve(n);
        return r.kind == CalcRefKind.boolean ? CalcType.boolean : CalcType.number;
      case _Unary(:final op, :final child):
        type(child);
        return op == '-' ? CalcType.number : CalcType.boolean;
      case _Binary(:final op, :final left, :final right):
        type(left);
        type(right);
        return op == 'e' || op == 'ou' || _comparisons.contains(op) ? CalcType.boolean : CalcType.number;
      case _Call(:final fn, :final args):
        final types = [for (final a in args) type(a)];
        if (fn == CalcFunction.taxa) {
          final ref = (args.first as _RefNode).ref!;
          if (ref.kind != CalcRefKind.number) {
            throw CalcError('taxa( ) conta quanto um número sobe por hora: use com um contador, não com liga/desliga', n.start, n.end);
          }
        }
        if (fn == CalcFunction.se) return types[1] == types[2] ? types[1] : CalcType.number;
        return CalcType.number;
    }
  }

  CalcRef _resolve(_RefNode n) {
    final ref = n.byId ? _byId(n) : _byName(n);
    if (ref.kind == CalcRefKind.text) throw CalcError('"${ref.name}" é texto: não entra em conta', n.start, n.end);
    if (ref.kind == CalcRefKind.list) throw CalcError('"${ref.name}" é uma lista: não entra em conta', n.start, n.end);
    n.ref = ref;
    uses.add(CalcRefUse(ref, n.start, n.end));
    return ref;
  }

  CalcRef _byId(_RefNode n) {
    final r = scope.byId(n.text);
    if (r != null) return r;
    final known = scope.knownNames[n.text];
    throw CalcError(known == null ? 'Uma variável da conta foi apagada' : 'A variável "$known" foi apagada', n.start, n.end);
  }

  CalcRef _byName(_RefNode n) {
    final named = scope.named(n.text);
    if (named.length == 1) return named.first;
    if (named.length > 1) {
      final devices = named.map((r) => r.device).toSet();
      if (devices.length < named.length) {
        throw CalcError('Há ${named.length} variáveis "${n.text}" no mesmo equipamento: renomeie uma', n.start, n.end);
      }
      throw CalcError('Há ${named.length} variáveis "${n.text}" (${devices.join(', ')}): escreva [${named.first.device}: ${named.first.name}]', n.start, n.end);
    }
    // [Equipamento: Nome] desempata nomes repetidos.
    final colon = n.text.indexOf(':');
    if (colon > 0) {
      final found = scope.inDevice(n.text.substring(0, colon), n.text.substring(colon + 1));
      if (found.length == 1) return found.first;
    }
    throw CalcError('Não existe variável "${n.text}"', n.start, n.end);
  }
}

Set<String> _rateIds(_Node n) => switch (n) {
      _Call(fn: CalcFunction.taxa, :final args) => {(args.first as _RefNode).ref!.id},
      _Call(:final args) => {for (final a in args) ..._rateIds(a)},
      _Unary(:final child) => _rateIds(child),
      _Binary(:final left, :final right) => {..._rateIds(left), ..._rateIds(right)},
      _ => const {},
    };

// ── Cálculo ────────────────────────────────────────────────────────────────────

Object _eval(_Node n, CalcEnv env) {
  switch (n) {
    case _Num(:final value):
      return value;
    case _Bool(:final value):
      return value;
    case _RefNode():
      final ref = n.ref!;
      final v = env.valueOf(ref.id);
      if (v is bool) return v;
      if (v is num) return v.toDouble();
      throw CalcRuntimeError('"${ref.name}" não trouxe um número');
    case _Unary(:final op, :final child):
      return op == '-' ? -_number(_eval(child, env)) : !_truth(_eval(child, env));
    case _Binary(:final op, :final left, :final right):
      // "e"/"ou" param no primeiro que decide.
      if (op == 'e') return _truth(_eval(left, env)) && _truth(_eval(right, env));
      if (op == 'ou') return _truth(_eval(left, env)) || _truth(_eval(right, env));
      final a = _eval(left, env), b = _eval(right, env);
      if (a is bool && b is bool && (op == '=' || op == '<>')) return op == '=' ? a == b : a != b;
      final x = _number(a), y = _number(b);
      switch (op) {
        case '+':
          return x + y;
        case '-':
          return x - y;
        case '*':
          return x * y;
        case '/':
          if (y == 0) throw const CalcRuntimeError('divisão por zero');
          return x / y;
        case '=':
          return _same(x, y);
        case '<>':
          return !_same(x, y);
        case '<':
          return x < y && !_same(x, y);
        case '>':
          return x > y && !_same(x, y);
        case '<=':
          return x < y || _same(x, y);
        case '>=':
          return x > y || _same(x, y);
      }
      throw CalcRuntimeError('operador "$op" desconhecido');
    case _Call(:final fn, :final args):
      switch (fn) {
        case CalcFunction.se:
          return _truth(_eval(args[0], env)) ? _eval(args[1], env) : _eval(args[2], env);
        case CalcFunction.min:
          return args.map((a) => _number(_eval(a, env))).reduce(math.min);
        case CalcFunction.max:
          return args.map((a) => _number(_eval(a, env))).reduce(math.max);
        case CalcFunction.abs:
          return _number(_eval(args[0], env)).abs();
        case CalcFunction.arred:
          final x = _number(_eval(args[0], env));
          final places = args.length > 1 ? (args[1] as _Num).value.round() : 0;
          final f = math.pow(10, places);
          return (x * f).round() / f;
        case CalcFunction.taxa:
          final ref = (args.first as _RefNode).ref!;
          final r = env.perHour(ref.id);
          if (r == null) throw const CalcNotReady('calculando a taxa (precisa de alguns segundos)');
          return r;
      }
  }
}

/// Liga/desliga entra em conta como 1/0.
double _number(Object v) => v is bool ? (v ? 1.0 : 0.0) : (v as num).toDouble();

/// Número vale como condição se for diferente de zero.
bool _truth(Object v) => v is bool ? v : (v as num) != 0;

/// Igualdade com folga para o erro do ponto flutuante (0,1 + 0,2 = 0,3).
bool _same(double a, double b) => (a - b).abs() <= 1e-9 * math.max(1.0, math.max(a.abs(), b.abs()));
