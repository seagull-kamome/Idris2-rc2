#include "net_util.h"

#include <sys/socket.h>

int idris2rc2_buf_send(int fd, void *data, int off, int len) {
  return (int)send(fd, (char *)data + off, (size_t)len, 0);
}

int idris2rc2_buf_recv(int fd, void *data, int off, int len) {
  return (int)recv(fd, (char *)data + off, (size_t)len, 0);
}
