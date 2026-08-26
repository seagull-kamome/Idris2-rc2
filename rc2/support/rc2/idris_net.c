// System.Socket (network package) support -- rc2's own port of upstream
// Idris2's support/c/idris_net.c. See idris_net.h's own top-of-file
// comment for why this file must keep upstream's exact filename/symbol
// names. POSIX-only; the original's `_WIN32` branches are dropped
// (matching every other file under rc2/support/rc2/, which assume
// POSIX/Linux throughout).
//
// Two bugs fixed relative to upstream while porting, since rc2 is now
// the one maintaining this code (see TODO.md for the record of both,
// found via rc2's own network smoke test under valgrind):
//   - idrnet_sockaddr_ipv4 used to malloc its returned string and never
//     free it (packCFType's own idris2rc2_mkString always copies the
//     content into a fresh Idris String, so the original buffer was
//     never anyone's responsibility to free) -- now uses a
//     thread-local fixed buffer instead, so there's nothing to leak.
//   - idrnet_bind's own getaddrinfo() result was never freed on any
//     path (upstream even has the call commented out). Fixed to
//     freeaddrinfo() unconditionally once the addrinfo is no longer
//     needed. idrnet_sendto_buf had the same commented-out omission,
//     fixed the same way while porting.
//
// idrnet_send_bytes also gained a genuine 4th `flags` parameter here --
// see idris_net.h's own comment on that one, a compile-error fix, not a
// leak fix.

#include "idris_net.h"

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "util.h"

static void buf_htonl(void *buf, int len) {
  int *buf_i = (int *)buf;
  for (int i = 0; i < (len / (int)sizeof(int)) + 1; i++) {
    buf_i[i] = htonl(buf_i[i]);
  }
}

static void buf_ntohl(void *buf, int len) {
  int *buf_i = (int *)buf;
  for (int i = 0; i < (len / (int)sizeof(int)) + 1; i++) {
    buf_i[i] = ntohl(buf_i[i]);
  }
}

static struct sockaddr_un get_sockaddr_unix(char *host) {
  struct sockaddr_un addr;
  memset(&addr, 0, sizeof(addr));
  addr.sun_family = AF_UNIX;
  strncpy(addr.sun_path, host, sizeof(addr.sun_path) - 1);
  return addr;
}

unsigned int idrnet_peek(void *ptr, unsigned int offset) {
  unsigned char *buf_c = (unsigned char *)ptr;
  return (unsigned int)buf_c[offset];
}

void idrnet_poke(void *ptr, unsigned int offset, char val) {
  char *buf_c = (char *)ptr;
  buf_c[offset] = val;
}

int idrnet_socket(int domain, int type, int protocol) {
  return socket(domain, type, protocol);
}

int idrnet_close(int fd) { return close(fd); }

int idrnet_af_unspec(void) { return AF_UNSPEC; }
int idrnet_af_unix(void) { return AF_UNIX; }
int idrnet_af_inet(void) { return AF_INET; }
int idrnet_af_inet6(void) { return AF_INET6; }

int idrnet_getaddrinfo(struct addrinfo **address_res, char *host, int port,
                        int family, int socket_type) {
  struct addrinfo hints;
  char str_port[8];
  snprintf(str_port, sizeof(str_port), "%d", port);

  memset(&hints, 0, sizeof(hints));
  hints.ai_family = family;
  hints.ai_socktype = socket_type;

  // Idris passed Nothing for the host -- ask the C library to fill the
  // IP in automatically.
  if (strlen(host) == 0) {
    hints.ai_flags = AI_PASSIVE;
    return getaddrinfo(NULL, str_port, &hints, address_res);
  }
  return getaddrinfo(host, str_port, &hints, address_res);
}

int idrnet_bind(int sockfd, int family, int socket_type, char *host, int port) {
  if (family == AF_UNIX) {
    struct sockaddr_un addr = get_sockaddr_unix(host);
    return bind(sockfd, (struct sockaddr *)&addr, sizeof(addr)) == -1 ? -1 : 0;
  }

  struct addrinfo *address_res;
  int addr_res = idrnet_getaddrinfo(&address_res, host, port, family, socket_type);
  if (addr_res != 0) {
    return -1;
  }

  int bind_res = bind(sockfd, address_res->ai_addr, address_res->ai_addrlen);
  freeaddrinfo(address_res);
  return bind_res == -1 ? -1 : 0;
}

int idrnet_getsockname(int sockfd, void *address, void *len) {
  return getsockname(sockfd, address, len) == 0 ? 0 : -1;
}

