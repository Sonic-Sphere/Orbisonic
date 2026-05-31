import CoreAudio
import CoreGraphics
import XCTest
@testable import Orbisonic

final class RendererModuleTests: XCTestCase {
    private let tolerance = 0.000_1

    func testSourceChannelPolicyRejectsSixtyFiveChannels() {
        XCTAssertTrue(OrbisonicAudioLimits.supportsSourceChannelCount(64))
        XCTAssertFalse(OrbisonicAudioLimits.supportsSourceChannelCount(65))
    }

    func testDefaultPresetBuildsFeyThirtyPointOneSpeakerTopology() {
        let speakers = SonicSphereTopology.outputSpeakers(for: .sonicSphere30Point1)

        XCTAssertEqual(speakers.count, 31)
        XCTAssertEqual(speakers.filter(\.isLFE).count, 1)
        XCTAssertEqual(speakers.filter { !$0.isLFE }.count, 30)
        XCTAssertEqual(speakers.compactMap(\.speakerId), Array(1...30))
        XCTAssertEqual(speakers.filter { !$0.isLFE }.map(\.index), Array(0..<30))
        XCTAssertEqual(speakers.last?.index, 30)
    }

    func testNormalMonitorPlanningLeavesProductionSonicSphereSceneUnchanged() {
        let layout = SurroundLayoutDetector.fallbackLayout(for: 6)
        let baselineTopology = RendererPreset.sonicSphere30Point1.outputTopology
        let baselineSpeakers = SonicSphereTopology.outputSpeakers(for: .sonicSphere30Point1)
        let baselineScene = RendererMatrixBuilder.sceneModel(
            for: layout,
            preset: .sonicSphere30Point1,
            renderMode: .automatic
        )

        XCTAssertEqual(baselineTopology.fullRangeCount, 30)
        XCTAssertEqual(baselineTopology.lfeCount, 1)
        XCTAssertEqual(baselineScene.matrix.outputCount, RendererOutputTopology.fey30Point1.outputCount)

        for sourceFamily in NormalMonitorSourceFamily.allCases {
            let topology = NormalMonitorGraphTopology.audible(sourceFamily: sourceFamily)
            let route = NormalMonitorRoutePlanner.audibleRoute(
                sourceFamily: sourceFamily,
                sourceLayoutDescription: "Synthetic monitor boundary fixture"
            )

            XCTAssertTrue(topology.hasExactlyOneAudiblePath, "\(sourceFamily)")
            XCTAssertFalse(topology.containsAudibleSonicSphereMatrixNode, "\(sourceFamily)")
            XCTAssertTrue(route.usesNormalMonitor, "\(sourceFamily)")
            XCTAssertEqual(route.outputChannelCount, 2, "\(sourceFamily)")
        }

        for mode in rendererModesIncludingDirectBypass {
            let route = NormalMonitorAudibleRouteSelector.select(
                sourceFamily: .localFile,
                sourceLayoutDescription: "Synthetic monitor boundary fixture",
                rendererMode: mode,
                activeOutputRoute: rendererCapableRoute,
                rendererOutputRoute: rendererCapableRoute,
                requiredSonicSphereOutputChannelCount: RendererOutputTopology.fey30Point1.outputCount
            )

            XCTAssertTrue(route.usesNormalMonitor, mode.displayName)
            XCTAssertEqual(route.outputChannelCount, 2, mode.displayName)
            XCTAssertFalse(route.usesAudibleDirectSonicSphereMatrix, mode.displayName)
        }

        let currentScene = RendererMatrixBuilder.sceneModel(
            for: layout,
            preset: .sonicSphere30Point1,
            renderMode: .automatic
        )

        XCTAssertEqual(RendererPreset.sonicSphere30Point1.outputTopology, baselineTopology)
        XCTAssertEqual(currentScene.preset.outputTopology, baselineTopology)
        XCTAssertEqual(SonicSphereTopology.outputSpeakers(for: .sonicSphere30Point1), baselineSpeakers)
        XCTAssertEqual(currentScene.outputSpeakers, baselineScene.outputSpeakers)
        XCTAssertEqual(currentScene.matrix, baselineScene.matrix)
        XCTAssertEqual(currentScene.matrix.outputMajorGains.count, RendererOutputTopology.fey30Point1.outputCount)
    }

    func testRendererValidationAcceptsDefaultLayoutAndMatrices() {
        let renderer = FeyStaticBedRenderer()
        XCTAssertTrue(renderer.validationMessages().isEmpty)

        let modes = FeyStaticBedRenderer().getSupportedLayouts()
        for mode in modes {
            let matrix = renderer.buildMatrix(mode: mode)
            XCTAssertTrue(renderer.validationMessages(for: matrix, mode: mode).isEmpty, mode.displayName)
            XCTAssertEqual(matrix.outputCount, 31)
            XCTAssertEqual(matrix.inputCount, mode.expectedInputCount)
            XCTAssertFalse(matrix.gains.flatMap { $0 }.contains { $0 < 0 })
        }
    }

