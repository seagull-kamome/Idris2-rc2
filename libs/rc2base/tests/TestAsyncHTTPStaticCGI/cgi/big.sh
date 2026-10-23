#!/bin/sh
printf 'Content-Type: text/plain\n\n'
head -c 100000 /dev/zero | tr '\0' 'x'
