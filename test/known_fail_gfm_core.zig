//! CommonMark core fixture를 `gfm: true`로 돌릴 때의 known-fail.
//! 여기 있는 항목은 전부 **GFM이 의도적으로 다르게 렌더하는 것**이다.
//! 미구현이나 버그로 인한 실패를 여기 넣지 않는다 — 그건 고쳐야 할 대상이다.
pub const gfm_core: []const usize = &.{
    // GFM disallowed raw HTML: <script>/<style>/<textarea>가 &lt;로 필터됨
    170, 171, 172, 173, 178,
    // GFM autolink literal: bare URL/email이 링크가 됨
    602, 608, 611, 612,
    // GFM email postprocess는 escape가 해제된 텍스트 위에서 동작하므로
    // `<foo\+@bar.example.com>`의 `foo+@…`가 링크가 된다.
    // cmark-gfm 0.29.0.gfm.13 실물 출력과 일치함을 확인했다.
    606,
};
