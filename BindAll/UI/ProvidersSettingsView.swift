import SwiftUI

struct ProvidersSettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedKind: ProviderKind = .deepseek
    @State private var apiKeyDraft: String = ""
    @State private var testStatus: String = ""
    @State private var testOK: Bool?
    @State private var isTesting = false
    @State private var models: [String] = []

    private var cloudKinds: [ProviderKind] {
        ProviderKind.allCases.filter { $0 != .apple }
    }

    private var configBinding: Binding<ProviderConfig> {
        Binding(
            get: { appState.settings.provider(selectedKind) },
            set: { appState.updateProvider($0) }
        )
    }

    var body: some View {
        Form {
            Section {
                Picker("Provider", selection: $selectedKind) {
                    ForEach(cloudKinds) { Text($0.displayName).tag($0) }
                }
                .onChange(of: selectedKind) { _, _ in loadForSelection() }
            }

            Section("Connection") {
                if selectedKind.requiresAPIKey {
                    LabeledContent("API key") {
                        SecureField("", text: $apiKeyDraft)
                            .labelsHidden()
                            .textFieldStyle(.plain)
                            .darkField()
                    }
                    Button("Save key") {
                        appState.setAPIKey(apiKeyDraft, for: selectedKind)
                    }
                }
                LabeledContent("Base URL") {
                    TextField("", text: Binding(
                        get: { configBinding.wrappedValue.baseURLOverride ?? "" },
                        set: { var c = configBinding.wrappedValue; c.baseURLOverride = $0.isEmpty ? nil : $0; configBinding.wrappedValue = c }
                    ), prompt: Text(selectedKind.defaultBaseURL ?? ""))
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .darkField()
                }

                LabeledContent("Model") {
                    HStack {
                        TextField("", text: Binding(
                            get: { configBinding.wrappedValue.model },
                            set: { var c = configBinding.wrappedValue; c.model = $0; configBinding.wrappedValue = c }
                        ))
                        .labelsHidden()
                        .textFieldStyle(.plain)
                        .darkField()
                        Button("Fetch") { fetchModels() }
                    }
                }
                if selectedKind == .openrouter {
                    Toggle("Free models only", isOn: $appState.settings.openRouterFreeOnly)
                        .onChange(of: appState.settings.openRouterFreeOnly) { _, _ in
                            if !models.isEmpty { fetchModels() }
                        }
                }
                if !models.isEmpty {
                    Picker("Available", selection: Binding(
                        get: { configBinding.wrappedValue.model },
                        set: { var c = configBinding.wrappedValue; c.model = $0; configBinding.wrappedValue = c }
                    )) {
                        ForEach(models, id: \.self) { Text($0).tag($0) }
                    }
                }
            }

            Section {
                HStack {
                    Button(isTesting ? "Testing…" : "Test connection") { testConnection() }
                        .disabled(isTesting)
                    if let testOK {
                        Image(systemName: testOK ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(testOK ? .green : .red)
                    }
                }
                if !testStatus.isEmpty {
                    Text(testStatus).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .clearFocusOnAppear()
        .onAppear { loadForSelection() }
    }

    private func loadForSelection() {
        apiKeyDraft = appState.apiKey(for: selectedKind)
        models = []
        testStatus = ""
        testOK = nil
    }

    private func testConnection() {
        if selectedKind.requiresAPIKey {
            appState.setAPIKey(apiKeyDraft, for: selectedKind)
        }
        isTesting = true
        testStatus = ""
        testOK = nil
        let engine = EngineFactory.make(kind: selectedKind, appState: appState)
        Task {
            do {
                let status = try await engine.testConnection()
                testOK = true
                testStatus = status
            } catch {
                testOK = false
                testStatus = error.localizedDescription
            }
            isTesting = false
        }
    }

    private func fetchModels() {
        if selectedKind.requiresAPIKey {
            appState.setAPIKey(apiKeyDraft, for: selectedKind)
        }
        let config = appState.settings.provider(selectedKind)
        let engine = OpenAICompatibleEngine(
            baseURL: config.effectiveBaseURL,
            apiKey: appState.apiKey(for: selectedKind),
            model: config.model,
            requiresAPIKey: selectedKind.requiresAPIKey
        )
        let freeOnly = selectedKind == .openrouter && appState.settings.openRouterFreeOnly
        Task {
            do { models = try await engine.listModels(freeOnly: freeOnly) }
            catch { testStatus = error.localizedDescription; testOK = false }
        }
    }
}
