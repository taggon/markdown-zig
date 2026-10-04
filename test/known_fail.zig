//! Known-fail allowlist for the CommonMark 0.31.2 fixtures.
//! Empty: every example passes. An entry here is a promise to come back, and
//! `unexpected_pass` is a build failure, so anything fixed leaves immediately
//! (SPEC §16.1).
pub const commonmark: []const usize = &.{};
