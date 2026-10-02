#if DEBUG
import Foundation

nonisolated enum UITestAudio {
    static func silence() -> Data {
        let sampleRate: UInt32 = 44_100
        let byteCount = sampleRate * 2 * 20
        var data = Data("RIFF".utf8)
        append(byteCount + 36, to: &data)
        data.append(Data("WAVEfmt ".utf8))
        append(UInt32(16), to: &data)
        append(UInt16(1), to: &data)
        append(UInt16(1), to: &data)
        append(sampleRate, to: &data)
        append(sampleRate * 2, to: &data)
        append(UInt16(2), to: &data)
        append(UInt16(16), to: &data)
        data.append(Data("data".utf8))
        append(byteCount, to: &data)
        data.append(Data(repeating: 0, count: Int(byteCount)))
        return data
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var value = value.littleEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }
}
#endif
