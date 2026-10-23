#!/bin/sh
# Ends at once and leaves a child that has let go of the output: the answer is
# complete, and the child is killed with the process group all the same.
(while :; do :; done) > /dev/null 2>&1 &
echo $! > ../build/orphan-child.pid
printf 'Content-Type: text/plain\n\n'
printf 'left a child\n'
