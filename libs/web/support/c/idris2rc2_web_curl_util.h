/* Pairs with src/Network/HTTP/Client/Curl/Raw.idr. */
#ifndef IDRIS2RC2_WEB_CURL_UTIL_H
#define IDRIS2RC2_WEB_CURL_UTIL_H

/* curl_global_init(CURL_GLOBAL_ALL) at most once per process, whichever thread
 * asks first; the others wait for it. Returns its CURLcode (0 on success), the
 * same for every caller. */
int idris2rc2_curl_global_init_once(void);

#endif /* IDRIS2RC2_WEB_CURL_UTIL_H */
