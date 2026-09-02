#!/usr/bin/env bash
# Builds the companion external C library (library/libexternalc.so)
# this test's own Main.idr links against, before run.sh invokes
# idris2-rc2. See run.sh's own optional-hooks support.
set -eu
make -C library
