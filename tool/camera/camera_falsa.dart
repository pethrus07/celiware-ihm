// Câmera IP falsa — para testar as câmeras (CM-1 a CM-5) sem câmera.
//
// O ffmpeg sozinho não serve: o `-rtsp_flags listen` é só de entrada (ele
// recebe um fluxo empurrado, não atende um player). Aqui o ffmpeg gera o
// vídeo — barras de teste com o **relógio do PC com milissegundos** gravado
// na imagem — e manda RTP H.264 para este programa, que faz o papel de
// servidor RTSP: OPTIONS, DESCRIBE, SETUP, PLAY, GET_PARAMETER e TEARDOWN,
// com o vídeo intercalado na própria conexão TCP (o "RTP sobre TCP" das
// câmeras). Pedido de RTP por UDP recebe 461, e o player cai para TCP —
// no emulador o UDP nem chegaria (a rede dele é NAT).
//
// Com `--usuario` e `--senha`, pede autenticação Basic do DESCRIBE em diante
// (o OPTIONS passa, como na maioria das câmeras): senha errada dá 401.
// `--http` liga a foto em `http://<pc>:<porta>/foto.jpg`, com a mesma senha.
//
// Latência: tire uma captura do aparelho e compare o relógio do vídeo com a
// hora do PC no instante da captura. Pelo `adb exec-out screencap` a captura
// leva ~0,1–0,3 s; anote a hora antes e depois.
//
// Situações:
//   • câmera desligada  → encerre este programa (Ctrl+C): conexão recusada;
//   • câmera sem imagem → mate só o ffmpeg (o PID sai na partida): a
//     conexão continua de pé e nada chega;
//   • câmera voltou     → rode de novo.
//
// Uso (no emulador, o PC é 10.0.2.2):
//   dart run tool/camera/camera_falsa.dart [--porta 8554] [--tamanho 640x360]
//       [--fps 25] [--usuario admin --senha 1234] [--http 8080] [--fatias 1]
//   rtsp://10.0.2.2:8554/live
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

Future<void> main(List<String> args) async {
  final o = _Options.parse(args);
  final dir = await Directory.systemTemp.createTemp('camera_falsa');
  final sdpFile = File('${dir.path}${Platform.pathSeparator}camera.sdp');

  // RTP e RTCP do ffmpeg chegam aqui. O RTCP só é drenado: sem ninguém na
  // porta, o Windows devolve "porta inalcançável" e o ffmpeg pode desistir.
  final rtp = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, o.rtpPort);
  final rtcp = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, o.rtpPort + 1);
  rtcp.listen((_) => rtcp.receive());

  final ffmpeg = await Process.start('ffmpeg', [
    '-hide_banner', '-loglevel', 'warning',
    '-re', '-f', 'lavfi', '-i', 'testsrc2=size=${o.size}:rate=${o.fps}',
    '-vf', _clockFilter,
    '-c:v', 'libx264', '-preset', 'veryfast', '-tune', 'zerolatency',
    '-pix_fmt', 'yuv420p', '-g', '${o.fps}', '-keyint_min', '${o.fps}', '-sc_threshold', '0', '-b:v', '1M',
    // Fatias por quadro: o zerolatency do x264 corta em várias (uma por
    // núcleo); câmera costuma mandar uma. `--fatias 4` testa o outro caso.
    '-x264-params', o.slices > 1 ? 'slices=${o.slices}' : 'sliced-threads=0:slices=1',
    // SPS/PPS no SDP (sprop-parameter-sets), como numa câmera: o ExoPlayer
    // recusa H.264 sem eles ("missing sprop parameter").
    '-flags', '+global_header',
    '-f', 'rtp', '-payload_type', '96', '-sdp_file', sdpFile.path,
    'rtp://127.0.0.1:${o.rtpPort}?rtcpport=${o.rtpPort + 1}&pkt_size=1200',
  ]);
  ffmpeg.stdout.drain<void>();
  ffmpeg.stderr.transform(utf8.decoder).listen((l) => _log('ffmpeg: ${l.trim()}'));
  _log('ffmpeg no PID ${ffmpeg.pid} (mate só ele para simular "câmera sem imagem")');

  final sdp = await _waitSdp(sdpFile);
  final server = _RtspServer(o, sdp);
  rtp.listen((ev) {
    if (ev != RawSocketEvent.read) return;
    final d = rtp.receive();
    if (d != null) server.onRtp(d.data);
  });
  await server.start();
  if (o.httpPort != null) await _startHttp(o);

  ProcessSignal.sigint.watch().listen((_) {
    ffmpeg.kill();
    exit(0);
  });
  final code = await ffmpeg.exitCode;
  _log('ffmpeg saiu ($code): a câmera segue de pé, sem imagem');
}