    func testQuadFLImpulseUsesFLLobeAndAdjacentBleedOnly() {
        let renderer = FeyStaticBedRenderer()
        let output = renderer.render(inputFrame: [1, 0, 0, 0], mode: .quad)
        let active = activeSpeakerIDs(output)
        let allowed = Set([5, 6, 11, 17, 22, 28, 1, 12, 23, 2, 7, 13, 18, 24, 29, 4, 10, 15, 16, 21, 27, 9, 20, 26])

        XCTAssertTrue(Set(active).isSubset(of: allowed))
        XCTAssertTrue(active.contains(5))
        XCTAssertTrue(active.contains(1))
        XCTAssertFalse(active.contains(3))
        XCTAssertFalse(active.contains(8))
        XCTAssertEqual(output[30], 0, accuracy: Float(tolerance))
    }

    func testQuadFRImpulseMirrorsFL() {
        let renderer = FeyStaticBedRenderer()
        let fl = renderer.render(inputFrame: [1, 0, 0, 0], mode: .quad)
        let fr = renderer.render(inputFrame: [0, 1, 0, 0], mode: .quad)

        XCTAssertEqual(fr[FeyStaticBedRenderer.speakerOutputIndex(2)], fl[FeyStaticBedRenderer.speakerOutputIndex(5)], accuracy: Float(0.02))
        XCTAssertEqual(fr[FeyStaticBedRenderer.speakerOutputIndex(7)], fl[FeyStaticBedRenderer.speakerOutputIndex(6)], accuracy: Float(0.02))
        XCTAssertGreaterThan(fr[FeyStaticBedRenderer.speakerOutputIndex(1)], 0)
        XCTAssertEqual(fr[30], 0, accuracy: Float(tolerance))
    }

    func testQuadRLImpulseUsesRearLeftLobeAndRearSupport() {
        let renderer = FeyStaticBedRenderer()
        let output = renderer.render(inputFrame: [0, 0, 1, 0], mode: .quad)

        XCTAssertGreaterThan(output[FeyStaticBedRenderer.speakerOutputIndex(4)], 0)
        XCTAssertGreaterThan(output[FeyStaticBedRenderer.speakerOutputIndex(9)], 0)
        XCTAssertGreaterThan(output[FeyStaticBedRenderer.speakerOutputIndex(20)], 0)
        XCTAssertGreaterThan(output[FeyStaticBedRenderer.speakerOutputIndex(26)], 0)
        XCTAssertEqual(output[30], 0, accuracy: Float(tolerance))
    }

    func testQuadRRImpulseMirrorsRL() {
        let renderer = FeyStaticBedRenderer()
        let rl = renderer.render(inputFrame: [0, 0, 1, 0], mode: .quad)
        let rr = renderer.render(inputFrame: [0, 0, 0, 1], mode: .quad)

        XCTAssertEqual(rr[FeyStaticBedRenderer.speakerOutputIndex(3)], rl[FeyStaticBedRenderer.speakerOutputIndex(4)], accuracy: Float(0.02))
        XCTAssertEqual(rr[FeyStaticBedRenderer.speakerOutputIndex(8)], rl[FeyStaticBedRenderer.speakerOutputIndex(10)], accuracy: Float(0.02))
        XCTAssertGreaterThan(rr[FeyStaticBedRenderer.speakerOutputIndex(9)], 0)
        XCTAssertEqual(rr[30], 0, accuracy: Float(tolerance))
    }

    func testQuadFrontPairUsesSharedFrontCenterSpeakers() {
        let renderer = FeyStaticBedRenderer()
        let output = renderer.render(inputFrame: [1, 1, 0, 0], mode: .quad)

        for speakerId in [1, 12, 23] {
            XCTAssertGreaterThan(output[FeyStaticBedRenderer.speakerOutputIndex(speakerId)], 0)
        }
    }

    func testQuadRearPairUsesSharedRearCenterSpeakers() {
        let renderer = FeyStaticBedRenderer()
        let output = renderer.render(inputFrame: [0, 0, 1, 1], mode: .quad)

        for speakerId in [9, 20, 26] {
            XCTAssertGreaterThan(output[FeyStaticBedRenderer.speakerOutputIndex(speakerId)], 0)
        }
    }

    func testStereoLeftMostlyUsesFLWithSmallRearFill() {
        let renderer = FeyStaticBedRenderer()
        let output = renderer.render(inputFrame: [1, 0], mode: .stereo)
        let flEnergy = energy(output, speakerIDs: [5, 6, 11, 17, 22, 28])
        let rlEnergy = energy(output, speakerIDs: [4, 10, 15, 16, 21, 27])
        let frEnergy = energy(output, speakerIDs: [2, 7, 13, 18, 24, 29])

        XCTAssertGreaterThan(flEnergy, rlEnergy)
        XCTAssertGreaterThan(rlEnergy, 0)
        XCTAssertGreaterThan(flEnergy, frEnergy)
        XCTAssertEqual(output[30], 0, accuracy: Float(tolerance))
    }

    func testStereoRightMostlyUsesFRWithSmallRearFill() {
        let renderer = FeyStaticBedRenderer()
        let output = renderer.render(inputFrame: [0, 1], mode: .stereo)
        let frEnergy = energy(output, speakerIDs: [2, 7, 13, 18, 24, 29])
        let rrEnergy = energy(output, speakerIDs: [3, 8, 14, 19, 25, 30])
        let flEnergy = energy(output, speakerIDs: [5, 6, 11, 17, 22, 28])

        XCTAssertGreaterThan(frEnergy, rrEnergy)
        XCTAssertGreaterThan(rrEnergy, 0)
        XCTAssertGreaterThan(frEnergy, flEnergy)
        XCTAssertEqual(output[30], 0, accuracy: Float(tolerance))
    }

