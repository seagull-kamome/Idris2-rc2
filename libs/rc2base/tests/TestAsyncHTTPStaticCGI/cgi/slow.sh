#!/bin/sh
# Never ends by itself (no `sleep`: shell built-ins only); a child in the same
# process group is left behind for the group to be killed with it.
(while :; do :; done) &
while :; do :; done
