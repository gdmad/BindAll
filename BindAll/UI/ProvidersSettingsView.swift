import SwiftUI

struct ProvidersSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var selectedKind: ProviderKind = .deepseek
    @State private var apiKeyDraft = ""
    // Edited as drafts and written back deferred (see `deferredWrite`): text fields commit inside
    // the view update when the tab switches.
    @State private var baseURLDraft = ""
    @State private var modelDraft = ""
    @State private var testStatus = ""
    @State private var testOK: Bool?
    @State private var isTesting = false
    @State private var models: [String] = []
    @State private var testTask: Task<Void, Never>?

    private var cloudKinds: [ProviderKind] {
        ProviderKind.allCases.filter { $0 != .apple }
    }

    var body: some View {
        @Bindable var appState = appState
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
                HelpHeader("Engine", "Used for the default action and custom prompts. Translation always runs on-device via Apple's Translation framework, and proofreading always uses LanguageTool.")
            }

            Section {
                Picker("Provider", selection: $selectedKind) {
                    ForEach(cloudKinds) { kind in
                        Text(kind == appState.settings.defaultEngine ? "\(kind.displayName) — active" : kind.displayName)
                            .tag(kind)
                    }
                }
                // The draft is already saved keystroke by keystroke, so switching providers only has
                // to reload -- saving here would write the old provider's key under the new one.
                .onChange(of: selectedKind) { _, _ in loadForSelection() }
            } header: {
                HelpHeader("Provider", "Credentials and model for each cloud provider. Configuring one does not select it -- that is the Engine picker above.")
            }

            Section("Connection") {
                if selectedKind.requiresAPIKey {
                    LabeledContent("API key") {
                        // Saved as it is typed. Every other control here saves itself, and neither
                        // onSubmit nor onDisappear fires when the window is simply closed -- a key
                        // typed and left behind used to be discarded silently.
                        SecureField("API key", text: $apiKeyDraft)
                            .labelsHidden()
                            .textFieldStyle(.plain)
                            .darkField()
                            .onChange(of: apiKeyDraft) { _, _ in saveKey(for: selectedKind) }
                    }
                }
                LabeledContent("Base URL") {
                    TextField("Base URL", text: $baseURLDraft, prompt: Text(selectedKind.defaultBaseURL ?? ""))
                        .labelsHidden()
                        .textFieldStyle(.plain)
                        .darkField()
                        .onChange(of: baseURLDraft) { _, url in storeBaseURL(url) }
                }

                LabeledContent("Model") {
                    HStack {
                        TextField("Model", text: $modelDraft)
                            .labelsHidden()
                            .textFieldStyle(.plain)
                            .darkField()
                        Button("Fetch", action: fetchModels)
                    }
                }
                .onChange(of: modelDraft) { _, model in storeModel(model) }
                if selectedKind == .openrouter {
                    Toggle("Free models only", isOn: $appState.settings.openRouterFreeOnly)
                        .onChange(of: appState.settings.openRouterFreeOnly) { _, _ in
                            if !models.isEmpty { fetchModels() }
                        }
                }
                if !models.isEmpty {
                    Picker("Available", selection: $modelDraft) {
                        ForEach(models, id: \.self) { Text($0).tag($0) }
                    }
                }
            }

            Section {
                HStack {
                    Button(isTesting ? "Testing…" : "Test connection", action: testConnection)
                        .disabled(isTesting)
                    if let testOK {
                        Image(systemName: testOK ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(testOK ? .green : .red)
                            .accessibilityLabel(testOK ? "Connected" : "Failed")
                    }
                }
                if !testStatus.isEmpty {
                    Text(testStatus).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .clearFocusOnAppear()
        .onAppear(perform: loadForSelection)
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
        guard kind.requiresAPIKey else { return }
        // A key pasted from a browser or password manager often carries a trailing newline or space,
        // which is invisible in the field but turns into a silently-rejected Authorization header.
        let trimmed = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != appState.apiKey(for: kind) else { return }
        appState.setAPIKey(trimmed, for: kind)
    }

    private func storeBaseURL(_ url: String) {
        let kind = selectedKind
        Task { @MainActor in
            var config = appState.settings.provider(kind)
            let override = url.isEmpty ? nil : url
            guard config.baseURLOverride != override else { return }
            config.baseURLOverride = override
            appState.updateProvider(config)
        }
    }

    private func storeModel(_ model: String) {
        let kind = selectedKind
        Task { @MainActor in
            var config = appState.settings.provider(kind)
            guard config.model != model else { return }
            config.model = model
            appState.updateProvider(config)
        }
    }

    private func loadForSelection() {
        let config = appState.settings.provider(selectedKind)
        apiKeyDraft = appState.apiKey(for: selectedKind)
        baseURLDraft = config.baseURLOverride ?? ""
        modelDraft = config.model
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
            requiresAPIKey: selectedKind.requiresAPIKey,
            providerName: selectedKind.displayName
        )
        let freeOnly = selectedKind == .openrouter && appState.settings.openRouterFreeOnly
        Task {
            do { models = try await engine.listModels(freeOnly: freeOnly) }
            catch { testStatus = error.localizedDescription; testOK = false }
        }
    }
}