    func testBinauralLeftMapsToWestHemisphereForSonicSphereRenderer() {
        let renderer = FeyStaticBedRenderer()
        let output = renderer.render(inputFrame: [1, 0], mode: .binaural)
        let westEnergy = energy(output, speakerIDs: [4, 5, 6, 10, 11, 15, 16, 17, 21, 22, 27, 28])
        let eastEnergy = energy(output, speakerIDs: [2, 3, 7, 8, 13, 14, 18, 19, 24, 25, 29, 30])

        XCTAssertGreaterThan(westEnergy, eastEnergy)
        XCTAssertGreaterThan(westEnergy, 0)
        XCTAssertEqual(output[30], 0, accuracy: Float(tolerance))
    }

    func testBinauralRightMapsToEastHemisphereForSonicSphereRenderer() {
        let renderer = FeyStaticBedRenderer()
        let output = renderer.render(inputFrame: [0, 1], mode: .binaural)
        let westEnergy = energy(output, speakerIDs: [4, 5, 6, 10, 11, 15, 16, 17, 21, 22, 27, 28])
        let eastEnergy = energy(output, speakerIDs: [2, 3, 7, 8, 13, 14, 18, 19, 24, 25, 29, 30])

        XCTAssertGreaterThan(eastEnergy, westEnergy)
        XCTAssertGreaterThan(eastEnergy, 0)
        XCTAssertEqual(output[30], 0, accuracy: Float(tolerance))
    }

    func testMonoImpulseHitsAllSpeakersUniformly() {
        let renderer = FeyStaticBedRenderer()
        let output = renderer.render(inputFrame: [1], mode: .mono)
        XCTAssertEqual(output.prefix(30).filter { $0 > 0 }.count, 30)
        let firstFullRange = output[0]
        for fullRangeOutput in output.prefix(30) {
            XCTAssertEqual(fullRangeOutput, firstFullRange, accuracy: Float(tolerance))
        }
        XCTAssertEqual(output[30], 0, accuracy: Float(tolerance))
    }

    func testManualMonoOverrideAcceptsEveryMusicSourceWidth() {
        for channelCount in [1, 2, 6, 8, 12, 30, 31] {
            let scene = RendererMatrixBuilder.sceneModel(
                for: SurroundLayoutDetector.fallbackLayout(for: channelCount),
                preset: .sonicSphere30Point1,
                renderMode: .mono
            )

            XCTAssertEqual(scene.renderMode, .mono, "\(channelCount) channels")
            XCTAssertEqual(scene.matrix.inputCount, channelCount, "\(channelCount) channels")
            XCTAssertEqual(scene.matrix.outputCount, 31, "\(channelCount) channels")
            XCTAssertTrue(scene.validationMessages.isEmpty, "\(channelCount) channels")
            XCTAssertTrue(scene.matrix.outputMajorGains[30].allSatisfy { abs($0) < tolerance }, "\(channelCount) channels")

            let output0 = scene.matrix.gains[0][0]
            for inputIndex in 0..<channelCount {
                XCTAssertEqual(scene.matrix.gains[inputIndex][0], output0, accuracy: tolerance, "\(channelCount) channels")
                XCTAssertEqual(scene.matrix.gains[inputIndex][29], output0, accuracy: tolerance, "\(channelCount) channels")
                XCTAssertEqual(scene.matrix.gains[inputIndex][30], 0, accuracy: tolerance, "\(channelCount) channels")
            }
        }
    }

    func testMonoMatrixAveragesInputsBeforeUniformFanout() {
        let scene = RendererMatrixBuilder.sceneModel(
            for: SurroundLayoutDetector.fallbackLayout(for: 6),
            preset: .sonicSphere30Point1,
            renderMode: .mono
        )
        let singleInputScene = RendererMatrixBuilder.sceneModel(
            for: SurroundLayoutDetector.fallbackLayout(for: 1),
            preset: .sonicSphere30Point1,
            renderMode: .mono
        )

        XCTAssertEqual(scene.matrix.gains[0][0], singleInputScene.matrix.gains[0][0] / 6, accuracy: tolerance)

        let inputChannels = (0..<6).map { index in
            [Float(index + 1)]
        }
        let output = SonicSphereAudioRenderer.render(inputChannels: inputChannels, matrix: scene.matrix)

        XCTAssertEqual(output.count, 31)
        XCTAssertEqual(output[30][0], 0, accuracy: Float(tolerance))
        for speakerOutput in output.prefix(30) {
            XCTAssertEqual(speakerOutput[0], output[0][0], accuracy: Float(tolerance))
        }
    }

    func testMonitorPreviewLevelsUseMonoRendererMatrix() {
        let monoScene = RendererMatrixBuilder.sceneModel(
            for: SurroundLayoutDetector.fallbackLayout(for: 1),
            preset: .sonicSphere30Point1,
            renderMode: .mono
        )
        let preview = RendererMeterLevelModel.monoPreviewOutputLevels(
            sourceLevels: [0.5, 0.5],
            matrix: monoScene.matrix
        )
        let directMono = RendererMeterLevelModel.outputLevels(
            sourceLevels: [0.5],
            matrix: monoScene.matrix
        )

        XCTAssertEqual(preview.count, 31)
        XCTAssertEqual(preview.prefix(30).filter { $0 > 0 }.count, 30)
        XCTAssertEqual(preview[30], 0, accuracy: Float(tolerance))
        XCTAssertEqual(preview.count, directMono.count)

        for (previewLevel, directLevel) in zip(preview, directMono) {
            XCTAssertEqual(previewLevel, directLevel, accuracy: Float(tolerance))
        }
    }

