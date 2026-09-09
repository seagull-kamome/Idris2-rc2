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

// A non-blocking eventfd, used by Network.HTTP.Server as a cross-thread
// wakeup: the single-threaded event loop parks in epoll_wait, and any
// other thread makes that call return by writing to this fd. Created
// with EFD_NONBLOCK|EFD_CLOEXEC. Returns the fd, or -1 on failure.
int idris2rc2_eventfd_create(void);

// Wakes the event loop: adds 1 to the eventfd counter. Safe to call
// from any thread. A full counter (EAGAIN) is ignored -- the loop is
// already scheduled to wake. Returns 0 on success, -1 on a real error.
int idris2rc2_eventfd_signal(int fd);

// Clears the eventfd counter (reads until EAGAIN). The loop calls this
// once per wakeup before draining its task queue, so a signal that
// races in during draining re-arms the fd for the next epoll_wait
// rather than being lost.
int idris2rc2_eventfd_drain(int fd);

// close(2) on a raw descriptor (epoll fd, eventfd) that isn't wrapped
// by Network.Socket. EINTR is retried; other errors are returned.
int idris2rc2_close_fd(int fd);

#endif
