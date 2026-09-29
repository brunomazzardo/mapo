import Testing

@testable import MapoProtocol

@Test func protocolVersionIsOne() {
    #expect(MapoProtocolVersion.current == 1)
}