    func testFiveOneLFEImpulseAppearsOnlyOnSubOutput() {
        let renderer = FeyStaticBedRenderer()
        let output = renderer.render(inputFrame: [0, 0, 0, 1, 0, 0], mode: .surround51)

        XCTAssertEqual(output[0..<30].reduce(0, +), 0, accuracy: Float(tolerance))
        XCTAssertEqual(output[30], 1, accuracy: Float(tolerance))
    }

    func testSceneModelRoutesFiveOneMatrixByDetectedChannelRoles() {
        let layout = SurroundLayout(
            name: "5.1 Surround",
            channels: [
                SurroundChannel(index: 0, role: .frontLeft),
                SurroundChannel(index: 1, role: .center),
                SurroundChannel(index: 2, role: .frontRight),
                SurroundChannel(index: 3, role: .sideLeft),
                SurroundChannel(index: 4, role: .sideRight),
                SurroundChannel(index: 5, role: .lfe)
            ]
        )

        let scene = RendererMatrixBuilder.sceneModel(
            for: layout,
            preset: .sonicSphere30Point1,
            renderMode: .automatic
        )

        XCTAssertEqual(scene.renderMode, .surround51)
        XCTAssertEqual(scene.inputSpeakers.map(\.shortLabel), ["FL", "C", "FR", "SL", "SR", "LFE1"])
        XCTAssertEqual(scene.matrix.lfeInputIndexes, [5])
        XCTAssertEqual(scene.matrix.gains[5][30], 1, accuracy: tolerance)
        XCTAssertEqual(scene.matrix.gains[3][30], 0, accuracy: tolerance)

        let rightSurroundOutput = scene.matrix.gains[4].map(Float.init)
        XCTAssertGreaterThan(energy(rightSurroundOutput, speakerIDs: [3, 8, 14, 19, 25, 30]), 0)
    }

    func testRenderedColumnsArePowerNormalizedBeforeTrim() {
        let renderer = FeyStaticBedRenderer()
        let modes = [
            RendererRenderMode.mono, .stereo, .binaural, .quad, .surround51,
            .auro80, .auro91, .auro101, .auro111714h, .auro111515hT, .auro121, .auro131
        ]
        for mode in modes {
            let matrix = renderer.buildMatrix(mode: mode)
            for inputIndex in 0..<matrix.inputCount {
                if matrix.lfeInputIndexes.contains(inputIndex) {
                    continue
                }

                let power = sqrt(matrix.untrimmedGains[inputIndex].prefix(30).reduce(0) { $0 + $1 * $1 })
                XCTAssertEqual(power, 1.0, accuracy: tolerance, mode.displayName)
                XCTAssertEqual(matrix.outputMajorGains.count, 31, mode.displayName)
                XCTAssertEqual(matrix.outputMajorGains.first?.count, mode.expectedInputCount, mode.displayName)
            }
        }
    }

    func testDirect30BypassesRendererAndLeavesSubSilent() {
        let renderer = FeyStaticBedRenderer()
        var input = Array(repeating: Float(0), count: 30)
        input[12] = 0.75
        let output = renderer.render(inputFrame: input, mode: .direct30)

        XCTAssertEqual(output.count, 31)
        XCTAssertEqual(output[12], 0.75, accuracy: Float(tolerance))
        XCTAssertEqual(output[30], 0, accuracy: Float(tolerance))
        XCTAssertEqual(output.enumerated().filter { $0.offset != 12 && abs($0.element) > 0.000_1 }.count, 0)
    }

    func testDirect31BypassesRendererIncludingLFE() {
        let renderer = FeyStaticBedRenderer()
        var input = Array(repeating: Float(0), count: 31)
        input[30] = 0.5
        let output = renderer.render(inputFrame: input, mode: .direct31)

        XCTAssertEqual(output.count, 31)
        XCTAssertEqual(output[30], 0.5, accuracy: Float(tolerance))
        XCTAssertEqual(output.dropLast().reduce(0, +), 0, accuracy: Float(tolerance))
    }

    func testDirectModesAreUnityBypassWithoutTrim() {
        let renderer = FeyStaticBedRenderer()
        let direct30 = renderer.buildMatrix(mode: .direct30)
        let direct31 = renderer.buildMatrix(mode: .direct31)

        XCTAssertTrue(direct30.isBypass)
        XCTAssertTrue(direct31.isBypass)
        XCTAssertEqual(direct30.gains[0][0], 1, accuracy: tolerance)
        XCTAssertEqual(direct30.gains[0].reduce(0, +), 1, accuracy: tolerance)
        XCTAssertEqual(direct31.gains[30][30], 1, accuracy: tolerance)
    }