int idrnet_sockaddr_port(int sockfd) {
  struct sockaddr_storage address;
  socklen_t addrlen = sizeof(struct sockaddr_storage);
  if (getsockname(sockfd, (struct sockaddr *)&address, &addrlen) < 0) {
    return -1;
  }

  switch (address.ss_family) {
  case AF_INET:
    return ntohs(((struct sockaddr_in *)&address)->sin_port);
  case AF_INET6:
    return ntohs(((struct sockaddr_in6 *)&address)->sin6_port);
  default:
    return -1;
  }
}

int idrnet_connect(int sockfd, int family, int socket_type, char *host,
                    int port) {
  if (family == AF_UNIX) {
    struct sockaddr_un addr = get_sockaddr_unix(host);
    return connect(sockfd, (struct sockaddr *)&addr, sizeof(addr));
  }

  struct addrinfo *remote_host;
  int addr_res = idrnet_getaddrinfo(&remote_host, host, port, family, socket_type);
  if (addr_res != 0) {
    return -1;
  }

  int connect_res = connect(sockfd, remote_host->ai_addr, remote_host->ai_addrlen);
  freeaddrinfo(remote_host);
  return connect_res == -1 ? -1 : 0;
}

int idrnet_listen(int socket, int backlog) { return listen(socket, backlog); }

FILE *idrnet_fdopen(int fd, const char *mode) { return fdopen(fd, mode); }

int idrnet_sockaddr_family(void *sockaddr) {
  return (int)((struct sockaddr *)sockaddr)->sa_family;
}

char *idrnet_sockaddr_ipv4(void *sockaddr) {
  // Thread-local, not malloc'd: packCFType's own idris2rc2_mkString
  // always copies this into a fresh Idris String immediately at the
  // call site, so there's nothing for the caller to free -- and
  // nothing here to leak.
  static _Thread_local char ip_addr[INET_ADDRSTRLEN];
  struct sockaddr_in *addr = (struct sockaddr_in *)sockaddr;
  inet_ntop(AF_INET, &(addr->sin_addr), ip_addr, INET_ADDRSTRLEN);
  return ip_addr;
}

int idrnet_sockaddr_ipv4_port(void *sockaddr) {
  return (int)ntohs(((struct sockaddr_in *)sockaddr)->sin_port);
}

char *idrnet_sockaddr_unix(void *sockaddr) {
  return ((struct sockaddr_un *)sockaddr)->sun_path;
}

void *idrnet_create_sockaddr(void) {
  void *sa = malloc(sizeof(struct sockaddr_storage));
  IDRIS2RC2_VERIFY(sa, "malloc failed");
  return sa;
}

int idrnet_accept(int sockfd, void *sockaddr) {
  socklen_t addr_size = sizeof(struct sockaddr_storage);
  return accept(sockfd, (struct sockaddr *)sockaddr, &addr_size);
}

int idrnet_send(int sockfd, char *data) {
  return (int)send(sockfd, (void *)data, strlen(data), 0);
}

int idrnet_send_bytes(int sockfd, void *data, int len, uint32_t flags) {
  return (int)send(sockfd, data, len, (int)flags);
}

int idrnet_send_buf(int sockfd, void *data, int len) {
  void *buf_cpy = malloc(len);
  IDRIS2RC2_VERIFY(buf_cpy, "malloc failed");
  memcpy(buf_cpy, data, len);
  buf_htonl(buf_cpy, len);
  int res = (int)send(sockfd, buf_cpy, len, 0);
  free(buf_cpy);
  return res;
}

void *idrnet_recv(int sockfd, int len) {
  idrnet_recv_result *res_struct = malloc(sizeof(idrnet_recv_result));
  IDRIS2RC2_VERIFY(res_struct, "malloc failed");
  char *buf = malloc(len + 1);
  IDRIS2RC2_VERIFY(buf, "malloc failed");
  memset(buf, 0, len + 1);

  int recv_res = (int)recv(sockfd, buf, len, 0);
  res_struct->result = recv_res;
  if (recv_res > 0) {
    buf[recv_res] = 0x00;
  }
  res_struct->payload = buf;
  return res_struct;
}

int idrnet_recv_bytes(int sockfd, void *buf, int len, int flags) {
  return (int)recv(sockfd, buf, len, flags);
}

int idrnet_recv_buf(int sockfd, void *buf, int len) {
  int recv_res = (int)recv(sockfd, buf, len, 0);
  if (recv_res != -1) {
    buf_ntohl(buf, len);
  }
  return recv_res;
}

int idrnet_get_recv_res(void *res_struct) {
  return ((idrnet_recv_result *)res_struct)->result;
}

char *idrnet_get_recv_payload(void *res_struct) {
  return ((idrnet_recv_result *)res_struct)->payload;
}

