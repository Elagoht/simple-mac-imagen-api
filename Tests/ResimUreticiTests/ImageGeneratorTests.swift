import Testing
import Foundation
import CoreML
import StableDiffusion
@testable import resimuretici

@Suite struct ImageGeneratorTests {
    private func makeTempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("resimuretici-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func fillRequiredResources(_ dir: URL) throws {
        // SD tam seti: requiredResources + Unet (Unet, tip-duyarlı doğrulamada ayrı ekleniyor)
        for name in CoreMLImageGenerator.requiredResources + ["Unet.mlmodelc"] {
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

    @Test func validateRejectsDirectoryMissingUnet() throws {
        // UNet en büyük ve en gerekli bileşen; eksikken yarım servis başlamamalı.
        let dir = makeTempDir()
        for name in CoreMLImageGenerator.requiredResources where name != "Unet.mlmodelc" {
            let path = dir.appendingPathComponent(name)
            if name.hasSuffix(".mlmodelc") {
                try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            } else {
                try Data("x".utf8).write(to: path)
            }
        }
        do {
            _ = try CoreMLImageGenerator.validateResources(at: dir)
            Issue.record("Unet eksikken doğrulama geçmemeli")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            #expect(message.contains("Unet.mlmodelc"), "mesaj Unet'i adlandırmalı: \(message)")
        }
    }

    @Test func validateRejectsFileWhereDirectoryExpected() throws {
        // .mlmodelc kaynakları dizin olmalı; aynı adlı düz dosya eksik sayılır.
        let dir = makeTempDir()
        try fillRequiredResources(dir)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("Unet.mlmodelc"))
        try Data("x".utf8).write(to: dir.appendingPathComponent("Unet.mlmodelc"))
        do {
            _ = try CoreMLImageGenerator.validateResources(at: dir)
            Issue.record("dosya yerine geçen .mlmodelc kabul edilmemeli")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            #expect(message.contains("Unet.mlmodelc"), "mesaj Unet'i adlandırmalı: \(message)")
        }
    }

    @Test func validateAcceptsXLResources() throws {
        // SDXL yerleşimi: TextEncoder2 + chunk'lı Unet (UnetChunk1/2)
        let dir = makeTempDir()
        for name in ["TextEncoder.mlmodelc", "TextEncoder2.mlmodelc", "UnetChunk1.mlmodelc",
                     "UnetChunk2.mlmodelc", "VAEDecoder.mlmodelc", "vocab.json", "merges.txt"] {
            let path = dir.appendingPathComponent(name)
            if name.hasSuffix(".mlmodelc") {
                try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            } else {
                try Data("x".utf8).write(to: path)
            }
        }
        #expect(throws: Never.self) {
            try CoreMLImageGenerator.validateResources(at: dir)
        }
    }

    @Test func validateRejectsXLMissingUnetChunks() throws {
        // TextEncoder2 varsa XL kabul edilir; chunk'lı UNet eksikse reddedilmeli.
        let dir = makeTempDir()
        for name in ["TextEncoder.mlmodelc", "TextEncoder2.mlmodelc",
                     "VAEDecoder.mlmodelc", "vocab.json", "merges.txt"] {
            let path = dir.appendingPathComponent(name)
            if name.hasSuffix(".mlmodelc") {
                try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            } else {
                try Data("x".utf8).write(to: path)
            }
        }
        do {
            _ = try CoreMLImageGenerator.validateResources(at: dir)
            Issue.record("XL'de UnetChunk'lar eksikken doğrulama geçmemeli")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            #expect(message.contains("Unet"), "mesaj Unet'i adlandırmalı: \(message)")
        }
    }

    @Test func factoryPrefersBasePipelineForSDResources() throws {
        let dir = makeTempDir()
        try fillRequiredResources(dir)
        #expect(CoreMLImageGenerator.preferredPipelineKind(at: dir) == .sd)
    }

    @Test func factoryPrefersXLPipelineWhenTextEncoder2Present() throws {
        let dir = makeTempDir()
        for name in ["TextEncoder.mlmodelc", "TextEncoder2.mlmodelc", "UnetChunk1.mlmodelc",
                     "UnetChunk2.mlmodelc", "VAEDecoder.mlmodelc", "vocab.json", "merges.txt"] {
            let path = dir.appendingPathComponent(name)
            if name.hasSuffix(".mlmodelc") {
                try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            } else {
                try Data("x".utf8).write(to: path)
            }
        }
        #expect(CoreMLImageGenerator.preferredPipelineKind(at: dir) == .xl)
    }

    @Test func initThrowsForMissingDirectory() {
        let dir = makeTempDir().appendingPathComponent("yok-boyle-klasor")
        #expect(throws: (any Error).self) {
            try CoreMLImageGenerator(resourcesAt: dir)
        }
    }
}
