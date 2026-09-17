||| Bindings to Linux's `io_uring` async I/O interface, via
||| [liburing](https://github.com/axboe/liburing) rather than the raw
||| `io_uring_setup`/`io_uring_enter` syscalls directly. Most of
||| liburing's own API (every `io_uring_prep_*`, `io_uring_get_sqe`,
||| `io_uring_sqe_set_data64`, `io_uring_submit(_and_wait)`,
||| `io_uring_{wait,peek}_cqe`, `io_uring_cqe_get_data64`) is `static
||| inline` in `<liburing.h>` with no linkable symbol of its own --
||| rc2's own code generator already `#include`s every `%foreign`
||| header directly into the *consumer's* own generated `.c` file
||| (never a separate translation unit), so these bind straight onto
||| `liburing.h` with no shim needed at all. This package's own shim
||| (`support/c/iouring_util.c`/`.h`) exists only for what genuinely
||| can't be a bare `%foreign` declaration: `io_uring_queue_init`/
||| `_exit` need a caller-allocated `struct io_uring` (Idris has
||| nowhere to put one), `io_uring_{wait,peek}_cqe` write their result
||| through a `struct io_uring_cqe **` out-parameter (same "nowhere to
||| put the address of a local pointer" problem), and connecting needs
||| a `struct sockaddr` built from a host/port pair (`getaddrinfo`, a
||| real function, not a bare inline wrapper). See `doc/iouring.md` for
||| the full design, scope, and what this package deliberately doesn't
||| cover yet (fixed buffers/files, multishot ops, linked SQEs, poll).
||| Linux only, `--cg rc2` (every `%foreign` binding here is C-only).
module System.IO.Uring

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

import Data.Buffer
import Data.IORef
import System.FFI

-------------------------------------------------------------------------------
-- Raw FFI
-------------------------------------------------------------------------------

data RawURing : Type where [external]
data RawSQE : Type where [external]
data RawCQE : Type where [external]
data RawSockAddr : Type where [external]

%foreign "C:idris2_isNull, libidris2_support, idris_support.h"
prim__isNull : AnyPtr -> PrimIO Int

-- idris2rc2iouring (this package's own shim; ring lifetime, cqe/sockaddr
-- out-param collapsing -- see iouring_util.h)

%foreign "C:idris2rc2_iouring_queue_init, libidris2rc2iouring, iouring_util.h"
prim__queueInit : Bits32 -> Bits32 -> PrimIO AnyPtr
%foreign "C:idris2rc2_iouring_queue_exit, libidris2rc2iouring, iouring_util.h"
prim__queueExit : Ptr RawURing -> PrimIO ()

%foreign "C:idris2rc2_iouring_wait_cqe, libidris2rc2iouring, iouring_util.h"
prim__waitCqe : Ptr RawURing -> PrimIO AnyPtr
%foreign "C:idris2rc2_iouring_peek_cqe, libidris2rc2iouring, iouring_util.h"
prim__peekCqe : Ptr RawURing -> PrimIO AnyPtr
%foreign "C:idris2rc2_iouring_cqe_res, libidris2rc2iouring, iouring_util.h"
prim__cqeRes : Ptr RawCQE -> PrimIO Int
%foreign "C:idris2rc2_iouring_cqe_user_data, libidris2rc2iouring, iouring_util.h"
prim__cqeUserData : Ptr RawCQE -> PrimIO Bits64
%foreign "C:idris2rc2_iouring_cqe_flags, libidris2rc2iouring, iouring_util.h"
prim__cqeFlags : Ptr RawCQE -> PrimIO Bits32

%foreign "C:idris2rc2_iouring_prep_accept_simple, libidris2rc2iouring, iouring_util.h"
prim__prepAcceptSimple : Ptr RawSQE -> Int -> Int -> PrimIO ()

%foreign "C:idris2rc2_iouring_make_sockaddr, libidris2rc2iouring, iouring_util.h"
prim__makeSockAddr : String -> Bits16 -> PrimIO AnyPtr
%foreign "C:idris2rc2_iouring_sockaddr_len, libidris2rc2iouring, iouring_util.h"
prim__sockAddrLen : Ptr RawSockAddr -> PrimIO Bits32

-- liburing (always-real symbols: io_uring_queue_init/_exit proper, not
-- called directly here -- see the shim wrappers above)

%foreign "C:io_uring_get_sqe, liburing, liburing.h"
prim__getSqe : Ptr RawURing -> PrimIO AnyPtr
%foreign "C:io_uring_sqe_set_data64, liburing, liburing.h"
prim__sqeSetData64 : Ptr RawSQE -> Bits64 -> PrimIO ()
%foreign "C:io_uring_submit, liburing, liburing.h"
prim__submit : Ptr RawURing -> PrimIO Int
%foreign "C:io_uring_submit_and_wait, liburing, liburing.h"
prim__submitAndWait : Ptr RawURing -> Bits32 -> PrimIO Int
%foreign "C:io_uring_cqe_seen, liburing, liburing.h"
prim__cqeSeen : Ptr RawURing -> Ptr RawCQE -> PrimIO ()

-- `io_uring_prep_*` (all `static inline` in liburing.h -- see this
-- module's own doc comment)

%foreign "C:io_uring_prep_nop, liburing, liburing.h"
prim__prepNop : Ptr RawSQE -> PrimIO ()
%foreign "C:io_uring_prep_read, liburing, liburing.h"
prim__prepRead : Ptr RawSQE -> Int -> Buffer -> Bits32 -> Bits64 -> PrimIO ()
%foreign "C:io_uring_prep_write, liburing, liburing.h"
prim__prepWrite : Ptr RawSQE -> Int -> Buffer -> Bits32 -> Bits64 -> PrimIO ()
%foreign "C:io_uring_prep_openat, liburing, liburing.h"
prim__prepOpenat : Ptr RawSQE -> Int -> String -> Int -> Int -> PrimIO ()
%foreign "C:io_uring_prep_close, liburing, liburing.h"
prim__prepClose : Ptr RawSQE -> Int -> PrimIO ()
%foreign "C:io_uring_prep_fsync, liburing, liburing.h"
prim__prepFsync : Ptr RawSQE -> Int -> Bits32 -> PrimIO ()
%foreign "C:io_uring_prep_connect, liburing, liburing.h"
prim__prepConnect : Ptr RawSQE -> Int -> Ptr RawSockAddr -> Bits32 -> PrimIO ()
%foreign "C:io_uring_prep_send, liburing, liburing.h"
prim__prepSend : Ptr RawSQE -> Int -> Buffer -> Bits64 -> Int -> PrimIO ()
%foreign "C:io_uring_prep_recv, liburing, liburing.h"
prim__prepRecv : Ptr RawSQE -> Int -> Buffer -> Bits64 -> Int -> PrimIO ()

-------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------

||| A live `io_uring` instance. Exactly one submission/completion queue
||| pair, sized by `init`'s own `queueDepth`. Not GC-managed (unlike
||| e.g. `Text.Regex.RE2`'s `Regex`) -- `exit` tears down the ring's own
||| mmap'd memory and must run at a deterministic point, not whenever
||| the GC happens to collect it. Not thread-safe: a single `URing`
||| (and every `SQE` obtained from it) must only ever be used from the
||| thread that created it, per liburing's own documented contract.
|||
||| `pending`/`pendingAddrs` are this record's own answer to a real
||| correctness trap, confirmed *twice* by actual bugs while writing
||| this package (see `doc/iouring.md`'s own "Design choices" section):
||| every `prep*` function that hands the kernel a pointer to read or
||| write *later* -- `prepRead`/`prepWrite`/`prepSend`/`prepRecv`'s own
||| `Buffer`, `prepConnect`'s own `sockaddr` -- only actually gets read
||| once `submit` runs the underlying `io_uring_enter` syscall,
||| arbitrarily long after the `prep*` call itself returns. A `Buffer`
||| argument looks fully consumed to rc2's own ownership analysis the
||| moment the (`void`-returning, entirely opaque to rc2) `prep*` FFI
||| call returns, and gets dropped immediately; `prepConnect`'s own
||| `sockaddr` is plain `malloc`'d memory this package owns outright,
||| with no refcounting at all to protect it if freed too early. `pending`
||| gives every such `Buffer` a second, library-held live reference,
||| `pendingAddrs` holds every such `sockaddr` unfreed, both for exactly
||| as long as this `URing` itself is (freed in a batch whenever this
||| `URing` value itself is -- `exit` -- never reclaimed retail
||| per-completion) -- not maximally precise, but correct, and needs no
||| cooperation from a caller who might forget to keep their own
||| reference alive across the async boundary.
export
record URing where
  constructor MkURing
  ptr : Ptr RawURing
  pending : IORef (List Buffer)
  pendingAddrs : IORef (List AnyPtr)

||| Sets up a new ring with room for at least `queueDepth` in-flight
||| submissions (liburing itself rounds this up to the next power of
||| two). `Nothing` on failure -- e.g. `queueDepth` exceeds
||| `/proc/sys/kernel/io_uring_disabled`'s own limit, or the process is
||| out of locked-memory headroom (`RLIMIT_MEMLOCK`); see `man
||| io_uring_setup` for the full list. No `flags` parameter -- every
||| advanced setup flag (`IORING_SETUP_SQPOLL`, fixed files/buffers,
||| ...) is out of scope for this package's first cut, see
||| `doc/iouring.md`'s own "Scope" section.
export
init : (queueDepth : Nat) -> IO (Maybe URing)
init queueDepth = do
  raw <- primIO (prim__queueInit (cast queueDepth) 0)
  isN <- primIO (prim__isNull raw)
  if isN /= 0
     then pure Nothing
     else do
       pendingRef <- newIORef []
       pendingAddrsRef <- newIORef []
       pure (Just (MkURing (prim__castPtr raw) pendingRef pendingAddrsRef))

||| Tears the ring down. Every `SQE` obtained from it, and every
||| `Completion` not yet consumed, is invalid afterward. Also releases
||| this `URing`'s own held references to every `Buffer` any `prepRead`/
||| `prepWrite`/`prepSend`/`prepRecv` call ever protected (see
||| `URing.pending`'s own doc comment; each individually frees at this
||| point only if nothing else in the caller's own program still
||| references it), and actually `free`s every `sockaddr` any
||| `prepConnect` call ever built.
export
exit : URing -> IO ()
exit r = do
  primIO (prim__queueExit r.ptr)
  writeIORef r.pending []
  addrs <- readIORef r.pendingAddrs
  traverse_ free addrs
  writeIORef r.pendingAddrs []

-------------------------------------------------------------------------------
-- Submission
-------------------------------------------------------------------------------

||| One submission-queue entry, obtained from `getSqe` and filled in by
||| exactly one `prep*` call before the next `submit`. Never reuse an
||| `SQE` across two `prep*` calls or past its own `submit` -- once
||| submitted it belongs to the kernel until its matching `Completion`
||| comes back.
export
record SQE where
  constructor MkSQE
  ptr : Ptr RawSQE

||| Reserves the next free submission-queue slot. `Nothing` if the
||| queue is full -- call `submit` (or `submitAndWait`) to drain it
||| first, then retry.
export
getSqe : URing -> IO (Maybe SQE)
getSqe r = do
  raw <- primIO (prim__getSqe r.ptr)
  isN <- primIO (prim__isNull raw)
  pure $ if isN /= 0 then Nothing else Just (MkSQE (prim__castPtr raw))

||| Tags `sqe` with an arbitrary 64-bit value, returned verbatim in the
||| matching `Completion.userData` -- the usual way to correlate a
||| completion back to whatever it was for (an index into a table of
||| pending requests, a request-specific continuation key, ...). Optional:
||| an untagged `SQE`'s completion just carries `userData = 0`.
export
setUserData : SQE -> Bits64 -> IO ()
setUserData sqe = primIO . prim__sqeSetData64 sqe.ptr

||| A no-op request -- completes immediately with `res = 0`. Mainly
||| useful for exercising the submit/complete round-trip itself (this
||| package's own `tests/TestNop.idr` does exactly that) or as a
||| "wake up the completion side" signal tagged with a known
||| `userData`.
export
prepNop : SQE -> IO ()
prepNop sqe = primIO (prim__prepNop sqe.ptr)

||| `pread`-equivalent: reads up to `nbytes` from `fd` at `fileOffset`
||| into `buf`'s own start (byte 0 -- reading into a sub-range of a
||| larger buffer isn't exposed yet, see `doc/iouring.md`'s "Scope").
||| `nbytes` must not exceed `buf`'s own size. The completion's `res` is
||| the byte count actually read (`0` at EOF), or a negative `-errno`.
||| Takes `ring` (not just `sqe`) to protect `buf` from being freed
||| before the kernel gets to it -- see `URing.pending`'s own doc
||| comment for why that's a real, not hypothetical, concern.
export
prepRead : URing -> SQE -> (fd : Int) -> (buf : Buffer) -> (nbytes : Bits32) -> (fileOffset : Bits64) -> IO ()
prepRead ring sqe fd buf nbytes fileOffset = do
  primIO (prim__prepRead sqe.ptr fd buf nbytes fileOffset)
  modifyIORef ring.pending (buf ::)

||| `pwrite`-equivalent: writes `nbytes` from `buf`'s own start to `fd`
||| at `fileOffset`. The completion's `res` is the byte count actually
||| written, or a negative `-errno`. Takes `ring` for the same reason
||| `prepRead` does.
export
prepWrite : URing -> SQE -> (fd : Int) -> (buf : Buffer) -> (nbytes : Bits32) -> (fileOffset : Bits64) -> IO ()
prepWrite ring sqe fd buf nbytes fileOffset = do
  primIO (prim__prepWrite sqe.ptr fd buf nbytes fileOffset)
  modifyIORef ring.pending (buf ::)

||| `openat`-equivalent, `dirfd = Uring.atFdcwd` for a plain
||| CWD-relative `path` (matches the C `AT_FDCWD` convention -- see
||| that constant's own doc comment). The completion's `res` is the new
||| file descriptor, or a negative `-errno`.
export
prepOpenat : SQE -> (dirfd : Int) -> (path : String) -> (flags : Int) -> (mode : Int) -> IO ()
prepOpenat sqe dirfd path flags mode = primIO (prim__prepOpenat sqe.ptr dirfd path flags mode)

||| Closes `fd`. The completion's `res` is `0` on success, a negative
||| `-errno` otherwise.
export
prepClose : SQE -> (fd : Int) -> IO ()
prepClose sqe fd = primIO (prim__prepClose sqe.ptr fd)

||| `fsync`-equivalent (pass `Uring.fsyncDatasync` for `fdatasync`
||| semantics instead, `0` for a full `fsync`).
export
prepFsync : SQE -> (fd : Int) -> (fsyncFlags : Bits32) -> IO ()
prepFsync sqe fd fsyncFlags = primIO (prim__prepFsync sqe.ptr fd fsyncFlags)

||| Accepts one pending connection on the listening socket `fd` (already
||| `bind`/`listen`ed synchronously, e.g. via upstream `Network.Socket`
||| -- this package only covers the connection-oriented operations
||| liburing itself speeds up, not socket creation/binding). The peer's
||| own address isn't exposed (pass `getpeername` the resulting fd
||| afterward if needed) -- see `iouring_util.h`'s own
||| `idris2rc2_iouring_prep_accept_simple`. The completion's `res` is
||| the new connected socket's file descriptor, or a negative `-errno`.
export
prepAccept : SQE -> (fd : Int) -> (flags : Int) -> IO ()
prepAccept sqe fd flags = primIO (prim__prepAcceptSimple sqe.ptr fd flags)

||| Connects the socket `fd` (already created, e.g. via upstream
||| `Network.Socket.socket`) to `host:port` -- `host` may be a hostname
||| or a numeric IPv4/IPv6 address (resolved via `getaddrinfo`,
||| synchronously, *before* the SQE is even prepared -- name resolution
||| itself doesn't go through the ring). `False` if resolution failed
||| (nothing was prepared -- `sqe` is still free to reuse); the
||| completion's `res` is otherwise `0` on success, a negative `-errno`.
||| Takes `ring`: the built `sockaddr` is only actually read by the
||| kernel once `submit` runs, same timing trap as `prepRead`'s own
||| `buf` (confirmed by a real `-EAFNOSUPPORT` failure from freeing it
||| immediately here instead -- see `URing.pending`'s own doc comment)
||| -- kept alive via `ring.pendingAddrs` until `exit` instead of freed
||| right away.
export
prepConnect : URing -> SQE -> (fd : Int) -> (host : String) -> (port : Bits16) -> IO Bool
prepConnect ring sqe fd host port = do
  raw <- primIO (prim__makeSockAddr host port)
  isN <- primIO (prim__isNull raw)
  if isN /= 0
     then pure False
     else do
       let addr = the (Ptr RawSockAddr) (prim__castPtr raw)
       len <- primIO (prim__sockAddrLen addr)
       primIO (prim__prepConnect sqe.ptr fd addr len)
       modifyIORef ring.pendingAddrs (raw ::)
       pure True

||| Sends `len` bytes from `buf`'s own start on the connected/accepted
||| socket `fd`. The completion's `res` is the byte count actually
||| sent, or a negative `-errno`. Takes `ring` for the same
||| buffer-lifetime reason `prepRead` does.
export
prepSend : URing -> SQE -> (fd : Int) -> (buf : Buffer) -> (len : Bits64) -> (flags : Int) -> IO ()
prepSend ring sqe fd buf len flags = do
  primIO (prim__prepSend sqe.ptr fd buf len flags)
  modifyIORef ring.pending (buf ::)

||| Receives up to `len` bytes into `buf`'s own start from the socket
||| `fd`. The completion's `res` is the byte count actually received
||| (`0` means the peer closed its end), or a negative `-errno`. Takes
||| `ring` for the same buffer-lifetime reason `prepRead` does.
export
prepRecv : URing -> SQE -> (fd : Int) -> (buf : Buffer) -> (len : Bits64) -> (flags : Int) -> IO ()
prepRecv ring sqe fd buf len flags = do
  primIO (prim__prepRecv sqe.ptr fd buf len flags)
  modifyIORef ring.pending (buf ::)

-------------------------------------------------------------------------------
-- Submission / completion
-------------------------------------------------------------------------------

||| Hands every `SQE` prepared since the last `submit`/`submitAndWait`
||| to the kernel. Returns the number actually submitted, or a negative
||| `-errno` (liburing itself already retries the underlying
||| `io_uring_enter` once on `-EINTR`, so a negative result here is a
||| genuine failure, not a spurious signal interruption).
export
submit : URing -> IO Int
submit r = primIO (prim__submit r.ptr)

||| Like `submit`, but additionally blocks until at least `waitNr`
||| completions are ready (`0` behaves exactly like plain `submit`) --
||| one syscall instead of a separate `submit` + `waitCompletion` pair.
export
submitAndWait : URing -> (waitNr : Nat) -> IO Int
submitAndWait r waitNr = primIO (prim__submitAndWait r.ptr (cast waitNr))

||| One finished request: `userData` is whatever `setUserData` tagged
||| its `SQE` with (`0` if untagged), `res` is that operation's own
||| result (positive/zero on success -- a byte count, a new fd, ... --
||| or a negative `-errno` on failure; see each `prep*` function's own
||| doc comment for what `res` means for it), `flags` is liburing's own
||| `IORING_CQE_F_*` bits (`0` for every operation this package exposes
||| so far -- none of them are multishot or use provided buffers).
public export
record Completion where
  constructor MkCompletion
  userData : Bits64
  res : Int
  flags : Bits32

readCompletion : Ptr RawCQE -> IO Completion
readCompletion cqe = do
  ud <- primIO (prim__cqeUserData cqe)
  res <- primIO (prim__cqeRes cqe)
  fl <- primIO (prim__cqeFlags cqe)
  pure (MkCompletion ud res fl)

||| Blocks until at least one completion is ready, consumes exactly
||| one, and returns it -- combines `io_uring_wait_cqe` with the
||| matching `io_uring_cqe_seen` (skipping it is a real bug: the
||| completion-queue slot never gets reclaimed, and the ring
||| eventually wedges once it fills up), so a caller can never forget
||| the second half. `Nothing` on failure (see `man io_uring_enter`'s
||| own `io_uring_wait_cqe` documentation for the ways this can fail --
||| interruption by a signal with no handler installed is the common
||| one).
export
waitCompletion : URing -> IO (Maybe Completion)
waitCompletion r = do
  raw <- primIO (prim__waitCqe r.ptr)
  isN <- primIO (prim__isNull raw)
  if isN /= 0
     then pure Nothing
     else do
       let cqe = the (Ptr RawCQE) (prim__castPtr raw)
       c <- readCompletion cqe
       primIO (prim__cqeSeen r.ptr cqe)
       pure (Just c)

||| Like `waitCompletion`, but returns immediately with `Nothing` if no
||| completion is ready yet, instead of blocking -- the usual way to
||| drain whatever's already finished inside a larger event loop
||| without stalling it.
export
pollCompletion : URing -> IO (Maybe Completion)
pollCompletion r = do
  raw <- primIO (prim__peekCqe r.ptr)
  isN <- primIO (prim__isNull raw)
  if isN /= 0
     then pure Nothing
     else do
       let cqe = the (Ptr RawCQE) (prim__castPtr raw)
       c <- readCompletion cqe
       primIO (prim__cqeSeen r.ptr cqe)
       pure (Just c)

-------------------------------------------------------------------------------
-- Constants
-------------------------------------------------------------------------------

||| `AT_FDCWD` -- pass as `prepOpenat`'s own `dirfd` for a plain
||| CWD-relative path. A fixed glibc/Linux ABI constant (`-100`),
||| stable to hardcode the same way `libs/notcurses`'s own `NCKEY_MOD_*`
||| bits are.
export
atFdcwd : Int
atFdcwd = -100

||| `O_RDONLY`/`O_WRONLY`/`O_RDWR`/`O_CREAT`/`O_TRUNC`/`O_APPEND`, for
||| `prepOpenat`'s own `flags` -- combine with `.|.`
||| (`Data.Bits`). Fixed Linux ABI constants, stable to hardcode.
namespace OpenFlags
  public export
  rdonly, wronly, rdwr, creat, trunc, append : Int
  rdonly = 0x0000
  wronly = 0x0001
  rdwr   = 0x0002
  creat  = 0x0040
  trunc  = 0x0200
  append = 0x0400

||| `fdatasync` instead of a full `fsync`, for `prepFsync`'s own
||| `fsyncFlags` (`IORING_FSYNC_DATASYNC` -- an `io_uring`-specific
||| flag, not the raw `fsync(2)` ABI, but likewise stable to hardcode).
export
fsyncDatasync : Bits32
fsyncDatasync = 1
