import AppKit
import KirkTranslation
import SwiftUI

enum AITranslationProvider: String {
    case chatGPT, apiKey
}

@MainActor private final class AITranslationSetupState: ObservableObject {
    enum Action: Equatable { case signIn, switchAccount, signOut, loadModels }

    @Published var baseURL = CaptureTranslationSettings.baseURL
    @Published var model = CaptureTranslationSettings.model
    @Published var key = ""
    @Published var error = ""
    @Published var action: Action?
    @Published var models: [ChatGPTPlan.Model] = []
}

struct AITranslationSetup: View {
    @Binding var provider: AITranslationProvider
    @Binding var chatModel: String
    var forImageAnalysis = false
    let close: () -> Void
    @StateObject private var state = AITranslationSetupState()

    private var plan: ChatGPTPlan { CaptureTranslationSettings.chatGPT }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(localized(forImageAnalysis ? "capture_image.settings" : "capture_text.ai_settings"), systemImage: "sparkles").font(.headline)
                Spacer()
                Button(localized("capture_text.ai_back_to_capture"), action: close)
                    .disabled(state.action == .signIn || state.action == .switchAccount || state.action == .signOut)
            }
            Picker(localized("capture_text.ai_service"), selection: $provider) {
                Text("ChatGPT Plus / Pro").tag(AITranslationProvider.chatGPT)
                Text(localized("capture_text.ai_byok")).tag(AITranslationProvider.apiKey)
            }
            .pickerStyle(.segmented)
            .disabled(state.action != nil && state.action != .loadModels)
            .onChange(of: provider) { _, _ in
                if state.action == .loadModels { state.action = nil }
                state.key = ""
                state.error = ""
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if provider == .chatGPT { chatSettings } else { keySettings }
                    if !state.error.isEmpty {
                        Text(state.error).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task(id: state.action) {
            guard let action = state.action else { return }
            state.error = ""
            do {
                switch action {
                case .signIn, .switchAccount:
                    do {
                        try await plan.signIn(newAccount: action == .switchAccount) { NSWorkspace.shared.open($0) }
                    } catch ChatGPTPlan.Failure.revocationFailed {
                        state.error = Self.message(for: ChatGPTPlan.Failure.revocationFailed)
                    }
                    if action == .switchAccount {
                        chatModel = ""
                        state.models = []
                    }
                case .loadModels:
                    let available = try await loadAvailableModels()
                    try Task.checkCancellation()
                    state.models = available
                    if chatModel == ChatGPTPlan.defaultTranslationModel ||
                        (!chatModel.isEmpty && !available.contains(where: { $0.slug == chatModel })) {
                        chatModel = ""
                    }
                    if available.isEmpty { state.error = localized("capture_text.ai_no_models") }
                case .signOut:
                    try await plan.signOut()
                    chatModel = ""
                    state.models = []
                }
            } catch {
                if !Task.isCancelled { state.error = Self.message(for: error) }
            }
            if !Task.isCancelled { state.action = nil }
        }
    }

    private func loadAvailableModels() async throws -> [ChatGPTPlan.Model] {
        let timing = CaptureTiming(source: "translation.chatgpt.models")
        do {
            let models = try await plan.models { event in
                switch event {
                case .sessionReady: timing.mark("session.ready")
                case .httpStatus(let status): timing.httpStatus(status)
                case .bodyBytes: break
                case .bodyShape(let shape):
                    switch shape {
                    case .chatGPTCatalog: timing.mark("http.body.chatgpt_catalog")
                    case .standardCatalog: timing.mark("http.body.standard_catalog")
                    case .errorObject: timing.mark("http.body.error_object")
                    case .otherJSON: timing.mark("http.body.other_json")
                    case .nonJSON: timing.mark("http.body.non_json")
                    }
                }
            }
            if models.isEmpty {
                timing.finish("empty_catalog", error: "empty_catalog", level: .warning)
            } else {
                timing.finish("success")
            }
            return models
        } catch {
            Self.recordFailure(error, timing: timing)
            throw error
        }
    }

    private var chatSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(localized(forImageAnalysis ? "capture_image.chatgpt_help" : "capture_text.ai_chatgpt_help")).foregroundStyle(.secondary)
            if let action = state.action {
                ProgressView(localized(action == .signIn || action == .switchAccount
                                       ? "capture_text.ai_browser"
                                       : (action == .loadModels ? "capture_text.ai_loading_models" : "capture_text.ai_account_wait")))
                    .controlSize(.small)
                if action == .signIn || action == .switchAccount {
                    Button(localized("capture_text.ai_cancel_login")) { state.action = nil }
                } else if action == .loadModels {
                    Button(localized("capture_text.ai_cancel_model_load")) { state.action = nil }
                }
            } else if plan.isSignedIn {
                if let email = plan.email { Text(email).textSelection(.enabled) }
                if !state.models.isEmpty {
                    Picker(localized("capture_text.cloud_model"), selection: $chatModel) {
                        Text(localized("capture_text.ai_luna_low")).tag("")
                        ForEach(state.models.filter { $0.slug != ChatGPTPlan.defaultTranslationModel }) {
                            Text($0.displayName).tag($0.slug)
                        }
                    }
                    .fixedSize()
                } else {
                    LabeledContent(localized("capture_text.cloud_model"),
                                   value: chatModel.isEmpty || chatModel == ChatGPTPlan.defaultTranslationModel
                                       ? localized("capture_text.ai_luna_low") : chatModel)
                }
                HStack {
                    if !chatModel.isEmpty {
                        Button(localized("capture_text.ai_use_luna")) { chatModel = "" }
                    }
                    Button(localized("capture_text.ai_refresh_models")) { state.action = .loadModels }
                }
                HStack {
                    Button(localized("capture_text.ai_reconnect")) { state.action = .signIn }
                    Button(localized("capture_text.ai_switch")) { state.action = .switchAccount }
                    Button(localized("capture_text.ai_signout")) { state.action = .signOut }
                    Link(localized("capture_text.ai_manage"), destination: URL(string: "https://chatgpt.com/settings/usage")!)
                }
            } else {
                if plan.needsKeychainAccess {
                    Text(localized("capture_text.ai_keychain_unavailable")).foregroundStyle(.secondary)
                    Button(localized("capture_text.ai_restore_authorization")) {
                        state.error = ""
                        do {
                            try plan.restoreAuthorization()
                            state.models = []
                        } catch {
                            state.error = Self.message(for: error)
                        }
                    }
                }
                HStack {
                    Button(localized("capture_text.ai_signin")) { state.action = .signIn }
                        .buttonStyle(.borderedProminent)
                    if plan.email != nil {
                        Button(localized("capture_text.ai_switch")) { state.action = .switchAccount }
                    }
                }
            }
        }
    }

    private var keySettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(localized(forImageAnalysis ? "capture_image.vision_model" : "capture_text.cloud_disclosure")).foregroundStyle(.secondary)
            TextField(localized("capture_text.cloud_url"), text: $state.baseURL)
            TextField(localized("capture_text.cloud_model"), text: $state.model)
            SecureField(localized("capture_text.cloud_key"), text: $state.key)
            Button(localized("capture_text.cloud_save")) {
                do {
                    try CaptureTranslationSettings.save(baseURL: state.baseURL, model: state.model, apiKey: state.key)
                    state.key = ""
                    close()
                } catch {
                    state.error = localized("capture_text.cloud_settings_error")
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .textFieldStyle(.roundedBorder)
    }

    /// 诊断仅记录固定错误分类和数值，避免持久化网络错误的原始正文或 URL。
    static func recordFailure(_ error: Error, timing: CaptureTiming) {
        if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
            timing.finish("cancelled")
            return
        }
        let code: StaticString
        switch error {
        case let http as ChatGPTPlan.HTTPFailure:
            timing.httpStatus(http.status)
            code = diagnosticCode(for: http.reason)
        case let failure as ChatGPTPlan.Failure:
            code = diagnosticCode(for: failure)
        case let failure as CloudTranslation.Failure:
            switch failure {
            case .denied(let status):
                timing.httpStatus(status)
                code = "http_denied"
            case .invalidResponse: code = "invalid_response"
            case .invalidConfiguration: code = "invalid_configuration"
            case .inputTooLong: code = "input_too_long"
            }
        case let network as URLError:
            code = network.code == .timedOut ? "network_timeout" : "network_error"
        default:
            code = "unexpected_error"
        }
        timing.finish("failed", error: code)
    }

    private static func diagnosticCode(for failure: ChatGPTPlan.Failure) -> StaticString {
        switch failure {
        case .invalidAuthorization: return "invalid_authorization"
        case .signInTimedOut: return "sign_in_timeout"
        case .signInRequired: return "sign_in_required"
        case .accessDenied: return "access_denied"
        case .busy: return "busy"
        case .usageLimit: return "usage_limit"
        case .unavailable: return "unavailable"
        case .invalidResponse: return "invalid_response"
        case .revocationFailed: return "revocation_failed"
        case .noModels: return "no_models"
        case .keychainUnavailable: return "keychain_unavailable"
        case .invalidModelCatalog: return "invalid_model_catalog"
        case .sessionStorageUnavailable: return "session_storage_unavailable"
        }
    }

    static func message(for error: Error) -> String {
        if (error as? URLError)?.code == .timedOut { return localized("capture_text.ai_timeout") }
        let http = error as? ChatGPTPlan.HTTPFailure
        guard let failure = http?.reason ?? error as? ChatGPTPlan.Failure else { return error.localizedDescription }
        let suffix: String
        switch failure {
        case .invalidAuthorization: suffix = "login_failed"
        case .signInTimedOut: suffix = "login_timeout"
        case .signInRequired: suffix = "reconnect_needed"
        case .accessDenied: suffix = "ineligible"
        case .usageLimit: suffix = "usage_limit"
        case .noModels: suffix = "no_models"
        case .keychainUnavailable: suffix = "keychain_unavailable"
        case .invalidModelCatalog: suffix = "invalid_model_catalog"
        case .sessionStorageUnavailable: suffix = "session_storage_unavailable"
        case .busy: suffix = "account_wait"
        case .revocationFailed: suffix = "revocation_failed"
        case .unavailable, .invalidResponse: suffix = "service_error"
        }
        let message = localized("capture_text.ai_" + suffix)
        return http.map { message + " (HTTP \($0.status))" } ?? message
    }
}
