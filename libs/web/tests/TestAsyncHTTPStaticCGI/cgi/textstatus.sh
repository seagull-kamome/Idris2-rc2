#!/bin/sh
# A status that is not a number is not an answer either: 502.
printf 'Status: abc\nContent-Type: text/plain\n\nnope\n'
