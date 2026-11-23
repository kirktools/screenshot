import AppKit
import KirkTranslation
import KirkTranslationUI
import SwiftUI
import Vision

enum CaptureTextRecognition {
    static func recognize(_ image: CGImage) throws -> String {
        try Task.checkCancellation()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
        // Vision 的文本观察结果包含分行信息，保留原来的换行，方便复制报错等内容。
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}

final class CaptureTextPanel: NSPanel {
    let model: CaptureTextModel

    init(contentRect: CGRect, image: CGImage, model: CaptureTextModel, analyzingImage: Bool = false) {
        self.model = model
        super.init(contentRect: contentRect, styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        let hosting: NSHostingController<AnyView>
        if analyzingImage {
            hosting = NSHostingController(rootView: AnyView(CaptureImageAnalysisView(image: image, model: model)))
        } else {
            hosting = NSHostingController(rootView: AnyView(CaptureTextView(image: image, model: model)))
        }
        // 加载中的内容只有一行，不能用它的理想尺寸调整整个浮窗。
        hosting.sizingOptions = []
        let container = NSViewController()
        container.view = NSView(frame: CGRect(origin: .zero, size: contentRect.size))
        container.addChild(hosting)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        container.view.addSubview(hosting.view)
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: container.view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: container.view.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: container.view.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: container.view.bottomAnchor)
        ])
        contentViewController = container
        acceptsMouseMovedEvents = true
        contentMinSize = NSSize(width: min(480, contentRect.width), height: min(240, contentRect.height))
        setFrame(frameRect(forContentRect: contentRect), display: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { performClose(sender) }
}

@MainActor final class CaptureTextModel: ObservableObject {
    enum Engine {
        case system
        case apiKey
        case chatGPT
    }

    struct TranslationInput: Identifiable {
        let id = UUID()
        let target: String
        let engine: Engine
        let systemTiming: CaptureTiming?

        init(target: String, engine: Engine) {
            self.target = target
            self.engine = engine
            systemTiming = engine == .system ? CaptureTiming(source: "translation.system") : nil
        }
    }

    @Published var source: String?
    @Published var recognitionFailed = false
    @Published var sentencePairs: TranslationSentencePairs?
    @Published var translated = ""
    @Published var partialTranslation = ""
    @Published var resultEngine: Engine?
    @Published var status = ""
    @Published var target = "zh-Hans"
    @Published private(set) var configuringAI = false
    var aiConfigurationChanged: ((Bool) -> Void)?
    @Published var input: TranslationInput?

    func setConfiguringAI(_ configuring: Bool) {
        guard configuring != configuringAI else { return }
        aiConfigurationChanged?(configuring)
        configuringAI = configuring
    }
}

struct CaptureTextView: View {
    let image: CGImage
    @ObservedObject var model: CaptureTextModel
    @AppStorage("capture.translation.ai.provider") private var provider = CaptureTranslationSettings.initialProvider
    @AppStorage("capture.translation.chatgpt.model") private var chatModel = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.recognitionFailed {
                Text(localized("capture_text.ocr_error"))
            } else if let source = model.source {
                if source.isEmpty {
                    Text(localized("capture_text.empty"))
                } else {
                    translationControls(source)
                }
            } else {
                ProgressView(localized("capture_text.recognizing"))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            let timing = CaptureTiming(source: "translation.ocr")
            let worker = Task.detached(priority: .userInitiated) { try CaptureTextRecognition.recognize(image) }
            do {
                let text = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                timing.finish(Task.isCancelled ? "cancelled" : (text.isEmpty ? "empty" : "success"))
                guard !Task.isCancelled else { return }
                model.source = text
            } catch {
                if Task.isCancelled {
                    timing.finish("cancelled")
                } else {
                    timing.finish("failed", error: "ocr_failed")
                    model.recognitionFailed = true
                }
            }
        }
    }

