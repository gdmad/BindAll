import SwiftUI

struct ProvidersSettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedKind: ProviderKind = .deepseek
    @State private var apiKeyDraft: String = ""
    @State private var testStatus: String = ""
    @State private var testOK: Bool?
    @State private var isTesting = false
    @State private var models: [String] = []

    @State private var testTask: Task<Void, Never>?

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
            // The engine that actually runs, and below it the credentials for each provider: the
            // two used to live on different tabs, which read as if they were unrelated.
            Section {
                Picker("Engine for text actions", selection: $appState.settings.defaultEngine) {
                    ForEach(ProviderKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
            } header: {
                helpHeader("Engine", "Used for the default action and custom prompts. Translation always runs on-device via Apple's Translation framework, and proofreading always uses LanguageTool.")
            }

            Section {
                Picker("Provider", selection: $selectedKind) {
                    ForEach(cloudKinds) { Text($0.displayName).tag($0) }
                }
                // The draft is already saved keystroke by keystroke, so switching providers only has
                // to reload -- saving here would write the old provider's key under the new one.
                .onChange(of: selectedKind) { _, _ in loadForSelection() }
            } header: {
                helpHeader("Provider", "Credentials and model for each cloud provider. Configuring one does not select it -- that is the Engine picker above.")
            }

            Section("Connection") {
                if selectedKind.requiresAPIKey {
                    LabeledContent("API key") {
                        // Saved as it is typed. Every other control here saves itself, and neither
                        // onSubmit nor onDisappear fires when the window is simply closed -- a key
                        // typed and left behind used to be discarded silently.
                        SecureField("", text: $apiKeyDraft)
                            .labelsHidden()
                            .textFieldStyle(.plain)
                            .darkField()
                            .onChange(of: apiKeyDraft) { _, _ in saveKey(for: selectedKind) }
                    }
                }
                LabeledContent("Base URL") {
                    TextField("", text: deferredWrite(Binding(
                        get: { configBinding.wrappedValue.baseURLOverride ?? "" },
                        set: { var c = configBinding.wrappedValue; c.baseURLOverride = $0.isEmpty ? nil : $0; configBinding.wrappedValue = c }
                    )), prompt: Text(selectedKind.defaultBaseURL ?? ""))
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .darkField()
                }

                LabeledContent("Model") {
                    HStack {
                        TextField("", text: deferredWrite(Binding(
                            get: { configBinding.wrappedValue.model },
                            set: { var c = configBinding.wrappedValue; c.model = $0; configBinding.wrappedValue = c }
                        )))
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
        .onDisappear {
            saveKey(for: selectedKind)
            // A verdict must not survive a tab switch, and an in-flight test must not surface later.
            testTask?.cancel()
            testTask = nil
            isTesting = false
            testStatus = ""
            testOK = nil
        }
    }

    private func saveKey(for kind: ProviderKind) {
        guard kind.requiresAPIKey, apiKeyDraft != appState.apiKey(for: kind) else { return }
        appState.setAPIKey(apiKeyDraft, for: kind)
    }

    private func loadForSelection() {
        apiKeyDraft = appState.apiKey(for: selectedKind)
        models = []
        testStatus = ""
        testOK = nil
    }

    private func testConnection() {
        saveKey(for: selectedKind)
        isTesting = true
        testStatus = ""
        testOK = nil
        let engine = EngineFactory.make(kind: selectedKind, appState: appState)
        testTask = Task {
            do {
                let status = try await engine.testConnection()
                guard !Task.isCancelled else { return }
                testOK = true
                testStatus = status
            } catch {
                guard !Task.isCancelled else { return }
                testOK = false
                testStatus = error.localizedDescription
            }
            isTesting = false
        }
    }

    private func fetchModels() {
        saveKey(for: selectedKind)
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
