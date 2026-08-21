#pragma once

#include "datatypes.h"

// UTF-8 codec shared by every String primitive that needs codepoint- (not
// byte-) indexed semantics, matching Idris2's own Chez backend (Scheme
// strings are Unicode-scalar sequences by spec, unlike upstream RefC's own
// byte-wise treatment). Every function here is bounds-checked against an
// explicit byte length -- never trusts NUL-termination alone -- so a
// malformed or truncated sequence can't read past the buffer regardless of
// what its own leading byte claims.

#define IDRIS2RC2_UTF8_REPLACEMENT 0xFFFDu

// Decodes the codepoint starting at byte offset `offset` (must be a valid
// character boundary, e.g. as returned by idris2rc2_utf8ByteOffsetOfChar).
// *consumed is set to the number of bytes read: 1..4 for a well-formed
// sequence, or 1 for an invalid lead byte / a sequence truncated by
// byteLen, decoding to U+FFFD per Unicode's own replacement-character
// convention -- consumed staying 1 in that case keeps a scanning caller
// always making forward progress.
uint32_t idris2rc2_utf8DecodeAt(char const *s, size_t byteLen, size_t offset, size_t *consumed);

// Number of codepoints in s[0..byteLen) (each malformed byte counts as one
// U+FFFD "character", consistent with idris2rc2_utf8DecodeAt).
size_t idris2rc2_utf8Length(char const *s, size_t byteLen);

// Byte offset of the charIdx-th codepoint in s[0..byteLen). Returns byteLen
// itself once charIdx reaches or passes the string's own character count,
// so every caller can treat that as "points at an empty remainder" without
// a separate bounds check of its own.
size_t idris2rc2_utf8ByteOffsetOfChar(char const *s, size_t byteLen, size_t charIdx);

// Bytes a valid codepoint (already range-checked, e.g. by
// idris2rc2_charFromCodepoint) needs: 1..4.
int idris2rc2_utf8EncodeLen(uint32_t cp);
// Writes cp's UTF-8 encoding into out (must have room for at least
// idris2rc2_utf8EncodeLen(cp) bytes; no NUL is added). Returns the byte
// count written, same as idris2rc2_utf8EncodeLen(cp).
int idris2rc2_utf8EncodeInto(uint32_t cp, char *out);
