#!/bin/bash -ex

export PATH=/snap/bin:$PATH
curl --version
wget --version
npm --version
node --version

curl -v $LIQUID_URL
