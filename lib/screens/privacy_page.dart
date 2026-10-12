import 'package:flutter/material.dart';

import '../app/app_info.dart';
import '../core/theme/app_theme.dart';
import '../widgets/common/adaptive.dart';
import '../widgets/common/common.dart';

/// Mais → Sobre → Privacidade (PS-5). A Play pede a política também dentro do
/// app, em link ou texto. Texto, de propósito: na rede da máquina quase nunca
/// há internet, e um link não abriria justo onde o app é usado.
///
/// É o mesmo conteúdo de `site/privacidade.html`: mudou um, mude o outro (e a
/// ficha de Segurança dos dados em `docs/loja/formularios.md`).
class PrivacyPage extends StatelessWidget {
  const PrivacyPage({super.key});

  /// Título da seção e parágrafos; linha começando com "• " vira item de lista.
  static const sections = <(String, List<String>)>[
    ('O que fica no seu celular', [
      'O app guarda, só na área privada dele no aparelho:',
      '• o projeto: equipamentos, variáveis, telas, alarmes, receitas e regras que você cadastrou, inclusive usuário e senha de equipamento (broker MQTT), quando houver;',
      '• os históricos de alarmes, de regras e de receitas aplicadas, com o nome digitado em "Quem está aplicando";',
      '• os registros de dados que você criar (Mais → Registros);',
      '• preferências do aparelho: aparência, voz e tutoriais já vistos.',
      'Nada disso é enviado para nós nem para ninguém. Com o backup do Android ligado, o próprio Android pode guardar uma cópia do projeto, dos históricos e das preferências na sua conta Google, como faz com os outros apps; os registros de dados ficam de fora. Para apagar tudo, desinstale o app ou limpe os dados dele nos ajustes do Android.',
    ]),
    ('A rede local', [
      'O app conversa com os equipamentos que você cadastrar (CLP, inversor, conversor, broker), no endereço que você informar ou pelo cabo USB ligado ao celular. A conversa vai direto do celular para o equipamento, pela sua rede, pela VPN que você configurar ou pelo cabo, sem passar por servidor nosso.',
      'O app também consulta em qual Wi-Fi o celular está, para usar a rede da máquina e avisar quando a faixa de IP é diferente. Isso não sai do aparelho.',
    ]),
    ('Arquivos', [
      'O app só abre ou grava arquivo quando você pede: enviar ou salvar o projeto, mandar a planilha de um registro, importar um projeto, escolher uma imagem ou um PDF para a tela.',
      'O arquivo do projeto leva as senhas de equipamento cadastradas: envie só para quem pode acessar a máquina. Depois de enviado, vale a política do app que você escolheu (WhatsApp, e-mail, Drive).',
    ]),
    ('Voz', [
      'Os avisos por voz usam o motor de voz do Android (por exemplo, Serviços de fala do Google), que segue a política dele.',
    ]),
    ('O que o app não faz', [
      '• Não pede cadastro nem login.',
      '• Não coleta localização, contatos, fotos, áudio nem identificadores do aparelho.',
      '• Não usa anúncios, análise de uso nem relatório de falhas que envie dados.',
      '• Não vende nem compartilha dados com ninguém.',
    ]),
    ('Permissões', [
      'Só de rede (internet, estado da rede e troca de rede), para falar com os equipamentos e usar o Wi-Fi da máquina. O Android concede sem perguntar.',
    ]),
    ('Uso profissional', [
      'O ${AppInfo.name} é da ${AppInfo.company}, feito para uso profissional, na indústria, e não é direcionado a crianças.',
    ]),
    ('Seus direitos (LGPD)', [
      'Como nenhum dado sai do seu celular para nós, não guardamos nada sobre você para consultar, corrigir ou apagar. Os dados do projeto estão no aparelho, sob o seu controle.',
    ]),
  ];

  @override
  Widget build(BuildContext context) {
    final body = TextStyle(color: Ind.text, fontSize: 15, height: 1.45);
    return Scaffold(
      appBar: AppBar(title: const Text('Privacidade')),
      body: FormWidth(
        child: ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Ind.page, 16, Ind.page, 0),
              child: Text(
                'O ${AppInfo.name} não coleta, não envia e não compartilha dados. Não tem conta, anúncio nem rastreamento. O que você cria fica no seu celular.',
                style: body.copyWith(fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ),
            for (final (title, paragraphs) in sections) ...[
              SectionHeader(title),
              for (final p in paragraphs)
                Padding(
                  padding: EdgeInsets.fromLTRB(p.startsWith('• ') ? Ind.page + 8 : Ind.page, 0, Ind.page, 10),
                  child: Text(p, style: body),
                ),
            ],
            Padding(
              padding: const EdgeInsets.fromLTRB(Ind.page, 18, Ind.page, 0),
              child: SelectableText(
                'Política completa e contato: ${AppInfo.privacyUrl}',
                style: TextStyle(color: Ind.textMuted, fontSize: 13, height: 1.4),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
