
#include <stdint.h>

extern uint64_t idris2rc2_System_Random128_system_seed[2];
void idris2rc2_System_Random128_set_system_seed(uint64_t s0, uint64_t s1);
uint64_t idris2rc2_System_Random128_next_sys();
/* `sv` is `void*`, not `uint64_t s[2]`: see idris2rc2_rc2base_xoroshiro128plusplus.c's own
   comment just above idris2rc2_System_Random128_next for why (in short,
   Idris's "C:" %foreign Buffer -> C convention hands over a flat char*,
   which won't implicitly convert to a typed pointer). */
uint64_t idris2rc2_System_Random128_next(void *sv);
void idris2rc2_System_Random128_jump_sys();
void idris2rc2_System_Random128_jump(void *sv);
void idris2rc2_System_Random128_long_jump_sys();
void idris2rc2_System_Random128_long_jump(void *sv);
void idris2rc2_System_Random128_jump_ce_sys(uint64_t c, uint32_t e);
void idris2rc2_System_Random128_jump_ce(void *sv, uint64_t c, uint32_t e);
/* This generator's state is 128 bits (POLY_DEG = 128 in the .c file), so
   the jump distance `n` (conceptually a POLY_WORDS-word little-endian
   bignum in the reference implementation this is ported from) always
   fits in exactly two 64-bit words -- taken by value here rather than
   by pointer to a POLY_WORDS-sized array (POLY_WORDS itself is only
   defined inside xoroshiro128plusplus.c, via idris2rc2_rc2base_f2x.c, so this header
   couldn't reference it and still stand on its own when included
   elsewhere, e.g. by rc2's generated C output). */
void idris2rc2_System_Random128_jump_n_sys(uint64_t n0, uint64_t n1);
void idris2rc2_System_Random128_jump_n(void *sv, uint64_t n0, uint64_t n1);
/* Pure counterparts: state by value, one result word per call (see the
   .c file). A pure_jump* function returns the new s[0] and leaves the new
   s[1] for pure_jump_hi(), on the same thread, right after it. */
uint64_t idris2rc2_System_Random128_pure_out(uint64_t s0, uint64_t s1);
uint64_t idris2rc2_System_Random128_pure_s0(uint64_t s0, uint64_t s1);
uint64_t idris2rc2_System_Random128_pure_s1(uint64_t s0, uint64_t s1);
uint64_t idris2rc2_System_Random128_pure_jump(uint64_t s0, uint64_t s1);
uint64_t idris2rc2_System_Random128_pure_long_jump(uint64_t s0, uint64_t s1);
uint64_t idris2rc2_System_Random128_pure_jump_ce(uint64_t s0, uint64_t s1, uint64_t c, uint32_t e);
uint64_t idris2rc2_System_Random128_pure_jump_n(uint64_t s0, uint64_t s1, uint64_t n0, uint64_t n1);
uint64_t idris2rc2_System_Random128_pure_jump_hi(void);
