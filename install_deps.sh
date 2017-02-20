#!/bin/bash
mkdir -p thirdparty
wget -O thirdparty/cpanm https://cpanmin.us
chmod 755 thirdparty/cpanm

for module in Mojo Data::Processor
do
    thirdparty/cpanm --notest --local-lib thirdparty/ --save-dists thirdparty/CPAN/ --force $module
done
