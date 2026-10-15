import SwiftUI

struct OnboardingView: View {
    @Bindable var settings = AppSettings.shared
    @State private var step = CommandLine.arguments.firstIndex(of: "--step").flatMap { Int(CommandLine.arguments[$0 + 1]) } ?? 0
    @State private var forward = true
    @State private var account = AccountModel()
    @State private var appleModel = AppleModelModel()
    @State private var permissions = PermissionModel()
    @State private var tryText = ""
    var finish: () -> Void

    private let steps = 6

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                page(step)
                    .id(step)
                    .transition(.asymmetric(
                        insertion: .offset(x: forward ? 24 : -24).combined(with: .opacity),
                        removal: .offset(x: forward ? -24 : 24).combined(with: .opacity)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            footer
        }
        .padding(.horizontal, 48)
        .padding(.top, 52)
        .padding(.bottom, 28)
        .frame(width: 600, height: 560)
        .background(.background)
        .onAppear { account.refresh() }
    }

    // MARK: Pages

    @ViewBuilder
    private func page(_ i: Int) -> some View {
        switch i {
        case 0: welcome
        case 1: engine
        case 2: setup
        case 3: permissionsPage
        case 4: shortcut
        default: tryIt
        }
    }

    private var welcome: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 40)
            AppMark(size: 96)
            Text("Fala")
                .font(.system(size: 34, weight: .semibold))
                .tracking(-0.6)
                .padding(.top, 26)
            Text("Dite em qualquer app.\nSegure um atalho, fale e solte.")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.top, 10)
            Spacer()
        }
    }

    private var engine: some View {
        VStack(spacing: 28) {
            Header(title: "Motor de transcrição", subtitle: "Você pode trocar depois pelo menu da barra.")
            VStack(spacing: 10) {
                ForEach(Engine.allCases) { e in
                    EngineRow(engine: e, selected: settings.engine == e) {
                        withAnimation(.spring(response: 0.3, dampingFraction: 1)) { settings.engine = e }
                    }
                }
            }
        }
    }

    private var setup: some View {
        VStack(spacing: 28) {
            if settings.engine == .chatgpt {
                Header(title: "Conta ChatGPT", subtitle: "O Fala usa o login do Codex. Sem chave de API —\na transcrição conta na cota da sua assinatura.")
                Surface { AccountRow(account: account) }
            } else {
                Header(title: "Modelo on-device", subtitle: "A transcrição roda inteira no seu Mac.\nO macOS baixa o modelo do idioma uma única vez.")
                Surface {
                    VStack(spacing: 14) {
                        HStack {
                            Text("Idioma").font(.system(size: 13))
                            Spacer()
                            Picker("Idioma", selection: $settings.language) {
                                ForEach(LanguageOption.all.dropFirst()) { Text($0.name).tag($0.code) }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                        Divider()
                        AppleModelRow(model: appleModel, language: settings.language)
                    }
                }
                .onAppear { if settings.language == "auto" { settings.language = "pt" } }
            }
        }
    }

    private var permissionsPage: some View {
        VStack(spacing: 28) {
            Header(title: "Permissões", subtitle: "O microfone só é usado enquanto o atalho está ativo.")
            Surface { PermissionRows(permissions: permissions) }
        }
    }

    private var shortcut: some View {
        VStack(spacing: 28) {
            Header(title: "Atalho", subtitle: "Clique e pressione uma tecla, uma combinação,\nou um modificador sozinho, como ⌥ direito ou fn.")
            ShortcutRecorder(large: true)
            VStack(spacing: 12) {
                Picker("Modo", selection: $settings.mode) {
                    ForEach(TriggerMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 300)
                Text(settings.mode.detail)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(width: 380, height: 36, alignment: .top)
            }
        }
    }

    private var tryIt: some View {
        VStack(spacing: 24) {
            Header(title: "Experimente", subtitle: "Clique no campo abaixo, segure o atalho e fale.")
            HStack(spacing: 5) {
                ForEach(Array(settings.shortcut.parts.enumerated()), id: \.offset) { _, p in KeyCap(text: p, large: true) }
            }
            TextEditor(text: $tryText)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .scrollIndicators(.never)
                .padding(12)
                .frame(height: 130)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator))
            if !permissions.accessibility {
                Label("O atalho precisa da permissão de Acessibilidade.", systemImage: "exclamationmark.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { permissions.poll() }
    }

    // MARK: Footer

    private var footer: some View {
        ZStack {
            HStack(spacing: 6) {
                ForEach(0..<steps, id: \.self) { i in
                    Circle()
                        .fill(i == step ? Color.primary : Color.primary.opacity(0.18))
                        .frame(width: 6, height: 6)
                }
            }
            .animation(.easeOut(duration: 0.2), value: step)

            HStack {
                if step > 0 {
                    Button("Voltar") { go(-1) }
                        .buttonStyle(PillButtonStyle(prominent: false))
                        .transition(.opacity)
                }
                Spacer()
                Button(nextTitle) {
                    if step == steps - 1 {
                        settings.onboarded = true
                        finish()
                    } else {
                        go(1)
                    }
                }
                .buttonStyle(PillButtonStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var nextTitle: String {
        switch step {
        case 0: "Começar"
        case 2 where settings.engine == .chatgpt && !account.connected: "Pular"
        case steps - 1: "Concluir"
        default: "Continuar"
        }
    }

    private func go(_ delta: Int) {
        forward = delta > 0
        withAnimation(.spring(response: 0.35, dampingFraction: 1)) {
            step = min(max(step + delta, 0), steps - 1)
        }
    }
}

// MARK: - Pieces

private struct Header: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.system(size: 24, weight: .semibold))
                .tracking(-0.4)
            Text(subtitle)
                .font(.system(size: 13.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
        }
    }
}

private struct Surface<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity)
            .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator.opacity(0.6)))
    }
}

private struct EngineRow: View {
    let engine: Engine
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: engine.symbol)
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 36, height: 36)
                    .background(.primary.opacity(0.06), in: .rect(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(engine.title).font(.system(size: 14, weight: .semibold))
                        Text(engine == .chatgpt ? "Recomendado" : "Offline")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.primary.opacity(0.06), in: .capsule)
                    }
                    Text(engine.subtitle)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(16)
            .contentShape(.rect(cornerRadius: 14))
            .background(.quaternary.opacity(selected ? 0.7 : 0.35), in: .rect(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(selected ? AnyShapeStyle(.primary.opacity(0.85)) : AnyShapeStyle(.separator.opacity(0.6)), lineWidth: selected ? 1.5 : 1)
            }
        }
        .buttonStyle(.plain)
    }
}
