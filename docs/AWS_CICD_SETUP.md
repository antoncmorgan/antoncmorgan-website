# AWS CI/CD setup

## Chosen architecture

| Workload | AWS service | Why |
| --- | --- | --- |
| Next.js frontend | AWS Amplify Hosting | Managed Next.js SSR/CDN hosting, branch builds, custom domains, and no server administration. |
| Strapi API | Amazon ECS Express Mode from Amazon ECR | Managed Fargate container deployment, HTTPS ingress, health management, and autoscaling. |
| Database | Amazon RDS for PostgreSQL | Durable relational storage supported by Strapi, automated backups, snapshots, and private networking. |
| Media | Amazon S3 behind CloudFront | Durable uploads independent of ECS task storage; CloudFront serves media without exposing the bucket. |
| Application secrets | AWS Secrets Manager | ECS task execution can inject database and Strapi secrets without placing them in GitHub. |
| Logs and alarms | Amazon CloudWatch | Centralized application logs, deployment diagnostics, and availability alarms. |

The workflow deploys only on a push to `main`, which is produced when a pull request is merged. It validates pull requests and direct pushes to every non-`main` branch. It also uses Semantic Release to derive the version and `CHANGELOG.md` from conventional commits after a successful production deployment.

## Repository changes

- `.github/workflows/validate.yml` validates conventional commits and runs each application's available `test`, `test:system`, and build scripts.
- `.github/workflows/deploy.yml` builds both applications, waits for an RDS snapshot, publishes a versioned and `latest` Strapi image to ECR, updates ECS Express Mode, then starts the Amplify production build.
- `strapi/Dockerfile` is the ECS image definition.
- Strapi now supports PostgreSQL and S3 uploads. Without `AWS_S3_BUCKET`, local development continues to use local uploads.
- The frontend reads `STRAPI_URL`, defaulting to `http://localhost:1337` for local development.

There are currently no unit or system test scripts in either application. The validation workflow deliberately uses `--if-present`; add those scripts as tests are introduced, and make the `Validate` workflow a required pull-request check.

## Complete setup checklist

