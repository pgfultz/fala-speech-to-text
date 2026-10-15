import SwiftUI

struct SettingsView: View {
    @Bindable var settings = AppSettings.shared
    @State private var account = AccountModel()
    @State private var appleModel = AppleModelModel()
    @State private var permissions = PermissionModel()
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    var reopenOnboarding: () -> Void

    var body: some View {
        Form {
            Section {
                Picker("Motor", selection: $settings.engine) {
                    ForEach(Engine.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Group {
                    if settings.engine == .chatgpt {
                        AccountRow(account: account)
                    } else {
                        AppleModelRow(model: appleModel, language: settings.language)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Transcrição")
            } footer: {
                Text(settings.engine.subtitle).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Atalho") { ShortcutRecorder() }
                Picker("Modo", selection: $settings.mode) {
                    ForEach(TriggerMode.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Atalho")
            } footer: {
                Text(settings.mode.detail + " Pressione esc para cancelar. Para usar fn 🌐, defina em Ajustes › Teclado “Pressionar 🌐 para: Não fazer nada”.")
                    .foregroundStyle(.secondary)
            }

            Section("Idioma") {
                Picker("Idioma falado", selection: $settings.language) {
                    ForEach(LanguageOption.all) { Text($0.name).tag($0.code) }
                }
            }

            Section("Aparência e comportamento") {
                Picker("Indicador", selection: $settings.pillStyle) {
                    ForEach(PillStyle.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Sons sutis", isOn: $settings.sounds)
                Toggle("Restaurar área de transferência após colar", isOn: $settings.restoreClipboard)
                Toggle("Abrir ao iniciar sessão", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in LaunchAtLogin.set(on) }
            }

            Section("Permissões") {
                PermissionRows(permissions: permissions).padding(.vertical, 4)
            }

            if !settings.history.isEmpty {
                Section {
                    ForEach(settings.history.prefix(8)) { item in
                        HStack {
                            Text(item.text).lineLimit(2).font(.callout)
                            Spacer()
                            Button {
                                Paster.copy(item.text)
                            } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless)
                            .help("Copiar")
                        }
                    }
                } header: {
                    HStack {
                        Text("Recentes")
                        Spacer()
                        Button("Limpar") { settings.history.removeAll() }.buttonStyle(.borderless).font(.caption)
                    }
                }
            }

            Section {
                HStack {
                    Button("Refazer configuração inicial", action: reopenOnboarding).buttonStyle(PillButtonStyle(prominent: false))
                    Spacer()
                    Text("Fala 1.0").font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .frame(minHeight: 700)
        .onAppear { account.refresh() }
    }
}
