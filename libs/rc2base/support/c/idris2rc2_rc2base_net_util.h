#ifndef NET_UTIL_H
#define NET_UTIL_H

// Offset+length socket IO straight into/out of an Idris `Buffer`'s
// bytes, for Network.RC2. The standard `network` package only exposes
// buffer send/recv via `List Bits8` (one cons cell per byte) or via
// `String` (truncates at the first NUL) -- neither is usable for an
// event-driven server moving binary payloads. `data` is the raw byte
// pointer rc2 passes for a generic "C:" %foreign Buffer argument (past
// the size header); `off` is a byte offset into it.

// send(fd, data+off, len, 0). Returns bytes sent (>=0) or -1; on -1,
// classify with System.Errno.getErrno (libidris2_support's idris2_getErrno).
int idris2rc2_buf_send(int fd, void *data, int off, int len);

// recv(fd, data+off, len, 0). Returns bytes read (>=0, 0 = peer closed)
// or -1 (see above re: errno).
int idris2rc2_buf_recv(int fd, void *data, int off, int len);

#endif
