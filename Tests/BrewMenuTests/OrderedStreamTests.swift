import Testing
import Foundation
@testable import BrewMenu

@Suite("OrderedStream — orden de la salida de brew")
@MainActor
struct OrderedStreamTests {
    // Regression: one Task per streamed line had no ordering guarantee, so brew's output
    // could reach the log out of order.
    @Test("los valores llegan al MainActor en el mismo orden en que se enviaron")
    func valuesArriveInSendOrder() async throws {
        var received: [Int] = []
        let stream = makeOrderedStream { (value: Int) in received.append(value) }

        let producer = Task.detached {
            for value in 0..<1000 { stream.send(value) }
        }
        await producer.value
        stream.finish()
        try await waitUntil { received.count == 1000 }

        #expect(received == Array(0..<1000))
    }
}
