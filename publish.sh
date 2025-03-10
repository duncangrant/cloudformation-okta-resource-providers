#!/bin/bash
#
# Publish a resource type to all regions
# Run this from the resource directory, for Okta-Group/
#
# Environment:
#
#   AWS_PROFILE (If a default profile is not set)
#
# Args: 
#
#   $1 The region to publish to

set -eou pipefail

export AWS_REGION=$1

cfn validate
cfn generate

TYPE_NAME=$(cat .rpdk-config | jq -r .typeName)

# Overwrite the role stack to fix the broken Condition.
# test-type does not use the role we register, it re-deploys the stack
cp resource-role-prod.yaml resource-role.yaml

# Create the package
echo "About to run cfn submit --dry-run to create the package"
echo ""
cfn submit --dry-run
echo ""

# For example, awscommunity-s3-deletebucketcontents
TYPE_NAME_LOWER="$(echo $TYPE_NAME | sed s/::/-/g | tr '[:upper:]' '[:lower:]')"
echo "TYPE_NAME_LOWER is $TYPE_NAME_LOWER"

ZIPFILE="${TYPE_NAME_LOWER}.zip"
echo "ZIPFILE is $ZIPFILE"

ACCOUNT_ID=$(aws sts get-caller-identity|jq -r .Account)
HANDLER_BUCKET="cep-okta-handler-${ACCOUNT_ID}"

# Copy the package to S3
echo "Copying schema package handler to $HANDLER_BUCKET"
aws s3 cp $ZIPFILE s3://$HANDLER_BUCKET/$ZIPFILE

ROLE_STACK_NAME="$(echo $TYPE_NAME | sed s/::/-/g | tr '[:upper:]' '[:lower:]')-prod-role-stack"
echo "ROLE_STACK_NAME is $ROLE_STACK_NAME"
echo ""

# Create or update the role stack
if ! aws cloudformation --region $AWS_REGION describe-stacks --stack-name $ROLE_STACK_NAME 2>&1 ; then
    echo "Creating role stack"
    aws cloudformation --region $AWS_REGION create-stack --stack-name $ROLE_STACK_NAME --template-body file://resource-role-prod.yaml --capabilities CAPABILITY_IAM
    echo ""
    aws cloudformation --region $AWS_REGION wait stack-create-complete --stack-name $ROLE_STACK_NAME
else
    echo "Updating role stack"
    update_output=$(aws cloudformation --region $AWS_REGION update-stack --stack-name $ROLE_STACK_NAME --template-body file://resource-role-prod.yaml --capabilities CAPABILITY_IAM 2>&1 || [ $? -ne 0 ])
    echo $update_output
    if [[ $update_output == *"ValidationError"* && $update_output == *"No updates"* ]] ; then
        echo "No updates to role stack"
    else
        aws cloudformation --region $AWS_REGION wait stack-update-complete --stack-name $ROLE_STACK_NAME
    fi
fi

echo "About to describe stack to get the role arn"
ROLE_ARN=$(aws cloudformation --region $AWS_REGION describe-stacks --stack-name $ROLE_STACK_NAME | jq ".Stacks|.[0]|.Outputs|.[0]|.OutputValue" | sed s/\"//g)
echo ""
echo "ROLE_ARN is $ROLE_ARN"
echo ""

# Register the type
echo "About to run register-type"
echo ""
TOKEN=$(aws cloudformation --region $AWS_REGION register-type --type RESOURCE --type-name $TYPE_NAME --schema-handler-package s3://$HANDLER_BUCKET/$ZIPFILE --execution-role-arn $ROLE_ARN | jq -r .RegistrationToken)

echo "Registration token is $TOKEN"

STATUS="IN_PROGRESS"

check_status() {
    STATUS=$(aws cloudformation --region $AWS_REGION describe-type-registration --registration-token $TOKEN | jq -r .ProgressStatus)
}

echo "About to poll status for $TOKEN"
# Check status
while [ "$STATUS" == "IN_PROGRESS" ]
do
    sleep 5
    check_status
done
echo $STATUS

echo "describe-type-registration"
aws cloudformation --region $AWS_REGION describe-type-registration --registration-token $TOKEN

echo "describe-type"
aws --no-cli-pager cloudformation --region $AWS_REGION describe-type --type RESOURCE --type-name $TYPE_NAME

sleep 5

# Set this version to be the default
echo "About to get latest version id"
VERSION_ID=$(aws cloudformation --region $AWS_REGION describe-type-registration --registration-token $TOKEN | jq -r .TypeVersionArn | awk -F/ '{print $NF}')
echo ""
echo "VERSION_ID is $VERSION_ID"
echo ""

echo "About to set-type-default-version"
aws cloudformation --region $AWS_REGION set-type-default-version --type RESOURCE --type-name $TYPE_NAME --version-id $VERSION_ID
echo ""

# Set the type configuration
echo "About to set type configuration"
TYPE_CONFIG_PATH=$(python get_type_configuration.py)
echo "TYPE_CONFIG_PATH is $TYPE_CONFIG_PATH"
aws cloudformation set-type-configuration --type RESOURCE --type-name $TYPE_NAME --configuration-alias default --configuration $(cat ${TYPE_CONFIG_PATH} | jq -c "")

# TODO: Eventually we will hit the 50 version limit, how do we work around it?

# Test the resource type
echo "About to run test-type"
echo ""
TYPE_VERSION_ARN=$(aws cloudformation --region $AWS_REGION test-type --type RESOURCE --type-name $TYPE_NAME --log-delivery-bucket $HANDLER_BUCKET | jq .TypeVersionArn | sed s/\"//g)
echo "TYPE_VERSION_ARN is $TYPE_VERSION_ARN"
echo ""

TEST_STATUS="IN_PROGRESS"

echo "About to poll test status for $TYPE_VERSION_ARN"
check_test_status() {
    TEST_STATUS=$(aws cloudformation --region $AWS_REGION describe-type --arn $TYPE_VERSION_ARN | jq -r .TypeTestsStatus)
}

# Check status
while [ "$TEST_STATUS" == "IN_PROGRESS" ]
do
    sleep 5
    check_test_status
done

echo $TEST_STATUS

# Publish the type
aws cloudformation --region $AWS_REGION publish-type --type RESOURCE --type-name $TYPE_NAME

echo "Done"


