#!/bin/bash
set -ex
(
    /entrypoint.sh apache2-foreground &
    sudo -Eu www-data /local/setup.sh
)
