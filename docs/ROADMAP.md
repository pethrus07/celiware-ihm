# Ware IoT · roadmap

Fila curta, em ordem. Atualizado em 01/11/2026.
O diário até esta data (etapa 4, reuniões, versões, site, Play) é interno e fica fora do repositório.
O que existe e como funciona: [ARQUITETURA.md](ARQUITETURA.md).

## Estado em 01/11/2026

- **Na loja:** 1.4.0 (versão 12), aprovada na Play em 21/10/2026, Brasil.
- **Pronta, não enviada:** 1.5.0 (13), no `main` desde 21/10. Traz planta com vários projetos,
  barra de cinco áreas, aviso de versão nova pela Play, equipamento HTTP, projetos prontos,
  imagem de fundo da tela e grade extra-fina. Depois do pacote final entrou um commit
  (`5f9cbf5`, 22/10: telas do Tex G4 em "Começar de"); o próximo `.aab` precisa ser gerado
  de novo para levar esse commit.
- **Site:** https://wareiot.com.br no ar desde 14/10; os textos da navegação nova esperam a 1.5.0.

## Agora

1. **Enviar a 1.5.0 ao teste interno** (Pedro): gerar o `.aab` de novo a partir do `main`,
   subir no teste interno, o cliente testa pela Play, depois promover para produção
   (roteiro interno de publicação). Antes: refazer as capturas da loja (a barra e a primeira tela
   mudaram) e conferir a ficha de Segurança dos dados com a biblioteca de atualização.
2. **Publicar o site junto com a 1.5.0** (Pedro), não antes: `tutoriais.html` e
   `privacidade.html` já descrevem a navegação nova.
3. **Teste em equipamento real** (depende das peças do cliente): nada passou de simulador.
   Ordem sugerida: Modbus TCP na cortadora de rótulos do cliente, mapa Inovance H3U, cabo
   USB-OTG, Siemens S7, OPC UA, MQTT com broker, HTTP com ESP32, câmera IP, voz no fone e a
   prova da 1.3.2 (Wi-Fi sem internet com 4G ligado).
4. **Decisões abertas da 1.5.0** (Pedro): o app abre dentro do último projeto e não na lista;
   regras antigas ficam no projeto migrado; aviso na tela quando a planta não abre (modo de
   socorro); depois de cancelar a atualização imediata, 24 h sem nenhuma oferta.

## Depois

- **Faixa de status completa na tela em operação:** estado da máquina, equipamento e hora da
  última leitura (o espaço da faixa já é reservado desde 12/10).
- **Comando em três fases visíveis** (enviando, confirmado, falhou com motivo) em todo comando.
- **Alarmes:** alarme com o app fechado (serviço em primeiro plano; a Play pede declaração com
  vídeo), adiar um alarme com motivo e prazo, exportar o histórico em CSV.
- **Tex G4:** endereços Modbus, códigos de estado e unidades, quando vier o manual Modbus do
  equipamento.
- **Site, lote 3:** foto, ficha e preço do hardware, WhatsApp de suporte, "Qual peça eu
  preciso?", diagramas de ligação com foto, foto de bancada. Tudo depende de material do
  cliente.
- **Pequenos do QA:** "desde 20:07" num alarme que já voltou deveria ser "disparou 20:07";
  ~14 quadros/s com a máquina parada.
- **HTTP:** Digest, redirecionamento, certificado próprio com teste automatizado.

## Talvez

- Sinótico da planta: uma tela que junta máquinas de vários projetos.
- Várias plantas no mesmo aparelho; mover projeto entre plantas sem arquivo.
- Versão Windows do app (adiada em 11/10/2026; `windows/` existe, `.exe` nunca gerado).
- Monetização dentro do app (estudo de 19/10 no diário interno; não é intenção agora).
- Texto gravável pela tela; backup e comparação de parâmetros de inversor; CANopen.
- Módulos locais de gestão da lista do cliente (turnos, metas, paradas, manutenção), cada um
  é um módulo próprio.

## Fora de propósito

- Tudo que é externo ao app: login, contas, servidor, nuvem, licenças, biometria, idiomas
  (regra de corte de 11/10/2026).
- Script (JS) na variável: não tem conta inversa e quebra a escrita.
- O app nunca é função de segurança da máquina (NR-12).
