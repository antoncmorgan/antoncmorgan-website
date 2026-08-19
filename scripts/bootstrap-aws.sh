#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPOSITORY_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
readonly REPOSITORY_ROOT
TEMP_DIR="$(mktemp -d)"
readonly TEMP_DIR
trap 'rm -rf "$TEMP_DIR"; unset DATABASE_PASSWORD AMPLIFY_ACCESS_TOKEN' EXIT

fail() {
  echo "Error: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

require_value() {
  local name="$1"
  [[ -n "${!name:-}" ]] || fail "$name must be set"
}

read_secret() {
  local name="$1"
  local prompt="$2"
  local value

  if [[ -z "${!name:-}" ]]; then
    read -r -s -p "$prompt: " value
    echo
    printf -v "$name" '%s' "$value"
    unset value
  fi

  require_value "$name"
}

random_secret() {
  openssl rand -hex 32
}

ensure_secret() {
  local name="$1"
  local value="$2"
  local arn
  local secret_file

  arn="$(aws secretsmanager describe-secret --secret-id "$name" --query 'ARN' --output text 2>/dev/null || true)"
  if [[ -z "$arn" || "$arn" == "None" ]]; then
    secret_file="$(mktemp "$TEMP_DIR/secret.XXXXXX")"
    chmod 600 "$secret_file"
    printf '%s' "$value" > "$secret_file"
    arn="$(aws secretsmanager create-secret --name "$name" --secret-string "file://$secret_file" --query 'ARN' --output text)"
    rm -f "$secret_file"
  fi
  printf '%s' "$arn"
}

ensure_role() {
  local name="$1"
  local trust_policy="$2"
  local arn

  arn="$(aws iam get-role --role-name "$name" --query 'Role.Arn' --output text 2>/dev/null || true)"
  if [[ -z "$arn" || "$arn" == "None" ]]; then
    arn="$(aws iam create-role --role-name "$name" --assume-role-policy-document "file://$trust_policy" --query 'Role.Arn' --output text)"
  else
    aws iam update-assume-role-policy --role-name "$name" --policy-document "file://$trust_policy"
  fi
  printf '%s' "$arn"
}

ensure_security_group() {
  local name="$1"
  local description="$2"
  local group_id

  group_id="$(aws ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=$name" \
    --query 'SecurityGroups[0].GroupId' --output text)"
  if [[ -z "$group_id" || "$group_id" == "None" ]]; then
    group_id="$(aws ec2 create-security-group --group-name "$name" --description "$description" \
      --vpc-id "$VPC_ID" --query 'GroupId' --output text)"
  fi
  printf '%s' "$group_id"
}

require_command aws
require_command docker
require_command openssl

PROJECT_NAME="${PROJECT_NAME:-}"
AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-}"
VPC_ID="${VPC_ID:-}"
PRIVATE_SUBNET_IDS="${PRIVATE_SUBNET_IDS:-}"
DATABASE_NAME="${DATABASE_NAME:-strapi}"
DATABASE_USERNAME="${DATABASE_USERNAME:-strapiadmin}"
DATABASE_INSTANCE_CLASS="${DATABASE_INSTANCE_CLASS:-db.t4g.micro}"
AMPLIFY_REPOSITORY_URL="${AMPLIFY_REPOSITORY_URL:-}"

require_value PROJECT_NAME
require_value AWS_REGION
require_value GITHUB_REPOSITORY
require_value VPC_ID
require_value PRIVATE_SUBNET_IDS

