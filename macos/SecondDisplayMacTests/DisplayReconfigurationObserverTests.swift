import CoreGraphics
import VirtualDisplayCore
import XCTest

final class DisplayReconfigurationObserverTests: XCTestCase {
    func testEventsContainDisplayFlagsKindsAndGeneration() async throws {
        let registrar = FakeReconfigurationRegistrar()
        let observer = try DisplayReconfigurationObserver(generation: 42, registrar: registrar)
        var iterator = observer.events.makeAsyncIterator()

        registrar.emit(displayID: 77, flags: [.addFlag, .setModeFlag])
        let event = await iterator.next()
        XCTAssertEqual(event?.displayID, 77)
        XCTAssertEqual(event?.flags, (CGDisplayChangeSummaryFlags.addFlag.union(.setModeFlag)).rawValue)
        XCTAssertEqual(event?.kinds, [.added, .modeChanged])
        XCTAssertTrue(event?.belongs(to: 42) == true)
        XCTAssertFalse(event?.belongs(to: 41) == true)
        observer.stop()
    }

    func testStopUnregistersAndFinishesStream() async throws {
        let registrar = FakeReconfigurationRegistrar()
        let observer = try DisplayReconfigurationObserver(generation: 1, registrar: registrar)
        var iterator = observer.events.makeAsyncIterator()
        observer.stop()
        observer.stop()
        XCTAssertEqual(registrar.unregisterCount, 1)
        let next = await iterator.next()
        XCTAssertNil(next)
    }

    func testDeinitUnregistersCallback() throws {
        let registrar = FakeReconfigurationRegistrar()
        weak var weakObserver: DisplayReconfigurationObserver?
        do {
            let observer = try DisplayReconfigurationObserver(generation: 1, registrar: registrar)
            weakObserver = observer
        }
        XCTAssertNil(weakObserver)
        XCTAssertEqual(registrar.unregisterCount, 1)
        XCTAssertNil(registrar.handler)
    }
}

private final class FakeReconfigurationRegistrar: DisplayReconfigurationRegistering, @unchecked Sendable {
    private let lock = NSLock()
    var handler: (@Sendable (CGDirectDisplayID, CGDisplayChangeSummaryFlags) -> Void)?
    var unregisterCount = 0

    func register(
        _ handler: @escaping @Sendable (CGDirectDisplayID, CGDisplayChangeSummaryFlags) -> Void
    ) throws -> UInt {
        lock.withLock { self.handler = handler }
        return 1
    }

    func unregister(token: UInt) {
        lock.withLock {
            handler = nil
            unregisterCount += 1
        }
    }

    func emit(displayID: CGDirectDisplayID, flags: CGDisplayChangeSummaryFlags) {
        let callback = lock.withLock { handler }
        callback?(displayID, flags)
    }
}
