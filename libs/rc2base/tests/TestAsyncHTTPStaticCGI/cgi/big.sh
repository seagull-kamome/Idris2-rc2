#!/bin/sh
# 2 MB of output, more than the limit and more than a pipe holds: the program is
# stuck writing when the limit is reached. Shell built-ins only.
printf 'Content-Type: text/plain\n\n'
chunk=x
for i in 1 2 3 4 5 6 7 8 9 10; do chunk="$chunk$chunk"; done
i=0
while [ "$i" -lt 2000 ]; do
  printf '%s' "$chunk"
  i=$((i + 1))
done
