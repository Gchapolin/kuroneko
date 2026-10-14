# Project: Kuroneko

## Overview

App de menu bar 100% local que grava sozinho as chamadas do Google Meet (Chrome), transcreve durante a call em lotes de ~2 minutos (o texto chega uns 2 minutos atrás da conversa; não é tempo real), separa e reconhece as vozes, e guarda notas pessoais na linha do tempo. No fim da call, as vozes são separadas de novo na gravação inteira: a prioridade é precisão no que foi dito e em quem disse. Nome em homenagem ao gato do João.

## Tech Stack

- **Language**: Swift 6 (SPM puro, sem .xcodeproj — bundle montado pelo Makefile)
- **UI**: SwiftUI (MenuBarExtra, menu-bar-only app)
- **Database**: SQLite via GRDB 7 + FTS5
- **Audio**: Core Audio Process Taps (Chrome) + AVAudioEngine (mic), canais separados e alinhados no mesmo zero
- **ML local**: WhisperKit (pacote `argmax-oss-swift`) large-v3-turbo para ASR; FluidAudio `OfflineDiarizerManager` (pyannote community-1) para diarização e Silero VAD para detecção de fala — inferência 100% local, modelos em `~/Library/Application Support/Kuroneko/models`
- **Testing**: Swift Testing (`swift test`)
- **Hotkeys**: KeyboardShortcuts (sindresorhus), nota rápida em ⌃⌥⌘N; toque duplo no ⌘ reconhecido pelo `DoubleTapDetector` (o app do Claude usa ⌥ duplo)

## Architecture

```
Sources/
├── KuronekoCore/        # lógica sem UI, testável
│   ├── Capture/         # tap do Chrome, mic, detecção da call (abas + saída de áudio), prints (`ScreenCapture`)
│   ├── Processing/      # pipeline (em lotes durante a call + fechamento): diarização, VAD, eco, idioma, ASR, vozes conhecidas
│   ├── Review/          # timeline, agrupamento por semana, busca, pendências/decisões do resumo, rótulos de links
│   ├── API/             # contrato JSON (MeetingExport), transcrição em Markdown, parser do `kuroneko`, resumo com o Claude
│   ├── Support/         # FileLog, toque duplo no ⌘ (`DoubleTapDetector`)
│   └── Store/           # AppDatabase (GRDB), Models, migrations, FTS5
├── KuronekoCLI/         # executável `kuroneko` (vai em Contents/Helpers do app): JSON para editores, scripts e Claude
├── Kuroneko/            # executável: MenuBarExtra, janela de reuniões, nota rápida, ajustes
Support/Info.plist       # LSUIElement + usage descriptions (TCC)
Makefile                 # build | test | bundle | run | clean
```

Pipeline (`MeetingProcessor`): sistema → diarização + VAD (VAD recupera falas curtas que o diarizador perde) → mic → VAD menos eco (`EchoGate`, usa system.wav como referência) → idioma por enunciado entre pt/es/en → turnos de mesma voz e mesmo idioma → Whisper por turno com vocabulário no prompt → `HallucinationFilter` → vozes casadas com voiceprints.

Durante a call (`advanceLive`, agendado pelo `ProcessingQueue` a cada 2 s): quando há `liveBatchSeconds` (120 s) de áudio novo, o lote é lido do WAV ainda sendo gravado (`AudioSamples.load(_:from:to:)`), cortado na última pausa dos dois canais (`LiveCut`) e passa pelo mesmo pipeline; cada lote é diarizado sozinho e as vozes são seguidas entre lotes por embedding (`LiveVoices`, limiar 0.65). Os trechos vão para o banco a cada lote (`appendTranscript`: voz já nomeada mantém a pessoa). No fim (`process` com histórico ao vivo): último lote + diarização da gravação inteira, cujos rótulos herdam os índices da call (`VoiceRelabel`) — nomes dados durante a call ficam. Sem histórico (app reiniciou, lote falhou, call < 2 min) `process` transcreve tudo de uma vez, como antes. O processador só atende uma chamada por vez; quem serializa é o `ProcessingQueue` (call atual em lotes, reunião que acabou de terminar logo em seguida, o resto só sem call em andamento).

Regra de dependência: `Kuroneko` (UI) depende de `KuronekoCore`; o core nunca importa SwiftUI/AppKit. Lógica nova vai no core com testes; a UI é casca fina.

