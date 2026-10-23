#!/bin/sh
# Shell built-ins only: the test must not depend on a PATH.
printf 'Content-Type: text/plain\r\nX-Script: env\r\n\r\n'
echo "$REQUEST_METHOD|$SCRIPT_NAME|$PATH_INFO|$QUERY_STRING|$CONTENT_LENGTH|$CONTENT_TYPE|$HTTP_X_TEST|$GATEWAY_INTERFACE|$SERVER_NAME:$SERVER_PORT|$HTTP_PROXY|$PATH|$HTTP_AUTHORIZATION|$HTTP_X_DUP"
IFS= read -r body
printf '%s' "$body"
