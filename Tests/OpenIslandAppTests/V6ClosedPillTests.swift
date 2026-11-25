import Testing
@testable import OpenIslandApp

struct V6ClosedPillTests {
    @Test
    @MainActor
    func reportsRenderedWidthForPanelMorphing() {
        let macbookPill = V6ClosedPill(
            mode: .idle,
            label: nil,
            rightSlot: nil,
            layout: .macbook,
            height: 32,
            physicalNotchWidth: 224
        )
        let externalPill = V6ClosedPill(
            mode: .idle,
            label: nil,
            rightSlot: nil,
            layout: .external,
            height: 32
        )

        #expect(macbookPill.resolvedWidth == 312)
        #expect(externalPill.resolvedWidth == 70)
    }
    @Test
    @MainActor
    func quietClosedSurfaceKeepsNotchWidthRegardlessOfActivityPayload() {
        let pill = V6ClosedPill(mode: .running, label: "Working", rightSlot: .count(99), layout: .macbook,
                                height: 32, physicalNotchWidth: 224, showsActivity: false)
        #expect(pill.resolvedWidth == 224)
        let external = V6ClosedPill(mode: .waiting, label: "Needs attention", rightSlot: .count(99), layout: .external,
                                    showsActivity: false)
        #expect(external.resolvedWidth == 70)
    }

}
