import XCTest
@testable import RendererResolver

final class RendererResolverTests: XCTestCase {

    func testTwoKindsOf51() {
        // Order A (film/ITU): L R C LFE Ls Rs — already in renderer order.
        let a = RendererResolver.resolve(SourceLayout(channelCount: 6, layoutTag: "MPEG_5_1_A"))!
        XCTAssertEqual(a.layoutId, "5_1")
        XCTAssertEqual(a.inputPermutation, [0, 1, 2, 3, 4, 5])
        // Order B: L R Ls Rs C LFE — renderer order L R C LFE Ls Rs ⇒ C/LFE pulled from 4,5.
        let b = RendererResolver.resolve(SourceLayout(channelCount: 6, layoutTag: "MPEG_5_1_B"))!
        XCTAssertEqual(b.layoutId, "5_1")
        XCTAssertEqual(b.inputPermutation, [0, 1, 4, 5, 2, 3])
        // DTS order: C L R Ls Rs LFE.
        let d = RendererResolver.resolve(SourceLayout(channelCount: 6, layoutTag: "DTS_5_1"))!
        XCTAssertEqual(d.layoutId, "5_1")
        XCTAssertEqual(d.inputPermutation, [1, 2, 0, 5, 3, 4])
    }

    func test8ChannelDisambiguation() {
        let s71 = RendererResolver.resolve(SourceLayout(channelCount: 8, labels: ["L", "R", "C", "LFE", "Lss", "Rss", "Lrs", "Rrs"]))!
        XCTAssertEqual(s71.layoutId, "7_1")
        let auro = RendererResolver.resolve(SourceLayout(channelCount: 8, labels: ["L", "R", "Ls", "Rs", "HL", "HR", "HLs", "HRs"]))!
        XCTAssertEqual(auro.layoutId, "auro_8_0")
        let bare = RendererResolver.resolve(SourceLayout(channelCount: 8))!
        XCTAssertEqual(bare.layoutId, "7_1")
        XCTAssertEqual(bare.reason, "channel-count default")
    }

    func testSidecarWins() {
        let r = RendererResolver.resolve(SourceLayout(channelCount: 8,
            labels: ["L", "R", "C", "LFE", "Lss", "Rss", "Lrs", "Rrs"], sidecarLayoutId: "auro_8_0"))!
        XCTAssertEqual(r.layoutId, "auro_8_0")
        XCTAssertEqual(r.reason, "sidecar override")
    }

    func testCountFallbacks() {
        XCTAssertEqual(RendererResolver.resolve(SourceLayout(channelCount: 2))!.layoutId, "stereo_2_0")
        XCTAssertEqual(RendererResolver.resolve(SourceLayout(channelCount: 12))!.layoutId, "7_1_4")
        XCTAssertEqual(RendererResolver.resolve(SourceLayout(channelCount: 6))!.layoutId, "5_1")
        XCTAssertNil(RendererResolver.resolve(SourceLayout(channelCount: 3)))
    }

    func testResolvedPermutationsAreValid() {
        for tag in ["MPEG_5_1_A", "MPEG_5_1_B", "MPEG_5_1_C", "MPEG_5_1_D", "DTS_5_1"] {
            let r = RendererResolver.resolve(SourceLayout(channelCount: 6, layoutTag: tag))!
            XCTAssertEqual(r.inputPermutation.sorted(), Array(0..<6), tag)
        }
        let atmos = RendererResolver.resolve(SourceLayout(channelCount: 12, layoutTag: "Atmos_7_1_4"))!
        XCTAssertEqual(atmos.layoutId, "7_1_4")
        XCTAssertEqual(atmos.inputPermutation.sorted(), Array(0..<12))
    }
}