/// Relógio do PC (hora local com milissegundos) no alto da imagem.
const _clockFilter = "drawtext=fontfile='C\\:/Windows/Fonts/consola.ttf':text='%{localtime\\:%T.%3N}'"
    ':fontsize=h/9:fontcolor=white:box=1:boxcolor=black@0.75:boxborderw=8:x=(w-text_w)/2:y=h/12';

class _Options {
  int port = 8554;
  int rtpPort = 5004;
  int? httpPort;
  String size = '640x360';
  int fps = 25;
  String? user;
  String? pass;
  int slices = 1;

  static _Options parse(List<String> a) {
    final o = _Options();
    for (var i = 0; i + 1 < a.length; i += 2) {
      final v = a[i + 1];
      switch (a[i]) {
        case '--porta':
          o.port = int.parse(v);
        case '--rtp':
          o.rtpPort = int.parse(v);
        case '--http':
          o.httpPort = int.parse(v);
        case '--tamanho':
          o.size = v;
        case '--fps':
          o.fps = int.parse(v);
        case '--usuario':
          o.user = v;
        case '--senha':
          o.pass = v;
        case '--fatias':
          o.slices = int.parse(v);
      }
    }
    return o;
  }

  bool get auth => user != null && pass != null;

  /// Confere o cabeçalho Authorization (Basic).
  bool accepts(String? header) {
    if (!auth) return true;
    if (header == null || !header.startsWith('Basic ')) return false;
    try {
      return utf8.decode(base64.decode(header.substring(6).trim())) == '$user:$pass';
    } on FormatException {
      return false;
    }
  }
}

void _log(String s) {
  final t = DateTime.now();
  String two(int n) => n.toString().padLeft(2, '0');
  stdout.writeln('[${two(t.hour)}:${two(t.minute)}:${two(t.second)}.${t.millisecond.toString().padLeft(3, '0')}] $s');
}

