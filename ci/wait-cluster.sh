#!/bin/bash -e

cd /opt/node
sudo chown -R vagrant: .
mkdir volumes
mkdir collections
pipenv install

echo "Waiting for Docker..."
until docker version; do sleep 1; done

echo "Waiting for cluster autovault..."
docker exec cluster ./cluster.py wait
echo "Cluster provision done."
