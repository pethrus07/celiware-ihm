// Câmera IP ligada a uma máquina (REQUISITOS-ETAPA4 §9.2, CM-1 a CM-5):
// aberta em tela cheia por um botão da tela de operação ou pela lista em
// Ferramentas → Câmeras.
//
// Mora no projeto e viaja na exportação — **menos a senha**. O projeto guarda
// só uma referência ([IpCamera.secretRef]) para o cofre do aparelho
// (`CameraVault`, Android Keystore); quem importa o arquivo digita a senha
// de novo. Ver ARQUITETURA.md, "Câmeras".

import '../core/utils/ids.dart';
import 'project.dart';

/// Uma câmera cadastrada. Imutável.
class IpCamera {
  const IpCamera({
    required this.id,
    this.name = 'Câmera',
    this.deviceId,
    this.url = '',
    this.substreamUrl = '',
    this.snapshotUrl = '',
    this.username = '',
    this.secretRef,
  });

  final String id;
  final String name;

  /// Máquina (equipamento do projeto) a que a câmera pertence; nulo = nenhuma.
  /// Agrupa a lista e põe as câmeras da máquina primeiro na escolha do botão.
  final String? deviceId;

  /// Fluxo principal (`rtsp://192.168.1.64:554/...`), **sem** usuário e senha
  /// dentro — eles ficam em [username] e no cofre.
  final String url;

  /// Fluxo leve (substream: resolução baixa, H.264): é o que a tela cheia
  /// abre quando existe — chega mais rápido e gasta menos Wi-Fi. Vazio = só
  /// o principal.
  final String substreamUrl;

  /// Foto pela URL HTTP da câmera (`http://.../picture`). Vazio = sem o botão
  /// de foto.
  final String snapshotUrl;

  final String username;

  /// Chave da senha no cofre do aparelho. Nula = câmera sem senha. Depois de
  /// importar, aponta para uma chave que o cofre ainda não tem: o app sabe
  /// que precisa da senha e pede.
  final String? secretRef;

  bool get hasPassword => secretRef != null;

  /// O que a tela cheia abre: o fluxo leve, quando existe.
  String get liveUrl => substreamUrl.isNotEmpty ? substreamUrl : url;

  /// "192.168.1.64" — para as listas.
  String get host => CameraUrl.host(url) ?? '';

  IpCamera copyWith({
    String? name,
    String? deviceId,
    bool clearDevice = false,
    String? url,
    String? substreamUrl,
    String? snapshotUrl,
    String? username,
    String? secretRef,
    bool clearSecret = false,
  }) =>
      IpCamera(
        id: id,
        name: name ?? this.name,
        deviceId: clearDevice ? null : (deviceId ?? this.deviceId),
        url: url ?? this.url,
        substreamUrl: substreamUrl ?? this.substreamUrl,
        snapshotUrl: snapshotUrl ?? this.snapshotUrl,
        username: username ?? this.username,
        secretRef: clearSecret ? null : (secretRef ?? this.secretRef),
      );

  /// Só o que existe vai para o arquivo. Nunca a senha.
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        if (deviceId != null) 'deviceId': deviceId,
        'url': url,
        if (substreamUrl.isNotEmpty) 'substreamUrl': substreamUrl,
        if (snapshotUrl.isNotEmpty) 'snapshotUrl': snapshotUrl,
        if (username.isNotEmpty) 'username': username,
        if (secretRef != null) 'secretRef': secretRef,
      };

  /// Arquivo editado à mão com usuário e senha dentro da URL: o usuário vai
  /// para o campo, a senha é descartada (nunca fica no projeto) e a câmera
  /// passa a pedir a senha.
  factory IpCamera.fromJson(Map<String, dynamic> j) {
    String text(String key) => j[key] is String ? (j[key] as String).trim() : '';
    final main = CameraUrl.split(text('url'));
    final sub = CameraUrl.split(text('substreamUrl'));
    final snap = CameraUrl.split(text('snapshotUrl'));
    final user = text('username').isNotEmpty ? text('username') : (main.user ?? sub.user ?? snap.user ?? '');
    final leaked = main.password != null || sub.password != null || snap.password != null;
    final ref = j['secretRef'] is String ? j['secretRef'] as String : null;
    return IpCamera(
      id: j['id'] as String,
      name: text('name').isEmpty ? 'Câmera' : text('name'),
      deviceId: j['deviceId'] is String ? j['deviceId'] as String : null,
      url: main.url,
      substreamUrl: sub.url,
      snapshotUrl: snap.url,
      username: user,
      secretRef: ref ?? (leaked ? newSecretRef() : null),
    );
  }

  /// Chave nova para o cofre ("cs_lz3k9q_4f2a").
  static String newSecretRef() => newId('cs');
}

