import Testing
import Foundation
@testable import resimuretici

@Suite struct ImageGeneratorTests {
    private func makeTempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("resimuretici-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func fillRequiredResources(_ dir: URL) throws {
        for name in CoreMLImageGenerator.requiredResources {
            let path = dir.appendingPathComponent(name)
            if name.hasSuffix(".mlmodelc") {
                try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            } else {
                try Data("x".utf8).write(to: path)
            }
        }
    }

    @Test func validateRejectsMissingResources() {
        let dir = makeTempDir()
        #expect(throws: (any Error).self) {
            try CoreMLImageGenerator.validateResources(at: dir)
        }
        do {
            _ = try CoreMLImageGenerator.validateResources(at: dir)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            #expect(message.contains("vocab.json"), "eksik dosya adını içermeli: \(message)")
        }
    }

    @Test func validateRejectsDirectoryItselfMissing() {
        let dir = makeTempDir().appendingPathComponent("yok-boyle-klasor")
        #expect(throws: (any Error).self) {
            try CoreMLImageGenerator.validateResources(at: dir)
        }
    }

    @Test func validateAcceptsCompleteResources() throws {
        let dir = makeTempDir()
        try fillRequiredResources(dir)
        #expect(throws: Never.self) {
            try CoreMLImageGenerator.validateResources(at: dir)
        }
    }

    @Test func initThrowsForMissingDirectory() {
        let dir = makeTempDir().appendingPathComponent("yok-boyle-klasor")
        #expect(throws: (any Error).self) {
            try CoreMLImageGenerator(resourcesAt: dir)
        }
    }
}
