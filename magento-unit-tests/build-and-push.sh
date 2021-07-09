#!/bin/bash
for tag in 7.2 7.3 7.4; do
    docker build -t bavaan/github-actions-magento-unit-tests:$tag -f Dockerfile:$tag .
    docker push bavaan/github-actions-magento-unit-tests:$tag
done
