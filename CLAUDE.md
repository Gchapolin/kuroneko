# Project: Kuroneko

## Overview

App de menu bar 100% local para gravar reuniões do Google Meet (Chrome), transcrever ao vivo (pt-BR + espanhol), diarizar falantes e guardar notas/screenshots vinculados à timeline. Nome em homenagem ao gato do João.

## Tech Stack

- **Language**: Swift 6 (SPM puro, sem .xcodeproj — bundle montado pelo Makefile)
- **UI**: SwiftUI (MenuBarExtra, menu-bar-only app)
- **Database**: SQLite via GRDB 7 + FTS5
- **Audio**: Core Audio Process Taps (Chrome) + AVAudioEngine (mic), canais separados
- **ML local**: WhisperKit large-v3-turbo (ASR), FluidAudio (diarização) — inferência 100% local
- **Testing**: Swift Testing (`swift test`)
- **Hotkeys**: KeyboardShortcuts (sindresorhus)

## Architecture

```
Sources/
├── KuronekoCore/        # lógica sem UI, testável
│   └── Store/           # AppDatabase (GRDB), Models, migrations, FTS5
├── Kuroneko/            # executável: MenuBarExtra, AppState (@Observable)
Support/Info.plist       # LSUIElement + usage descriptions (TCC)
Makefile                 # build | test | bundle | run | clean
```

Regra de dependência: `Kuroneko` (UI) depende de `KuronekoCore`; o core nunca importa SwiftUI/AppKit. Lógica nova vai no core com testes; a UI é casca fina.

## Coding Conventions

- camelCase para variáveis/funções, PascalCase para tipos
- Colunas SQLite em camelCase espelhando as propriedades dos records (convenção GRDB)
- Strings de UI em português (com acentos); identificadores e código em inglês
- Erros: nunca engolir silenciosamente — logar via os.Logger e refletir em `AppState.lastError`

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
- `make run` — monta `dist/Kuroneko.app` (Info.plist + codesign ad-hoc) e abre
- O process tap de áudio exige rodar via bundle assinado, não via `swift run`

## Current Focus

Fase 1 (esqueleto + storage) concluída em desenvolvimento. Próximas fases: captura de áudio (mic + tap Chrome), transcrição ao vivo, notas/screenshots, diarização, consulta. Plano completo: `~/.claude/plans/golden-doodling-frost.md`.

## Known Issues

- Deleção de reunião apaga filhos explicitamente (não confia no FK cascade) para os triggers de sincronização do FTS5 dispararem — manter esse padrão em novas tabelas indexadas.

## Do NOT

- Do not create documentation files unless asked
- Do not add dependencies without confirming first
- Do not change architecture without prior discussion
- Do not ignore failing tests
- Do not over-engineer — solve the current problem, not hypothetical ones
- Nunca usar chords `Alt+dígito` em hotkeys (colide com Aerospace)
- Nunca commitar mudança visual/interativa sem aprovação manual do João
