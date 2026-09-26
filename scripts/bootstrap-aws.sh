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

aws_file_uri() {
  local path="$1"

  if command -v cygpath >/dev/null 2>&1; then
    printf 'file://%s' "$(cygpath -m "$path")"
  else
    printf 'file://%s' "$path"
  fi
}

ensure_secret() {
  local name="$1"
  local value="$2"
  local arn

  arn="$(aws secretsmanager describe-secret --secret-id "$name" --query 'ARN' --output text 2>/dev/null || true)"
  if [[ -z "$arn" || "$arn" == "None" ]]; then
    arn="$(aws secretsmanager create-secret --name "$name" --secret-string "$value" --query 'ARN' --output text)"
  fi
  [[ -n "$arn" && "$arn" != "None" ]] || fail "Unable to create or find Secrets Manager secret: $name"
  printf '%s' "$arn"
}

ensure_role() {
  local name="$1"
  local trust_policy="$2"
  local arn

  arn="$(aws iam get-role --role-name "$name" --query 'Role.Arn' --output text 2>/dev/null || true)"
  if [[ -z "$arn" || "$arn" == "None" ]]; then
    arn="$(aws iam create-role --role-name "$name" --assume-role-policy-document "$(aws_file_uri "$trust_policy")" --query 'Role.Arn' --output text)"
  else
    aws iam update-assume-role-policy --role-name "$name" --policy-document "$(aws_file_uri "$trust_policy")"
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

require_public_subnet() {
  local subnet_id="$1"
  local route_table_id
  local gateway_id

  route_table_id="$(aws ec2 describe-route-tables --filters "Name=association.subnet-id,Values=$subnet_id" \
    --query 'RouteTables[0].RouteTableId' --output text)"
  if [[ -z "$route_table_id" || "$route_table_id" == "None" ]]; then
    route_table_id="$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" "Name=association.main,Values=true" \
      --query 'RouteTables[0].RouteTableId' --output text)"
  fi
  gateway_id="$(aws ec2 describe-route-tables --route-table-ids "$route_table_id" \
    --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0'].GatewayId | [0]" --output text)"
  [[ "$gateway_id" == igw-* ]] || fail "PUBLIC_SUBNET_IDS subnet $subnet_id must have a 0.0.0.0/0 route to an Internet Gateway"
}

require_command aws
require_command docker
require_command openssl

PROJECT_NAME="${PROJECT_NAME:-}"
AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-}"
VPC_ID="${VPC_ID:-}"
PRIVATE_SUBNET_IDS="${PRIVATE_SUBNET_IDS:-}"
PUBLIC_SUBNET_IDS="${PUBLIC_SUBNET_IDS:-}"
DATABASE_NAME="${DATABASE_NAME:-strapi}"
DATABASE_USERNAME="${DATABASE_USERNAME:-strapiadmin}"
DATABASE_INSTANCE_CLASS="${DATABASE_INSTANCE_CLASS:-db.t4g.micro}"
AMPLIFY_REPOSITORY_URL="${AMPLIFY_REPOSITORY_URL:-}"

require_value PROJECT_NAME
require_value AWS_REGION
require_value GITHUB_REPOSITORY
require_value VPC_ID
require_value PRIVATE_SUBNET_IDS
require_value PUBLIC_SUBNET_IDS

