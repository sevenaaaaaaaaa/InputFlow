//! InputFlow 内核类型契约。零依赖，可被引擎、词典、平台前端独立复用。

pub mod syllables;
pub mod types;
pub mod user;

pub use types::{Candidate, CandidateKind, Composition, Decoder, Mode, Scheme};
pub use user::UserModel;
