#!/bin/sh
# A status outside 200 to 599 is not an answer: 502.
printf 'Status: 99999 nope\nContent-Type: text/plain\n\nnope\n'
