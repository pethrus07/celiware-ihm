/// Dados fixos do app — um lugar só para nome, versão e links.
class AppInfo {
  AppInfo._();

  static const name = 'Celiware IHM';
  static const company = 'Celiware';

  /// Manter igual ao `version:` do pubspec.yaml (o build de loja lê de lá).
  static const version = '1.0.0';

  /// Pasta dos vídeos tutoriais (Drive/YouTube). Vídeo não mora dentro do app
  /// — incharia o download da loja. Enquanto for nulo, a tela de tutoriais diz
  /// que os vídeos estão em produção, em vez de mostrar lista falsa.
  static const String? videosUrl = null;
}