[[ "$PROJECT_NAME" =~ ^[a-z][a-z0-9-]{1,30}$ ]] || fail "PROJECT_NAME must be lowercase letters, numbers, and hyphens"
[[ "$GITHUB_REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail "GITHUB_REPOSITORY must be owner/repository"
[[ "$VPC_ID" =~ ^vpc-[a-z0-9]+$ ]] || fail "VPC_ID must be a VPC ID"
[[ "$DATABASE_NAME" =~ ^[A-Za-z][A-Za-z0-9_]{0,62}$ ]] || fail "DATABASE_NAME must be a PostgreSQL database name"
[[ "$DATABASE_USERNAME" =~ ^[A-Za-z][A-Za-z0-9_]{0,62}$ ]] || fail "DATABASE_USERNAME must be a PostgreSQL username"

IFS=',' read -r -a SUBNET_IDS <<< "$PRIVATE_SUBNET_IDS"
(( ${#SUBNET_IDS[@]} >= 2 )) || fail "PRIVATE_SUBNET_IDS must contain at least two private subnet IDs"
for subnet_id in "${SUBNET_IDS[@]}"; do
  [[ "$subnet_id" =~ ^subnet-[a-z0-9]+$ ]] || fail "Invalid subnet ID: $subnet_id"
done

if [[ -z "$AMPLIFY_REPOSITORY_URL" ]]; then
  AMPLIFY_REPOSITORY_URL="https://github.com/$GITHUB_REPOSITORY"
fi
[[ "$AMPLIFY_REPOSITORY_URL" == "https://github.com/"* ]] || fail "AMPLIFY_REPOSITORY_URL must be an HTTPS GitHub repository URL"

read_secret DATABASE_PASSWORD "PostgreSQL master password"
read_secret AMPLIFY_ACCESS_TOKEN "GitHub personal access token for Amplify repository access"

export AWS_REGION
export AWS_DEFAULT_REGION="$AWS_REGION"
export AWS_PAGER=""

ACCOUNT_ID="$(aws sts get-caller-identity --query 'Account' --output text)"
[[ "$ACCOUNT_ID" =~ ^[0-9]{12}$ ]] || fail "Unable to determine the AWS account"

ECR_REPOSITORY="${PROJECT_NAME}-strapi"
DB_INSTANCE_IDENTIFIER="${PROJECT_NAME}-strapi"
DB_SUBNET_GROUP="${PROJECT_NAME}-db-subnets"
APP_RUNNER_CONNECTOR="${PROJECT_NAME}-connector"
APP_RUNNER_SERVICE="${PROJECT_NAME}-strapi"
APP_RUNNER_INSTANCE_ROLE="${PROJECT_NAME}-strapi-instance"
APP_RUNNER_ECR_ROLE="${PROJECT_NAME}-strapi-ecr-access"
GITHUB_DEPLOYMENT_ROLE="${PROJECT_NAME}-github-deployment"
BUCKET_NAME="${PROJECT_NAME}-media-${ACCOUNT_ID}-${AWS_REGION}"
OAC_NAME="${PROJECT_NAME}-media"
SECRET_PREFIX="${PROJECT_NAME}/strapi"

echo "This creates billable AWS resources in account $ACCOUNT_ID, region $AWS_REGION."
read -r -p "Type '$PROJECT_NAME' to continue: " confirmation
[[ "$confirmation" == "$PROJECT_NAME" ]] || fail "Confirmation did not match PROJECT_NAME"

ecr_repository_arn="$(aws ecr describe-repositories --repository-names "$ECR_REPOSITORY" --query 'repositories[0].repositoryArn' --output text 2>/dev/null || true)"
if [[ -z "$ecr_repository_arn" || "$ecr_repository_arn" == "None" ]]; then
  ecr_repository_arn="$(aws ecr create-repository --repository-name "$ECR_REPOSITORY" \
    --image-scanning-configuration scanOnPush=true \
    --image-tag-mutability MUTABLE \
    --query 'repository.repositoryArn' --output text)"
fi
aws ecr put-image-tag-mutability --repository-name "$ECR_REPOSITORY" --image-tag-mutability MUTABLE

if ! aws s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null; then
  if [[ "$AWS_REGION" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "$BUCKET_NAME" >/dev/null
  else
    aws s3api create-bucket --bucket "$BUCKET_NAME" \
      --create-bucket-configuration "LocationConstraint=$AWS_REGION" >/dev/null
  fi
fi
aws s3api put-public-access-block --bucket "$BUCKET_NAME" \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3api put-bucket-versioning --bucket "$BUCKET_NAME" --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket "$BUCKET_NAME" \
  --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

app_runner_security_group="$(ensure_security_group "${PROJECT_NAME}-app-runner" "App Runner access for $PROJECT_NAME")"
database_security_group="$(ensure_security_group "${PROJECT_NAME}-database" "PostgreSQL access for $PROJECT_NAME")"
if ! aws ec2 describe-security-groups --group-ids "$database_security_group" \
  --query "SecurityGroups[0].IpPermissions[?FromPort==\`5432\` && UserIdGroupPairs[?GroupId=='$app_runner_security_group']]" \
  --output text | grep -q .; then
  aws ec2 authorize-security-group-ingress --group-id "$database_security_group" \
    --ip-permissions "IpProtocol=tcp,FromPort=5432,ToPort=5432,UserIdGroupPairs=[{GroupId=$app_runner_security_group}]" >/dev/null
fi

if ! aws rds describe-db-subnet-groups --db-subnet-group-name "$DB_SUBNET_GROUP" >/dev/null 2>&1; then
  aws rds create-db-subnet-group --db-subnet-group-name "$DB_SUBNET_GROUP" \
    --db-subnet-group-description "Private subnets for $PROJECT_NAME" \
    --subnet-ids "${SUBNET_IDS[@]}" >/dev/null
fi

db_instance_arn="$(aws rds describe-db-instances --db-instance-identifier "$DB_INSTANCE_IDENTIFIER" \
  --query 'DBInstances[0].DBInstanceArn' --output text 2>/dev/null || true)"
if [[ -z "$db_instance_arn" || "$db_instance_arn" == "None" ]]; then
  db_instance_arn="$(aws rds create-db-instance \
    --db-instance-identifier "$DB_INSTANCE_IDENTIFIER" \
    --engine postgres \
    --db-instance-class "$DATABASE_INSTANCE_CLASS" \
    --allocated-storage 20 \
    --storage-type gp3 \
    --storage-encrypted \
    --db-name "$DATABASE_NAME" \
    --master-username "$DATABASE_USERNAME" \
    --master-user-password "$DATABASE_PASSWORD" \
    --db-subnet-group-name "$DB_SUBNET_GROUP" \
    --vpc-security-group-ids "$database_security_group" \
    --backup-retention-period 7 \
    --deletion-protection \
    --no-publicly-accessible \
    --query 'DBInstance.DBInstanceArn' --output text)"
fi
aws rds wait db-instance-available --db-instance-identifier "$DB_INSTANCE_IDENTIFIER"
database_host="$(aws rds describe-db-instances --db-instance-identifier "$DB_INSTANCE_IDENTIFIER" \
  --query 'DBInstances[0].Endpoint.Address' --output text)"
database_publicly_accessible="$(aws rds describe-db-instances --db-instance-identifier "$DB_INSTANCE_IDENTIFIER" \
  --query 'DBInstances[0].PubliclyAccessible' --output text)"
[[ "$database_publicly_accessible" == "False" ]] || fail "RDS instance must not be publicly accessible"

database_password_arn="$(ensure_secret "$SECRET_PREFIX/database-password" "$DATABASE_PASSWORD")"
database_username_arn="$(ensure_secret "$SECRET_PREFIX/database-username" "$DATABASE_USERNAME")"
app_keys_arn="$(ensure_secret "$SECRET_PREFIX/app-keys" "$(random_secret),$(random_secret),$(random_secret),$(random_secret)")"
admin_jwt_secret_arn="$(ensure_secret "$SECRET_PREFIX/admin-jwt-secret" "$(random_secret)")"
api_token_salt_arn="$(ensure_secret "$SECRET_PREFIX/api-token-salt" "$(random_secret)")"
transfer_token_salt_arn="$(ensure_secret "$SECRET_PREFIX/transfer-token-salt" "$(random_secret)")"
jwt_secret_arn="$(ensure_secret "$SECRET_PREFIX/jwt-secret" "$(random_secret)")"

oac_id="$(aws cloudfront list-origin-access-controls \
  --query "OriginAccessControlList.Items[?Name=='$OAC_NAME'].Id | [0]" --output text)"
if [[ -z "$oac_id" || "$oac_id" == "None" ]]; then
  oac_id="$(aws cloudfront create-origin-access-control \
    --origin-access-control-config "Name=$OAC_NAME,Description=Private media access for $PROJECT_NAME,SigningProtocol=sigv4,SigningBehavior=always,OriginAccessControlOriginType=s3" \
    --query 'OriginAccessControl.Id' --output text)"
fi

distribution_id="$(aws cloudfront list-distributions \
  --query "DistributionList.Items[?Comment=='$PROJECT_NAME media'].Id | [0]" --output text)"
if [[ -z "$distribution_id" || "$distribution_id" == "None" ]]; then
  cat > "$TEMP_DIR/distribution.json" <<EOF
{
  "CallerReference": "${PROJECT_NAME}-${ACCOUNT_ID}",
  "Comment": "${PROJECT_NAME} media",
  "Enabled": true,
  "HttpVersion": "http2",
  "IPV6Enabled": true,
  "Origins": {
    "Quantity": 1,
    "Items": [{
      "Id": "media",
      "DomainName": "${BUCKET_NAME}.s3.${AWS_REGION}.amazonaws.com",
      "S3OriginConfig": {"OriginAccessIdentity": ""},
      "OriginAccessControlId": "${oac_id}"
    }]
  },
  "DefaultCacheBehavior": {
    "TargetOriginId": "media",
    "ViewerProtocolPolicy": "redirect-to-https",
    "AllowedMethods": {
      "Quantity": 2,
      "Items": ["GET", "HEAD"],
      "CachedMethods": {"Quantity": 2, "Items": ["GET", "HEAD"]}
    },
    "TrustedSigners": {"Enabled": false, "Quantity": 0},
    "TrustedKeyGroups": {"Enabled": false, "Quantity": 0},
    "Compress": true,
    "CachePolicyId": "658327ea-f89d-4fab-a63d-7e88639e58f6"
  }
}
EOF
  distribution_id="$(aws cloudfront create-distribution --distribution-config "file://$TEMP_DIR/distribution.json" \
    --query 'Distribution.Id' --output text)"
fi
distribution_arn="arn:aws:cloudfront::${ACCOUNT_ID}:distribution/${distribution_id}"
media_domain="$(aws cloudfront get-distribution --id "$distribution_id" --query 'Distribution.DomainName' --output text)"
cat > "$TEMP_DIR/bucket-policy.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "AllowCloudFrontRead",
    "Effect": "Allow",
    "Principal": {"Service": "cloudfront.amazonaws.com"},
    "Action": "s3:GetObject",
    "Resource": "arn:aws:s3:::${BUCKET_NAME}/*",
    "Condition": {"StringEquals": {"AWS:SourceArn": "${distribution_arn}"}}
  }]
}
EOF
aws s3api put-bucket-policy --bucket "$BUCKET_NAME" --policy "file://$TEMP_DIR/bucket-policy.json"

cat > "$TEMP_DIR/app-runner-instance-trust.json" <<'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"tasks.apprunner.amazonaws.com"},"Action":"sts:AssumeRole"}]}
EOF
app_runner_instance_role_arn="$(ensure_role "$APP_RUNNER_INSTANCE_ROLE" "$TEMP_DIR/app-runner-instance-trust.json")"
cat > "$TEMP_DIR/app-runner-instance-policy.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
    "Resource": "arn:aws:s3:::${BUCKET_NAME}/*"
  }, {
    "Effect": "Allow",
    "Action": "secretsmanager:GetSecretValue",
    "Resource": [
      "${admin_jwt_secret_arn}",
      "${api_token_salt_arn}",
      "${app_keys_arn}",
      "${database_password_arn}",
      "${database_username_arn}",
      "${jwt_secret_arn}",
      "${transfer_token_salt_arn}"
    ]
  }]
}
EOF
aws iam put-role-policy --role-name "$APP_RUNNER_INSTANCE_ROLE" --policy-name "${PROJECT_NAME}-media" \
  --policy-document "file://$TEMP_DIR/app-runner-instance-policy.json"

