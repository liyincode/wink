import XCTest
import Darwin
@testable import ScreenCore

final class AgentControlTests: XCTestCase {
    func testCommandParsingRejectsAmbiguousArguments() {
        for command in [AgentCommand.blackout, .restore, .status] {
            XCTAssertEqual(AgentCommand.parse([command.rawValue]), command)
            XCTAssertEqual(AgentCommand.parse([command.rawValue, "--json"]), command)
        }
        for arguments in [[], ["toggle"], ["status", "blackout"], ["restore", "--json", "extra"], ["--json", "status"]] {
            XCTAssertNil(AgentCommand.parse(arguments))
        }
    }

    func testResponseContractAndNewlineFraming() throws {
        let response = AgentResponse.success(AgentStatus(state: "visible", target: "visible", progress: 0,
                                                        recoveryPending: false, scheduleEnabled: false))
        let data = try response.json()
        XCTAssertEqual(data.last, 10)
        let decoded = try JSONDecoder().decode(AgentResponse.self, from: data)
        XCTAssertEqual(decoded.version, 1)
        XCTAssertTrue(decoded.ok)
        XCTAssertEqual(decoded.status?.state, "visible")
        XCTAssertNil(decoded.error)
        let failure = try JSONDecoder().decode(AgentResponse.self, from: AgentResponse.failure("interrupted", "Retry after status.").json())
        XCTAssertFalse(failure.ok)
        XCTAssertNil(failure.status)
        XCTAssertEqual(failure.error?.code, "interrupted")
    }

    func testTransportSeparatesLinesAndRejectsOversizedInput() throws {
        var sockets: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        defer { for fd in sockets { close(fd) } }
        for fd in sockets { AgentIPC.configure(fd) }
        try AgentIPC.write(Data("\"status\"\n\"restore\"\n".utf8), to: sockets[0])
        XCTAssertEqual(try AgentIPC.readLine(sockets[1]), Data("\"status\"".utf8))
        XCTAssertEqual(try AgentIPC.readLine(sockets[1]), Data("\"restore\"".utf8))
        try AgentIPC.write(Data(repeating: 65, count: 4096), to: sockets[0])
        XCTAssertThrowsError(try AgentIPC.readLine(sockets[1]))
        shutdown(sockets[0], SHUT_WR)
        XCTAssertThrowsError(try AgentIPC.readLine(sockets[1]))
    }

    func testSocketPathLimitIsChecked() throws {
        XCTAssertNoThrow(try AgentIPC.address("/tmp/wink.sock"))
        XCTAssertThrowsError(try AgentIPC.address(String(repeating: "a", count: 200)))
    }
}
