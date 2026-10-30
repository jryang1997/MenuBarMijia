import Testing
import Foundation
@testable import MenuBarMijiaApp

struct SettingsCategoryGeometryTests {
    @Test("The category lens stays within the first and last segments")
    func boundaries() {
        let rail = SettingsCategoryGeometry(width: 640, count: 6)
        #expect(rail.index(at: rail.clampedCenter(-400)) == 0)
        #expect(rail.index(at: rail.clampedCenter(1400)) == 5)
        #expect(rail.clampedCenter(-400) == rail.center(of: 0))
        #expect(rail.clampedCenter(1400) == rail.center(of: 5))
    }

    @Test("The adjacent category is selected only after crossing its midpoint")
    func snapping() {
        for width: CGFloat in [540, 640] {
            let rail = SettingsCategoryGeometry(width: width, count: 6)
            let origin = rail.center(of: 2)
            #expect(rail.index(at: origin + rail.segmentWidth * 0.49) == 2)
            #expect(rail.index(at: origin + rail.segmentWidth * 0.51) == 3)
            #expect(rail.index(at: origin - rail.segmentWidth * 0.51) == 1)
        }
    }
    @Test("A quick release cannot fling the selection past the intended segment")
    func boundedMomentum() {
        let rail = SettingsCategoryGeometry(width: 640, count: 6)
        #expect(rail.destination(from: 0, translation: rail.segmentWidth, predictedTranslation: 900) == 1)
        #expect(rail.destination(from: 5, translation: -rail.segmentWidth, predictedTranslation: -900) == 4)
        #expect(rail.destination(from: 2, translation: rail.segmentWidth * 0.4, predictedTranslation: rail.segmentWidth) == 3)
        #expect(rail.destination(from: 2, translation: 0, predictedTranslation: 0) == 2)
    }

}