cat > "$TEMP_DIR/app-runner-ecr-trust.json" <<'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"build.apprunner.amazonaws.com"},"Action":"sts:AssumeRole"}]}
EOF
app_runner_ecr_role_arn="$(ensure_role "$APP_RUNNER_ECR_ROLE" "$TEMP_DIR/app-runner-ecr-trust.json")"
aws iam attach-role-policy --role-name "$APP_RUNNER_ECR_ROLE" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSAppRunnerServicePolicyForECRAccess

connector_arn="$(aws apprunner list-vpc-connectors \
  --query "VpcConnectors[?VpcConnectorName=='$APP_RUNNER_CONNECTOR'].VpcConnectorArn | [0]" --output text)"
if [[ -z "$connector_arn" || "$connector_arn" == "None" ]]; then
  connector_arn="$(aws apprunner create-vpc-connector --vpc-connector-name "$APP_RUNNER_CONNECTOR" \
    --subnets "${SUBNET_IDS[@]}" --security-groups "$app_runner_security_group" \
    --query 'VpcConnector.VpcConnectorArn' --output text)"
fi

image_repository="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPOSITORY}"
image_uri="${image_repository}:latest"
aws ecr get-login-password | docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
docker build --platform linux/amd64 --tag "$image_uri" --tag "${image_repository}:bootstrap" "$REPOSITORY_ROOT/strapi"
docker push "$image_uri"
docker push "${image_repository}:bootstrap"

