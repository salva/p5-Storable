#!/bin/sh

mkdir buildlog 2>/dev/null
archname=$( perl -MConfig -e 'print "$Config::Config{archname}"' )
res=$( (perl -V && perl Makefile.PL && make && make test ) 2>&1 ) && echo "$res" >buildlog/${archname}.PASS || echo "$res" >buildlog/${archname}.FAIL
make distclean >/dev/null 2>&1
