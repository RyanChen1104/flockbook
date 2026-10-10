use std::fmt;

#[derive(Debug)]
pub enum HerdrError {
    Socket(String),
    Server { code: String, message: String },
    Protocol(String),
    Closed,
}

impl fmt::Display for HerdrError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            HerdrError::Socket(m) => write!(f, "socket: {m}"),
            HerdrError::Server { code, message } => write!(f, "server error {code}: {message}"),
            HerdrError::Protocol(m) => write!(f, "protocol: {m}"),
            HerdrError::Closed => write!(f, "connection closed"),
        }
    }
}

impl std::error::Error for HerdrError {}
