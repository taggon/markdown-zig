//! Known-fail allowlist for the MDX fixtures. Empty lists mean every example
//! passes; an entry that starts passing must be removed on the spot
//! (SPEC §16.1).
pub const mdx_expression: []const usize = &.{};

pub const mdx_jsx: []const usize = &.{};

pub const mdx_errors: []const usize = &.{};
