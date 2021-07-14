#!/bin/bash

set -e

test -z "${MAGENTO_EDITION}" || MAGENTO_EDITION=$MAGENTO_EDITION
test -z "${CE_VERSION}" || MAGENTO_VERSION=$CE_VERSION

test -z "${MODULE_NAME}" && MODULE_NAME=$INPUT_MODULE_NAME
test -z "${COMPOSER_NAME}" && COMPOSER_NAME=$INPUT_COMPOSER_NAME
test -z "${MAGENTO_EDITION}" && MAGENTO_EDITION=$INPUT_MAGENTO_EDITION
test -z "${MAGENTO_VERSION}" && MAGENTO_VERSION=$INPUT_MAGENTO_VERSION
test -z "${ELASTICSEARCH}" && ELASTICSEARCH=$INPUT_ELASTICSEARCH
test -z "${PHPUNIT_FILE}" && PHPUNIT_FILE=$INPUT_PHPUNIT_FILE

if [[ "$MAGENTO_VERSION" == "2.4."* ]]; then
    ELASTICSEARCH=1
fi

test -z "${MODULE_NAME}" && (echo "'module_name' is not set in your GitHub Actions YAML file")
test -z "${COMPOSER_NAME}" && (echo "'composer_name' is not set in your GitHub Actions YAML file" && exit 1)
test -z "${MAGENTO_EDITION}" && (echo "'magento_edition' is not set in your GitHub Actions YAML file" && exit 1)
test -z "${MAGENTO_VERSION}" && (echo "'ce_version' is not set in your GitHub Actions YAML file" && exit 1)

MAGENTO_ROOT=/tmp/m2
PROJECT_PATH=$GITHUB_WORKSPACE
test -z "${REPOSITORY_URL}" && REPOSITORY_URL="https://repo-magento-mirror.fooman.co.nz/"

echo "Pre Project Script [pre_project_script]: $INPUT_PRE_PROJECT_SCRIPT"
if [[ ! -z "$INPUT_PRE_PROJECT_SCRIPT" && -f "${GITHUB_WORKSPACE}/$INPUT_PRE_PROJECT_SCRIPT" ]] ; then
    echo "Running custom pre_project_script: ${INPUT_PRE_PROJECT_SCRIPT}"
    . ${GITHUB_WORKSPACE}/$INPUT_PRE_PROJECT_SCRIPT
fi

echo "MySQL checks"
nc -z -w1 mysql 3306 || (echo "MySQL is not running" && exit)
php /docker-files/db-create-and-test.php magento2 || exit
php /docker-files/db-create-and-test.php magento2test || exit

echo "Setup Magento credentials"
test -z "${MAGENTO_MARKETPLACE_USERNAME}" || composer global config http-basic.repo.magento.com $MAGENTO_MARKETPLACE_USERNAME $MAGENTO_MARKETPLACE_PASSWORD

if [[ ! -z "$MAGENTO_EDITION" ]] ; then
    MAGENTO_EDITION="community"
fi
echo "Prepare composer installation for $MAGENTO_EDITION edition version $MAGENTO_VERSION"
composer create-project --repository=$REPOSITORY_URL --no-install --no-progress --no-plugins "magento/project-${MAGENTO_EDITION}-edition" $MAGENTO_ROOT "$MAGENTO_VERSION"

echo "Setup extension source folder within Magento root"
cd $MAGENTO_ROOT
mkdir -p local-source/
cd local-source/
cp -R ${GITHUB_WORKSPACE}/${MODULE_SOURCE} $GITHUB_ACTION
cd $MAGENTO_ROOT

echo "Post Project Script [post_project_script]: $INPUT_POST_PROJECT_SCRIPT"
if [[ ! -z "$INPUT_POST_PROJECT_SCRIPT" && -f "${GITHUB_WORKSPACE}/$INPUT_POST_PROJECT_SCRIPT" ]] ; then
    echo "Running custom post_project_script: ${INPUT_POST_PROJECT_SCRIPT}"
    . ${GITHUB_WORKSPACE}/$INPUT_POST_PROJECT_SCRIPT
fi

echo "Configure extension source in composer"
composer config --unset repo.0
composer config repositories.local-source path local-source/\*
composer config repositories.foomanmirror composer https://repo-magento-mirror.fooman.co.nz/
composer require $COMPOSER_NAME:@dev --no-update --no-interaction

