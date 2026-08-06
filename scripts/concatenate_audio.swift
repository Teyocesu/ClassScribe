import Foundation

guard CommandLine.arguments.count >= 4 else {
    fputs("uso: concatenate_audio.swift entrada1 entrada2 [entradaN] salida\n", stderr)
    exit(2)
}

struct WaveParts {
    let format: Data
    let samples: Data
}

func littleEndianUInt32(_ data: Data, at offset: Int) throws -> Int {
    guard offset + 4 <= data.count else {
        throw NSError(domain: "ClassScribeFixtures", code: 1, userInfo: [NSLocalizedDescriptionKey: "WAV truncado"])
    }
    return Int(data[offset])
        | (Int(data[offset + 1]) << 8)
        | (Int(data[offset + 2]) << 16)
        | (Int(data[offset + 3]) << 24)
}

func waveParts(at url: URL) throws -> WaveParts {
    let data = try Data(contentsOf: url)
    guard data.count >= 12,
          String(data: data[0 ..< 4], encoding: .ascii) == "RIFF",
          String(data: data[8 ..< 12], encoding: .ascii) == "WAVE" else {
        throw NSError(domain: "ClassScribeFixtures", code: 2, userInfo: [NSLocalizedDescriptionKey: "Formato WAV inválido"])
    }

    var format: Data?
    var samples: Data?
    var offset = 12
    while offset + 8 <= data.count {
        let identifier = String(data: data[offset ..< offset + 4], encoding: .ascii)
        let size = try littleEndianUInt32(data, at: offset + 4)
        let start = offset + 8
        let end = start + size
        guard end <= data.count else { break }
        if identifier == "fmt " { format = data[start ..< end] }
        if identifier == "data" { samples = data[start ..< end] }
        offset = end + (size % 2)
    }

    guard let format, let samples else {
        throw NSError(domain: "ClassScribeFixtures", code: 3, userInfo: [NSLocalizedDescriptionKey: "WAV sin fmt o data"])
    }
    return WaveParts(format: format, samples: samples)
}

func appendUInt32(_ value: Int, to data: inout Data) {
    var number = UInt32(value).littleEndian
    withUnsafeBytes(of: &number) { data.append(contentsOf: $0) }
}

let inputURLs = CommandLine.arguments.dropFirst().dropLast().map { URL(fileURLWithPath: $0) }
let outputURL = URL(fileURLWithPath: CommandLine.arguments.last!)
let parts = try inputURLs.map(waveParts)
guard parts.dropFirst().allSatisfy({ $0.format == parts[0].format }) else {
    throw NSError(domain: "ClassScribeFixtures", code: 4, userInfo: [NSLocalizedDescriptionKey: "Los formatos WAV no coinciden"])
}

var allSamples = Data()
parts.forEach { allSamples.append($0.samples) }
var output = Data("RIFF".utf8)
appendUInt32(4 + 8 + parts[0].format.count + 8 + allSamples.count, to: &output)
output.append(Data("WAVEfmt ".utf8))
appendUInt32(parts[0].format.count, to: &output)
output.append(parts[0].format)
if parts[0].format.count % 2 == 1 { output.append(0) }
output.append(Data("data".utf8))
appendUInt32(allSamples.count, to: &output)
output.append(allSamples)
try output.write(to: outputURL, options: .atomic)
