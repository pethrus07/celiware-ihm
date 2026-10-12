/// Dados fixos do app — um lugar só para nome, versão e links.
class AppInfo {
  AppInfo._();

  static const name = 'Ware IoT';
  static const company = 'Celiware';

  /// Manter igual ao `version:` do pubspec.yaml (o build de loja lê de lá).
  static const version = '1.4.0';

  /// Pasta dos vídeos tutoriais (Drive/YouTube). Vídeo não mora dentro do app
  /// — incharia o download da loja. Enquanto for nulo, a tela de tutoriais diz
  /// que os vídeos estão em produção, em vez de mostrar lista falsa.
  static const String? videosUrl = null;

  /// Política de privacidade publicada (a mesma URL vai no Play Console).
  /// Mudou o domínio do site (`site/README.md`), mude aqui também.
  static const privacyUrl = 'https://ware-iot.pages.dev/privacidade';
}