    func testSceneModelAutoSelectsRenderedAndBypassModes() {
        XCTAssertEqual(scene(channelCount: 1).renderMode, .mono)
        XCTAssertEqual(scene(channelCount: 2).renderMode, .stereo)
        XCTAssertEqual(scene(channelCount: 4).renderMode, .quad)
        XCTAssertEqual(scene(channelCount: 6).renderMode, .surround51)
        XCTAssertEqual(scene(channelCount: 8).renderMode, .auro80)
        XCTAssertEqual(scene(channelCount: 10).renderMode, .auro91)
        XCTAssertEqual(scene(channelCount: 11).renderMode, .auro101)
        XCTAssertEqual(scene(channelCount: 12).renderMode, .auro111714h)
        XCTAssertEqual(scene(channelCount: 13).renderMode, .auro121)
        XCTAssertEqual(scene(channelCount: 14).renderMode, .auro131)
        XCTAssertEqual(scene(channelCount: 30).renderMode, .direct30)
        XCTAssertEqual(scene(channelCount: 31).renderMode, .direct31)
        XCTAssertTrue(scene(channelCount: 30).matrix.isBypass)
        XCTAssertEqual(scene(channelCount: 30).outputSpeakers.count, 31)
        XCTAssertEqual(scene(channelCount: 31).outputSpeakers.count, 31)
    }

    func testManualOverrideFallsBackToAutomaticWhenInputCountDoesNotMatch() {
        let layout = SurroundLayoutDetector.fallbackLayout(for: 2)
        let scene = RendererMatrixBuilder.sceneModel(
            for: layout,
            preset: .sonicSphere30Point1,
            renderMode: .quad
        )

        XCTAssertEqual(scene.requestedRenderMode, .quad)
        XCTAssertEqual(scene.renderMode, .stereo)
        XCTAssertEqual(scene.matrix.inputCount, 2)
        XCTAssertEqual(scene.matrix.outputCount, 31)
        XCTAssertFalse(scene.validationMessages.isEmpty)
        XCTAssertTrue(scene.validationMessages.contains { $0.contains("Quad unavailable") && $0.contains("Using Stereo") })
    }

    func testRendererModePolicyAlwaysMonoOverridesAutoAndStereoPreference() {
        let mode = RendererModePolicy.effectiveRequestedMode(
            requestedMode: .automatic,
            inputChannelCount: 2,
            alwaysMono: true,
            twoChannelPreference: .stereo
        )

        XCTAssertEqual(mode, .mono)
    }

    func testRendererModePolicyDefaultsTwoChannelSourcesToStereo90() {
        let mode = RendererModePolicy.effectiveRequestedMode(
            requestedMode: .automatic,
            inputChannelCount: 2,
            alwaysMono: false,
            twoChannelPreference: .stereo
        )

        XCTAssertEqual(mode, .stereo)
        XCTAssertEqual(RendererTwoChannelPreference.stereo.displayName, "Stereo 90")
    }

    func testRendererModePolicyCanUseBinaural180ForTwoChannelSources() {
        let mode = RendererModePolicy.effectiveRequestedMode(
            requestedMode: .automatic,
            inputChannelCount: 2,
            alwaysMono: false,
            twoChannelPreference: .binaural
        )

        XCTAssertEqual(mode, .binaural)
        XCTAssertEqual(RendererTwoChannelPreference.binaural.displayName, "Binaural 180")
    }

    func testVerticalBarsStayTallForLowChannelCountsAndCentered() {
        let rect = CGRect(x: 10, y: 20, width: 180, height: 80)
        let frames = VUMeterVerticalBarLayout.frames(count: 2, rect: rect)

        XCTAssertEqual(frames.count, 2)
        XCTAssertLessThanOrEqual(frames[0].width, frames[0].height / 2)
        XCTAssertLessThanOrEqual(frames[1].width, frames[1].height / 2)
        XCTAssertEqual(frames[0].minX - rect.minX, rect.maxX - frames[1].maxX, accuracy: 0.000_1)
    }

    func testVerticalBarsRemainDenseForHighChannelCounts() {
        let rect = CGRect(x: 0, y: 0, width: 320, height: 120)
        let frames = VUMeterVerticalBarLayout.frames(count: 64, rect: rect)

        XCTAssertEqual(frames.count, 64)
        XCTAssertGreaterThanOrEqual(frames.first?.minX ?? -1, rect.minX)
        XCTAssertLessThanOrEqual(frames.last?.maxX ?? .greatestFiniteMagnitude, rect.maxX)
        XCTAssertTrue(frames.allSatisfy { $0.width <= $0.height / 2 })
        XCTAssertTrue(frames.allSatisfy { $0.width >= 1 })
    }

    func testManualAuroTwelveChannelCinemaOverrideIsSelectable() {
        let layout = SurroundLayoutDetector.fallbackLayout(for: 12)
        let scene = RendererMatrixBuilder.sceneModel(
            for: layout,
            preset: .sonicSphere30Point1,
            renderMode: .auro111515hT
        )

        XCTAssertEqual(scene.renderMode, .auro111515hT)
        XCTAssertEqual(scene.matrix.inputCount, 12)
        XCTAssertEqual(scene.inputSpeakers.map(\.shortLabel), ["FL", "FR", "C", "LFE1", "SL", "SR", "TMC", "TFL", "TFC", "TFR", "TRL", "TRR"])
    }

