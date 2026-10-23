#!/bin/sh
printf 'Content-Type: text/plain\n\n'
printf '%s\n' "${PWD##*/}"
