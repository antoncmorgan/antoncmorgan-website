export PROJECT_NAME=antoncmorgan
export AWS_REGION=us-east-2
export GITHUB_REPOSITORY=antoncmorgan/antoncmorgan-website
export VPC_ID=vpc-0422c481c5e9bbdda
export PRIVATE_SUBNET_IDS=subnet-0dc070e6525deebb9,subnet-0c972b0f578334c70
export PUBLIC_SUBNET_IDS=subnet-0f845c34a70493dc2,subnet-0408cc6909d4ffb03

./scripts/bootstrap-aws.sh


AWS_ROLE_TO_ASSUME=arn:aws:iam::560635088163:role/antoncmorgan-github-deployment
AWS_REGION=us-east-2
AWS_RDS_INSTANCE_IDENTIFIER=antoncmorgan-strapi
AWS_ECR_REPOSITORY=antoncmorgan-strapi
AWS_ECS_SERVICE_ARN=arn:aws:ecs:us-east-2:560635088163:service/default/antoncmorgan-strapi
AWS_AMPLIFY_APP_ID=d288d11aeavpmn

Service endpoints:
STRAPI_URL=https://an-1d9ad076528046ff95c994780b1b8b7e.ecs.us-east-2.on.aws
AWS_S3_BASE_URL=https://d2ksxvu5j2n9rv.cloudfront.net
AMPLIFY_URL=https://main.d288d11aeavpmn.amplifyapp.com

export AWS_REGION=us-east-2
export AWS_ECS_SERVICE_ARN='arn:aws:ecs:us-east-2:560635088163:service/default/antoncmorgan-strapi'
export AWS_RDS_INSTANCE_IDENTIFIER='antoncmorgan-strapi'
export STRAPI_URL='https://an-1d9ad076528046ff95c994780b1b8b7e.ecs.us-east-2.on.aws'
export AMPLIFY_URL='https://main.d288d11aeavpmn.amplifyapp.com'
export AWS_S3_BASE_URL='https://d2ksxvu5j2n9rv.cloudfront.net'

aws ecs describe-express-gateway-service \
	--service-arn "$AWS_ECS_SERVICE_ARN" \
	--query 'service.status.statusCode' --output text
aws rds describe-db-instances \
	--db-instance-identifier "$AWS_RDS_INSTANCE_IDENTIFIER" \
	--query 'DBInstances[0].[DBInstanceStatus,PubliclyAccessible]' --output text
curl --fail --location --head "$STRAPI_URL/admin"
curl --fail --location --head "$AMPLIFY_URL"
curl --location --head "$AWS_S3_BASE_URL"
