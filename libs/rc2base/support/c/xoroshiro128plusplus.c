/*  Written in 2019 by David Blackman and Sebastiano Vigna (vigna@acm.org)

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

// 2026/08/28 rename functions by Hattori, Hiroki (idris2rc2_System_Random128_*
// prefix -- distinct from xoroshiro64starstar.c's idris2rc2_System_Random_*,
// since both object files link into the same libidris2rc2base.a).

#include <stdint.h>
// Self-included so the _sys wrappers below (each calling its own
// non-_sys counterpart, defined later in this file) have a prototype in
// scope -- without it, implicit-declaration errors under a strict C
// compiler, since every _sys wrapper is defined before the function it
// calls (same reasoning as xoroshiro64starstar.c's own self-include).
#include "xoroshiro128plusplus.h"

/* This is xoroshiro128++ 1.0, one of our all-purpose, rock-solid,
   small-state generators. It is extremely (sub-ns) fast and it passes all
   tests we are aware of, but its state space is large enough only for
   mild parallelism.

   For generating just floating-point numbers, xoroshiro128+ is even
   faster (but it has a very mild bias, see notes in the comments).

   The state must be seeded so that it is not everywhere zero. If you have
   a 64-bit seed, we suggest to seed a splitmix64 generator and use its
   output to fill s. */


static inline uint64_t rotl(const uint64_t x, int k) {
	return (x << k) | (x >> (64 - k));
}


uint64_t idris2rc2_System_Random128_system_seed[2];
void idris2rc2_System_Random128_set_system_seed(uint64_t s0, uint64_t s1) {
	idris2rc2_System_Random128_system_seed[0] = s0;
	idris2rc2_System_Random128_system_seed[1] = s1;
}


uint64_t idris2rc2_System_Random128_next_sys() {
	return idris2rc2_System_Random128_next(idris2rc2_System_Random128_system_seed);
}

/* Every function below that Idris calls directly takes its state (and,
   for jump_n, its jump-distance words) as `void*`/plain `uint64_t`
   rather than `uint64_t s[2]`: Idris's own `Buffer` -> C FFI convention
   (the "C:" %foreign tag, Compiler.RC2.EmitUtil's `extractValue CLangC
   CFBuffer`) hands over a flat `char*` into the buffer's data, which C
   won't implicitly convert to a typed pointer without a cast -- unlike
   the reverse direction (any object pointer type implicitly converts to
   `void*`), which is why these same functions can still freely pass `s`
   on to each other, and to the internal-only helpers below, using their
   natural typed-pointer signatures. */

uint64_t idris2rc2_System_Random128_next(void *sv) {
	uint64_t *s = (uint64_t *)sv;
	const uint64_t s0 = s[0];
	uint64_t s1 = s[1];
	const uint64_t result = rotl(s0 + s1, 17) + s0;

	s1 ^= s0;
	s[0] = rotl(s0, 49) ^ s1 ^ (s1 << 21); // a, b
	s[1] = rotl(s1, 28); // c

	return result;
}


/* This is the jump function for the generator. It is equivalent
   to 2^64 calls to next(); it can be used to generate 2^64
   non-overlapping subsequences for parallel computations. */

void idris2rc2_System_Random128_jump_sys() {
	idris2rc2_System_Random128_jump(idris2rc2_System_Random128_system_seed);
}
void idris2rc2_System_Random128_jump(void *sv) {
	uint64_t *s = (uint64_t *)sv;
	static const uint64_t JUMP[] = { 0x2bd7a6a6e99c2ddc, 0x0992ccaf6a6fca05 };

	uint64_t s0 = 0;
	uint64_t s1 = 0;
	for(int i = 0; i < (int)(sizeof JUMP / sizeof *JUMP); i++)
		for(int b = 0; b < 64; b++) {
			if (JUMP[i] & UINT64_C(1) << b) {
				s0 ^= s[0];
				s1 ^= s[1];
			}
			idris2rc2_System_Random128_next(s);
		}

	s[0] = s0;
	s[1] = s1;
}


/* This is the long-jump function for the generator. It is equivalent to
   2^96 calls to next(); it can be used to generate 2^32 starting points,
   from each of which jump() will generate 2^32 non-overlapping
   subsequences for parallel distributed computations. */

