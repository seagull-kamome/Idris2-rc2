/*  Written in 2018 by David Blackman and Sebastiano Vigna (vigna@acm.org)

To the extent possible under law, the author has dedicated all copyright
and related and neighboring rights to this software to the public domain
worldwide.

Permission to use, copy, modify, and/or distribute this software for any
purpose with or without fee is hereby granted.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR
IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE. */

// 2026/08/28 rename functions by Hattori, Hiroki

#include <stdint.h>
// Self-included so the _sys wrappers below (each calling its own
// non-_sys counterpart, defined later in this file) have a prototype in
// scope -- without it, implicit-declaration errors under a strict C
// compiler, since every _sys wrapper is defined before the function it
// calls.
#include "xoroshiro64starstar.h"

/* This is xoroshiro64** 1.0, our 32-bit all-purpose, rock-solid,
   small-state generator. It is extremely fast and it passes all tests we
   are aware of, but its state space is not large enough for any parallel
   application.

   For generating just single-precision (i.e., 32-bit) floating-point
   numbers, xoroshiro64* is even faster.

   The state must be seeded so that it is not everywhere zero. */


static inline uint32_t rotl(const uint32_t x, int k) {
	return (x << k) | (x >> (32 - k));
}


uint32_t idris2rc2_System_Random_system_seed[2];
void idris2rc2_System_Random_set_system_seed(uint64_t seed) {
	idris2rc2_System_Random_system_seed[0] = (uint32_t)seed;
	idris2rc2_System_Random_system_seed[1] = (uint32_t)(seed >> 32);
}


uint32_t idris2rc2_System_Random_next_sys() {
	return idris2rc2_System_Random_next(idris2rc2_System_Random_system_seed);
}

/* Every function below that Idris calls directly takes its state (and,
   for jump_n, its jump-distance array) as `void*` rather than
   `uint32_t s[2]`/`const uint64_t jump[1]`: Idris's own `Buffer` -> C FFI
   convention (the "C:" %foreign tag, Compiler.RC2.EmitUtil's
   `extractValue CLangC CFBuffer`) hands over a flat `char*` into the
   buffer's data, which C won't implicitly convert to a typed pointer
   without a cast -- unlike the reverse direction (any object pointer
   type implicitly converts to `void*`), which is why these same
   functions can still freely pass `s`/`jump` on to each other, and to
   the internal-only helpers below, using their natural typed-pointer
   signatures. */

uint32_t idris2rc2_System_Random_next(void *sv) {
	uint32_t *s = (uint32_t *)sv;
	const uint32_t s0 = s[0];
	uint32_t s1 = s[1];
	const uint32_t result = rotl(s0 * 0x9E3779BB, 5) * 5;

	s1 ^= s0;
	s[0] = rotl(s0, 26) ^ s1 ^ (s1 << 9); // a, b
	s[1] = rotl(s1, 13); // c

	return result;
}


/* This is the jump function for the generator. It is equivalent
   to 2^32 calls to next(); it can be used to generate 2^32
   non-overlapping subsequences for parallel computations. */

void idris2rc2_System_Random_jump_sys() {
	idris2rc2_System_Random_jump(idris2rc2_System_Random_system_seed);
}
void idris2rc2_System_Random_jump(void *sv) {
	uint32_t *s = (uint32_t *)sv;
	static const uint32_t JUMP[] = { 0x77fcd1a0, 0x4cbf99bd };

	uint32_t s0 = 0;
	uint32_t s1 = 0;
	for(int i = 0; i < (int)(sizeof JUMP / sizeof *JUMP); i++)
		for(int b = 0; b < 32; b++) {
			if (JUMP[i] & UINT32_C(1) << b) {
				s0 ^= s[0];
				s1 ^= s[1];
			}
			idris2rc2_System_Random_next(s);
		}

	s[0] = s0;
	s[1] = s1;
}


/* This is the long-jump function for the generator. It is equivalent to
   2^48 calls to next(); it can be used to generate 2^16 starting points,
   from each of which jump() will generate 2^16 non-overlapping
   subsequences for parallel distributed computations. */