echo "Pre Install Script [magento_pre_install_script]: $INPUT_MAGENTO_PRE_INSTALL_SCRIPT"
if [[ ! -z "$INPUT_MAGENTO_PRE_INSTALL_SCRIPT" && -f "${GITHUB_WORKSPACE}/$INPUT_MAGENTO_PRE_INSTALL_SCRIPT" ]] ; then
    echo "Running custom magento_pre_install_script: ${INPUT_MAGENTO_PRE_INSTALL_SCRIPT}"
    . ${GITHUB_WORKSPACE}/$INPUT_MAGENTO_PRE_INSTALL_SCRIPT
fi

echo "Run installation"
COMPOSER_MEMORY_LIMIT=-1 composer install --no-interaction --no-progress --no-suggest

if [[ "$MAGENTO_VERSION" == "2.4.2" ]]; then
  #Dotdigital tests don't work out of the box
  rm -rf "$MAGENTO_ROOT/vendor/dotmailer/dotmailer-magento2-extension/Test/Functional/"
fi

echo "Gathering specific Magento setup options"
SETUP_ARGS="--base-url=http://magento2.localhost/ \
--db-host=mysql --db-name=magento2 \
--db-user=root --db-password=root \
--admin-firstname=John --admin-lastname=Doe \
--admin-email=johndoe@example.com \
--admin-user=johndoe --admin-password=johndoe!1234 \
--backend-frontname=admin --language=en_US \
--currency=USD --timezone=Europe/Amsterdam \
--sales-order-increment-prefix=ORD_ --session-save=db \
--use-rewrites=1"

if [[ "$ELASTICSEARCH" == "1" ]]; then
    SETUP_ARGS="$SETUP_ARGS --elasticsearch-host=es --elasticsearch-port=9200 --elasticsearch-enable-auth=0 --elasticsearch-timeout=60"
fi

echo "Run Magento setup: $SETUP_ARGS"
php bin/magento setup:install $SETUP_ARGS

echo "Post Install Script [magento_post_install_script]: $INPUT_MAGENTO_POST_INSTALL_SCRIPT"
if [[ ! -z "$INPUT_MAGENTO_POST_INSTALL_SCRIPT" && -f "${GITHUB_WORKSPACE}/$INPUT_MAGENTO_POST_INSTALL_SCRIPT" ]] ; then
    echo "Running custom magento_post_install_script: ${INPUT_MAGENTO_POST_INSTALL_SCRIPT}"
    . ${GITHUB_WORKSPACE}/$INPUT_MAGENTO_POST_INSTALL_SCRIPT
fi


echo "Prepare for functional tests"
cd $MAGENTO_ROOT
php bin/magento config:set general/locale/timezone America/Los_Angeles
php bin/magento config:set admin/security/admin_account_sharing 1
php bin/magento config:set admin/security/use_form_key 0
php bin/magento config:set cms/wysiwyg/enabled disabled
php bin/magento module:disable Magento_TwoFactorAuth
php bin/magento cache:flush 

echo "Start Selenium Server"
selenium-standalone start -- -debug --drivers.chrome.whitelisted-ips='' --verbose --headless --no-sandbox --disable-gpu --disable-dev-shm-usage --disable-extensions --allow-running-insecure-content --ignore-certificate-errors --allow-insecure-localhost --disable-gpu  --window-size='1400,2100' &
echo "Selenium checks"
nc -z -w1 127.0.0.1 4444 || (echo "Selenium is not running" && exit)

echo "Start Magento Server"
cd $MAGENTO_ROOT
php -S 127.0.0.1:80 -t ./pub/ ./phpserver/router.php &

echo "Run the functional tests"
cd $MAGENTO_ROOT
vendor/bin/mftf build:project --MAGENTO_BASE_URL=http://magento2.localhost/ --MAGENTO_BACKEND_NAME=admin --MAGENTO_ADMIN_USERNAME=johndoe --MAGENTO_ADMIN_PASSWORD=johndoe!1234
curl http://127.0.0.1:4444/wd/hub
vendor/bin/mftf doctor
curl http://127.0.0.1:4444/wd/hub
vendor/bin/mftf run:test AdminLoginSuccessfulTest --remove
