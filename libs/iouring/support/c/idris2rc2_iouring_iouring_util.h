#pragma once
// Shim for what liburing's own <liburing.h> genuinely can't give a
// %foreign binding for free -- see ../../doc/iouring.md. Everything
// here is either a real compiled function (iouring_util.c: ring
// init/exit, sockaddr construction) or `static inline` reading a
// struct field liburing.h itself declares but doesn't expose an
// accessor for (cqe->res/user_data/flags, sockaddr->sa_family) --
// these need zero linking, same reasoning as every direct
// liburing.h binding in src/System/IO/Uring.idr.
#include <liburing.h>
#include <stdint.h>
#include <sys/socket.h>
#include <netinet/in.h>

// `struct io_uring` is a real (non-trivial-size) struct io_uring_queue_init
// wants the caller to already own the storage for -- Idris has nowhere
// to put that itself, so this allocates it on the heap and returns the
// pointer (NULL on failure; no separate error code exposed, same
// "Maybe"-shaped contract as every other init function in this repo's
// libs/, e.g. libs/notcurses's own `init`).
struct io_uring *idris2rc2_iouring_queue_init(unsigned entries, unsigned flags);

// Tears the ring down and frees the storage idris2rc2_iouring_queue_init
// allocated.
void idris2rc2_iouring_queue_exit(struct io_uring *ring);

// io_uring_wait_cqe/io_uring_peek_cqe both write their result through
// an out-parameter (`struct io_uring_cqe **`) -- awkward from Idris FFI
// (nowhere to put "the address of a local pointer"). Since a genuinely
// successful call never yields a NULL cqe, collapsing (return code,
// out-param) into a single "NULL means failed" return sidesteps that
// entirely, no shim .o needed (both liburing functions themselves are
// `static inline`).
static inline struct io_uring_cqe *idris2rc2_iouring_wait_cqe(struct io_uring *ring) {
  struct io_uring_cqe *cqe;
  return (io_uring_wait_cqe(ring, &cqe) < 0) ? NULL : cqe;
}
// `io_uring_peek_cqe` returns -EAGAIN (via the same "NULL means
// nothing ready" collapse above) when no completion is available yet --
// System.IO.Uring's own `pollCompletion` surfaces this as `Nothing`,
// indistinguishable here from a genuine error (peeking doesn't fail any
// other way in practice).
static inline struct io_uring_cqe *idris2rc2_iouring_peek_cqe(struct io_uring *ring) {
  struct io_uring_cqe *cqe;
  return (io_uring_peek_cqe(ring, &cqe) < 0) ? NULL : cqe;
}

// `io_uring_prep_accept`'s own `addr`/`addrlen` out-parameters (the
// peer's address) are the same "nowhere to put a local pointer"
// problem as wait_cqe/peek_cqe above -- System.IO.Uring's own `prepAccept`
// doesn't expose the peer address at all (a caller who needs it can
// still call `getpeername` afterward on the resulting fd), so this
// just always passes NULL/NULL.
static inline void idris2rc2_iouring_prep_accept_simple(struct io_uring_sqe *sqe, int fd, int flags) {
  io_uring_prep_accept(sqe, fd, NULL, NULL, flags);
}

// Same NULL/NULL peer-address collapse as idris2rc2_iouring_prep_accept_simple
// above, but arms the SQE to keep generating one CQE per accepted
// connection instead of being consumed by the first one -- see
// System.IO.Uring's own `prepMultishotAccept` doc comment for the
// resulting completion-stream contract (an F_MORE flag on each CQE,
// exposed there as `hasMore`).
static inline void idris2rc2_iouring_prep_multishot_accept_simple(struct io_uring_sqe *sqe, int fd, int flags) {
  io_uring_prep_multishot_accept(sqe, fd, NULL, NULL, flags);
}

// Resolves `host`/`port` (via getaddrinfo, so `host` may be a hostname
// or a numeric address, IPv4 or IPv6) into a malloc'd sockaddr suitable
// for io_uring_prep_connect's own `addr` parameter. NULL on resolution
// failure. Do NOT free this before the matching completion has been
// reaped -- io_uring_prep_connect only *stores* the pointer on the SQE,
// exactly like a read/write's own buffer; the kernel doesn't actually
// read its contents until `submit` runs (confirmed the hard way: an
// earlier version of this comment claimed freeing right after prepping
// was safe, and System.IO.Uring's own `prepConnect` briefly did exactly
// that -- produced a real `-EAFNOSUPPORT` failure every time, from the
// kernel reading already-freed memory as the sockaddr). Free only once
// nothing needs it anymore, with `System.FFI.free` (libc `free`, from
// idris2-src's own base library -- a bare `malloc`'d block needs
// nothing package-specific to release, unlike `idris2rc2_iouring_queue_init`'s
// own `struct io_uring`, which `idris2rc2_iouring_queue_exit` also has
// to unregister from the kernel first) -- System.IO.Uring's own
// `prepConnect` keeps it alive via the owning `URing`'s own
// `pendingAddrs` until `exit` instead of freeing it immediately.
void *idris2rc2_iouring_make_sockaddr(char const *host, uint16_t port);

// `sockaddr`'s own `sa_family` (AF_INET=2/AF_INET6=10 on Linux, stable
// to hardcode the same way libs/notcurses's own NCKEY_MOD_* bits are --
// see System.IO.Uring's own doc comment) tells the Idris side which of
// sockaddr_in/sockaddr_in6 idris2rc2_iouring_make_sockaddr actually
// built, and therefore the addrlen io_uring_prep_connect needs.
static inline int idris2rc2_iouring_sockaddr_family(void *addr) {
  return ((struct sockaddr *)addr)->sa_family;
}
static inline unsigned idris2rc2_iouring_sockaddr_len(void *addr) {
  return idris2rc2_iouring_sockaddr_family(addr) == AF_INET6
    ? (unsigned)sizeof(struct sockaddr_in6) : (unsigned)sizeof(struct sockaddr_in);
}

// io_uring_cqe's own res/user_data/flags fields, same "no accessor of
// its own, just read the struct field liburing.h already declares"
// reasoning as the sockaddr getters above.
static inline int32_t idris2rc2_iouring_cqe_res(struct io_uring_cqe *cqe) { return cqe->res; }
static inline uint64_t idris2rc2_iouring_cqe_user_data(struct io_uring_cqe *cqe) { return io_uring_cqe_get_data64(cqe); }
static inline uint32_t idris2rc2_iouring_cqe_flags(struct io_uring_cqe *cqe) { return cqe->flags; }
