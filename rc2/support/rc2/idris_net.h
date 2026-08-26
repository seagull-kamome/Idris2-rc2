#pragma once

// System.Socket (network package) support, ported from upstream Idris2's
// support/c/idris_net.c -- Network.FFI's own `%foreign "C:idrnet_socket,
// libidris2_support, idris_net.h"` declarations (untouched, upstream)
// name this exact header, so this file MUST keep upstream's own
// "idris_net.h" filename: `Compiler.RC2.CC`'s own `-I` order puts rc2's
// own support dir ahead of the shared library's, so the generated code's
// `#include <idris_net.h>` resolves here instead of to
// `libidris2_support`'s copy -- a same-named file living in a
// lower-priority `-I` directory is what actually makes this port take
// effect over the shared library's own, not just adding these symbols
// somewhere new. POSIX-only (no Windows fallback, matching every other
// file under rc2/support/rc2/).

#include <netdb.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/un.h>

struct sockaddr_storage;
struct addrinfo;

typedef struct idrnet_recv_result {
  int result;
  void *payload;
} idrnet_recv_result;

// Same shape as idrnet_recv_result, but for UDP, so it also carries the
// remote address the datagram came from.
typedef struct idrnet_recvfrom_result {
  int result;
  void *payload;
  struct sockaddr_storage *remote_addr;
} idrnet_recvfrom_result;

unsigned int idrnet_peek(void *ptr, unsigned int offset);
void idrnet_poke(void *ptr, unsigned int offset, char val);

int idrnet_errno(void);

int idrnet_socket(int domain, int type, int protocol);
int idrnet_close(int fd);

int idrnet_af_unspec(void);
int idrnet_af_unix(void);
int idrnet_af_inet(void);
int idrnet_af_inet6(void);

int idrnet_bind(int sockfd, int family, int socket_type, char *host, int port);
int idrnet_getsockname(int sockfd, void *address, void *len);
int idrnet_connect(int sockfd, int family, int socket_type, char *host,
                    int port);
int idrnet_listen(int socket, int backlog);
FILE *idrnet_fdopen(int fd, const char *mode);

int idrnet_sockaddr_family(void *sockaddr);
char *idrnet_sockaddr_ipv4(void *sockaddr);
int idrnet_sockaddr_ipv4_port(void *sockaddr);
char *idrnet_sockaddr_unix(void *sockaddr);
void *idrnet_create_sockaddr(void);
int idrnet_sockaddr_port(int sockfd);

int idrnet_accept(int sockfd, void *sockaddr);

int idrnet_send(int sockfd, char *data);
int idrnet_send_buf(int sockfd, void *data, int len);
// `flags` is a genuine 4th parameter here (unlike upstream's own 3-param
// idrnet_send_bytes) -- Network.FFI.idr's `prim__idrnet_send_bytes`
// declares 4 args including `flags : Bits32`, which is a hard C
// prototype-mismatch compile error against upstream's own 3-param
// implementation (confirmed identically against real `idris2 --cg
// refc`). Matching the declared arity here, rather than porting the
// mismatch as-is, is what makes `sendBytes` usable at all.
int idrnet_send_bytes(int sockfd, void *data, int len, uint32_t flags);

void *idrnet_recv(int sockfd, int len);
int idrnet_recv_buf(int sockfd, void *buf, int len);
int idrnet_recv_bytes(int sockfd, void *buf, int len, int flags);

int idrnet_sendto(int sockfd, char *data, char *host, int port, int family);
int idrnet_sendto_buf(int sockfd, void *buf, int buf_len, char *host, int port,
                       int family);

void *idrnet_recvfrom(int sockfd, int len);
void *idrnet_recvfrom_buf(int sockfd, void *buf, int len);

int idrnet_get_recv_res(void *res_struct);
char *idrnet_get_recv_payload(void *res_struct);
void idrnet_free_recv_struct(void *res_struct);

int idrnet_get_recvfrom_res(void *res_struct);
char *idrnet_get_recvfrom_payload(void *res_struct);
void *idrnet_get_recvfrom_sockaddr(void *res_struct);
int idrnet_get_recvfrom_port(void *res_struct);
void idrnet_free_recvfrom_struct(void *res_struct);

int idrnet_getaddrinfo(struct addrinfo **address_res, char *host, int port,
                        int family, int socket_type);

int idrnet_geteagain(void);

int isNull(void *ptr);
