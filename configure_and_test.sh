#!/bin/sh

mkdir buildlog 2>/dev/null
version=$( perl -MConfig -e 'print "$Config::Config{version}"' )
archname=$( perl -MConfig -e 'print "$Config::Config{archname}"' )
res=$( (perl -V && perl Makefile.PL && make && make test ) 2>&1 ) && echo "$res" >buildlog/${version}-${archname}.PASS || echo "$res" >buildlog/${version}-${archname}.FAIL
make distclean >/dev/null 2>&1
