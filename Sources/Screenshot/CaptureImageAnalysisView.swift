import AppKit
import KirkTranslation
import SwiftUI

@MainActor private final class CaptureImageAnalysisState: ObservableObject {
    struct Request: Identifiable {
        let id = UUID()
        let question: String
        let provider: AITranslationProvider
        let model: String
        let api: CloudTranslation?
    }

    @Published var question = ""
    @Published var request: Request?
    @Published var answer = ""
    @Published var draft = ""
    @Published var error = ""
}

struct CaptureImageAnalysisView: View {
    let image: CGImage
    @ObservedObject var model: CaptureTextModel
    @StateObject private var state = CaptureImageAnalysisState()
    @AppStorage("capture.translation.ai.provider") private var provider = CaptureTranslationSettings.initialProvider
    @AppStorage("capture.translation.chatgpt.model") private var chatModel = ""

    private var api: CloudTranslation? {
        try? CloudTranslation(baseURL: CaptureTranslationSettings.baseURL, model: CaptureTranslationSettings.model)
    }

    private var destination: String? {
        switch provider {
        case .chatGPT: return CaptureTranslationSettings.chatGPT.isSignedIn ? "ChatGPT" : nil
        case .apiKey: return api?.endpoint.host
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.configuringAI {
                AITranslationSetup(provider: $provider, chatModel: $chatModel, forImageAnalysis: true) {
                    model.setConfiguringAI(false)
                }
            } else {
                Image(decorative: image, scale: 1)
                    .resizable().scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 115)
                    .accessibilityLabel(localized("capture_image.preview"))
                Text(destination.map { String(format: localized("capture_image.disclosure"), $0) }
                     ?? localized("capture_image.configure"))
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField(localized("capture_image.question"), text: $state.question)
                        .textFieldStyle(.roundedBorder)
                        .disabled(state.request != nil)
                    if state.request == nil {
                        Button(destination == nil ? localized("capture_image.settings") : localized("capture_image.send")) {
                            state.error = ""
                            if destination == nil {
                                model.setConfiguringAI(true)
                            } else if state.question.count > ImageAnalysis.maximumQuestionLength {
                                state.error = localized("capture_image.question_limit")
                            } else {
                                state.draft = ""
                                state.request = .init(question: state.question, provider: provider, model: chatModel, api: api)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        Button {
                            model.setConfiguringAI(true)
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel(localized("capture_image.settings"))
                        .help(localized("capture_image.settings"))
                    } else {
                        Button(localized("capture_image.cancel")) {
                            state.request = nil
                            state.draft = ""
                        }
                    }
                }
                HStack {
                    Text(localized("capture_image.result")).font(.headline)
                    if state.request != nil { ProgressView().controlSize(.small) }
                    Spacer()
                    Button(localized("capture_text.copy")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(state.answer, forType: .string)
                    }
                    .disabled(state.answer.isEmpty || state.request != nil)
                }
                if !state.error.isEmpty {
                    Text(state.error).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                ScrollView {
                    Text(state.draft.isEmpty ? state.answer : state.draft)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(9)
                }
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: state.request?.id) {
            if let request = state.request { await analyze(request) }
        }
    }

    private func analyze(_ request: CaptureImageAnalysisState.Request) async {
        let timing = CaptureTiming(source: "image.analysis")
        do {
            guard image.width <= 4096, image.height <= 4096 else { throw CloudTranslation.Failure.inputTooLong }
            let png = try await Task.detached(priority: .userInitiated) { try image.png() }.value
            try Task.checkCancellation()
            let analysis = try ImageAnalysis(png: png, question: request.question,
                                             language: Locale.current.identifier)
            timing.mark("image.encoded")
            let headers: (Int) -> Void = { timing.mark("http.status", value: Double($0)) }
            let answer: String
            switch request.provider {
            case .chatGPT:
                answer = try await CaptureTranslationSettings.chatGPT.analyze(
                    analysis, model: request.model, onHeaders: headers
                ) { text in
                    if state.request?.id == request.id { state.draft = text }
                }
            case .apiKey:
                guard let api = request.api, let key = CaptureTranslationSettings.apiKey(for: api.endpoint) else {
                    throw CloudTranslation.Failure.invalidConfiguration
                }
                answer = try await api.analyze(analysis, apiKey: key, onHeaders: headers)
            }
            try Task.checkCancellation()
            timing.finish("success")
            guard state.request?.id == request.id else { return }
            state.answer = answer
        } catch {
            AITranslationSetup.recordFailure(error, timing: timing)
            guard !Task.isCancelled, state.request?.id == request.id else { return }
            if let error = error as? CloudTranslation.Failure, case .inputTooLong = error {
                state.error = localized("capture_image.too_large")
            } else {
                state.error = AITranslationSetup.message(for: error)
                    + (request.provider == .apiKey ? " " + localized("capture_image.vision_model") : "")
            }
        }
        guard state.request?.id == request.id else { return }
        state.draft = ""
        state.request = nil
    }
}