/// Endereços de câmera: separar e juntar usuário e senha, conferir, sugerir
/// o fluxo leve. Tudo por texto — o `Uri` do Dart reescreveria a consulta de
/// câmeras que dependem dela (`?channel=1&subtype=0`).
class CameraUrl {
  CameraUrl._();

  /// Tira usuário e senha de dentro do endereço (`rtsp://admin:1234@ip/...`).
  /// Devolve o endereço limpo e o que estava nele, já sem os `%40` da URL.
  static ({String url, String? user, String? password}) split(String raw) {
    final s = raw.trim();
    final scheme = s.indexOf('://');
    if (scheme < 0) return (url: s, user: null, password: null);
    final start = scheme + 3;
    var end = s.length;
    for (final c in const ['/', '?', '#']) {
      final i = s.indexOf(c, start);
      if (i >= 0 && i < end) end = i;
    }
    final authority = s.substring(start, end);
    final at = authority.lastIndexOf('@');
    if (at < 0) return (url: s, user: null, password: null);
    final info = authority.substring(0, at);
    final clean = s.substring(0, start) + authority.substring(at + 1) + s.substring(end);
    final colon = info.indexOf(':');
    String dec(String x) {
      try {
        return Uri.decodeComponent(x);
      } on ArgumentError {
        return x;
      }
    }
    final user = dec(colon < 0 ? info : info.substring(0, colon));
    final pass = colon < 0 ? null : dec(info.substring(colon + 1));
    return (url: clean, user: user.isEmpty ? null : user, password: pass == null || pass.isEmpty ? null : pass);
  }

  /// O endereço com usuário e senha dentro, codificados (`@`, `:`, `/` e `#`
  /// da senha não podem quebrar a URL). É o que vai para o player — nunca
  /// para o arquivo nem para a tela.
  static String withCredentials(String url, String user, String? password) {
    if (user.isEmpty) return url;
    final scheme = url.indexOf('://');
    if (scheme < 0) return url;
    final info = Uri.encodeComponent(user) + (password == null || password.isEmpty ? '' : ':${Uri.encodeComponent(password)}');
    return '${url.substring(0, scheme + 3)}$info@${url.substring(scheme + 3)}';
  }

  /// "192.168.1.64" de "rtsp://192.168.1.64:554/...". Nulo se não dá para ler.
  static String? host(String url) {
    final s = split(url).url;
    final scheme = s.indexOf('://');
    if (scheme < 0) return null;
    var rest = s.substring(scheme + 3);
    for (final c in const ['/', '?', '#']) {
      final i = rest.indexOf(c);
      if (i >= 0) rest = rest.substring(0, i);
    }
    if (rest.startsWith('[')) {
      final close = rest.indexOf(']');
      return close < 0 ? null : rest.substring(1, close);
    }
    final colon = rest.indexOf(':');
    final h = colon < 0 ? rest : rest.substring(0, colon);
    return h.isEmpty ? null : h;
  }

  /// Erro do endereço do vídeo, em palavras; nulo = serve.
  static String? rtspError(String url) {
    final s = url.trim();
    if (s.isEmpty) return 'Cole o endereço do vídeo (rtsp://…) — vem no manual ou no app da câmera';
    if (!s.toLowerCase().startsWith('rtsp://')) return 'O endereço do vídeo começa com rtsp://';
    if (host(s) == null) return 'Falta o IP da câmera depois de rtsp://';
    if (s.contains(' ')) return 'O endereço não pode ter espaço';
    return null;
  }

