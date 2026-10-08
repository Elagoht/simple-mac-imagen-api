import Foundation

struct AppConfig: Equatable, Sendable {
    var host = "127.0.0.1"
    var port = 8787
    var modelDirectory = "Models/coreml-sd-v1-5-palettized"

    static func parse(_ args: [String], environment: [String: String]) -> AppConfig {
        var config = AppConfig()
        if let value = environment["RESIM_HOST"] { config.host = value }
        if let value = environment["RESIM_PORT"], let port = Int(value) { config.port = port }
        if let value = environment["RESIM_MODEL_DIR"] { config.modelDirectory = value }
        var index = args.startIndex + 1 // args[0] çalıştırılabilirin adı
        while index < args.count {
            let argument = args[index]
            let valueAt: (Int) -> String? = { offset in
                let position = index + offset
                return position < args.count ? args[position] : nil
            }
            switch argument {
            case "--host":
                if let value = valueAt(1) { config.host = value; index += 2 } else { index += 1 }
            case "--port":
                if let value = valueAt(1), let port = Int(value) {
                    config.port = port
                    index += 2
                } else { index += 1 }
            case "--model":
                if let value = valueAt(1) { config.modelDirectory = value; index += 2 } else { index += 1 }
            default:
                index += 1
            }
        }
        return config
    }
}
