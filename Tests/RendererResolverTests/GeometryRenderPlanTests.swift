import XCTest
@testable import RendererResolver

final class GeometryRenderPlanTests: XCTestCase {

    func testStereoPlan() {
        let p = GeometryRenderPlan(source: SourceLayout(channelCount: 2))!
        XCTAssertEqual(p.resolved.layoutId, "stereo_2_0")
        XCTAssertEqual(p.gainMatrix.count, 2)
        XCTAssertEqual(p.gainMatrix[0].count, 31)
        for row in p.gainMatrix { XCTAssertEqual(row[30], 0, accuracy: 1e-12) }   // sub bass-managed, not flat
        XCTAssertEqual(p.subSourceInputs.sorted(), [0, 1])                        // L + R → mono sub
        XCTAssertEqual(p.subLowPassHz, 400, accuracy: 1e-9)
    }

    func testReordered51PlacesCenterAndLFE() {
        // tag B order: L R Ls Rs C LFE — source C = idx 4, LFE = idx 5.
        let p = GeometryRenderPlan(source: SourceLayout(channelCount: 6, layoutTag: "MPEG_5_1_B"))!
        XCTAssertEqual(p.resolved.layoutId, "5_1")
        // The source LFE channel carries no dome gain (it only feeds the sub).
        XCTAssertEqual(p.gainMatrix[5].prefix(30).reduce(0) { $0 + abs($1) }, 0, accuracy: 1e-9)
        // The source C channel images to the front (power-normalized).
        XCTAssertEqual(p.gainMatrix[4].prefix(30).reduce(0) { $0 + $1 * $1 }, 1, accuracy: 2e-3)
        XCTAssertTrue(p.subSourceInputs.contains(5))   // LFE folds into the mono sub
    }

    func testLowPassPassesDCAttenuatesHF() {
        var lp = OnePoleLowPass(cutoffHz: 400, sampleRate: 48000)
        var dc = 0.0
        for _ in 0..<3000 { dc = lp.process(1.0) }
        XCTAssertEqual(dc, 1.0, accuracy: 1e-3, "DC passes")
        var hf = OnePoleLowPass(cutoffHz: 400, sampleRate: 48000)
        var peak = 0.0
        for n in 0..<3000 { peak = max(peak, abs(hf.process(n % 2 == 0 ? 1.0 : -1.0))) }
        XCTAssertLessThan(peak, 0.2, "Nyquist-rate content strongly attenuated")
    }
}
