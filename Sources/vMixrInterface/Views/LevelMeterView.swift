import SwiftUI

// REQ-014/018: horizontal level meter (VU style). The color scale is fixed to
// the full track width (green -> yellow around 70% -> red at 100%), a slowly
// decaying peak-hold tick lags behind the current level, and a dB scale row
// (-20/-10/0) marks the linear amplitude position.
struct LevelMeterView: View {
    let value: Double
    var peak: Double = 0

    // Linear-amplitude position of each dB mark (0 dB = full scale).
    private let scaleMarks: [(mark: String, position: Double)] = [
        ("-20", 0.10),
        ("-10", 0.3162),
        ("0", 1.0)
    ]

    private var clamped: Double { min(max(value, 0), 1) }
    private var peakClamped: Double { min(max(max(value, peak), 0), 1) }
    private var isClip: Bool { clamped >= 0.999 }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(Color.black.opacity(0.45))
                        .overlay(
                            RoundedRectangle(cornerRadius: 2.5)
                                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                        )
                    vuGradient
                        .mask(alignment: .leading) { Rectangle().frame(width: w * clamped) }
                        .clipShape(RoundedRectangle(cornerRadius: 2.5))
                    if isClip {
                        Rectangle().fill(Color.red.opacity(0.35))
                            .mask(alignment: .leading) { Rectangle().frame(width: w * clamped) }
                            .clipShape(RoundedRectangle(cornerRadius: 2.5))
                        Text("CLIP")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.red)
                            .position(x: max(16, w - 16), y: 4)
                    }
                    Rectangle()
                        .fill(Color.white.opacity(0.9))
                        .frame(width: 2, height: 8)
                        .offset(x: max(0, (w - 2) * peakClamped))
                }
            }
            .frame(height: 8)
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .topLeading) {
                    ForEach(scaleMarks, id: \.mark) { mark in
                        let x = w * mark.position
                        Rectangle()
                            .fill(Color.white.opacity(0.25))
                            .frame(width: 1, height: 3)
                            .position(x: min(max(x, 0.5), w - 0.5), y: 1.5)
                        Text(mark.mark)
                            .font(.system(size: 7).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .position(x: min(max(x, 10), w - 9), y: 5.5)
                    }
                }
            }
            .frame(height: 8)
        }
        .frame(maxWidth: .infinity)
    }

    // Green 0 -> ~55%, yellow ~70%, red 90 -> 100% of the full track width.
    private var vuGradient: LinearGradient {
        let green = Color(red: 0x33 / 255.0, green: 0xD9 / 255.0, blue: 0x66 / 255.0)
        let yellow = Color(red: 0xFF / 255.0, green: 0xD9 / 255.0, blue: 0x33 / 255.0)
        let red = Color(red: 0xFF / 255.0, green: 0x4D / 255.0, blue: 0x40 / 255.0)
        return LinearGradient(
            stops: [
                .init(color: green, location: 0),
                .init(color: green, location: 0.55),
                .init(color: yellow, location: 0.70),
                .init(color: red, location: 0.90),
                .init(color: red, location: 1.0)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}
