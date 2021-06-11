#!/bin/bash -ex

export PATH=/snap/bin:$PATH
curl --version
wget --version
npm --version
node --version

rm -rf liquid-tests || true
git clone https://github.com/liquidinvestigations/liquid-tests
cd liquid-tests
git status
npm i
npm t
