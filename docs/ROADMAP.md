# Roadmap — Celiware IHM

O que já está entregue, o que falta e o que ficou de fora de propósito.
A documentação técnica do que existe está em `ARQUITETURA.md`; este arquivo é
só a lista de trabalho.

## Versão estável atual: 1.3.0

Tag `v1.3.0`. É a versão para apresentar e instalar
(`celiware-ihm-1.3.0-arm64.apk`, celulares Android de 2017 para cá).

| Versão | O que trouxe |
|---|---|
| 1.0 | Modbus TCP próprio, variáveis intermediárias, 11 elementos, editor em grade, demonstração embutida, tutoriais, simulador Python. |
| 1.1 | Escala (fator + soma), texto ASCII, botão com retorno, "Ir para tela", imagem por etapa e PDF em páginas (os 7 áudios do cliente). |
| 1.1.1 | Correções do QA ponta a ponta: tablet/paisagem, bateria (quadros parados), acessibilidade, busca de variável, APK de 19 MB. |
| 1.2.0 | Sistema visual novo pela pesquisa de UI/UX: tema Claro/Escuro/Auto, interação verde-água, lâmpada alto desempenho, elementos redesenhados. |
| 1.3.0 | Alarmes ISA-18.2: prioridade por cor + forma + número, faixa no topo, marca no elemento, lista, histórico, editor na variável, falta de comunicação como alarme. |

## Próximo — visual e operação

Na ordem em que convém fazer. Cada item é uma versão pequena, testada no
emulador antes de seguir.

1. **Faixa de status na tela em operação.** Uma linha fixa no topo com o
   estado da máquina (rodando / parada / sem comunicação), o equipamento e
   a hora da última leitura. Hoje essa informação está espalhada.
2. **Miniatura real das telas.** A lista de telas mostra um desenho genérico;
   passar a mostrar a tela em miniatura, para reconhecer de relance.
3. **Tablet com barra lateral e duas colunas.** Foi a pior nota do QA (4).
   Barra de navegação lateral (NavigationRail) e lista + detalhe lado a lado
   em Equipamentos, Variáveis e Alarmes.
4. **Comando em 3 fases visíveis.** Tocar → "enviando" → confirmado pelo
   equipamento (ou falhou, com o motivo). O botão com retorno já faz parte
   disso; falta estender a todo comando e deixar as três fases à vista.

## Alarmes — o que falta

- **Alarme com o app fechado.** Hoje o alarme só vale com o app aberto.
  Exige serviço em primeiro plano do Android com notificação permanente
  (e mais bateria). Decidir com o cliente se o uso de campo pede isso.
- **Adiar (shelve)** um alarme com motivo e prazo, para manutenção planejada.
- **Exportar o histórico** de alarmes (CSV) junto com o projeto.

## Publicação — etapa 3 (Play Store)

Roteiro completo em `PUBLICACAO.md`.

- Conta de desenvolvedor **de organização** em nome da Celiware (pede D-U-N-S).
- Chave de upload (credencial permanente — criar e guardar no cofre).
- Ficha da loja: textos, capturas, ícone, política de privacidade.
- Teste fechado com o cliente antes de abrir ao público.

## Campo e fabricantes

- **Teste de campo** na cortadora de rótulos do cliente (mapa Modbus já
  preparado no CLP). É o que valida a 1.x de verdade.
- **Perfil Inovance:** tradução do nome da memória do manual para endereço
  Modbus (ARQUITETURA §10.2), validada no equipamento real.
- **Levantamento de recursos** no editor de IHM da Inovance e no WinCC da
  Siemens: o que ainda falta de "básico de IHM", para não descobrir as faltas
  uma a uma.

## Ideias registradas (sem data)

- Variável calculada / script — só se aparecer caso que a escala linear não cobre.
- Texto gravável pela tela.
- Backup e comparação de parâmetros de inversor.
- Conversores RS-485 e CANopen; perfil Siemens.
- Licenciamento.
- Identidade da Celiware no app (ficou de fora de propósito na 1.2).

## Ficou de fora de propósito

- **Script (JS) na variável:** recusado na 1.1 — não tem conta inversa, então
  quebra a escrita.
- **Vídeo "como fazer":** o Pedro decidiu não fazer (27/09/2026).
