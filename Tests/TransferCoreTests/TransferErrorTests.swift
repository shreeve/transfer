import Testing
import TransferCore

/// What the user reads for an error.
struct TransferErrorTests {
    /// A server's own message already says what went wrong; the label is not said twice, as
    /// "Permission denied: Permission denied" was.
    @Test func aServersMessageIsNotLabeledTwice() {
        #expect(TransferError.permissionDenied("Permission denied").localizedDescription == "Permission denied")
        #expect(TransferError.permissionDenied("").localizedDescription == "Permission denied")
        #expect(TransferError.permissionDenied("notes.txt: Operation not permitted").localizedDescription == "Permission denied: notes.txt: Operation not permitted")
        #expect(TransferError.noSuchFile("No such file").localizedDescription == "No such file")
        #expect(TransferError.noSuchFile("/srv/gone").localizedDescription == "No such file: /srv/gone")
    }
}