Future<String> _waitSdp(File f) async {
  for (var i = 0; i < 100; i++) {
    if (await f.exists()) {
      final s = await f.readAsString();
      if (s.contains('a=rtpmap')) return s;
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  throw StateError('o ffmpeg não escreveu o SDP');
}

/// O SDP do ffmpeg descreve um envio para 127.0.0.1:porta; o do RTSP
/// descreve a faixa e deixa o transporte para o SETUP.
String _rtspSdp(String ffmpegSdp) {
  final out = <String>[];
  for (final line in const LineSplitter().convert(ffmpegSdp)) {
    if (line.startsWith('c=')) {
      out.add('c=IN IP4 0.0.0.0');
    } else if (line.startsWith('m=video')) {
      out.add('m=video 0 RTP/AVP 96');
      out.add('a=control:trackID=0');
    } else if (line.startsWith('s=')) {
      out.add('s=Camera falsa');
    } else if (line.isNotEmpty) {
      out.add(line);
    }
  }
  final i = out.indexWhere((l) => l.startsWith('m='));
  out.insert(i, 'a=control:*');
  return '${out.join('\r\n')}\r\n';
}

class _Client {
  _Client(this.socket);
  final Socket socket;
  final List<int> buffer = [];
  String? session;
  int channel = 0;

  /// PLAY recebido; a resposta sai no próximo quadro-chave, com o RTP-Info
  /// do primeiro pacote que vai seguir.
  int? pendingPlayCSeq;
  String? pendingPlayUrl;
  bool playing = false;
}

class _RtspServer {
  _RtspServer(this.o, String ffmpegSdp) : sdp = _rtspSdp(ffmpegSdp);
  final _Options o;
  final String sdp;
  final _clients = <_Client>[];
  var _sessions = 0x2f1a000;

  Future<void> start() async {
    final server = await ServerSocket.bind(InternetAddress.anyIPv4, o.port);
    _log('RTSP em rtsp://<ip-do-pc>:${o.port}/live${o.auth ? ' (usuário "${o.user}")' : ''} — no emulador, 10.0.2.2');
    server.listen((s) {
      s.setOption(SocketOption.tcpNoDelay, true);
      final c = _Client(s);
      _clients.add(c);
      _log('conexão de ${s.remoteAddress.address}:${s.remotePort}');
      // Player que fecha no meio do envio: o erro de escrita chega aqui.
      s.done.then((_) => _drop(c), onError: (_) => _drop(c));
      s.listen((data) {
        c.buffer.addAll(data);
        _drain(c);
      }, onDone: () => _drop(c), onError: (_) => _drop(c));
    });
  }

  void _drop(_Client c) {
    if (_clients.remove(c)) _log('conexão fechada');
    c.socket.destroy();
  }

  void _drain(_Client c) {
    while (c.buffer.isNotEmpty && _clients.contains(c)) {
      // RTCP do cliente intercalado na conexão: só pular.
      if (c.buffer[0] == 0x24) {
        if (c.buffer.length < 4) return;
        final len = (c.buffer[2] << 8) | c.buffer[3];
        if (c.buffer.length < 4 + len) return;
        c.buffer.removeRange(0, 4 + len);
        continue;
      }
      final text = latin1.decode(c.buffer, allowInvalid: true);
      final end = text.indexOf('\r\n\r\n');
      if (end < 0) return;
      final head = text.substring(0, end);
      final lines = head.split('\r\n');
      final headers = <String, String>{};
      for (final l in lines.skip(1)) {
        final k = l.indexOf(':');
        if (k > 0) headers[l.substring(0, k).trim().toLowerCase()] = l.substring(k + 1).trim();
      }
      final bodyLen = int.tryParse(headers['content-length'] ?? '') ?? 0;
      if (c.buffer.length < end + 4 + bodyLen) return;
      c.buffer.removeRange(0, end + 4 + bodyLen);
      _handle(c, lines.first, headers);
    }
  }

  void _reply(_Client c, String cseq, int code, String reason, [Map<String, String> extra = const {}, String body = '']) {
    if (!_clients.contains(c)) return;
    final b = StringBuffer('RTSP/1.0 $code $reason\r\nCSeq: $cseq\r\nServer: camera-falsa\r\n');
    extra.forEach((k, v) => b.write('$k: $v\r\n'));
    if (body.isNotEmpty) b.write('Content-Length: ${latin1.encode(body).length}\r\n');
    b.write('\r\n$body');
    c.socket.add(latin1.encode(b.toString()));
  }

  void _handle(_Client c, String requestLine, Map<String, String> h) {
    final parts = requestLine.split(' ');
    final method = parts.first;
    final url = parts.length > 1 ? parts[1] : '';
    final cseq = h['cseq'] ?? '0';
    if (method != 'OPTIONS' && method != 'GET_PARAMETER' && !o.accepts(h['authorization'])) {
      _log('$method → 401 (${h['authorization'] == null ? 'sem senha' : 'senha errada'})');
      _reply(c, cseq, 401, 'Unauthorized', {'WWW-Authenticate': 'Basic realm="Camera falsa"'});
      return;
    }
    switch (method) {
      case 'OPTIONS':
        _reply(c, cseq, 200, 'OK', {'Public': 'OPTIONS, DESCRIBE, SETUP, PLAY, TEARDOWN, GET_PARAMETER'});
      case 'DESCRIBE':
        final base = url.endsWith('/') ? url : '$url/';
        _reply(c, cseq, 200, 'OK', {'Content-Base': base, 'Content-Type': 'application/sdp'}, sdp);
      case 'SETUP':
        final t = h['transport'] ?? '';
        if (!t.contains('TCP')) {
          _log('SETUP por UDP → 461 (o player tenta TCP)');
          _reply(c, cseq, 461, 'Unsupported Transport');
          return;
        }
        final m = RegExp(r'interleaved=(\d+)-(\d+)').firstMatch(t);
        c.channel = m == null ? 0 : int.parse(m.group(1)!);
        c.session ??= (_sessions++).toRadixString(16).toUpperCase();
        _reply(c, cseq, 200, 'OK', {
          'Transport': 'RTP/AVP/TCP;unicast;interleaved=${c.channel}-${c.channel + 1}',
          'Session': '${c.session};timeout=60',
        });
      case 'PLAY':
        c.pendingPlayCSeq = int.tryParse(cseq);
        c.pendingPlayUrl = url;
        _log('PLAY: espera o próximo quadro-chave');
      case 'GET_PARAMETER':
        _reply(c, cseq, 200, 'OK', {if (c.session != null) 'Session': c.session!});
      case 'TEARDOWN':
        _reply(c, cseq, 200, 'OK', {if (c.session != null) 'Session': c.session!});
        _drop(c);
      default:
        _reply(c, cseq, 405, 'Method Not Allowed');
    }
  }

  /// Começo de quadro-chave: SPS, IDR inteiro ou o primeiro pedaço de um IDR.
  static bool _startsKeyframe(Uint8List p) {
    final cc = p[0] & 0x0F;
    final off = 12 + cc * 4;
    if (p.length <= off + 1) return false;
    final nal = p[off] & 0x1F;
    if (nal == 7 || nal == 5) return true;
    if (nal == 28) {
      final fu = p[off + 1];
      return (fu & 0x80) != 0 && ((fu & 0x1F) == 5 || (fu & 0x1F) == 7);
    }
    if (nal == 24 && p.length > off + 3) {
      final inner = p[off + 3] & 0x1F;
      return inner == 7 || inner == 5;
    }
    return false;
  }

  void onRtp(Uint8List p) {
    if (p.length < 12 || _clients.isEmpty) return;
    final key = _startsKeyframe(p);
    for (final c in [..._clients]) {
      if (!c.playing && c.pendingPlayCSeq != null && key) {
        final seq = (p[2] << 8) | p[3];
        final ts = ByteData.sublistView(p, 4, 8).getUint32(0);
        final track = c.pendingPlayUrl!.endsWith('/') ? '${c.pendingPlayUrl}trackID=0' : '${c.pendingPlayUrl}/trackID=0';
        _reply(c, '${c.pendingPlayCSeq}', 200, 'OK', {
          'Session': c.session ?? '0',
          'Range': 'npt=0.000-',
          'RTP-Info': 'url=$track;seq=$seq;rtptime=$ts',
        });
        c.playing = true;
        c.pendingPlayCSeq = null;
        _log('tocando');
      }
      if (!c.playing) continue;
      final frame = Uint8List(4 + p.length)
        ..[0] = 0x24
        ..[1] = c.channel
        ..[2] = p.length >> 8
        ..[3] = p.length & 0xFF
        ..setRange(4, 4 + p.length, p);
      try {
        c.socket.add(frame);
      } on Object {
        _drop(c);
      }
    }
  }
}

/// Foto da câmera (CM-4): um JPEG novo a cada pedido, com o relógio.
Future<void> _startHttp(_Options o) async {
  final server = await HttpServer.bind(InternetAddress.anyIPv4, o.httpPort!);
  _log('Foto em http://<ip-do-pc>:${o.httpPort}/foto.jpg');
  server.listen((req) async {
    final res = req.response;
    if (!o.accepts(req.headers.value(HttpHeaders.authorizationHeader))) {
      _log('foto → 401');
      res.statusCode = HttpStatus.unauthorized;
      res.headers.set(HttpHeaders.wwwAuthenticateHeader, 'Basic realm="Camera falsa"');
      await res.close();
      return;
    }
    if (req.uri.path != '/foto.jpg') {
      res.statusCode = HttpStatus.notFound;
      await res.close();
      return;
    }
    final r = await Process.run('ffmpeg', [
      '-hide_banner', '-loglevel', 'error', '-f', 'lavfi', '-i', 'testsrc2=size=${o.size}:rate=1',
      '-vf', _clockFilter, '-frames:v', '1', '-f', 'image2pipe', '-c:v', 'mjpeg', '-',
    ], stdoutEncoding: null);
    final bytes = r.stdout as List<int>;
    _log('foto → 200 (${bytes.length} bytes)');
    res.headers.contentType = ContentType('image', 'jpeg');
    res.add(bytes);
    await res.close();
  });
}
