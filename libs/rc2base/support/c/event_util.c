#define _GNU_SOURCE

#include "event_util.h"

#include <errno.h>
#include <fcntl.h>
#include <stddef.h>
#include <sys/epoll.h>
#include <sys/socket.h>

#define IDRIS2RC2_EPOLL_MAX_EVENTS 64

static struct epoll_event idris2rc2_epollEvents[IDRIS2RC2_EPOLL_MAX_EVENTS];

int idris2rc2_epoll_create(void) {
  return epoll_create1(0);
}

static int idris2rc2_epoll_ctl_op(int epfd, int op, int fd, int events) {
  struct epoll_event ev;
  ev.events = (uint32_t)events;
  ev.data.fd = fd;
  return epoll_ctl(epfd, op, fd, &ev);
}

int idris2rc2_epoll_add(int epfd, int fd, int events) {
  return idris2rc2_epoll_ctl_op(epfd, EPOLL_CTL_ADD, fd, events);
}

int idris2rc2_epoll_mod(int epfd, int fd, int events) {
  return idris2rc2_epoll_ctl_op(epfd, EPOLL_CTL_MOD, fd, events);
}

int idris2rc2_epoll_del(int epfd, int fd) {
  return epoll_ctl(epfd, EPOLL_CTL_DEL, fd, NULL);
}

int idris2rc2_epoll_wait(int epfd, int timeout_ms) {
  int n;
  do {
    n = epoll_wait(epfd, idris2rc2_epollEvents, IDRIS2RC2_EPOLL_MAX_EVENTS, timeout_ms);
  } while (n == -1 && errno == EINTR);
  return n;
}

int idris2rc2_epoll_event_fd(int index) {
  return idris2rc2_epollEvents[index].data.fd;
}

int idris2rc2_epoll_event_flags(int index) {
  return (int)idris2rc2_epollEvents[index].events;
}

int idris2rc2_epollin(void) { return EPOLLIN; }
int idris2rc2_epollout(void) { return EPOLLOUT; }
int idris2rc2_epollerr(void) { return EPOLLERR; }
int idris2rc2_epollhup(void) { return EPOLLHUP; }

int idris2rc2_set_nonblocking(int fd) {
  int flags = fcntl(fd, F_GETFL, 0);
  if (flags == -1) return -1;
  return fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

int idris2rc2_set_reuseaddr(int fd) {
  int one = 1;
  return setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
}