void idris2rc2_System_Random_long_jump_sys() {
	idris2rc2_System_Random_long_jump(idris2rc2_System_Random_system_seed);
}
void idris2rc2_System_Random_long_jump(void *sv) {
	uint32_t *s = (uint32_t *)sv;
	static const uint32_t LONG_JUMP[] = { 0x3f1f8b95, 0xb4e7e463 };

	uint32_t s0 = 0;
	uint32_t s1 = 0;
	for(int i = 0; i < (int)(sizeof LONG_JUMP / sizeof *LONG_JUMP); i++)
		for(int b = 0; b < 32; b++) {
			if (LONG_JUMP[i] & UINT32_C(1) << b) {
				s0 ^= s[0];
				s1 ^= s[1];
			}
			idris2rc2_System_Random_next(s);
		}

	s[0] = s0;
	s[1] = s1;
}


/* The following arbitrary-jump function uses a minimal library to compute at
   run time the jump polynomial x^(c * 2^e) mod p(x), where p(x) is the
   characteristic polynomial of the generator; the polynomial is then applied
   to the state with the same accumulate-and-step loop used by jump(). */

#define POLY_DEG 64
static const uint64_t charpoly[] = { 0x053be9da6e2286c1 };
#include "f2x.c"

/* Applies the precomputed jump polynomial poly (= x^n mod charpoly for the
   desired distance n) to the state, using the same accumulate-and-step loop
   as jump(). Shared by jump_ce() and jump_n(). */

static void jump_apply(uint32_t s[2], const uint64_t *const poly) {
	uint32_t s0 = 0;
	uint32_t s1 = 0;
	for(int i = 0; i < POLY_WORDS; i++)
		for(int b = 0; b < 64; b++) {
			if (poly[i] & UINT64_C(1) << b) {
				s0 ^= s[0];
				s1 ^= s[1];
			}
			idris2rc2_System_Random_next(s);
		}

	s[0] = s0;
	s[1] = s1;
}

/* This is the arbitrary-jump function for the generator expressed as c * 2^e.
   It is equivalent to c * 2^e calls to next(); for example, jump_ce(1, 32) is
   equivalent to jump() and jump_ce(1, 48) is equivalent to long_jump().
   Expressing the distance as c * 2^e makes it possible to request both ordinary
   counts (jump_ce(k, 0)) and multiples of power-of-two jumps without handling
   multiple-precision integers. For the jump to be meaningful, c * 2^e should be
   smaller than the period (2^64 - 1). */

void idris2rc2_System_Random_jump_ce_sys(uint64_t c, uint32_t e) {
	idris2rc2_System_Random_jump_ce(idris2rc2_System_Random_system_seed, c, e);
}
void idris2rc2_System_Random_jump_ce(void *sv, uint64_t c, uint32_t e) {
	uint32_t *s = (uint32_t *)sv;
	uint64_t poly[POLY_WORDS];
	f2x_jumppoly_ce(c, e, poly);
	jump_apply(s, poly);
}

/* This is the general arbitrary-jump function for the generator. It is
   equivalent to n calls to next(). Unlike jump_ce(), it can express any
   jump distance. For the jump to be meaningful, n should be smaller
   than the period (2^64 - 1).

   The reference implementation this is ported from expresses n as a
   POLY_WORDS-word little-endian bignum (jump[0] + jump[1] * 2^64 + ...),
   passed by pointer, to support generators with state larger than 64
   bits (POLY_WORDS > 1). This generator's state is exactly 64 bits
   (POLY_DEG = 64 above), so POLY_WORDS is always 1 and n always fits in
   a single uint64_t -- taken by value here instead, which also sidesteps
   needing a second void*-vs-typed-pointer FFI argument like sv's. */
void idris2rc2_System_Random_jump_n_sys(uint64_t n) {
	idris2rc2_System_Random_jump_n(idris2rc2_System_Random_system_seed, n);
}
void idris2rc2_System_Random_jump_n(void *sv, uint64_t n) {
	uint32_t *s = (uint32_t *)sv;
	uint64_t jump[POLY_WORDS] = { n };
	uint64_t poly[POLY_WORDS];
	f2x_jumppoly_n(jump, POLY_WORDS, poly);
	jump_apply(s, poly);
}
