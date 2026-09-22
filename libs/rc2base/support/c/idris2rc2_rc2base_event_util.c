#define _GNU_SOURCE

#include "event_util.h"

#include <errno.h>
#include <fcntl.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/epoll.h>
#include <sys/eventfd.h>
#include <sys/socket.h>
#include <unistd.h>

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

int idris2rc2_eventfd_create(void) {
  return eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
}

int idris2rc2_eventfd_signal(int fd) {
  uint64_t one = 1;
  ssize_t n;
  do {
    n = write(fd, &one, sizeof(one));
  } while (n == -1 && errno == EINTR);
  if (n == -1 && errno == EAGAIN) return 0;
  return n == (ssize_t)sizeof(one) ? 0 : -1;
}

int idris2rc2_eventfd_drain(int fd) {
  uint64_t buf;
  ssize_t n;
  for (;;) {
    n = read(fd, &buf, sizeof(buf));
    if (n == -1) {
      if (errno == EINTR) continue;
      if (errno == EAGAIN) return 0;
      return -1;
    }
  }
}

int idris2rc2_close_fd(int fd) {
  int r;
  do {
    r = close(fd);
  } while (r == -1 && errno == EINTR);
  return r;
}
