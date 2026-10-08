import Vapor
import Foundation
import FoundationModels

enum Log {
    static func info(_ message: String) {
        FileHandle.standardError.write(Data("ℹ️  \(message)\n".utf8))
    }
    static func warn(_ message: String) {
        FileHandle.standardError.write(Data("⚠️  \(message)\n".utf8))
    }
    static func error(_ message: String) {
        FileHandle.standardError.write(Data("❌ \(message)\n".utf8))
    }
}

@main
struct ResimUreticiApp {
    static func main() async throws {
        let config = AppConfig.parse(
            CommandLine.arguments,
            environment: ProcessInfo.processInfo.environment
        )
        let modelURL = URL(fileURLWithPath: config.modelDirectory)

        // Fail fast: model kaynakları eksikse hiç başlama.
        do {
            try CoreMLImageGenerator.validateResources(at: modelURL)
        } catch {
            Log.error(error.localizedDescription)
            Log.error("Modeli indirmek için: Scripts/fetch-model.sh")
            exit(1)
        }

        Log.info("model: \(config.modelDirectory)")
        Log.info("http://\(config.host):\(config.port) hazırlanıyor...")

        let app = try await Application.make(Environment(name: "production", arguments: ["vapor"]))
        app.http.server.configuration.hostname = config.host
        app.http.server.configuration.port = config.port

        let generator = try CoreMLImageGenerator(resourcesAt: modelURL)
        let readiness = ReadinessFlag()

        // Prompt hazırlık zinciri: çeviri + token sayımı + yoğunlaştırma.
        let counter = PromptTokenCounter(modelDirectory: modelURL)
        if counter == nil {
            Log.warn("token sayacı yüklenemedi — uzun prompt yoğunlaştırması kapalı")
        }
        let condenser: (any PromptCondensing)? =
            SystemLanguageModel.default.availability == .available ? FoundationModelsCondenser() : nil
        if condenser == nil {
            Log.warn("FoundationModels kullanılamıyor — uzun prompt yoğunlaştırması kapalı")
        }
        let preparer = PromptPreparer(
            translator: SmartPromptTranslator(),
            counter: counter,
            condenser: condenser
        )

        let state = AppState(
            queue: GenerationQueue(generator: generator),
            preparer: preparer,
            modelName: modelURL.lastPathComponent,
            readiness: readiness
        )
        try routes(app, state: state)

        // Ağır model yüklemesi arka planda; sunucu hemen dinlemeye başlar (/health: loading).
        Task.detached {
            do {
                let startedAt = DispatchTime.now()
                try generator.loadResources()
                readiness.set()
                let seconds = Double(DispatchTime.now().uptimeNanoseconds - startedAt.uptimeNanoseconds) / 1_000_000_000
                Log.info(String(format: "model yüklendi (%.1f sn) — /generate hazır", seconds))
            } catch {
                Log.error("model yüklenemedi: \(error)")
                exit(1)
            }
        }

        do {
            try await app.execute()
            try await app.asyncShutdown()
        } catch {
            Log.error("sunucu hatası: \(error)")
            try? await app.asyncShutdown()
            exit(1)
        }
    }
}