[[ "$PROJECT_NAME" =~ ^[a-z][a-z0-9-]{1,30}$ ]] || fail "PROJECT_NAME must be lowercase letters, numbers, and hyphens"
[[ "$GITHUB_REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail "GITHUB_REPOSITORY must be owner/repository"
[[ "$VPC_ID" =~ ^vpc-[a-z0-9]+$ ]] || fail "VPC_ID must be a VPC ID"
[[ "$DATABASE_NAME" =~ ^[A-Za-z][A-Za-z0-9_]{0,62}$ ]] || fail "DATABASE_NAME must be a PostgreSQL database name"
[[ "$DATABASE_USERNAME" =~ ^[A-Za-z][A-Za-z0-9_]{0,62}$ ]] || fail "DATABASE_USERNAME must be a PostgreSQL username"

IFS=',' read -r -a PRIVATE_SUBNET_ID_LIST <<< "$PRIVATE_SUBNET_IDS"
(( ${#PRIVATE_SUBNET_ID_LIST[@]} >= 2 )) || fail "PRIVATE_SUBNET_IDS must contain at least two private subnet IDs"
for subnet_id in "${PRIVATE_SUBNET_ID_LIST[@]}"; do
  [[ "$subnet_id" =~ ^subnet-[a-z0-9]+$ ]] || fail "Invalid subnet ID: $subnet_id"
done

IFS=',' read -r -a PUBLIC_SUBNET_ID_LIST <<< "$PUBLIC_SUBNET_IDS"
(( ${#PUBLIC_SUBNET_ID_LIST[@]} >= 2 )) || fail "PUBLIC_SUBNET_IDS must contain at least two public subnet IDs"
for subnet_id in "${PUBLIC_SUBNET_ID_LIST[@]}"; do
  [[ "$subnet_id" =~ ^subnet-[a-z0-9]+$ ]] || fail "Invalid subnet ID: $subnet_id"
  require_public_subnet "$subnet_id"
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
ECS_SERVICE="${PROJECT_NAME}-strapi"
ECS_TASK_ROLE="${PROJECT_NAME}-ecs-task"
ECS_EXECUTION_ROLE="${PROJECT_NAME}-ecs-execution"
ECS_INFRASTRUCTURE_ROLE="${PROJECT_NAME}-ecs-infrastructure"
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

ecs_security_group="$(ensure_security_group "${PROJECT_NAME}-ecs" "ECS access for $PROJECT_NAME")"
database_security_group="$(ensure_security_group "${PROJECT_NAME}-database" "PostgreSQL access for $PROJECT_NAME")"
if ! aws ec2 describe-security-groups --group-ids "$database_security_group" \
  --query "SecurityGroups[0].IpPermissions[?FromPort==\`5432\` && UserIdGroupPairs[?GroupId=='$ecs_security_group']]" \
  --output text | grep -q .; then
  aws ec2 authorize-security-group-ingress --group-id "$database_security_group" \
    --ip-permissions "IpProtocol=tcp,FromPort=5432,ToPort=5432,UserIdGroupPairs=[{GroupId=$ecs_security_group}]" >/dev/null
fi

if ! aws rds describe-db-subnet-groups --db-subnet-group-name "$DB_SUBNET_GROUP" >/dev/null 2>&1; then
  aws rds create-db-subnet-group --db-subnet-group-name "$DB_SUBNET_GROUP" \
    --db-subnet-group-description "Private subnets for $PROJECT_NAME" \
    --subnet-ids "${PRIVATE_SUBNET_ID_LIST[@]}" >/dev/null
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
  "IsIPV6Enabled": true,
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
  distribution_id="$(aws cloudfront create-distribution --distribution-config "$(aws_file_uri "$TEMP_DIR/distribution.json")" \
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
aws s3api put-bucket-policy --bucket "$BUCKET_NAME" --policy "$(aws_file_uri "$TEMP_DIR/bucket-policy.json")"

cat > "$TEMP_DIR/ecs-task-trust.json" <<'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}
EOF
ecs_task_role_arn="$(ensure_role "$ECS_TASK_ROLE" "$TEMP_DIR/ecs-task-trust.json")"
cat > "$TEMP_DIR/ecs-task-policy.json" <<EOF
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
aws iam put-role-policy --role-name "$ECS_TASK_ROLE" --policy-name "${PROJECT_NAME}-media" \
  --policy-document "$(aws_file_uri "$TEMP_DIR/ecs-task-policy.json")"

cat > "$TEMP_DIR/ecs-execution-trust.json" <<'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}
EOF
ecs_execution_role_arn="$(ensure_role "$ECS_EXECUTION_ROLE" "$TEMP_DIR/ecs-execution-trust.json")"
aws iam attach-role-policy --role-name "$ECS_EXECUTION_ROLE" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
cat > "$TEMP_DIR/ecs-execution-policy.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
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
aws iam put-role-policy --role-name "$ECS_EXECUTION_ROLE" --policy-name "${PROJECT_NAME}-secrets" \
  --policy-document "$(aws_file_uri "$TEMP_DIR/ecs-execution-policy.json")"

cat > "$TEMP_DIR/ecs-infrastructure-trust.json" <<'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs.amazonaws.com"},"Action":"sts:AssumeRole"}]}
EOF
ecs_infrastructure_role_arn="$(ensure_role "$ECS_INFRASTRUCTURE_ROLE" "$TEMP_DIR/ecs-infrastructure-trust.json")"
aws iam attach-role-policy --role-name "$ECS_INFRASTRUCTURE_ROLE" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSInfrastructureRoleforExpressGatewayServices
aws iam delete-role-policy --role-name "$ECS_INFRASTRUCTURE_ROLE" --policy-name "${PROJECT_NAME}-infrastructure" 2>/dev/null || true

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
LOG_GROUP_NAME="ecs/${ECS_SERVICE}"
aws logs create-log-group --log-group-name "$LOG_GROUP_NAME" 2>/dev/null || true
cat > "$TEMP_DIR/ecs-primary-container.json" <<EOF
{
  "image": "${image_uri}",
  "containerPort": 1337,
  "awsLogsConfiguration": {"logGroup": "${LOG_GROUP_NAME}", "logStreamPrefix": "strapi"},
  "environment": [
    {"name":"AWS_REGION","value":"${AWS_REGION}"},
    {"name":"AWS_S3_BUCKET","value":"${BUCKET_NAME}"},
    {"name":"AWS_S3_BASE_URL","value":"https://${media_domain}"},
    {"name":"CORS_ORIGIN","value":"${frontend_origin}"},
    {"name":"DATABASE_CLIENT","value":"postgres"},
    {"name":"DATABASE_HOST","value":"${database_host}"},
    {"name":"DATABASE_NAME","value":"${DATABASE_NAME}"},
    {"name":"DATABASE_PORT","value":"5432"},
    {"name":"DATABASE_SSL","value":"true"},
    {"name":"DATABASE_SSL_REJECT_UNAUTHORIZED","value":"true"},
    {"name":"HOST","value":"0.0.0.0"},
    {"name":"NODE_ENV","value":"production"},
    {"name":"PORT","value":"1337"}
  ],
  "secrets": [
    {"name":"ADMIN_JWT_SECRET","valueFrom":"${admin_jwt_secret_arn}"},
    {"name":"API_TOKEN_SALT","valueFrom":"${api_token_salt_arn}"},
    {"name":"APP_KEYS","valueFrom":"${app_keys_arn}"},
    {"name":"DATABASE_PASSWORD","valueFrom":"${database_password_arn}"},
    {"name":"DATABASE_USERNAME","valueFrom":"${database_username_arn}"},
    {"name":"JWT_SECRET","valueFrom":"${jwt_secret_arn}"},
    {"name":"TRANSFER_TOKEN_SALT","valueFrom":"${transfer_token_salt_arn}"}
  ]
}
EOF
cat > "$TEMP_DIR/ecs-network.json" <<EOF
{
  "securityGroups": ["${ecs_security_group}"],
  "subnets": [$(printf '"%s",' "${PUBLIC_SUBNET_ID_LIST[@]}" | sed 's/,$//')]
}
EOF
service_arn="$(aws ecs list-services --cluster default --region "$AWS_REGION" \
  --query "serviceArns[?contains(@, '/$ECS_SERVICE')] | [0]" --output text 2>/dev/null || true)"
if [[ -z "$service_arn" || "$service_arn" == "None" ]]; then
  service_arn="$(MSYS_NO_PATHCONV=1 aws ecs create-express-gateway-service --service-name "$ECS_SERVICE" --cluster default \
    --infrastructure-role-arn "$ecs_infrastructure_role_arn" --execution-role-arn "$ecs_execution_role_arn" \
    --task-role-arn "$ecs_task_role_arn" --primary-container "$(aws_file_uri "$TEMP_DIR/ecs-primary-container.json")" \
    --network-configuration "$(aws_file_uri "$TEMP_DIR/ecs-network.json")" \
    --health-check-path /admin --cpu 1024 --memory 2048 --query 'service.serviceArn' --output text)"
fi
for _ in {1..60}; do
  service_status="$(aws ecs describe-express-gateway-service --service-arn "$service_arn" --region "$AWS_REGION" --query 'service.status.statusCode' --output text)"
  [[ "$service_status" == "ACTIVE" ]] && break
  [[ "$service_status" != "INACTIVE" ]] || fail "ECS Express service status: $service_status"
  sleep 20
done
[[ "$service_status" == "ACTIVE" ]] || fail "Timed out waiting for ECS Express service"
for _ in {1..30}; do
  strapi_endpoint="$(aws ecs describe-express-gateway-service --service-arn "$service_arn" --region "$AWS_REGION" --query 'service.activeConfigurations[0].ingressPaths[0].endpoint' --output text)"
  [[ -n "$strapi_endpoint" && "$strapi_endpoint" != "None" ]] && break
  sleep 20
done
[[ -n "$strapi_endpoint" && "$strapi_endpoint" != "None" ]] || fail "Timed out waiting for ECS Express ingress endpoint"
ingress_access_type="$(aws ecs describe-express-gateway-service --service-arn "$service_arn" --region "$AWS_REGION" --query 'service.activeConfigurations[0].ingressPaths[0].accessType' --output text)"
[[ "$ingress_access_type" == "PUBLIC" ]] || fail "ECS Express created a $ingress_access_type ingress endpoint. Amplify cannot reach a private endpoint; use a public API endpoint before configuring STRAPI_URL."
strapi_url="${strapi_endpoint}"
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
      "Action": ["ecs:UpdateExpressGatewayService", "ecs:DescribeExpressGatewayService", "ecs:DescribeServiceDeployments"],
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
  --policy-document "$(aws_file_uri "$TEMP_DIR/github-deployment-policy.json")"

cat <<EOF

Bootstrap complete. Set these GitHub production-environment variables:

AWS_ROLE_TO_ASSUME=$github_deployment_role_arn
AWS_REGION=$AWS_REGION
AWS_RDS_INSTANCE_IDENTIFIER=$DB_INSTANCE_IDENTIFIER
AWS_ECR_REPOSITORY=$ECR_REPOSITORY
AWS_ECS_SERVICE_ARN=$service_arn
AWS_AMPLIFY_APP_ID=$amplify_app_id

Service endpoints:
STRAPI_URL=$strapi_url
AWS_S3_BASE_URL=https://$media_domain
AMPLIFY_URL=$frontend_origin

Before the first production deployment, import the existing Strapi SQLite data and verify
that the supplied subnets are private and have the required NAT gateway or VPC endpoints.
EOF