    func testAuroEightPointZeroChannelVectors() {
        let renderer = FeyStaticBedRenderer()
        XCTAssertEqual(renderer.getInputLayout(layoutId: .auro80)?.channelLabels, ["L", "R", "Ls", "Rs", "HL", "HR", "HLs", "HRs"])

        XCTAssertEqual(Set(activeSpeakerIDs(renderer.render(inputFrame: impulseInput(mode: .auro80, inputIndex: 0), mode: .auro80))), Set([5, 6, 11, 17, 22, 28, 1, 12, 23]))
        XCTAssertEqual(Set(activeSpeakerIDs(renderer.render(inputFrame: impulseInput(mode: .auro80, inputIndex: 4), mode: .auro80))), Set([17, 22, 28, 11, 12, 23]))
        XCTAssertEqual(Set(activeSpeakerIDs(renderer.render(inputFrame: impulseInput(mode: .auro80, inputIndex: 6), mode: .auro80))), Set([16, 21, 27, 15, 20, 26]))
    }

    func testAuroNinePointOneLfeAndCenterRouting() {
        let renderer = FeyStaticBedRenderer()
        let lfe = renderer.render(inputFrame: impulseInput(mode: .auro91, inputIndex: 3), mode: .auro91)
        XCTAssertEqual(lfe[0..<30].reduce(0, +), 0, accuracy: Float(tolerance))
        XCTAssertEqual(lfe[30], 1, accuracy: Float(tolerance))

        let center = renderer.render(inputFrame: impulseInput(mode: .auro91, inputIndex: 2), mode: .auro91)
        XCTAssertGreaterThan(center[FeyStaticBedRenderer.speakerOutputIndex(1)], center[FeyStaticBedRenderer.speakerOutputIndex(5)])
        XCTAssertGreaterThan(center[FeyStaticBedRenderer.speakerOutputIndex(12)], center[FeyStaticBedRenderer.speakerOutputIndex(7)])
        XCTAssertGreaterThan(center[FeyStaticBedRenderer.speakerOutputIndex(23)], 0)
    }

    func testAuroTenPointOneTopComesBeforeHeightLeft() {
        let renderer = FeyStaticBedRenderer()
        XCTAssertEqual(renderer.getInputLayout(layoutId: .auro101)?.channelLabels, ["L", "R", "C", "LFE", "Ls", "Rs", "T", "HL", "HR", "HLs", "HRs"])

        let top = renderer.render(inputFrame: impulseInput(mode: .auro101, inputIndex: 6), mode: .auro101)
        XCTAssertEqual(Set(activeSpeakerIDs(top)), Set([21, 22, 23, 24, 25, 26, 27, 28, 29, 30]))

        let heightLeft = renderer.render(inputFrame: impulseInput(mode: .auro101, inputIndex: 7), mode: .auro101)
        XCTAssertGreaterThan(heightLeft[FeyStaticBedRenderer.speakerOutputIndex(22)], 0)
        XCTAssertEqual(heightLeft[FeyStaticBedRenderer.speakerOutputIndex(26)], 0, accuracy: Float(tolerance))
    }

    func testAuroElevenPointOneSevenOnePlacesBacksBeforeSides() {
        let renderer = FeyStaticBedRenderer()
        XCTAssertEqual(renderer.getInputLayout(layoutId: .auro111714h)?.channelLabels, ["L", "R", "C", "LFE", "Lb", "Rb", "Ls", "Rs", "HL", "HR", "HLs", "HRs"])

        let lb = renderer.render(inputFrame: impulseInput(mode: .auro111714h, inputIndex: 4), mode: .auro111714h)
        let rb = renderer.render(inputFrame: impulseInput(mode: .auro111714h, inputIndex: 5), mode: .auro111714h)
        let ls = renderer.render(inputFrame: impulseInput(mode: .auro111714h, inputIndex: 6), mode: .auro111714h)
        let rs = renderer.render(inputFrame: impulseInput(mode: .auro111714h, inputIndex: 7), mode: .auro111714h)

        XCTAssertGreaterThan(energy(lb, speakerIDs: [10, 16, 15]), energy(lb, speakerIDs: [8, 19, 14]))
        XCTAssertGreaterThan(energy(rb, speakerIDs: [8, 19, 14]), energy(rb, speakerIDs: [10, 16, 15]))
        XCTAssertGreaterThan(energy(ls, speakerIDs: [10, 16]), 0)
        XCTAssertGreaterThan(energy(rs, speakerIDs: [8, 19]), 0)
    }

    func testAuroElevenPointOneCinemaTopAndHighCenterOrder() {
        let renderer = FeyStaticBedRenderer()
        XCTAssertEqual(renderer.getInputLayout(layoutId: .auro111515hT)?.channelLabels, ["L", "R", "C", "LFE", "Ls", "Rs", "T", "HL", "HC", "HR", "HLs", "HRs"])

        let top = renderer.render(inputFrame: impulseInput(mode: .auro111515hT, inputIndex: 6), mode: .auro111515hT)
        XCTAssertGreaterThan(top[FeyStaticBedRenderer.speakerOutputIndex(26)], 0)

        let highCenter = renderer.render(inputFrame: impulseInput(mode: .auro111515hT, inputIndex: 8), mode: .auro111515hT)
        XCTAssertGreaterThan(highCenter[FeyStaticBedRenderer.speakerOutputIndex(23)], highCenter[FeyStaticBedRenderer.speakerOutputIndex(17)])
        XCTAssertGreaterThan(highCenter[FeyStaticBedRenderer.speakerOutputIndex(23)], highCenter[FeyStaticBedRenderer.speakerOutputIndex(29)])
    }

