#!/bin/bash -ex

curl --version
wget --version
npm --version
node --version

curl -v $LIQUID_URL
