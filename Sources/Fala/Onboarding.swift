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
        ZStack {
            Backdrop()
            VStack(spacing: 0) {
                ZStack {
                    page(step)
                        .id(step)
                        .transition(.asymmetric(
                            insertion: .offset(x: forward ? 40 : -40).combined(with: .opacity).combined(with: .scale(scale: 0.98)),
                            removal: .offset(x: forward ? -40 : 40).combined(with: .opacity)))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                footer
            }
            .padding(.horizontal, 44)
            .padding(.top, 40)
            .padding(.bottom, 28)
        }
        .frame(width: 620, height: 600)
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
        VStack(spacing: 22) {
            Spacer()
            AppGlyph(size: 112)
            VStack(spacing: 10) {
                Text("Fala").font(.system(size: 44, weight: .bold, design: .rounded))
                Text("Sua voz vira texto em qualquer app.\nSegure um atalho, fale e solte. Pronto.")
                    .font(.system(size: 16))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var engine: some View {
        VStack(spacing: 26) {
            Header(title: "Como transcrever?", subtitle: "Você pode trocar a qualquer momento pelo menu.")
            HStack(spacing: 16) {
                ForEach(Engine.allCases) { e in
                    EngineCard(engine: e, selected: settings.engine == e) {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { settings.engine = e }
                    }
                }
            }
            Spacer()
        }
    }

    private var setup: some View {
        VStack(spacing: 26) {
            if settings.engine == .chatgpt {
                Header(title: "Conecte sua conta", subtitle: "Usa sua assinatura do ChatGPT através do login do Codex.\nNada de chave de API — conta na sua cota do plano.")
                Card { AccountRow(account: account) }
            } else {
                Header(title: "Modelo da Apple", subtitle: "O reconhecimento roda inteiro no seu Mac.\nO macOS baixa o modelo do idioma uma única vez.")
                Card {
                    VStack(spacing: 16) {
                        Picker("Idioma", selection: $settings.language) {
                            ForEach(LanguageOption.all.dropFirst()) { Text($0.name).tag($0.code) }
                        }
                        AppleModelRow(model: appleModel, language: settings.language)
                    }
                }
                .onAppear { if settings.language == "auto" { settings.language = "pt" } }
            }
            Spacer()
        }
    }

    private var permissionsPage: some View {
        VStack(spacing: 26) {
            Header(title: "Duas permissões", subtitle: "O áudio só é capturado enquanto o atalho estiver ativo.")
            Card { PermissionRows(permissions: permissions) }
            Spacer()
        }
    }

    private var shortcut: some View {
        VStack(spacing: 26) {
            Header(title: "Seu atalho", subtitle: "Clique e pressione uma tecla, uma combinação\nou um modificador sozinho, como ⌥ direito ou fn.")
            ShortcutRecorder(large: true)
            Picker("Modo", selection: $settings.mode) {
                ForEach(TriggerMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 320)
            Text(settings.mode.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(height: 40, alignment: .top)
            Spacer()
        }
    }

    private var tryIt: some View {
        VStack(spacing: 22) {
            Header(title: "Experimente", subtitle: "Clique na caixa, segure o atalho e diga algo.")
            HStack(spacing: 6) {
                ForEach(Array(settings.shortcut.parts.enumerated()), id: \.offset) { _, p in KeyCap(text: p, large: true) }
            }
            TextEditor(text: $tryText)
                .font(.system(size: 15))
                .scrollContentBackground(.hidden)
                .scrollIndicators(.never)
                .padding(14)
                .frame(height: 150)
                .glassEffect(.regular, in: .rect(cornerRadius: 18))
            if !permissions.accessibility {
                Label("Sem a permissão de Acessibilidade o atalho não funciona.", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
            }
            Spacer()
        }
        .onAppear { permissions.poll() }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Button("Voltar") { go(-1) }
                .buttonStyle(.glass)
                .opacity(step == 0 ? 0 : 1)
                .disabled(step == 0)

            Spacer()
            HStack(spacing: 7) {
                ForEach(0..<steps, id: \.self) { i in
                    Capsule()
                        .fill(i == step ? Color.primary : Color.primary.opacity(0.2))
                        .frame(width: i == step ? 18 : 7, height: 7)
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.75), value: step)
            Spacer()

            Button(nextTitle) {
                if step == steps - 1 {
                    settings.onboarded = true
                    finish()
                } else {
                    go(1)
                }
            }
            .buttonStyle(.glassProminent)
            .keyboardShortcut(.defaultAction)
        }
        .controlSize(.large)
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
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
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
            Text(title).font(.system(size: 28, weight: .bold, design: .rounded))
            Text(subtitle)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 8)
    }
}

private struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(20)
            .frame(maxWidth: .infinity)
            .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }
}

private struct EngineCard: View {
    let engine: Engine
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: engine.symbol)
                        .font(.system(size: 22, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .background(.tint.opacity(0.15), in: .rect(cornerRadius: 12, style: .continuous))
                        .foregroundStyle(.tint)
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20))
                        .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                        .contentTransition(.symbolEffect(.replace))
                }
                Text(engine.title).font(.system(size: 17, weight: .semibold))
                Text(engine.subtitle)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    ForEach(tags, id: \.self) { t in
                        Text(t).font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(.primary.opacity(0.07), in: .capsule)
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 230, maxHeight: 230, alignment: .topLeading)
            .contentShape(.rect(cornerRadius: 22))
            .glassEffect(selected ? .regular.tint(.accentColor.opacity(0.16)).interactive() : .regular.interactive(), in: .rect(cornerRadius: 22))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor.opacity(0.8) : .clear, lineWidth: 2)
            }
            .scaleEffect(selected ? 1 : 0.98)
        }
        .buttonStyle(.plain)
    }

    private var tags: [String] {
        engine == .chatgpt ? ["Precisão máxima", "Multilíngue"] : ["Offline", "Privado", "Ao vivo"]
    }
}

/// Soft, slowly drifting color field behind the glass.
private struct Backdrop: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
            let t = Float(ctx.date.timeIntervalSinceReferenceDate)
            MeshGradient(width: 3, height: 3, points: [
                [0, 0], [0.5, 0], [1, 0],
                [0, 0.5], [0.5 + 0.12 * sin(t * 0.4), 0.5 + 0.1 * cos(t * 0.33)], [1, 0.5],
                [0, 1], [0.5, 1], [1, 1],
            ], colors: [
                Color(red: 0.36, green: 0.33, blue: 0.95), Color(red: 0.55, green: 0.38, blue: 0.98), Color(red: 0.93, green: 0.42, blue: 0.78),
                Color(red: 0.25, green: 0.5, blue: 0.98), Color(red: 0.62, green: 0.45, blue: 0.95), Color(red: 0.98, green: 0.55, blue: 0.6),
                Color(red: 0.2, green: 0.62, blue: 0.95), Color(red: 0.45, green: 0.55, blue: 0.98), Color(red: 0.95, green: 0.65, blue: 0.55),
            ])
            .opacity(0.75)
            .overlay(.background.opacity(0.4))
        }
        .ignoresSafeArea()
    }
}
