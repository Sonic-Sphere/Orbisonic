import XCTest
@testable import RendererGeometry

final class RendererGeometryTests: XCTestCase {

    // Energy-weighted (gain²) position of a dome row along an axis — robust geometry probe.
    private func weighted(_ row: [Double], _ axis: ((x: Double, y: Double, z: Double)) -> Double) -> Double {
        var num = 0.0, den = 0.0
        for (k, g) in row.enumerated() { let w = g * g; num += w * axis(SphereGeometry.unitSpeakers[k]); den += w }
        return den > 0 ? num / den : 0
    }

    func testAll19Present() {
        XCTAssertEqual(RendererGeometry.all.count, 19)
        for id in ["mono_1_0", "stereo_2_0", "7_1", "7_1_4", "9_1_6", "harmony_bloom_8ch", "auro_13_1"] {
            XCTAssertNotNil(RendererGeometry.renderer(layout: id), id)
        }
    }

    func testDomeMatrixDimensions() {
        for r in RendererGeometry.all {
            let m = RendererGeometry.domeMatrix(r)
            XCTAssertEqual(m.count, r.channelCount, "\(r.layout) rows")
            for row in m { XCTAssertEqual(row.count, 30, "\(r.layout) cols") }
        }
    }

    func testFullRangeColumnsPowerNormalizedAndLFEsilentOnDome() {
        for r in RendererGeometry.all {
            let m = RendererGeometry.domeMatrix(r)
            for (i, ch) in r.channels.enumerated() {
                let power = m[i].reduce(0) { $0 + $1 * $1 }
                if ch.isLFE {
                    XCTAssertEqual(power, 0, accuracy: 1e-9, "\(r.layout)/\(ch.label) LFE carries no dome gain")
                } else {
                    XCTAssertEqual(power, 1, accuracy: 2e-3, "\(r.layout)/\(ch.label) power-normalized")
                }
            }
        }
    }

    func testPerSpeakerPowerCapRespected() {
        // The cap targets ~22% power/speaker, but the final renormalization permits a slight
        // overshoot, so the real invariant is "no single speaker dominates" — assert ≤ 25% power.
        let cap = 0.5
        for r in RendererGeometry.all {
            for row in RendererGeometry.domeMatrix(r) {
                for g in row { XCTAssertLessThanOrEqual(g, cap, "\(r.layout) per-speaker cap") }
            }
        }
    }

    func testStereoIsParametricAndLiveMatchesGeneratedDefault() {
        let stereo = RendererGeometry.renderer(layout: "stereo_2_0")!
        XCTAssertTrue(stereo.isParametric)
        let gen = RendererGeometry.domeMatrix(stereo)                  // generated table @ default 90°
        let live = RendererGeometry.stereoDomeMatrix(angleDegrees: 90) // computed live
        for row in 0..<2 { for col in 0..<30 {
            XCTAssertEqual(gen[row][col], live[row][col], accuracy: 1e-3, "stereo[\(row)][\(col)]")
        } }
    }

    func testStereoMonoCollapseAtZero() {
        let m = RendererGeometry.stereoDomeMatrix(angleDegrees: 0)
        for col in 0..<30 { XCTAssertEqual(m[0][col], m[1][col], accuracy: 1e-12, "0° → L == R (mono)") }
    }

    func testStereoEnvelopingHardSidesAt180() {
        let m = RendererGeometry.stereoDomeMatrix(angleDegrees: 180)
        XCTAssertLessThan(weighted(m[0]) { $0.x }, -0.5, "180° L images hard-left")
        XCTAssertGreaterThan(weighted(m[1]) { $0.x }, 0.5, "180° R images hard-right")
    }

    func testStereoWidens() {
        // |x| of L should grow monotonically as the angle opens 0 → 90 → 180
        let x0 = abs(weighted(RendererGeometry.stereoDomeMatrix(angleDegrees: 0)[0]) { $0.x })
        let x90 = abs(weighted(RendererGeometry.stereoDomeMatrix(angleDegrees: 90)[0]) { $0.x })
        let x180 = abs(weighted(RendererGeometry.stereoDomeMatrix(angleDegrees: 180)[0]) { $0.x })
        XCTAssertLessThan(x0, x90)
        XCTAssertLessThan(x90, x180)
    }

    func testDolby71FrontSideRearOrdering() {
        let r = RendererGeometry.renderer(layout: "7_1")!
        let m = RendererGeometry.domeMatrix(r)
        func row(_ label: String) -> [Double] { m[r.channels.firstIndex { $0.label == label }!] }
        let yL = weighted(row("L")) { $0.y }, ySide = weighted(row("Lss")) { $0.y }, yRear = weighted(row("Lrs")) { $0.y }
        XCTAssertGreaterThan(yL, ySide, "front (L) ahead of side (Lss)")
        XCTAssertGreaterThan(ySide, yRear, "side (Lss) ahead of rear (Lrs)")
        XCTAssertLessThan(yRear, -0.2, "Lrs sits behind the listener")
        for l in ["L", "Lss", "Lrs"] { XCTAssertLessThan(weighted(row(l)) { $0.x }, 0, "\(l) images left") }
    }

    func testSubBassRouting() {
        let stereo = RendererGeometry.renderer(layout: "stereo_2_0")!
        XCTAssertTrue(stereo.subBass.derivedLFE)
        XCTAssertEqual(stereo.subBass.fullRangeInputs, [0, 1])
        XCTAssertTrue(stereo.subBass.lfeInputs.isEmpty)
        XCTAssertEqual(stereo.subBass.lowPassHz, 400, accuracy: 1e-9)
        XCTAssertEqual(stereo.subBass.lfeGainDb, 0, accuracy: 1e-9)  // music: no cinema +10 dB

        let d71 = RendererGeometry.renderer(layout: "7_1")!
        XCTAssertFalse(d71.subBass.derivedLFE)
        XCTAssertEqual(d71.subBass.lfeInputs, [3])            // the LFE channel index
        XCTAssertEqual(d71.subBass.fullRangeInputs.count, 7)  // L R C Lss Rss Lrs Rrs
    }

    func testGainMatrixHasSilentSubColumn() {
        for r in RendererGeometry.all {
            for row in RendererGeometry.gainMatrix(r) {
                XCTAssertEqual(row.count, 31)
                XCTAssertEqual(row[30], 0, accuracy: 1e-12, "\(r.layout) sub flat-gain is 0 (bass-managed)")
            }
        }
    }
}