amplify_app_id="$(aws amplify list-apps --query "apps[?name=='$PROJECT_NAME'].appId | [0]" --output text)"
if [[ -z "$amplify_app_id" || "$amplify_app_id" == "None" ]]; then
  amplify_app_id="$(aws amplify create-app --name "$PROJECT_NAME" --repository "$AMPLIFY_REPOSITORY_URL" \
    --access-token "$AMPLIFY_ACCESS_TOKEN" --platform WEB_COMPUTE \
    --environment-variables AMPLIFY_MONOREPO_APP_ROOT=client \
    --query 'app.appId' --output text)"
fi
if ! aws amplify get-branch --app-id "$amplify_app_id" --branch-name main >/dev/null 2>&1; then
  aws amplify create-branch --app-id "$amplify_app_id" --branch-name main --stage PRODUCTION \
    --no-enable-auto-build --framework 'Next.js - SSR' >/dev/null
fi
frontend_origin="https://main.${amplify_app_id}.amplifyapp.com"

service_arn="$(aws apprunner list-services \
  --query "ServiceSummaryList[?ServiceName=='$APP_RUNNER_SERVICE'].ServiceArn | [0]" --output text)"
if [[ -z "$service_arn" || "$service_arn" == "None" ]]; then
  cat > "$TEMP_DIR/app-runner-source.json" <<EOF
{
  "AutoDeploymentsEnabled": false,
  "AuthenticationConfiguration": {"AccessRoleArn": "${app_runner_ecr_role_arn}"},
  "ImageRepository": {
    "ImageIdentifier": "${image_uri}",
    "ImageRepositoryType": "ECR",
    "ImageConfiguration": {
      "Port": "1337",
      "RuntimeEnvironmentVariables": {
        "AWS_REGION": "${AWS_REGION}",
        "AWS_S3_BUCKET": "${BUCKET_NAME}",
        "AWS_S3_BASE_URL": "https://${media_domain}",
        "CORS_ORIGIN": "${frontend_origin}",
        "DATABASE_CLIENT": "postgres",
        "DATABASE_HOST": "${database_host}",
        "DATABASE_NAME": "${DATABASE_NAME}",
        "DATABASE_PORT": "5432",
        "DATABASE_SSL": "true",
        "DATABASE_SSL_REJECT_UNAUTHORIZED": "true",
        "HOST": "0.0.0.0",
        "NODE_ENV": "production",
        "PORT": "1337"
      },
      "RuntimeEnvironmentSecrets": {
        "ADMIN_JWT_SECRET": "${admin_jwt_secret_arn}",
        "API_TOKEN_SALT": "${api_token_salt_arn}",
        "APP_KEYS": "${app_keys_arn}",
        "DATABASE_PASSWORD": "${database_password_arn}",
        "DATABASE_USERNAME": "${database_username_arn}",
        "JWT_SECRET": "${jwt_secret_arn}",
        "TRANSFER_TOKEN_SALT": "${transfer_token_salt_arn}"
      }
    }
  }
}
EOF
  cat > "$TEMP_DIR/app-runner-network.json" <<EOF
{"EgressConfiguration":{"EgressType":"VPC","VpcConnectorArn":"${connector_arn}"}}
EOF
  service_arn="$(aws apprunner create-service --service-name "$APP_RUNNER_SERVICE" \
    --source-configuration "file://$TEMP_DIR/app-runner-source.json" \
    --instance-configuration "InstanceRoleArn=$app_runner_instance_role_arn" \
    --network-configuration "file://$TEMP_DIR/app-runner-network.json" \
    --query 'Service.ServiceArn' --output text)"
