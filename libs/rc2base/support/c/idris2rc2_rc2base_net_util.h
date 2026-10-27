/* Pairs with src/Network/Async.idr. */
#ifndef IDRIS2RC2_RC2BASE_NET_UTIL_H
#define IDRIS2RC2_RC2BASE_NET_UTIL_H

/* The address of the other end of the connected socket `fd`, as text (IPv4 as
 * "192.0.2.1", IPv6 as "::1"), written to `buf` (`len` bytes, 46 are enough).
 * 0 on success; -1 if the socket has no peer, is neither IPv4 nor IPv6, or
 * `len` is too small. */
int idris2rc2_net_peer_name(int fd, char *buf, int len);

#endif /* IDRIS2RC2_RC2BASE_NET_UTIL_H */
