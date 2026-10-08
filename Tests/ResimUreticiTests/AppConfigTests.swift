import Testing
@testable import resimuretici

@Suite struct AppConfigTests {
    @Test func defaults() {
        let config = AppConfig.parse([], environment: [:])
        #expect(config.host == "127.0.0.1")
        #expect(config.port == 8787)
        #expect(config.modelDirectory == "Models/coreml-sd-v1-5-palettized")
    }

    @Test func environmentOverrides() {
        let config = AppConfig.parse([], environment: [
            "RESIM_PORT": "9000",
            "RESIM_MODEL_DIR": "/tmp/m",
            "RESIM_HOST": "0.0.0.0",
        ])
        #expect(config.port == 9000)
        #expect(config.modelDirectory == "/tmp/m")
        #expect(config.host == "0.0.0.0")
    }

    @Test func cliOverridesEnvironment() {
        let config = AppConfig.parse(
            ["resimuretici", "--port", "8080", "--model", "/x", "--host", "1.2.3.4"],
            environment: ["RESIM_PORT": "9000"]
        )
        #expect(config.port == 8080)
        #expect(config.modelDirectory == "/x")
        #expect(config.host == "1.2.3.4")
    }

    @Test func invalidPortArgKeepsDefault() {
        let config = AppConfig.parse(["resimuretici", "--port", "abc"], environment: [:])
        #expect(config.port == 8787)
    }
}