    func testAuroTwelvePointOneHasNoTopChannel() {
        let renderer = FeyStaticBedRenderer()
        let labels = renderer.getInputLayout(layoutId: .auro121)?.channelLabels
        XCTAssertEqual(labels, ["L", "R", "C", "LFE", "Lb", "Rb", "Ls", "Rs", "HL", "HC", "HR", "HLs", "HRs"])
        XCTAssertFalse(labels?.contains("T") ?? true)
    }

    func testAuroThirteenPointOneTopPrecedesHeightChannels() {
        let renderer = FeyStaticBedRenderer()
        XCTAssertEqual(renderer.getInputLayout(layoutId: .auro131)?.channelLabels, ["L", "R", "C", "LFE", "Lb", "Rb", "Ls", "Rs", "T", "HL", "HC", "HR", "HLs", "HRs"])

        let top = renderer.render(inputFrame: impulseInput(mode: .auro131, inputIndex: 8), mode: .auro131)
        let heightLeft = renderer.render(inputFrame: impulseInput(mode: .auro131, inputIndex: 9), mode: .auro131)
        XCTAssertGreaterThan(top[FeyStaticBedRenderer.speakerOutputIndex(26)], 0)
        XCTAssertGreaterThan(heightLeft[FeyStaticBedRenderer.speakerOutputIndex(22)], 0)
        XCTAssertEqual(heightLeft[FeyStaticBedRenderer.speakerOutputIndex(26)], 0, accuracy: Float(tolerance))
    }

    func testAuroLobesMirrorAcrossLeftAndRight() {
        let lobes = FeyStaticBedRenderer().getLobes()

        assertMirror(lobes.lLower, lobes.rLower, pairs: [(5, 2), (6, 7), (11, 13), (17, 18), (22, 24), (28, 29), (1, 1), (12, 12), (23, 23)])
        assertMirror(lobes.hl, lobes.hr, pairs: [(17, 18), (22, 24), (28, 29), (11, 13), (12, 12), (23, 23)])
        assertMirror(lobes.hls, lobes.hrs, pairs: [(16, 19), (21, 25), (27, 30), (15, 14), (20, 20), (26, 26)])
        assertMirror(lobes.lbLower, lobes.rbLower, pairs: [(4, 3), (10, 8), (15, 14), (16, 19), (21, 25), (27, 30), (9, 9), (20, 20), (26, 26)])
    }

    func testAuroLayerSeparation() {
        let renderer = FeyStaticBedRenderer()
        let lowerLeft = renderer.render(inputFrame: impulseInput(mode: .auro80, inputIndex: 0), mode: .auro80)
        let heightLeft = renderer.render(inputFrame: impulseInput(mode: .auro80, inputIndex: 4), mode: .auro80)
        let top = renderer.render(inputFrame: impulseInput(mode: .auro101, inputIndex: 6), mode: .auro101)

        XCTAssertLessThan(energy(lowerLeft, speakerIDs: [26, 27, 28, 29, 30]), energy(lowerLeft, speakerIDs: [5, 6, 11, 17]) * 0.12)
        XCTAssertEqual(energy(heightLeft, speakerIDs: [1, 2, 3, 4, 5]), 0, accuracy: Float(tolerance))
        XCTAssertEqual(energy(top, speakerIDs: [1, 2, 3, 4, 5]), 0, accuracy: Float(tolerance))
    }

    func testPresetStoreRoundTripsFeyRendererJSONAndIgnoresLegacyPreset() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("orbisonic-renderer-tests-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let store = RendererPresetStore(directoryURL: directory)
        var preset = RendererPreset.sonicSphere30Point1
        preset.id = "custom-fey"
        preset.name = "Custom FEY"
        preset.options.stereoRearFill = 0.2

        let url = try store.save(preset)
        let data = try Data(contentsOf: url)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("\"schemaVersion\" : 3"))
        XCTAssertTrue(json.contains("\"stereoRearFill\" : 0.2"))
        XCTAssertTrue(json.contains("\"heightUpperBiasDbPerUnitZ\" : 1.5"))

        let schemaTwoURL = directory.appendingPathComponent("schema-2-renderer.json")
        try #"{"schemaVersion":2,"id":"schema-2","name":"Schema 2","description":"Old FEY","outputTopology":{"kind":"sonicSphere","fullRangeCount":30,"lfeCount":1},"options":{"coreGain":1,"seamSupportGain":0.55,"upperBiasDbPerUnitZ":2,"stereoRearFill":0.18,"centerSideSupportGain":0.35,"adjacentBleed":0.03,"maxSingleSpeakerPowerShare":0.22,"renderedOutputTrimDb":-4,"directOutputTrimDb":0,"fiveOneChannelOrder":"L R C LFE Ls Rs"}}"#
            .write(to: schemaTwoURL, atomically: true, encoding: .utf8)

        let legacyURL = directory.appendingPathComponent("legacy-renderer.json")
        try #"{"schemaVersion":1,"id":"legacy","name":"Legacy","description":"Old","outputTopology":{"kind":"sonicSphere","fullRangeCount":30,"lfeCount":1,"placement":"fibonacciSphere"},"inputGeometry":{"bedRadius":1.2,"overheadRadiusScale":1},"rendering":{"algorithm":"distanceWeightedPower","spread":1,"normalizePower":true,"lfePolicy":"lfeBusOnly"}}"#
            .write(to: legacyURL, atomically: true, encoding: .utf8)