  /// Erro do endereço da foto; vazio vale (sem foto).
  static String? httpError(String url) {
    final s = url.trim();
    if (s.isEmpty) return null;
    final l = s.toLowerCase();
    if (!l.startsWith('http://') && !l.startsWith('https://')) return 'O endereço da foto começa com http://';
    if (host(s) == null) return 'Falta o IP da câmera depois de http://';
    if (s.contains(' ')) return 'O endereço não pode ter espaço';
    return null;
  }

  /// O fluxo leve das marcas que seguem um padrão; nulo = não reconhecido.
  ///
  ///   • Hikvision: canal 101 → 102 (`/Streaming/Channels/101`) e
  ///     `/h264/ch1/main/` → `/h264/ch1/sub/` (firmware antigo);
  ///   • Intelbras e Dahua: `subtype=0` → `subtype=1`;
  ///   • TP-Link Tapo: `/stream1` → `/stream2`.
  static String? substreamGuess(String url) {
    final s = split(url).url;
    final hik = RegExp(r'(/Streaming/Channels/)(\d*?)01(?=$|[/?#])', caseSensitive: false).firstMatch(s);
    if (hik != null) return s.replaceRange(hik.start, hik.end, '${hik.group(1)}${hik.group(2)}02');
    final hikOld = RegExp(r'/main/av_stream', caseSensitive: false).firstMatch(s);
    if (hikOld != null) return s.replaceRange(hikOld.start, hikOld.end, '/sub/av_stream');
    final dahua = RegExp(r'([?&]subtype=)0(?=$|&)', caseSensitive: false).firstMatch(s);
    if (dahua != null) return s.replaceRange(dahua.start, dahua.end, '${dahua.group(1)}1');
    final tapo = RegExp(r'/stream1$').firstMatch(s);
    if (tapo != null) return s.replaceRange(tapo.start, tapo.end, '/stream2');
    return null;
  }
}

/// Modelos de endereço das marcas mais comuns — para quem não sabe o
/// endereço: escolhe a marca, digita o IP e o resto vem pronto.
class CameraBrand {
  const CameraBrand(this.name, this.main, this.sub, this.photo);
  final String name;
  final String main;
  final String sub;
  final String photo;

  static const all = [
    CameraBrand(
      'Hikvision',
      'rtsp://{ip}:554/Streaming/Channels/101',
      'rtsp://{ip}:554/Streaming/Channels/102',
      'http://{ip}/ISAPI/Streaming/channels/101/picture',
    ),
    CameraBrand(
      'Intelbras / Dahua',
      'rtsp://{ip}:554/cam/realmonitor?channel=1&subtype=0',
      'rtsp://{ip}:554/cam/realmonitor?channel=1&subtype=1',
      'http://{ip}/cgi-bin/snapshot.cgi?channel=1',
    ),
  ];

  String fill(String template, String ip) => template.replaceAll('{ip}', ip.trim());
}

/// Câmeras no projeto. Mora aqui, e não em `project.dart`, para o projeto
/// mudar o mínimo (como as receitas).
extension ProjectCameras on Project {
  IpCamera? camera(String id) => cameras.where((c) => c.id == id).firstOrNull;

  /// Câmeras da máquina [deviceId].
  List<IpCamera> camerasOf(String deviceId) => cameras.where((c) => c.deviceId == deviceId).toList();

  Project upsertCamera(IpCamera c) {
    final i = cameras.indexWhere((x) => x.id == c.id);
    return copyWith(cameras: i < 0 ? [...cameras, c] : ([...cameras]..[i] = c));
  }

  Project removeCamera(String id) => copyWith(cameras: cameras.where((c) => c.id != id).toList());

  /// As chaves do cofre que este projeto usa (o resto pode ser apagado).
  Set<String> get cameraSecretRefs => {for (final c in cameras) ?c.secretRef};

  /// Projeto vindo de um arquivo (importar): toda câmera com senha ganha uma
  /// chave nova, que o cofre ainda não tem — então a senha é pedida de novo,
  /// neste aparelho ou em outro. A chave antiga podia existir aqui (o mesmo
  /// projeto exportado e importado de volta) e daria a senha de outra câmera.
  Project withFreshCameraSecrets() {
    if (!cameras.any((c) => c.hasPassword)) return this;
    return copyWith(cameras: [
      for (final c in cameras) c.hasPassword ? c.copyWith(secretRef: IpCamera.newSecretRef()) : c,
    ]);
  }
}
