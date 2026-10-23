#!/bin/sh
# Ends at once and leaves a child that still holds the output. The answer is not
# complete until the output reaches its end, which waits for the child: 504 after the
# time limit, and the child is killed with the process group then.
(while :; do :; done) &
echo $! > ../build/keepout-child.pid
printf 'Content-Type: text/plain\n\n'
printf 'left a child holding the output\n'
