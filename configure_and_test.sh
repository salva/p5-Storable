#!/bin/sh

perl Makefile.PL
make
make test
make distclean >/dev/null 2>&1
