#include <pthread.h>

#include "idris2rc2_rc2base_curl_util.h"

/* Not <curl/curl.h>: rc2base builds without libcurl's headers. This object is
 * only linked into a program that refers to the function, and such a program
 * links libcurl anyway. CURLcode is an int-sized enum; CURL_GLOBAL_ALL is 3. */
extern int curl_global_init(long flags);

static pthread_once_t once = PTHREAD_ONCE_INIT;
static int result;

static void init(void) {
    result = curl_global_init(3);
}

int idris2rc2_curl_global_init_once(void) {
    pthread_once(&once, init);
    return result;
}
