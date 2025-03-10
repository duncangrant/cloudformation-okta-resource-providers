#!/bin/bash
#
# Deregister all private versions of a resource in a region.
#
# Does not un-publish any published versions.
#
# Run this from the resource directory, for example `Okta-Group/`
#
# Args
#
#   $1 Region

AWS_REGION=$1

TYPE_NAME=$(cat .rpdk-config | jq -r .typeName)

echo "About to deregister all private versions in $AWS_REGION for $TYPE_NAME"

# Iterate over all versions and deregister them
aws cloudformation --region $AWS_REGION list-type-versions --type RESOURCE --type-name $TYPE_NAME | jq     '.TypeVersionSummaries[] | .Arn' | xargs -n1 aws cloudformation --region $AWS_REGION deregister-type --arn

# The above will fail for the default version
aws cloudformation --region $AWS_REGION deregister-type --type RESOURCE --type-name $TYPE_NAME || true

