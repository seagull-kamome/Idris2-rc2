
#include <stdint.h>

extern uint32_t idris2rc2_System_Random_system_seed[2];
void idris2rc2_System_Random_set_system_seed(uint64_t seed);
uint32_t idris2rc2_System_Random_next_sys();
/* `sv`/`jumpv` are `void*`, not `uint32_t s[2]`/`const uint64_t jump[1]`:
   see xoroshiro64starstar.c's own comment just above
   idris2rc2_System_Random_next for why (in short, Idris's "C:" %foreign
   Buffer -> C convention hands over a flat char*, which won't implicitly
   convert to a typed pointer). */
uint32_t idris2rc2_System_Random_next(void *sv);
void idris2rc2_System_Random_jump_sys();
void idris2rc2_System_Random_jump(void *sv);
void idris2rc2_System_Random_long_jump_sys();
void idris2rc2_System_Random_long_jump(void *sv);
void idris2rc2_System_Random_jump_ce_sys(uint64_t c, uint32_t e);
void idris2rc2_System_Random_jump_ce(void *sv, uint64_t c, uint32_t e);
/* This generator's state is 64 bits (POLY_DEG = 64 in the .c file), so
   the jump distance `n` (conceptually a POLY_WORDS-word little-endian
   bignum in the reference implementation this is ported from) always
   fits in a single 64-bit word -- taken by value here rather than by
   pointer to a POLY_WORDS-sized array (POLY_WORDS itself is only
   defined inside xoroshiro64starstar.c, via f2x.c, so this header
   couldn't reference it and still stand on its own when included
   elsewhere, e.g. by rc2's generated C output). */
void idris2rc2_System_Random_jump_n_sys(uint64_t n);
void idris2rc2_System_Random_jump_n(void *sv, uint64_t n);

