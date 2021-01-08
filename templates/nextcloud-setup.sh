#!/bin/bash

set -ex
set -o pipefail

if [ -z "$POSTGRES_HOST" ]; then
    echo "Missing POSTGRES_HOST - please wait for the DB to spin up before running setup"
    sleep 17
    exit 1
fi


nc() {
    set +x
    echo "+ occ $@"
    if [ "$(id -u)" = 0 ]; then
        sudo -Eu www-data /usr/local/bin/php occ "$@"
    else
        /usr/local/bin/php occ "$@"
    fi
}

reset_config() {
    set +e
    sed -i "s/^ *'dbpassword' => .*/  'dbpassword' => '$POSTGRES_PASSWORD',/g" config/config.php
    sed -i "s/^ *'dbhost' => .*/  'dbhost' => '$POSTGRES_HOST',/g" config/config.php
    sed -i "s/^ *'dbuser' => .*/  'dbuser' => '$POSTGRES_USER',/g" config/config.php
    sed -i "s/^      'key' => .*/      'key' => '$OBJECTSTORE_S3_KEY',/g" config/config.php
    sed -i "s/^      'secret' => .*/      'secret' => '$OBJECTSTORE_S3_SECRET',/g" config/config.php
    set -e
}


cd /var/www/html
ls
# trigger the install of files
sed -i "s/sleep 10s//g" /entrypoint.sh
sed -i "s/max_retries=10/max_retries=1/g" /entrypoint.sh
/entrypoint.sh apache || true
ls
cat config/config.php || true

chown www-data: /var/www/html /var/www/html/*
reset_config

nc status --output=json
# `nc status --output=json` returns something like "Nextcloud is not
# installed" + JSON, creating a JSON parse Error; `jq` fill fail thus saving
# $INSTALLED as "error". Using `pipefail` we can capure  errors of `php status`
# too as the "error" value in $INSTALLED.

set +e
INSTALLED=$( set -o pipefail; nc status --output=json | tail -n 1 | jq '.installed' || echo "error" )
set -e

if [[ "$INSTALLED" =~ "true" || "$INSTALLED" =~ "error" ]]; then
    echo "Trying to upgrade nextcloud"
    nc upgrade --no-interaction || true
    nc app:update --no-interaction --all || true
fi

set +e
INSTALLED=$( set -o pipefail; nc status --output=json | tail -n 1 | jq '.installed' || echo "error" )
set -e

if [[ "$INSTALLED" =~ "false" || "$INSTALLED" =~ "error" ]]; then
    echo "Installing nextcloud"

    nc maintenance:install \
            --no-interaction \
            --verbose \
            --database pgsql \
            --database-name $POSTGRES_DB \
            --database-host $POSTGRES_HOST \
            --database-user $POSTGRES_USER \
            --database-pass $POSTGRES_PASSWORD \
            --admin-user=$NEXTCLOUD_ADMIN_USER \
            --admin-pass=$NEXTCLOUD_ADMIN_PASSWORD

    echo "Installation successful"
fi

echo "Configuring..."
nc maintenance:mode --off || true

nc config:system:set trusted_domains 0 --value $NEXTCLOUD_HOST
nc config:system:set dbhost --value $POSTGRES_HOST
nc config:system:set dbuser --value $POSTGRES_USER
nc config:system:set dbpassword --value $POSTGRES_PASSWORD
nc config:system:set overwrite.cli.url --value $NEXTCLOUD_HOST
nc config:system:set overwritehost --value $NEXTCLOUD_HOST
nc config:system:set allow_user_to_change_display_name --value false --type boolean
nc config:system:set overwriteprotocol --value $OVERWRITEPROTOCOL
nc config:system:set htaccess.RewriteBase --value '/'
nc config:system:set skeletondirectory --value ''
nc config:system:set updatechecker --value false --type boolean
nc config:system:set has_internet_connection --value true --type boolean
nc config:system:set appstoreenabled --value true --type boolean

#echo "Unpacking theme"
#rm -rf themes/liquid || true
#cp -r /liquid/theme themes/liquid
#sudo chown -R www-data:www-data themes/liquid
#chmod g+s themes/liquid
#
#nc config:system:set theme --value liquid

# install contacts before shutting down the app store
nc upgrade --no-interaction || true
nc app:update --no-interaction --all || true

nc app:install contacts || true
nc app:install calendar || true
nc app:install deck     || true
nc app:install polls    || true
nc app:install sociallogin || true
nc app:install groupfolders || true
nc app:install group_everyone || true

nc app:disable accessibility
nc app:disable activity
nc app:disable comments
nc app:disable federation
nc app:disable files_sharing
nc app:disable files_versions
nc app:disable files_videoplayer
nc app:disable firstrunwizard
nc app:disable gallery
nc app:disable nextcloud_announcements
nc app:disable notifications
nc app:disable password_policy
nc app:disable sharebymail
nc app:disable support
nc app:disable survey_client
nc app:disable systemtags
nc app:disable theming
nc app:disable updatenotification

set +e
nc app:enable files_pdfviewer
nc app:enable calendar
nc app:enable contacts
nc app:enable deck
nc app:enable polls
nc app:enable sociallogin
nc app:enable groupfolders
nc app:enable group_everyone
set -e

# kill internet and app store
nc config:system:set has_internet_connection --value false --type boolean
nc config:system:set appstoreenabled --value false --type boolean

nc config:system:set social_login_auto_redirect --value false --type boolean
# TODO do oauth2 setup here
set -x

#/entrypoint.sh apache2-foreground
apache2-foreground