        let loaded = try store.loadPresets()
        XCTAssertTrue(loaded.contains(where: { $0.id == "custom-fey" && $0.options.stereoRearFill == 0.2 }))
        XCTAssertTrue(loaded.contains(where: { $0.id == "schema-2" && $0.schemaVersion == 3 && $0.options.renderedMainTrimDb == -4 }))
        XCTAssertFalse(loaded.contains(where: { $0.id == "legacy" }))
    }

    func testSceneModelMapsOversizedSourceToFirst31Passthrough() {
        let scene = RendererMatrixBuilder.sceneModel(
            for: SurroundLayoutDetector.fallbackLayout(for: 52),
            preset: .sonicSphere30Point1,
            renderMode: .automatic
        )

        // Renderer must engage at the source width (not collapse to a stereo monitor).
        XCTAssertEqual(scene.renderMode, .directPassthrough)
        XCTAssertEqual(scene.matrix.inputCount, 52)
        XCTAssertEqual(scene.matrix.outputCount, 31)
        XCTAssertTrue(scene.matrix.isBypass)
        XCTAssertTrue(scene.validationMessages.isEmpty)

        // First 31 source channels map 1:1; channels beyond 31 are dropped.
        for inputIndex in 0..<52 {
            for outputIndex in 0..<31 {
                let expected = inputIndex == outputIndex ? 1.0 : 0.0
                XCTAssertEqual(
                    scene.matrix.gains[inputIndex][outputIndex], expected, accuracy: tolerance,
                    "in \(inputIndex) out \(outputIndex)"
                )
            }
        }

        // The 31st source channel feeds the LFE/sub output.
        XCTAssertTrue(scene.matrix.lfeInputIndexes.contains(FeyStaticBedRenderer.subOutputIndex))
    }

    func testSceneModelMapsUndersizedUnsupportedSourceToAvailableChannels() {
        // 16 channels is not a named bed layout; map all 16 to the first 16 outputs, no LFE.
        let scene = RendererMatrixBuilder.sceneModel(
            for: SurroundLayoutDetector.fallbackLayout(for: 16),
            preset: .sonicSphere30Point1,
            renderMode: .automatic
        )

        XCTAssertEqual(scene.renderMode, .directPassthrough)
        XCTAssertEqual(scene.matrix.inputCount, 16)
        XCTAssertEqual(scene.matrix.outputCount, 31)
        XCTAssertTrue(scene.matrix.isBypass)
        XCTAssertTrue(scene.matrix.lfeInputIndexes.isEmpty)
        for inputIndex in 0..<16 {
            XCTAssertEqual(scene.matrix.gains[inputIndex][inputIndex], 1.0, accuracy: tolerance)
        }
    }

    private func scene(channelCount: Int) -> RendererSceneModel {
        RendererMatrixBuilder.sceneModel(
            for: SurroundLayoutDetector.fallbackLayout(for: channelCount),
            preset: .sonicSphere30Point1,
            renderMode: .automatic
        )
    }

    private var rendererModesIncludingDirectBypass: [RendererRenderMode] {
        [
            .automatic,
            .mono,
            .stereo,
            .quad,
            .surround51,
            .auro80,
            .auro91,
            .auro101,
            .auro111714h,
            .auro111515hT,
            .auro121,
            .auro131,
            .direct30,
            .direct31
        ]
    }

    private var rendererCapableRoute: OutputRouteInfo {
        OutputRouteInfo(
            deviceID: AudioDeviceID(64),
            uid: "dante-vsc",
            deviceName: "Dante Virtual Soundcard",
            manufacturer: "Audinate",
            transportName: "Virtual",
            outputChannelCount: 64,
            nominalSampleRate: 48_000
        )
    }

    private func impulseInput(mode: RendererRenderMode, inputIndex: Int) -> [Float] {
        var input = Array(repeating: Float(0), count: mode.expectedInputCount ?? 0)
        input[inputIndex] = 1
        return input
    }

    private func activeSpeakerIDs(_ output: [Float]) -> [Int] {
        output.prefix(30).enumerated().compactMap { index, value in
            abs(value) > 0.000_1 ? index + 1 : nil
        }
    }

    private func energy(_ output: [Float], speakerIDs: [Int]) -> Float {
        speakerIDs.reduce(Float(0)) { partial, speakerId in
            let gain = output[FeyStaticBedRenderer.speakerOutputIndex(speakerId)]
            return partial + gain * gain
        }
    }

    private func assertMirror(
        _ left: [Double],
        _ right: [Double],
        pairs: [(leftSpeaker: Int, rightSpeaker: Int)],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for pair in pairs {
            let leftGain = left[FeyStaticBedRenderer.speakerOutputIndex(pair.leftSpeaker)]
            let rightGain = right[FeyStaticBedRenderer.speakerOutputIndex(pair.rightSpeaker)]
            XCTAssertEqual(leftGain, rightGain, accuracy: 0.03, "Speaker \(pair.leftSpeaker) / \(pair.rightSpeaker)", file: file, line: line)
        }
    }
}