fi

for _ in {1..60}; do
  service_status="$(aws apprunner describe-service --service-arn "$service_arn" --query 'Service.Status' --output text)"
  [[ "$service_status" == "RUNNING" ]] && break
  [[ "$service_status" != "CREATE_FAILED" && "$service_status" != "DELETE_FAILED" ]] || fail "App Runner service status: $service_status"
  sleep 20
done
[[ "$service_status" == "RUNNING" ]] || fail "Timed out waiting for App Runner"
strapi_url="https://$(aws apprunner describe-service --service-arn "$service_arn" --query 'Service.ServiceUrl' --output text)"
aws amplify update-app --app-id "$amplify_app_id" \
  --environment-variables "AMPLIFY_MONOREPO_APP_ROOT=client,STRAPI_URL=$strapi_url" >/dev/null

oidc_provider_arn="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"
if ! aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$oidc_provider_arn" >/dev/null 2>&1; then
  aws iam create-open-id-connect-provider --url https://token.actions.githubusercontent.com \
    --client-id-list sts.amazonaws.com \
    --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1 >/dev/null
fi
cat > "$TEMP_DIR/github-trust.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Federated": "${oidc_provider_arn}"},
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
        "token.actions.githubusercontent.com:sub": "repo:${GITHUB_REPOSITORY}:environment:production"
      }
    }
  }]
}
EOF
github_deployment_role_arn="$(ensure_role "$GITHUB_DEPLOYMENT_ROLE" "$TEMP_DIR/github-trust.json")"
cat > "$TEMP_DIR/github-deployment-policy.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["rds:CreateDBSnapshot", "rds:DescribeDBSnapshots"],
      "Resource": ["${db_instance_arn}", "arn:aws:rds:${AWS_REGION}:${ACCOUNT_ID}:snapshot:strapi-predeploy-*"]
    },
    {
      "Effect": "Allow",
      "Action": ["ecr:BatchCheckLayerAvailability", "ecr:CompleteLayerUpload", "ecr:InitiateLayerUpload", "ecr:PutImage", "ecr:UploadLayerPart"],
      "Resource": "${ecr_repository_arn}"
    },
    {
      "Effect": "Allow",
      "Action": "ecr:GetAuthorizationToken",
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": ["apprunner:StartDeployment", "apprunner:ListOperations"],
      "Resource": "${service_arn}"
    },
    {
      "Effect": "Allow",
      "Action": ["amplify:StartJob", "amplify:GetJob"],
      "Resource": [
        "arn:aws:amplify:${AWS_REGION}:${ACCOUNT_ID}:apps/${amplify_app_id}",
        "arn:aws:amplify:${AWS_REGION}:${ACCOUNT_ID}:apps/${amplify_app_id}/branches/main",
        "arn:aws:amplify:${AWS_REGION}:${ACCOUNT_ID}:apps/${amplify_app_id}/branches/main/jobs/*"
      ]
    }
  ]
}
EOF
aws iam put-role-policy --role-name "$GITHUB_DEPLOYMENT_ROLE" --policy-name "${PROJECT_NAME}-deployment" \
  --policy-document "file://$TEMP_DIR/github-deployment-policy.json"

cat <<EOF

Bootstrap complete. Set these GitHub production-environment variables:

AWS_ROLE_TO_ASSUME=$github_deployment_role_arn
AWS_REGION=$AWS_REGION
AWS_RDS_INSTANCE_IDENTIFIER=$DB_INSTANCE_IDENTIFIER
AWS_ECR_REPOSITORY=$ECR_REPOSITORY
AWS_APP_RUNNER_SERVICE_ARN=$service_arn
AWS_AMPLIFY_APP_ID=$amplify_app_id

Service endpoints:
STRAPI_URL=$strapi_url
AWS_S3_BASE_URL=https://$media_domain
AMPLIFY_URL=$frontend_origin

Before the first production deployment, import the existing Strapi SQLite data and verify
that the supplied subnets are private and have the required NAT gateway or VPC endpoints.
EOF
