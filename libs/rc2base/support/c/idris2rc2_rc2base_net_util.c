#include <stddef.h>

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>

#include "idris2rc2_rc2base_net_util.h"

int idris2rc2_net_peer_name(int fd, char *buf, int len) {
    struct sockaddr_storage ss;
    socklen_t l = sizeof ss;
    if (len <= 0 || getpeername(fd, (struct sockaddr *)&ss, &l) != 0)
        return -1;
    const void *addr;
    if (ss.ss_family == AF_INET)
        addr = &((struct sockaddr_in *)&ss)->sin_addr;
    else if (ss.ss_family == AF_INET6)
        addr = &((struct sockaddr_in6 *)&ss)->sin6_addr;
    else
        return -1;
    return inet_ntop(ss.ss_family, addr, buf, (socklen_t)len) != NULL ? 0 : -1;
}
