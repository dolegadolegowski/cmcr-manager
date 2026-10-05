import Foundation
import Testing
@testable import CMCRManager
@testable import CMCRCore

@MainActor @Test func appModuleLoads() {
    #expect(AppModel.retryTitle("x") == "x (ponowienie)")
}