1. Select the production AWS account and region, install and authenticate [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html), and install Docker and OpenSSL on the trusted operator machine.
2. Create or select a VPC with at least two public subnets and two private subnets, each pair in separate Availability Zones. Public subnets need a `0.0.0.0/0` route to an Internet Gateway; private subnets need [private-subnet egress](https://docs.aws.amazon.com/vpc/latest/userguide/vpc-nat-gateway.html) or suitable VPC endpoints.
3. Create a repository-scoped [GitHub personal access token](https://docs.github.com/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens) for Amplify, then run [`scripts/bootstrap-aws.sh`](../scripts/bootstrap-aws.sh) with the inputs below.
4. Add the script's printed values to the protected GitHub `production` environment and retain its OIDC restrictions; see [GitHub environments](https://docs.github.com/actions/reference/workflows-and-actions/deployments-and-environments) and [AWS OIDC configuration](https://docs.github.com/actions/how-tos/secure-your-work/security-harden-deployments/oidc-in-aws).
5. Migrate the existing SQLite content, configure domains and [ACM certificates](https://docs.aws.amazon.com/acm/latest/userguide/gs-acm-request-public.html), and set the ECS Express CORS origin and frontend Strapi URL to the production domains.
6. Configure the listed CloudWatch alarms and snapshot retention, then merge a validated conventional-commit pull request and approve the first production deployment.

## Automated one-time setup

`scripts/bootstrap-aws.sh` provisions the ECR repository, private/versioned/encrypted media bucket, CloudFront Origin Access Control and distribution, private RDS PostgreSQL database, ECS Express Mode service and roles, Amplify app and `main` branch, Strapi Secrets Manager values, and the GitHub Actions OIDC deployment role. It also builds and publishes the initial Strapi image, then prints the six values to add to the GitHub `production` environment.

Install and authenticate AWS CLI v2, Docker, and OpenSSL on a trusted machine. The GitHub personal access token used for Amplify must have access to this repository; the script does not write it to disk or print it. Provide an existing VPC, at least two **public** subnets for ECS Express, and at least two **private** subnets for RDS. Public subnets must route to an Internet Gateway. Private subnets need NAT access or suitable VPC endpoints for RDS-related operations. The script creates the ECS and database security groups and permits PostgreSQL access only from ECS.

```bash
export PROJECT_NAME=antoncmorgan
export AWS_REGION=eu-west-2
export GITHUB_REPOSITORY=antoncmorgan/antoncmorgan-website
export VPC_ID=vpc-0123456789abcdef0
export PRIVATE_SUBNET_IDS=subnet-0123456789abcdef0,subnet-0123456789abcdef1
export PUBLIC_SUBNET_IDS=subnet-0123456789abcdef2,subnet-0123456789abcdef3

./scripts/bootstrap-aws.sh
```

The script securely prompts for the PostgreSQL master password and Amplify GitHub access token. `PROJECT_NAME` must contain only lowercase letters, numbers, and hyphens. To use a different database size or name, set `DATABASE_INSTANCE_CLASS`, `DATABASE_NAME`, or `DATABASE_USERNAME` before running it. Re-running it preserves existing secrets and resources, but do not use it as a database migration tool.

## What to do after bootstrap

The script has created the AWS resources, deployed a first Strapi image, and created an Amplify application. It has **not** imported the existing content, configured custom domains, configured GitHub environments, or enabled useful operational alerts. Work through the following in order.

### 1. Save the bootstrap output

At the end of a successful run, the script prints six GitHub environment variables and three public endpoints. Save them in a password manager or another private operator record:

- `AWS_ROLE_TO_ASSUME`
- `AWS_REGION`
- `AWS_RDS_INSTANCE_IDENTIFIER`
- `AWS_ECR_REPOSITORY`
- `AWS_ECS_SERVICE_ARN`
- `AWS_AMPLIFY_APP_ID`
- `STRAPI_URL`, `AWS_S3_BASE_URL`, and `AMPLIFY_URL`

The secret values remain in AWS Secrets Manager; do not copy the generated database password or Strapi secrets into GitHub, source control, or an `.env` file.

### 2. Verify the initial AWS deployment

Use the printed values in a fresh terminal. Prefix the printed ECS endpoint with `https://` when setting `STRAPI_URL`; the ECS API returns only a hostname. These checks confirm the service, frontend host, media distribution, and database are reachable from their expected locations.

```bash
export AWS_REGION=eu-west-2
export AWS_ECS_SERVICE_ARN='paste the printed service ARN'
export AWS_RDS_INSTANCE_IDENTIFIER='paste the printed DB identifier'
export STRAPI_URL='https://paste-the-printed-Strapi-hostname'
export AMPLIFY_URL='paste the printed Amplify URL'
export AWS_S3_BASE_URL='paste the printed CloudFront URL'

aws ecs describe-express-gateway-service \
	--service-arn "$AWS_ECS_SERVICE_ARN" \
	--query 'service.status.statusCode' --output text
aws rds describe-db-instances \
	--db-instance-identifier "$AWS_RDS_INSTANCE_IDENTIFIER" \
	--query 'DBInstances[0].[DBInstanceStatus,PubliclyAccessible]' --output text
curl --fail --location --head "$STRAPI_URL/admin"
curl --fail --location --head "$AMPLIFY_URL"
curl --location --head "$AWS_S3_BASE_URL"
```

Expect an ECS status of `ACTIVE`, an RDS status of `available` with `False` for public access, and successful API/frontend HTTP responses. A CloudFront `403` response is expected until an uploaded media object is requested; its distribution itself can take several minutes to finish deploying. If the ingress access type is `PRIVATE`, the Strapi URL is only reachable from the VPC: a laptop and Amplify Hosting cannot use it. Use a public API entry point before setting `STRAPI_URL` in Amplify. For a failed Strapi deployment, start with the `ecs/<project>-strapi` CloudWatch log group created by the script.

### 3. Configure GitHub production deployment

In GitHub, open **Settings > Environments > New environment** and create `production`. Add the first six values from step 1 as **environment variables**, not secrets. In particular, `AWS_ROLE_TO_ASSUME` must be the printed IAM role ARN.

Protect the environment with the reviewers who may approve production deployments. The role's OIDC trust policy only accepts a deployment from `repo:<owner>/<repository>:environment:production`, so a workflow cannot assume it until this environment exists. Do not create AWS access keys for GitHub.

Then protect `main` under **Settings > Branches**: require pull requests, require the `Validate` workflow checks, and restrict direct pushes. Allow the release workflow to create tags/releases and, if semantic-release needs them, pull requests and issues under **Settings > Actions > General > Workflow permissions**.

### 4. Publish a first CI/CD deployment

Create a small conventional-commit pull request, for example `chore: verify production deployment`, and merge it into `main`. Approve the `production` environment when GitHub pauses the deployment.

The deployment workflow first builds both applications, creates a manual RDS snapshot, publishes a commit-tagged and `latest` Strapi image, updates ECS Express Mode, then starts the Amplify `main` release. Semantic Release runs only after all deployment steps succeed. Review the GitHub Actions log and confirm the final ECS and Amplify URLs still respond.

### 5. Initialize and migrate Strapi content

Open `STRAPI_URL/admin`, create the initial Strapi administrator account, and confirm you can create, publish, and retrieve a small test item. Upload one test media item and request its returned URL; it should be served via `AWS_S3_BASE_URL`, not an ECS container filesystem path.

There is no automatic SQLite-to-RDS migration in this repository. Export or recreate the content from the existing local Strapi instance before switching visitor traffic to the new frontend. Take an RDS snapshot before any bulk import. Keep the existing site live until the migrated content, API permissions, and uploaded media have been verified.

### 6. Add custom domains before public cutover

Configure the custom website domain in Amplify and the API domain in ECS Express Mode, requesting or attaching the required ACM certificates in the AWS region required by each service. Add the DNS records AWS supplies and wait for certificate validation and domain activation.

After both domains are active, update the deployed Strapi configuration so `CORS_ORIGIN` is the final website origin and `AWS_S3_BASE_URL` is the final media origin if you also add a CloudFront media domain. The script initially uses the generated Amplify URL, so cross-origin browser requests from a custom frontend domain will otherwise be rejected. Make this configuration change through the ECS Express service settings, then deploy again and verify a browser request from the website domain succeeds.

### 7. Set operational guardrails

Create CloudWatch alarms for ECS deployment failures and HTTP 5xx responses, RDS CPU/storage/free space/connections, and Amplify deployment failures. The workflow creates a manual RDS snapshot for every deployment; implement an EventBridge/Lambda cleanup policy that retains the required number of `strapi-predeploy-*` snapshots so they do not accumulate indefinitely. Review AWS Budgets and Cost Explorer during the first billing cycle because RDS, NAT gateways, CloudFront, and ECS all incur ongoing cost.

## ECS Express environment

Store the secret values in Secrets Manager and reference them from the ECS Express service:

- `DATABASE_URL` or `DATABASE_HOST`, `DATABASE_PORT`, `DATABASE_NAME`, `DATABASE_USERNAME`, `DATABASE_PASSWORD`
- `APP_KEYS` (a comma-separated set of at least four long random values)
- `ADMIN_JWT_SECRET`, `API_TOKEN_SALT`, `TRANSFER_TOKEN_SALT`, and `JWT_SECRET`

Set these non-secret values:

- `DATABASE_CLIENT=postgres`, `DATABASE_SSL=true`, and `DATABASE_SSL_REJECT_UNAUTHORIZED=true`
- `HOST=0.0.0.0`, `PORT=1337`, and `NODE_ENV=production`
- `AWS_REGION`, `AWS_S3_BUCKET`, and `AWS_S3_BASE_URL=https://<media-cloudfront-domain>`
- `CORS_ORIGIN=https://<frontend-domain>`

Use the RDS CA bundle with strict certificate validation where the deployment model requires it. Rotate every secret periodically and redeploy ECS Express after rotation.

## GitHub configuration

Create a GitHub **production environment** named `production`, protect it with the appropriate reviewers, and add these non-secret environment variables:

| Variable | Value |
| --- | --- |
| `AWS_ROLE_TO_ASSUME` | ARN of the GitHub Actions deployment role |
| `AWS_REGION` | Deployment region |
| `AWS_RDS_INSTANCE_IDENTIFIER` | RDS DB instance identifier |
| `AWS_ECR_REPOSITORY` | Private ECR repository name |
| `AWS_ECS_SERVICE_ARN` | Strapi ECS Express service ARN |
| `AWS_AMPLIFY_APP_ID` | Amplify application ID |

Do **not** add long-lived AWS access keys to GitHub secrets. Configure the IAM role's OIDC trust policy for `token.actions.githubusercontent.com`, restrict `sub` to this repository's `production` environment, and require the `sts.amazonaws.com` audience. Grant only:

- `rds:CreateDBSnapshot` and `rds:DescribeDBSnapshots` for the production database;
- ECR authorization and push permissions for the selected repository;
- `ecs:UpdateExpressGatewayService`, `ecs:DescribeExpressGatewayService`, and `ecs:DescribeServiceDeployments` for the selected service;
- `amplify:StartJob` and `amplify:GetJob` for the selected app and branch.

For releases, allow GitHub Actions read/write workflow `contents` permission and enable GitHub Actions to create pull requests/issues if required by the repository settings. Protect `main`, require the `Validate` checks, require pull requests, and allow only squash merges. The squash commit title must use Conventional Commits, for example `feat: add project filters` or `fix: correct image URL`.

## First deployment and recovery

1. Run the validation workflow on a conventional-commit pull request and merge it into `main`.
2. Approve the protected `production` deployment. Confirm the workflow reaches a completed RDS snapshot before it publishes the image.
3. Verify the ECS Express API, S3/CloudFront media, Amplify site, CORS policy, and CloudWatch alarms.
4. If deployment fails after the snapshot, stop promotion, restore the named RDS snapshot to a new instance, validate it, and repoint the App Runner secret/configuration. Re-deploy the last known ECR image digest. Do not restore over the live database without a tested recovery procedure.
