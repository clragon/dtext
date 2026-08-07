#ifndef DTEXT_ELEMENT_H
#define DTEXT_ELEMENT_H

// The parser's open-element enum, shared by the state machine and the sinks.
// It stays distinct from the AST node tags because the state machine reasons in
// terms of these (dstack_count, dstack_is_open, the leaf/container split) while
// the AST and the sinks speak node types and HTML tags.
//
// BLOCK_H1..BLOCK_H6 must stay consecutive and ordered: header handling derives
// the level as `BLOCK_H1 + (digit - '1')`. Everything below BLOCK_* through the
// inline set relies only on the block/inline grouping, not exact values.
typedef enum element_t {
  DSTACK_EMPTY = 0,
  BLOCK_P,
  BLOCK_QUOTE,
  BLOCK_SECTION,
  BLOCK_SPOILER,
  BLOCK_CODE,
  BLOCK_TABLE,
  BLOCK_THEAD,
  BLOCK_TBODY,
  BLOCK_UL,
  BLOCK_LI,
  BLOCK_TR,
  BLOCK_TH,
  BLOCK_TD,
  BLOCK_H1,
  BLOCK_H2,
  BLOCK_H3,
  BLOCK_H4,
  BLOCK_H5,
  BLOCK_H6,
  INLINE_B,
  INLINE_I,
  INLINE_U,
  INLINE_S,
  INLINE_SUP,
  INLINE_SUB,
  INLINE_COLOR,
  INLINE_SPOILER,
  INLINE_CODE,
} element_t;

// Block elements own their open/close tags and vanish in inline mode; inline
// elements always render. BLOCK_P through BLOCK_H6 are the block range.
inline bool is_block_element(element_t element) {
  return element >= BLOCK_P && element <= BLOCK_H6;
}

#endif
