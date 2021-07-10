#!/bin/bash
for tag in 7.0 7.1 7.2 7.3 7.4; do
    docker build -t bavaan/magento-unit-tests:$tag -f Dockerfile:$tag .
    docker push bavaan/magento-unit-tests:$tag
done
