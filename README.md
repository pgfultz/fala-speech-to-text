# Fala

Ditado por voz para o macOS, leve e nativo. Segure um atalho, fale e solte: o texto aparece no app que estiver em foco.

- **Motor ChatGPT**: usa a sua assinatura do ChatGPT pelo login do Codex (`~/.codex/auth.json`). Sem chave de API, consome a cota do plano. Chama o mesmo endpoint de transcrição que o ditado do Codex/ChatGPT usa.
- **Motor Apple on-device**: `SpeechAnalyzer` / `SpeechTranscriber` do macOS 26. Offline, privado, com texto parcial ao vivo.
- Indicador em formato de ilha saindo do notch (ou pílula de Liquid Glass em telas sem notch), com forma de onda animada pela sua voz.
- Atalho configurável a qualquer momento: tecla única (F5), combinação (⌃⌥Espaço) ou modificador sozinho com lado (⌥ direito, ⌘ direito, fn).
- Modos: **Inteligente** (segure para falar; um toque rápido trava), **Segurar** ou **Alternar**. `esc` cancela.
- Restaura sua área de transferência depois de colar. Histórico recente no menu.

Binário de ~1,5 MB, sem dependências.

## Requisitos

- macOS 26 (Tahoe) ou mais recente, Apple Silicon
- Xcode 26 (para compilar)
- Motor ChatGPT: [Codex CLI](https://github.com/openai/codex) com login feito com ChatGPT (`codex login`). O onboarding faz isso para você.

## Instalar

```sh
./scripts/build.sh --install   # compila, copia para /Applications e abre
```

Na primeira vez, o onboarding pede o login (se necessário), as permissões de Microfone e Acessibilidade, e o atalho.

> Builds com assinatura ad-hoc mudam de identidade a cada recompilação, e o macOS pode pedir a permissão de Acessibilidade de novo. Para evitar isso, defina `FALA_SIGN_IDENTITY` com uma identidade de assinatura de código sua.

## Testar pela linha de comando

```sh
say -o /tmp/t.wav --data-format=LEI16@16000 "Olá, isto é um teste"
/Applications/Fala.app/Contents/MacOS/Fala --transcribe /tmp/t.wav pt          # ChatGPT
/Applications/Fala.app/Contents/MacOS/Fala --transcribe /tmp/t.wav --apple pt  # Apple
/Applications/Fala.app/Contents/MacOS/Fala --demo --partial                    # anima o indicador sem microfone
```

## Como funciona

| Arquivo | Papel |
| --- | --- |
| `Hotkey.swift` | Atalho global via `CGEventTap` (teclas, combinações, modificadores sozinhos com lado) |
| `Audio.swift` | `AVAudioEngine`: níveis para a animação + PCM 16 kHz para envio |
| `ChatGPT.swift` | Lê/renova o token OAuth do Codex e envia para `chatgpt.com/backend-api/transcribe` |
| `AppleSpeech.swift` | Streaming para o `SpeechAnalyzer` on-device |
| `Controller.swift` | Máquina de estados: ouvindo → transcrevendo → pronto |
| `Overlay.swift` | Ilha do notch / pílula de vidro e forma de onda |
| `Onboarding.swift`, `SettingsView.swift` | Configuração inicial e Ajustes |
| `System.swift` | Colar no app ativo, permissões, `codex login`, abrir ao iniciar sessão |

Quando o token expira, o Fala o renova e grava de volta em `~/.codex/auth.json`, então o Codex continua usando a mesma sessão.

O endpoint de transcrição do ChatGPT não é uma API pública documentada. Ele pode mudar sem aviso; o motor Apple funciona como alternativa.