Integrações (Neovim em `gandarfh/kuroneko.nvim`, IDEs, web local) falam só com o comando `kuroneko`, nunca com o SQLite: o JSON de `MeetingExport`/`MeetingListItem` é o contrato — só se adicionam campos, nunca renomear ou remover. O comando avisa o app por `ExternalChange` (notificação distribuída) e o app recarrega. Comandos: `meetings`, `meeting`, `transcript`, `search`, `people`, `name`, `note add|rm`, `summarize`, `doc set|rm`, `link add|rm`, `tasks`, `task done|undo <ref>`, `play` (`kuroneko help`).

Resumos: `Summarizer` roda `claude -p` (`ClaudeCLI`; texto da reunião sai do Mac só nesse momento, áudio nunca) e guarda em `meetingDocument` tipo `summary` (tipo livre, um por tipo). O app resume sozinho quando uma reunião termina de transcrever (ajuste `autoSummarize`, ligado por padrão; só se tem fala e ainda não tem resumo), um por vez fora da fila de transcrição, e marca `meeting.newsAt` — as "novidades" do menu, limpas ao abrir a reunião. Aberto pelo Finder o app tem PATH mínimo: o `claude` é procurado em `KURONEKO_CLAUDE`, no PATH, no PATH do shell de login (sem e depois com `-i`) e em pastas conhecidas; timeout de 5 min.

Pendências: o resumo em Markdown é a fonte da verdade (o usuário edita no Neovim). `SummaryItems` lê as seções "Pendências"/"Decisões" com tolerância (com ou sem `##`, `- [ ]`, `- [x]`, `- `, `* `, `1.`; dono depois de " — "; primeiro `[mm:ss]`) e marcar como feita reescreve só o checkbox daquela linha. Notas `#acao` também são pendências (feita = `note.resolvedAt`). Referência estável: `summary:<reunião>:<linha>:<impressão do texto>` (acha a linha mesmo se ela mudou de lugar) ou `note:<id>`.

Notas com prints: tabela `attachment` (nota, tipo livre, caminho relativo à pasta da reunião, em `meetings/<id>/attachments/`); `addNote(…, attachments:)` move a captura para lá, e a nota pode ficar sem texto. Links por reunião em `meetingLink`, com rótulo curto quando não têm título (`LinkLabel`: "PR #482", "ABC-123", host/último trecho). `AppDatabase` conhece o `MeetingStorage` para resolver esses caminhos e apagar os arquivos junto com as linhas.

Telas (`Sources/Kuroneko`): janela de reuniões com abas Reuniões | Pendências (`MeetingsView`, `MeetingCard`, `TasksView`; cartões por dia via `DayGrouping`, gravações sem fala escondidas); tela da reunião (`MeetingDetailView` + `MeetingHeaderView`, `MeetingOverviewView` com resumo/pendências/decisões/notas sempre abertos, `MeetingTranscriptView` que acompanha o áudio, `MeetingBottomBar` com player ±15 s/velocidade e nota no ponto que está tocando; espaço, ←/→, ⌘N, ⌘F); nota rápida (`QuickNote`: ⌘⌘ por `CommandDoubleTap`, um event tap só de escuta — precisa de "Monitoramento de Entrada" e olha só quando há teclas, nunca quais; ⌃⌥⌘N continua sem permissão; ⌘1 janela do app da frente, ⌘2 tela sob o mouse, ⌘3 área, rascunho em `NoteDraft`; prints precisam de "Gravação de Tela"). Menu do gato com "Novidades" e ponto no ícone (`MenuBarIcon`); `Navigator` leva o menu a uma reunião ou às pendências.

## Coding Conventions

- camelCase para variáveis/funções, PascalCase para tipos
- Colunas SQLite em camelCase espelhando as propriedades dos records (convenção GRDB)
- Strings de UI em português (com acentos); identificadores e código em inglês
- Erros: nunca engolir silenciosamente — logar via os.Logger e refletir em `AppState.lastError`
- Nenhuma janela do Kuroneko aparece em compartilhamento/gravação de tela (`CaptureShield`, ligado por padrão): janelas que o app mostra por conta própria chamam `CaptureShield.protect` antes de aparecer; o resto é coberto pela varredura

## Testing Rules

- All new code MUST have tests (unit tests no `KuronekoCoreTests`)
- Framework: Swift Testing (`@Test` / `#expect`)
- Banco em testes: `AppDatabase.inMemory()`
- Run `swift test` before considering a task complete

## Git Conventions

