import Darwin
import Foundation

struct SerialError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Minimal POSIX serial reader: raw 8N1, no flow control, line-delimited output.
final class SerialPort: @unchecked Sendable {
    let path: String
    private let onLine: @Sendable (String) -> Void
    private let onUnexpectedClose: @Sendable (String) -> Void

    // Everything below is only touched on `queue` (or before the read source is resumed).
    private let queue = DispatchQueue(label: "PolyMac.serial")
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private var pending: [UInt8] = []
    private var closedByUser = false

    init(
        path: String,
        onLine: @escaping @Sendable (String) -> Void,
        onUnexpectedClose: @escaping @Sendable (String) -> Void
    ) {
        self.path = path
        self.onLine = onLine
        self.onUnexpectedClose = onUnexpectedClose
    }

    static func availablePorts() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return names
            .filter { $0.hasPrefix("cu.") }
            .map { "/dev/" + $0 }
            .sorted { (looksLikeBoard($0) ? 0 : 1, $0) < (looksLikeBoard($1) ? 0 : 1, $1) }
    }

    /// USB serial names used by genuine Arduinos and the common CH340 / CP210x / FTDI clones.
    static func looksLikeBoard(_ path: String) -> Bool {
        ["usbmodem", "usbserial", "wchusbserial", "SLAB_USBtoUART"].contains { path.contains($0) }
    }

    func open(baud: Int) throws {
        let fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { throw SerialError(message: "Couldn't open \(path): \(Self.lastError())") }

        var options = termios()
        guard tcgetattr(fd, &options) == 0 else {
            let message = Self.lastError()
            Darwin.close(fd)
            throw SerialError(message: "Couldn't read settings for \(path): \(message)")
        }
        cfmakeraw(&options)
        // On Darwin the speed_t constants equal the numeric baud rate.
        cfsetispeed(&options, speed_t(baud))
        cfsetospeed(&options, speed_t(baud))
        options.c_cflag |= tcflag_t(CLOCAL | CREAD)
        options.c_cflag &= ~tcflag_t(CRTSCTS)
        guard tcsetattr(fd, TCSANOW, &options) == 0 else {
            let message = Self.lastError()
            Darwin.close(fd)
            throw SerialError(message: "Couldn't configure \(path) at \(baud) baud: \(message)")
        }
        tcflush(fd, TCIOFLUSH)

        self.fd = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.setCancelHandler { Darwin.close(fd) }
        self.source = source
        source.resume()
    }

    func close() {
        queue.sync {
            closedByUser = true
            source?.cancel()
            source = nil
        }
    }

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 4096)
        let n = read(fd, &chunk, chunk.count)
        if n > 0 {
            consume(chunk[0..<n])
            return
        }
        if n < 0 && (errno == EAGAIN || errno == EINTR) { return }

        // EOF or a hard error: the board was unplugged or reset away from us.
        let reason = n == 0 ? "The device disconnected." : "Read failed: \(Self.lastError())"
        source?.cancel()
        source = nil
        if !closedByUser { onUnexpectedClose(reason) }
    }

    private func consume(_ bytes: ArraySlice<UInt8>) {
        for byte in bytes {
            if byte == UInt8(ascii: "\n") {
                if pending.last == UInt8(ascii: "\r") { pending.removeLast() }
                onLine(String(decoding: pending, as: UTF8.self))
                pending.removeAll(keepingCapacity: true)
            } else if pending.count < 512 {
                pending.append(byte)
            }
        }
    }

    private static func lastError() -> String { String(cString: strerror(errno)) }
}
