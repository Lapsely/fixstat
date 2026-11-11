import Testing
@testable import FixStatCore

@Suite struct NotebookBodyTests {
    typealias Body = NotebookSideScene.Body

    @Test func bodies() {
        #expect(Body.of(marketingName: "MacBook Pro (16-inch, 2019)", model: "MacBookPro16,1") == .classic16)
        #expect(Body.of(marketingName: "MacBook Pro (15-inch, 2018)", model: "MacBookPro15,1") == .classic15)
        #expect(Body.of(marketingName: "MacBook Pro (13-inch, 2020, Four Thunderbolt 3 ports)", model: "MacBookPro16,2") == .classic13)
        #expect(Body.of(marketingName: "MacBook Pro (16-inch, 2021)", model: "MacBookPro18,1") == .pro16)
        #expect(Body.of(marketingName: "MacBook Pro (14-inch, M3, Nov 2023)", model: "Mac15,3") == .pro14)
        #expect(Body.of(marketingName: "MacBook Pro (16-inch, Nov 2024)", model: "Mac16,5") == .pro16)
        #expect(Body.of(marketingName: "MacBook Air (15-inch, M3, 2024)", model: "Mac15,13") == .air15)
        #expect(Body.of(marketingName: nil, model: "Mac14,2") == .air13)
    }
}
