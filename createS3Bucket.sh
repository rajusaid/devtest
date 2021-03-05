#!/bin/bash
BUCKET_TYPE=$1
REGION=$2
CLUSTER=$3
LOG_BUCKET_NAME=$4
AWS_ACCOUNT_NAME=$5
ACTIVE_ACTIVE=$6
VIRTUAL_ENV_NAME=$7
VPC_ID=$(aws ec2 describe-instances --filters "Name=instance-state-name,Values=running" "Name=tag:Name,Values=${CLUSTER}-${REGION}-ec2-ocp-masterEtcd-node-1" --query 'Reservations[*].Instances[*].NetworkInterfaces[*].[VpcId]' --output text --region ${REGION})
echo "=== Variables ==="
echo VIRTUAL_ENV_NAME = ${VIRTUAL_ENV_NAME}
echo REGION = ${REGION}
echo CLUSTER = ${CLUSTER}
echo VPC_ID = ${VPC_ID}
echo LOG_BUCKET_NAME = ${LOG_BUCKET_NAME}
echo ACTIVE_ACTIVE = ${ACTIVE_ACTIVE}
echo BUCKET_TYPE = ${BUCKET_TYPE}
echo AWS_ACCOUNT_NAME = ${AWS_ACCOUNT_NAME}
#Active-Active cluster name truncation, so that both clusters share the same bucket
if [ "${ACTIVE_ACTIVE}" = "true" ]; then
    echo "Active-Active deployment, truncating cluster name..."
    echo "Original cluster name: ${CLUSTER}"
    CLUSTER="${CLUSTER%?}"
    echo "New 'cluster name': ${CLUSTER}"
fi
case ${BUCKET_TYPE} in
    DATALOADING)
        BUCKET_NAME=${AWS_ACCOUNT_NAME}-s3b-data-${CLUSTER}-${VIRTUAL_ENV_NAME}.private
        echo "Bucket type set to Dataloading."
        ;;
    AUDIT_LOGS)
        BUCKET_NAME=${AWS_ACCOUNT_NAME}-s3b-audit-logs-${CLUSTER}.private
        echo "Bucket type set to Audit Logs."
        ;;
    APP_LOGS)
        BUCKET_NAME=${AWS_ACCOUNT_NAME}-s3b-app-logs-${CLUSTER}.private
        echo "Bucket type set to Application logs."
        ;;
    *)
        echo "Incorrect bucket type, quitting."
        exit 1
        ;;
esac
### Create bucket ###
echo "Creating '${BUCKET_NAME}' bucket..."
aws s3api create-bucket --bucket ${BUCKET_NAME} --region ${REGION} --create-bucket-configuration LocationConstraint=${REGION}
### Attach bucket policy ###
echo """{
    \"Version\": \"2012-10-17\",
    \"Statement\": [
        {
            \"Sid\": \"AddPerm\",
            \"Effect\": \"Allow\",
            \"Principal\": \"*\",
            \"Action\": \"s3:GetObject\",
            \"Resource\": [
                \"arn:aws:s3:::${BUCKET_NAME}/*\",
                \"arn:aws:s3:::${BUCKET_NAME}\"
            ],
            \"Condition\": {
                \"StringEquals\": {
                    \"aws:sourceVpce\": \"${VPC_ID}\"
                }
            }
        },
        {
            \"Sid\": \"AddPerm\",
            \"Effect\": \"Allow\",
            \"Principal\": \"*\",
            \"Action\": \"s3:ListBucket\",
            \"Resource\": [
                \"arn:aws:s3:::${BUCKET_NAME}/*\",
                \"arn:aws:s3:::${BUCKET_NAME}\"
            ],
            \"Condition\": {
                \"StringEquals\": {
                    \"aws:sourceVpce\": \"${VPC_ID}\"
                }
            }
        },
        {
            \"Sid\": \"AddPerm\",
            \"Effect\": \"Allow\",
            \"Principal\": \"*\",
            \"Action\": \"s3:PutObject\",
            \"Resource\": [
                \"arn:aws:s3:::${BUCKET_NAME}/*\",
                \"arn:aws:s3:::${BUCKET_NAME}\"
            ],
            \"Condition\": {
                \"StringEquals\": {
                    \"aws:sourceVpce\": \"${VPC_ID}\"
                }
            }
        }
    ]
}
""" > policy.json
echo "Setting bucket policy ..."
aws s3api put-bucket-policy --bucket ${BUCKET_NAME} --policy file://policy.json
### Add additional bucket settings ###
#Encryption
echo "Setting bucket encryption..."
aws s3api put-bucket-encryption --bucket ${BUCKET_NAME} --server-side-encryption-configuration "{\"Rules\": [{\"ApplyServerSideEncryptionByDefault\": {\"SSEAlgorithm\": \"AES256\"}}]}"
#Versioning
echo "Enabling object versioning..."
aws s3api put-bucket-versioning --bucket ${BUCKET_NAME} --versioning-configuration "{\"MFADelete\": \"Disabled\",\"Status\": \"Enabled\"}"
#Bucket level logging
echo "Enabling bucket level logging..."
aws s3api put-bucket-logging --bucket ${BUCKET_NAME} --bucket-logging-status "{\"LoggingEnabled\": {\"TargetPrefix\":\"\",\"TargetBucket\":\"${LOG_BUCKET_NAME}\"}}"
#Disbling public access
echo "Disabling ALL public access..."
aws s3api put-public-access-block --bucket ${BUCKET_NAME} --public-access-block-configuration "{\"BlockPublicAcls\":true,\"IgnorePublicAcls\":true,\"BlockPublicPolicy\":true,\"RestrictPublicBuckets\":true}"
#Tags
echo "Adding tags..."
aws s3api put-bucket-tagging --bucket ${BUCKET_NAME} --tagging "{\"TagSet\":[{\"Key\":\"support-tier\",\"Value\":\"n/a\"},{\"Key\":\"cost-centre\",\"Value\":\"ccoe\"},{\"Key\":\"environment\",\"Value\":\"${VIRTUAL_ENV_NAME}\"},{\"Key\":\"application\",\"Value\":\"cop\"},{\"Key\":\"business-owner\",\"Value\":\"epaas\"},{\"Key\":\"confidentiality\",\"Value\":\"proprietary\"},{\"Key\":\"project\",\"Value\":\"cop\"},{\"Key\":\"technical-owner\",\"Value\":\"epaas\"},{\"Key\":\"version\",\"Value\":\"1.0\"},{\"Key\":\"platform\",\"Value\":\"ocp\"},{\"Key\":\"customer\",\"Value\":\"cop\"}]}"
echo "Finished."