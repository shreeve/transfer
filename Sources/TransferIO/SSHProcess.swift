import TransferCore

/// The process boundary. Views never start `ssh`.
enum SSHProcess {
    static let roles = ChannelRole.allCases
}