void idris2rc2_System_Random128_long_jump_sys() {
	idris2rc2_System_Random128_long_jump(idris2rc2_System_Random128_system_seed);
}
void idris2rc2_System_Random128_long_jump(void *sv) {
	uint64_t *s = (uint64_t *)sv;
	static const uint64_t LONG_JUMP[] = { 0x360fd5f2cf8d5d99, 0x9c6e6877736c46e3 };

	uint64_t s0 = 0;
	uint64_t s1 = 0;
	for(int i = 0; i < (int)(sizeof LONG_JUMP / sizeof *LONG_JUMP); i++)
		for(int b = 0; b < 64; b++) {
			if (LONG_JUMP[i] & UINT64_C(1) << b) {
				s0 ^= s[0];
				s1 ^= s[1];
			}
			idris2rc2_System_Random128_next(s);
		}

	s[0] = s0;
	s[1] = s1;
}


/* The following arbitrary-jump function uses a minimal library to compute at
   run time the jump polynomial x^(c * 2^e) mod p(x), where p(x) is the
   characteristic polynomial of the generator; the polynomial is then applied
   to the state with the same accumulate-and-step loop used by jump(). */

#define POLY_DEG 128
static const uint64_t charpoly[] = { 0x8dae70779760b081, 0x0031bcf2f855d6e5 };
#include "f2x.c"

/* Applies the precomputed jump polynomial poly (= x^n mod charpoly for the
   desired distance n) to the state, using the same accumulate-and-step loop
   as jump(). Shared by jump_ce() and jump_n(). */

static void jump_apply(uint64_t s[2], const uint64_t *const poly) {
	uint64_t s0 = 0;
	uint64_t s1 = 0;
	for(int i = 0; i < POLY_WORDS; i++)
		for(int b = 0; b < 64; b++) {
			if (poly[i] & UINT64_C(1) << b) {
				s0 ^= s[0];
				s1 ^= s[1];
			}
			idris2rc2_System_Random128_next(s);
		}

	s[0] = s0;
	s[1] = s1;
}

/* This is the arbitrary-jump function for the generator expressed as c * 2^e.
   It is equivalent to c * 2^e calls to next(); for example, jump_ce(1, 64) is
   equivalent to jump() and jump_ce(1, 96) is equivalent to long_jump().
   Expressing the distance as c * 2^e makes it possible to request both ordinary
   counts (jump_ce(k, 0)) and multiples of power-of-two jumps without handling
   multiple-precision integers. For the jump to be meaningful, c * 2^e should be
   smaller than the period (2^128 - 1). */

void idris2rc2_System_Random128_jump_ce_sys(uint64_t c, uint32_t e) {
	idris2rc2_System_Random128_jump_ce(idris2rc2_System_Random128_system_seed, c, e);
}
void idris2rc2_System_Random128_jump_ce(void *sv, uint64_t c, uint32_t e) {
	uint64_t *s = (uint64_t *)sv;
	uint64_t poly[POLY_WORDS];
	f2x_jumppoly_ce(c, e, poly);
	jump_apply(s, poly);
}

/* This is the general arbitrary-jump function for the generator. It is
   equivalent to n calls to next(), where n = jump[0] + jump[1] * 2^64 is
   the little-endian integer held in the two words of jump. Unlike
   jump_ce(), it can express any jump distance. For the jump to be meaningful, n
   should be smaller than the period (2^128 - 1).

   The reference implementation this is ported from expresses n as a
   POLY_WORDS-word little-endian bignum passed by pointer, to support
   generators with arbitrary state size. This generator's state is
   exactly 128 bits (POLY_DEG = 128 above), so POLY_WORDS is always 2 --
   taken as two uint64_t words by value here instead, which also
   sidesteps needing a second void*-vs-typed-pointer FFI argument like
   sv's. */
void idris2rc2_System_Random128_jump_n_sys(uint64_t n0, uint64_t n1) {
	idris2rc2_System_Random128_jump_n(idris2rc2_System_Random128_system_seed, n0, n1);
}
void idris2rc2_System_Random128_jump_n(void *sv, uint64_t n0, uint64_t n1) {
	uint64_t *s = (uint64_t *)sv;
	uint64_t jump[POLY_WORDS] = { n0, n1 };
	uint64_t poly[POLY_WORDS];
	f2x_jumppoly_n(jump, POLY_WORDS, poly);
	jump_apply(s, poly);
}
