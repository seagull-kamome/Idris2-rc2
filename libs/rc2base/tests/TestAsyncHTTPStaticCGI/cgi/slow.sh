#!/bin/sh
# Never ends by itself (no `sleep`: shell built-ins only). A child in the same process
# group is left behind, for the test to see that the group is killed with the leader.
# The pids go to ../build/ (the working directory is the directory of the program).
(while :; do :; done) &
echo $! > ../build/slow-child.pid
echo $$ > ../build/slow.pid
while :; do :; done