void idrnet_free_recv_struct(void *res_struct) {
  idrnet_recv_result *r = (idrnet_recv_result *)res_struct;
  if (r->payload != NULL) {
    free(r->payload);
  }
  free(r);
}

int idrnet_errno(void) { return errno; }

int idrnet_sendto(int sockfd, char *data, char *host, int port, int family) {
  struct addrinfo *remote_host;
  int addr_res = idrnet_getaddrinfo(&remote_host, host, port, family, SOCK_DGRAM);
  if (addr_res != 0) {
    return -1;
  }

  int send_res = (int)sendto(sockfd, data, strlen(data), 0, remote_host->ai_addr,
                              remote_host->ai_addrlen);
  freeaddrinfo(remote_host);
  return send_res;
}

int idrnet_sendto_buf(int sockfd, void *buf, int buf_len, char *host, int port,
                       int family) {
  struct addrinfo *remote_host;
  int addr_res = idrnet_getaddrinfo(&remote_host, host, port, family, SOCK_DGRAM);
  if (addr_res != 0) {
    return -1;
  }

  buf_htonl(buf, buf_len);
  int send_res = (int)sendto(sockfd, buf, buf_len, 0, remote_host->ai_addr,
                              remote_host->ai_addrlen);
  freeaddrinfo(remote_host);
  return send_res;
}

void *idrnet_recvfrom(int sockfd, int len) {
  struct sockaddr_storage *remote_addr = malloc(sizeof(struct sockaddr_storage));
  IDRIS2RC2_VERIFY(remote_addr, "malloc failed");
  char *buf = malloc(len + 1);
  IDRIS2RC2_VERIFY(buf, "malloc failed");
  idrnet_recvfrom_result *ret = malloc(sizeof(idrnet_recvfrom_result));
  IDRIS2RC2_VERIFY(ret, "malloc failed");
  memset(remote_addr, 0, sizeof(struct sockaddr_storage));
  memset(buf, 0, len + 1);
  memset(ret, 0, sizeof(idrnet_recvfrom_result));
  socklen_t fromlen = sizeof(struct sockaddr_storage);

  int recv_res = (int)recvfrom(sockfd, buf, len, 0, (struct sockaddr *)remote_addr,
                                &fromlen);
  ret->result = recv_res;
  if (recv_res == -1) {
    free(buf);
    free(remote_addr);
  } else {
    ret->remote_addr = remote_addr;
    buf[len] = 0x00;
    ret->payload = buf;
  }
  return ret;
}

void *idrnet_recvfrom_buf(int sockfd, void *buf, int len) {
  struct sockaddr_storage *remote_addr = malloc(sizeof(struct sockaddr_storage));
  IDRIS2RC2_VERIFY(remote_addr, "malloc failed");
  idrnet_recvfrom_result *ret = malloc(sizeof(idrnet_recvfrom_result));
  IDRIS2RC2_VERIFY(ret, "malloc failed");
  memset(remote_addr, 0, sizeof(struct sockaddr_storage));
  memset(ret, 0, sizeof(idrnet_recvfrom_result));
  socklen_t fromlen = 0;

  int recv_res = (int)recvfrom(sockfd, buf, len, 0, (struct sockaddr *)remote_addr,
                                &fromlen);
  ret->result = recv_res;
  if (recv_res == -1) {
    free(remote_addr);
  } else if (recv_res > 0) {
    buf_ntohl(buf, len);
    ret->remote_addr = remote_addr;
  } else {
    free(remote_addr);
  }
  return ret;
}

int idrnet_get_recvfrom_res(void *res_struct) {
  return ((idrnet_recvfrom_result *)res_struct)->result;
}

char *idrnet_get_recvfrom_payload(void *res_struct) {
  return ((idrnet_recvfrom_result *)res_struct)->payload;
}

void *idrnet_get_recvfrom_sockaddr(void *res_struct) {
  return ((idrnet_recvfrom_result *)res_struct)->remote_addr;
}

int idrnet_get_recvfrom_port(void *res_struct) {
  idrnet_recvfrom_result *r = (idrnet_recvfrom_result *)res_struct;
  if (r->remote_addr == NULL) {
    return -1;
  }
  return (int)ntohs(((struct sockaddr_in *)r->remote_addr)->sin_port);
}

void idrnet_free_recvfrom_struct(void *res_struct) {
  idrnet_recvfrom_result *r = (idrnet_recvfrom_result *)res_struct;
  if (r == NULL) {
    return;
  }
  if (r->payload != NULL) {
    free(r->payload);
  }
  if (r->remote_addr != NULL) {
    free(r->remote_addr);
  }
  free(r);
}

int idrnet_geteagain(void) { return EAGAIN; }

int isNull(void *ptr) { return ptr == NULL; }