- Commits in English, format: `type(scope): description`
- Types: feat, fix, refactor, test, docs, chore
- Never commit secrets or the local database

## Build

- `make test` — roda os testes
- `make run` — monta `dist/Kuroneko.app` (Info.plist + bundles de recursos do SwiftPM + codesign com o certificado "Apple Development") e abre
- O process tap de áudio exige rodar via bundle assinado, não via `swift run`
- Assinatura ad-hoc faz o macOS esquecer as permissões (mic, áudio do sistema, Automação) a cada build — manter o certificado estável
- Teste com os modelos reais (opcional, ~2 GB): `KURONEKO_E2E_AUDIO=/caminho/system.wav [KURONEKO_E2E_MIC=/caminho/mic.wav] swift test --filter EndToEnd` — inclui a mesma gravação reproduzida como se estivesse sendo gravada (lotes durante a call + fechamento)
- Benchmark de diarização e reconhecimento de vozes em reuniões reais do corpus AMI: `KURONEKO_AMI=/pasta swift test --filter DiarizationBenchmark` (instruções no teste; baseline 98%/98%; em lotes de 2 min como durante a call: 92%/95%, mesma pessoa entre lotes 0.80–0.98, pessoas diferentes ≤ 0.48)
- Vozes sintéticas do `say` não servem para testar diarização: o modelo funde vozes do macOS que soam parecidas
- CI: `.github/workflows/ci.yml` roda `swift test` em todo push (runner `macos-26`)
- Release: `git tag vX.Y.Z && git push origin vX.Y.Z` → `release.yml` monta o app assinado ad hoc e publica `Kuroneko-X.Y.Z.zip`, `SHA256SUMS` e `install.sh` no GitHub Release (`workflow_dispatch` = dry run sem publicar)
- Instalar/atualizar: `curl -fsSL https://github.com/gandarfh/kuroneko/releases/latest/download/install.sh | sh` — confere o checksum, re-assina com o "Apple Development" local (mesmo designated requirement do `make run`, então as permissões do TCC sobrevivem às atualizações), recusa atualizar durante uma gravação e instala em `/Applications`

## Current Focus

Captura automática do Meet, pipeline de transcrição, revisão (janela de reuniões, nomear vozes, ouvir trechos), nota rápida e busca prontos (out/2026). Ao fim de cada transcrição com vozes sem nome aparece um cartão flutuante (`VoicePrompt`) com as pessoas conhecidas da voz mais parecida para a menos (`VoiceReview`); some sozinho em 10s sem interação e fica no menu do gato ("Dizer quem falou…"). `SpeakerMatcher.threshold` (0.55) validado no AMI: mesma pessoa 0.92–0.97, pessoas diferentes ≤ 0.32. `EchoGate` validado numa call real com caixa de som (eco correlaciona 0.88–0.97, a voz do usuário ≤ 0.34); o atraso mic↔sistema muda no meio da call (deriva e pula ~150 ms), por isso é medido em volta de cada fala. Pendentes: calls muito curtas (1–2 min) podem juntar vozes (há o `@Nome` como fallback), resumo semanal (decidir LLM local ou não), huddle do Slack.

## Known Issues

- WhisperKit não implementa `noSpeechProb` (sempre 0) e `detectLangauge` só devolve o idioma vencedor: a proteção contra alucinação é VAD + `HallucinationFilter`, e as pontuações de pt/es/en vêm de um `TokenSampling` próprio (`LanguageScoreSampler`)
- Espanhol com sotaque brasileiro é detectado como pt (pt 0.77 / es 0.15): enunciados com idioma duvidoso são transcritos isolados para o Whisper não "traduzir" o trecho
- Meet: URL e título da aba continuam iguais depois de sair da call; o fim da call é detectado pela saída de áudio do Chrome
- Deleção de reunião apaga filhos explicitamente (não confia no FK cascade) para os triggers de sincronização do FTS5 dispararem — manter esse padrão em novas tabelas indexadas. Apagar reunião ou nota também apaga os arquivos (pasta da reunião, anexos) depois das linhas.

## Do NOT

- Do not create documentation files unless asked
- Do not add dependencies without confirming first
- Do not change architecture without prior discussion
- Do not ignore failing tests
- Do not over-engineer — solve the current problem, not hypothetical ones
- Nunca usar chords `Alt+dígito` em hotkeys (colide com Aerospace)
- Nunca commitar mudança visual/interativa sem aprovação manual do João
