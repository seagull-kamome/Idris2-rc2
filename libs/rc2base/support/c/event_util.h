#ifndef EVENT_UTIL_H
#define EVENT_UTIL_H

int idris2rc2_epoll_create(void);
int idris2rc2_epoll_add(int epfd, int fd, int events);
int idris2rc2_epoll_mod(int epfd, int fd, int events);
int idris2rc2_epoll_del(int epfd, int fd);

// Waits up to timeout_ms (negative = block indefinitely) for events on
// epfd, caching the ready ones internally (capped at
// IDRIS2RC2_EPOLL_MAX_EVENTS -- see event_util.c). Returns the count
// ready (0 on timeout, -1 on error). A signal interruption (EINTR) is
// retried internally, never surfaced to the caller. The cache is a
// single static buffer, so only one epfd's results may be read at a
// time -- fine for this library's one-event-loop-per-process design,
// see Network.HTTP.Server's own doc.
int idris2rc2_epoll_wait(int epfd, int timeout_ms);
int idris2rc2_epoll_event_fd(int index);
int idris2rc2_epoll_event_flags(int index);

int idris2rc2_epollin(void);
int idris2rc2_epollout(void);
int idris2rc2_epollerr(void);
int idris2rc2_epollhup(void);

int idris2rc2_set_nonblocking(int fd);
int idris2rc2_set_reuseaddr(int fd);

#endif
