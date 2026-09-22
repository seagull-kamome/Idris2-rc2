#include "idris2rc2_iouring_iouring_util.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <netdb.h>

struct io_uring *idris2rc2_iouring_queue_init(unsigned entries, unsigned flags) {
  struct io_uring *ring = malloc(sizeof(struct io_uring));
  if (!ring) return NULL;
  if (io_uring_queue_init(entries, ring, flags) < 0) {
    free(ring);
    return NULL;
  }
  return ring;
}

void idris2rc2_iouring_queue_exit(struct io_uring *ring) {
  if (!ring) return;
  io_uring_queue_exit(ring);
  free(ring);
}

void *idris2rc2_iouring_make_sockaddr(char const *host, uint16_t port) {
  struct addrinfo hints;
  memset(&hints, 0, sizeof(hints));
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;
  // AI_NUMERICSERV: `service` below is already a decimal port number,
  // never a /etc/services name -- skip that lookup.
  hints.ai_flags = AI_NUMERICSERV;

  char service[6]; // "0".."65535", 5 digits + NUL
  snprintf(service, sizeof(service), "%u", (unsigned)port);

  struct addrinfo *res = NULL;
  if (getaddrinfo(host, service, &hints, &res) != 0 || !res)
    return NULL;

  void *addr = malloc(res->ai_addrlen);
  if (!addr) {
    freeaddrinfo(res);
    return NULL;
  }
  memcpy(addr, res->ai_addr, res->ai_addrlen);
  freeaddrinfo(res);
  return addr;
}