    private var destination: String? {
        switch provider {
        case .chatGPT: return CaptureTranslationSettings.chatGPT.isSignedIn ? "ChatGPT" : nil
        case .apiKey:
            return (try? CloudTranslation(baseURL: CaptureTranslationSettings.baseURL,
                                          model: CaptureTranslationSettings.model))?.endpoint.host
        }
    }

    private func translationControls(_ source: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.configuringAI {
                AITranslationSetup(provider: $provider, chatModel: $chatModel) {
                    model.setConfiguringAI(false)
                }
            } else {
                HStack {
                    Picker(localized("capture_text.target"), selection: $model.target) {
                        ForEach(["zh-Hans", "en", "ja", "ko", "fr", "de", "es"], id: \.self) { code in
                            Text(Locale.current.localizedString(forIdentifier: code) ?? code).tag(code)
                        }
                    }
                    .fixedSize()
                    .onChange(of: model.target) { _, _ in
                        model.input = nil
                        model.partialTranslation = ""
                        model.status = ""
                        model.translated = ""
                        model.sentencePairs = nil
                        model.resultEngine = nil
                    }
                    Spacer(minLength: 0)
                    if model.input != nil {
                        Button(localized("capture_text.cancel")) {
                            model.input = nil
                            model.partialTranslation = ""
                            model.status = localized("capture_text.cancelled")
                        }
                    } else {
                        if #available(macOS 15.0, *) {
                            Button(localized("capture_text.translate")) { beginTranslation(.system) }
                        }
                        Button {
                            if destination == nil {
                                model.setConfiguringAI(true)
                            } else {
                                beginTranslation(provider == .chatGPT ? .chatGPT : .apiKey)
                            }
                        } label: {
                            Label(localized("capture_text.ai_translate"), systemImage: "sparkles")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Button {
                        model.setConfiguringAI(true)
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .help(localized("capture_text.ai_settings"))
                    .accessibilityLabel(localized("capture_text.ai_settings"))
                    .disabled(model.input != nil)
                }
                if let destination {
                    HStack {
                        Text(String(format: localized("capture_text.ai_destination"), destination))
                        if provider == .chatGPT {
                            let name = chatModel.isEmpty || chatModel == ChatGPTPlan.defaultTranslationModel
                                ? localized("capture_text.ai_luna_low") : chatModel
                            Text(name).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                if !model.status.isEmpty {
                    Text(model.status).font(.callout).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                let pairs = model.input == nil && model.sentencePairs?.canHighlight == true ? model.sentencePairs : nil
                TranslationTextColumns(
                    original: source,
                    translation: model.partialTranslation.isEmpty ? model.translated : model.partialTranslation,
                    originalTitle: localized("capture_text.original"),
                    translationTitle: localized(model.partialTranslation.isEmpty ? resultTitle : "capture_text.ai_result"),
                    copyTitle: localized("capture_text.copy"),
                    pairs: pairs,
                    approximateAlignmentNote: localized("capture_text.approximate_alignment"),
                    translationCanCopy: model.partialTranslation.isEmpty
                )
                if let input = model.input {
                    translationWorker(source, input: input)
                }
            }
        }
    }

    private var resultTitle: String {
        switch model.resultEngine {
        case .chatGPT, .apiKey: return "capture_text.ai_result"
        case .system: return "capture_text.local_result"
        case nil: return "capture_text.result"
        }
    }

    @ViewBuilder private func translationWorker(_ source: String, input: CaptureTextModel.TranslationInput) -> some View {
        let anchor = Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
        if input.engine != .system {
            anchor.task(id: input.id) {
                let timing = CaptureTiming(source: input.engine == .chatGPT
                                           ? "translation.chatgpt" : "translation.api_key")
                do {
                    let segmented = SegmentedTranslation(source: source, target: input.target)
                    let result: String
                    if input.engine == .chatGPT {
                        var receivedText = false
                        let network = CaptureTiming(source: "translation.chatgpt.network", operationID: timing.operationID)
                        result = try await CaptureTranslationSettings.chatGPT.translate(
                            segmented.source, target: input.target, model: chatModel, segmentMarker: segmented.marker,
                            onHeaders: timing.httpStatus,
                            onSessionReady: { timing.mark("session.ready") },
                            onText: { text in
                                if !receivedText {
                                    timing.mark("response.first_text")
                                    receivedText = true
                                }
                                guard model.input?.id == input.id else { return }
                                model.partialTranslation = segmented.render(text, streaming: true).text
                            },
                            onNetworkTiming: { trace in
                                if let dns = trace.dns { network.mark("network.dns_ms", elapsedMS: dns) }
                                if let tcp = trace.tcp { network.mark("network.tcp_ms", elapsedMS: tcp) }
                                if let tls = trace.tls { network.mark("network.tls_ms", elapsedMS: tls) }
                                if let wait = trace.responseWait { network.mark("network.response_wait_ms", elapsedMS: wait) }
                                network.mark("network.total_ms", elapsedMS: trace.total)
                                if trace.proxy { network.mark("network.proxy") }
                                if trace.reused { network.mark("network.reused") }
                                network.finish("measured")
                            }
                        )
                    } else {
                        let config = try CloudTranslation(baseURL: CaptureTranslationSettings.baseURL, model: CaptureTranslationSettings.model)
                        guard let key = CaptureTranslationSettings.apiKey(for: config.endpoint) else {
                            throw CloudTranslation.Failure.invalidConfiguration
                        }
                        timing.mark("session.ready")
                        result = try await config.translate(segmented.source, target: input.target, apiKey: key, segmentMarker: segmented.marker,
                                                            onHeaders: timing.httpStatus)
                    }
                    timing.mark("response.complete")
                    timing.finish(Task.isCancelled ? "cancelled" : "success")
                    let rendered = segmented.render(result)
                    finishTranslation(.success(rendered.text), input: input, alignedPairs: rendered.pairs)
                } catch {
                    AITranslationSetup.recordFailure(error, timing: timing)
                    if !Task.isCancelled { finishTranslation(.failure(error), input: input) }
                }
            }
        } else if #available(macOS 15.0, *) {
            let timing = input.systemTiming
            anchor.modifier(SystemTranslation(text: source, target: .init(identifier: input.target), progress: { phase in
                guard model.input?.id == input.id else { return }
                switch phase {
                case .needsLanguageDownload:
                    timing?.mark("language.download_required")
                    model.status = localized("capture_text.language_download")
                case .translating:
                    timing?.mark("translation.begin")
                    model.status = localized("capture_text.translating")
                }
            }) { result in
                finishTranslation(result, input: input)
            })
            .id(input.id)
        }
    }

    private func finishTranslation(_ result: Result<String, Error>, input: CaptureTextModel.TranslationInput,
                                   alignedPairs: TranslationSentencePairs? = nil) {
        guard model.input?.id == input.id else { return }
        model.input = nil
        model.partialTranslation = ""
        switch result {
        case .success(let text):
            model.translated = text
            let timing = CaptureTiming(source: "translation.alignment")
            let pairs = alignedPairs ?? TranslationSentencePairs(original: model.source ?? "", translation: text)
            model.sentencePairs = pairs
            if alignedPairs != nil { timing.mark("segments.explicit") }
            timing.finish(pairs.canHighlight ? "paired" : "no_sentences")
            model.resultEngine = input.engine
            model.status = ""
        case .failure(let error):
            model.status = localized("capture_text.translation_error") + " " + AITranslationSetup.message(for: error)
        }
    }

    private func beginTranslation(_ engine: CaptureTextModel.Engine) {
        model.status = localized(engine == .system ? "capture_text.checking_languages" : "capture_text.cloud_wait")
        model.input = CaptureTextModel.TranslationInput(target: model.target, engine: engine)
    }
}
