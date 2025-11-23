pub const RaftError = error{
    NotLeader,
    TermMismatch,
    UnknownNode,
    LogAppendFailed,
    Timeout,
    AlreadyExists,
    InvalidCommand,
    InternalFailure,
    PeerNotFound,
};
