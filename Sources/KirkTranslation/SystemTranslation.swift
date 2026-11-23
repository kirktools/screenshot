import Foundation
import SwiftUI
import Translation

/// 宿主提供文本与目标语言，系统负责识别源语言、下载语言模型及翻译。
@available(macOS 15.0, *)
public struct SystemTranslation: ViewModifier {
    public enum Phase {
        case needsLanguageDownload
        case translating
    }

    public let text: String
    public let target: Locale.Language
    private let progress: @MainActor (Phase) -> Void
    public let completion: @MainActor (Result<String, Error>) -> Void

    public init(text: String, target: Locale.Language,
                progress: @escaping @MainActor (Phase) -> Void = { _ in },
                completion: @escaping @MainActor (Result<String, Error>) -> Void) {
        self.text = text
        self.target = target
        self.progress = progress
        self.completion = completion
    }

    @ViewBuilder public func body(content: Content) -> some View {
        content.translationTask(source: nil, target: target) { session in
            await translate(using: session, availability: LanguageAvailability())
        }
    }

    @MainActor private func translate(using session: TranslationSession, availability: LanguageAvailability) async {
        do {
            let status = try? await availability.status(for: text, to: target)
            try Task.checkCancellation()
            progress(status == .supported ? .needsLanguageDownload : .translating)
            let response = try await session.translate(text)
            guard !Task.isCancelled else { return }
            completion(.success(response.targetText))
        } catch {
            guard !Task.isCancelled else { return }
            completion(.failure(error))
        }
    }
}
