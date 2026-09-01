import SwiftUI

/// The LanguageTool connection block (mode, URL, credentials, test), hosted on the
/// Proofread tab: LanguageTool serves only that feature, so its connection lives with it, the way
/// every other feature keeps its options on its own tab.
struct LanguageToolConnectionSection: View {
    @EnvironmentObject var appState: AppState

    // URL, username and token are edited via drafts: a TextField bound straight to the published
    // settings commits its text while SwiftUI switches tabs, publishing from within a view update.
    @State private var tokenDraft: String = ""
    @State private var urlDraft: String = ""
    @State private var usernameDraft: String = ""
    @State private var status: String = ""
    @State private var ok: Bool?
    @State private var testing = false
    @State private var modeDraft: LanguageToolMode = .free
    @State private var testTask: Task<Void, Never>?
    /// A token stored while typing still needs one engine rebuild.
    @State private var tokenPendingReconfigure = false

    var body: some View {
        Section {
            // Driven by a draft: a segmented picker bound straight to the published settings commits
            // its selection from within the view update ("Publishing changes from within view
            // updates"). The draft also keeps the segment and the credential rows in sync instantly.
            Picker("Account type", selection: $modeDraft) {
                ForEach(LanguageToolMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            .onChange(of: modeDraft) { _, mode in
                // A stale test verdict is misleading once the mode changed.
                resetTest()
                DispatchQueue.main.async { appState.settings.languageToolMode = mode }
                // Pre-fill the URL for the chosen mode; the field stays editable. The draft's own
                // onChange forwards it into settings on the next runloop tick.
                guard let url = mode.defaultURL else { return }
                urlDraft = url
            }

            LabeledContent("Server URL") {
                TextField("", text: $urlDraft,
                          prompt: Text("https://api.languagetool.org/v2"))
                    .labelsHidden().textFieldStyle(.plain).darkField()
                    .onChange(of: urlDraft) { _, url in
                        // Deferred: onChange fires inside the view update.
                        DispatchQueue.main.async { appState.settings.languageToolBaseURL = url }
                    }
            }
            // Credentials belong to Premium only: the public server rejects them, and a self-hosted
            // server is reached by URL.
            if modeDraft == .premium {
                LabeledContent("Username / email") {
                    TextField("", text: $usernameDraft)
                        .labelsHidden().textFieldStyle(.plain).darkField()
                        .onChange(of: usernameDraft) { _, name in
                            DispatchQueue.main.async { appState.settings.languageToolUsername = name }
                        }
                }
                LabeledContent("API token") {
                    // Saved as it is typed, like every other control here: neither onSubmit nor
                    // onDisappear fires when the window is simply closed, and a token typed and left
                    // behind used to be discarded silently. The engine is rebuilt once, on submit or
                    // when the tab goes away, rather than on every keystroke.
                    SecureField("", text: $tokenDraft)
                        .labelsHidden().textFieldStyle(.plain).darkField()
                        .onChange(of: tokenDraft) { _, _ in storeToken() }
                        .onSubmit { commitToken() }
                }
            }

            HStack {
                Button(testing ? "Testing…" : "Test connection") { test() }
                    .disabled(testing)
                if let ok {
                    Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(ok ? .green : .red)
                }
            }
            if !status.isEmpty {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            helpHeader("LanguageTool server", "How BindAll reaches LanguageTool.\n\nFree public: api.languagetool.org, no account, rate-limited, and your text is sent to languagetool.org. Credentials are never sent (the public server rejects them).\n\nPremium: api.languagetoolplus.com (a different host) with the username and token from your LanguageTool Premium account.\n\nSelf-hosted: your own server URL, no credentials.\n\nThe URL is pre-filled per mode but stays editable.")
        }
        .onAppear { load() }
        .onDisappear {
            commitToken()
            // A verdict must not survive a tab switch, and an in-flight test must not surface later.
            testTask?.cancel()
            testTask = nil
            testing = false
            resetTest()
        }
    }

    /// Keeps the Keychain in step with the field without rebuilding the engine on every keystroke.
    private func storeToken() {
        guard tokenDraft != appState.languageToolToken() else { return }
        appState.setLanguageToolToken(tokenDraft, reconfigure: false)
        tokenPendingReconfigure = true
    }

    /// The field is done with: make sure it is stored, then rebuild the engine once.
    private func commitToken() {
        storeToken()
        guard tokenPendingReconfigure else { return }
        tokenPendingReconfigure = false
        appState.setLanguageToolToken(tokenDraft)
    }

    private func load() {
        modeDraft = appState.settings.languageToolMode
        tokenDraft = appState.languageToolToken()
        urlDraft = appState.settings.languageToolBaseURL
        usernameDraft = appState.settings.languageToolUsername
        resetTest()
    }

    private func resetTest() {
        status = ""
        ok = nil
    }

    private func test() {
        commitToken()
        testing = true
        resetTest()
        let engine = EngineFactory.makeLanguageTool(appState: appState)
        testTask = Task {
            do {
                let result = try await engine.testConnection()
                guard !Task.isCancelled else { return }
                status = result
                ok = true
            } catch {
                guard !Task.isCancelled else { return }
                status = error.localizedDescription
                ok = false
            }
            testing = false
        }
    }
}
