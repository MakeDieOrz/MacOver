import Darwin
import Foundation
import Testing

extension PlayToolsGlobalStateScope {
@Suite(.serialized)
final class PTDebugTraceTests {
    deinit {
        pt_debug_trace_reset_for_testing(-1)
    }

    @Test
    func debugTraceDisabledEmitsNothingAndPreservesErrno() {
        var fds: [Int32] = [-1, -1]
        #expect(Darwin.pipe(&fds) == 0)
        defer {
            Darwin.close(fds[0])
            Darwin.close(fds[1])
        }

        pt_debug_trace_reset_for_testing(0)
        pt_debug_trace_set_sink_fd_for_testing(fds[1])

        errno = ENOENT
        pt_debug_trace_emit_cstr("test", "testDisabled", "trace_should_not_appear")
        #expect(errno == ENOENT)

        Darwin.close(fds[1])
        fds[1] = -1

        var buf = [UInt8](repeating: 0, count: 64)
        let n = Darwin.read(fds[0], &buf, buf.count)
        #expect(n == 0)
    }

    @Test
    func debugTraceEnabledFormatsOutputPreservesErrnoAndTruncatesSafely() throws {
        var fds: [Int32] = [-1, -1]
        #expect(Darwin.pipe(&fds) == 0)
        defer {
            if fds[0] >= 0 { Darwin.close(fds[0]) }
            if fds[1] >= 0 { Darwin.close(fds[1]) }
        }

        pt_debug_trace_reset_for_testing(1)
        pt_debug_trace_set_sink_fd_for_testing(fds[1])

        errno = EACCES
        pt_debug_trace_emit_cstr("test", "testEnabled", "short_event")
        #expect(errno == EACCES)

        let hugePayload = String(repeating: "X", count: 2048)
        pt_debug_trace_emit_cstr("test", "testEnabled", hugePayload)

        Darwin.close(fds[1])
        fds[1] = -1

        var collected = Data()
        var chunk = [UInt8](repeating: 0, count: 512)
        while true {
            let n = Darwin.read(fds[0], &chunk, chunk.count)
            if n <= 0 { break }
            collected.append(contentsOf: chunk.prefix(n))
        }

        let text = try #require(String(data: collected, encoding: .utf8))
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 2)
        #expect(lines[0].hasPrefix("[PlayTools] [test]"))
        #expect(lines[0].contains("short_event"))
        #expect(lines[1].hasPrefix("[PlayTools] [test]"))
        #expect(lines[1].utf8.count <= 511)
    }
}
}
