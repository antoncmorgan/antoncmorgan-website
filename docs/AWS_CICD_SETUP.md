# AWS CI/CD setup

## Chosen architecture

| Workload | AWS service | Why |
| --- | --- | --- |
| Next.js frontend | AWS Amplify Hosting | Managed Next.js SSR/CDN hosting, branch builds, custom domains, and no server administration. |
| Strapi API | AWS App Runner from Amazon ECR | Managed container deployment and health management, with a small operational footprint for this site. |
| Database | Amazon RDS for PostgreSQL | Durable relational storage supported by Strapi, automated backups, snapshots, and private networking. |
| Media | Amazon S3 behind CloudFront | Durable uploads independent of App Runner's ephemeral filesystem; CloudFront serves media without exposing the bucket. |
| Application secrets | AWS Secrets Manager | App Runner can inject database and Strapi secrets without placing them in GitHub. |
| Logs and alarms | Amazon CloudWatch | Centralized application logs, deployment diagnostics, and availability alarms. |

The workflow deploys only on a push to `main`, which is produced when a pull request is merged. It validates pull requests and direct pushes to every non-`main` branch. It also uses Semantic Release to derive the version and `CHANGELOG.md` from conventional commits after a successful production deployment.

## Repository changes

- `.github/workflows/validate.yml` validates conventional commits and runs each application's available `test`, `test:system`, and build scripts.
- `.github/workflows/deploy.yml` builds both applications, waits for an RDS snapshot, publishes a versioned and `latest` Strapi image to ECR, deploys App Runner, then starts the Amplify production build.
- `strapi/Dockerfile` is the App Runner image definition.
- Strapi now supports PostgreSQL and S3 uploads. Without `AWS_S3_BUCKET`, local development continues to use local uploads.
- The frontend reads `STRAPI_URL`, defaulting to `http://localhost:1337` for local development.

There are currently no unit or system test scripts in either application. The validation workflow deliberately uses `--if-present`; add those scripts as tests are introduced, and make the `Validate` workflow a required pull-request check.

## Complete setup checklist

1. Select the production AWS account and region, install and authenticate [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html), and install Docker and OpenSSL on the trusted operator machine.
2. Create or select a VPC with two private subnets in separate Availability Zones and provide their required [private-subnet egress](https://docs.aws.amazon.com/vpc/latest/userguide/vpc-nat-gateway.html).
3. Create a repository-scoped [GitHub personal access token](https://docs.github.com/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens) for Amplify, then run [`scripts/bootstrap-aws.sh`](../scripts/bootstrap-aws.sh) with the inputs below.
4. Add the script's printed values to the protected GitHub `production` environment and retain its OIDC restrictions; see [GitHub environments](https://docs.github.com/actions/reference/workflows-and-actions/deployments-and-environments) and [AWS OIDC configuration](https://docs.github.com/actions/how-tos/secure-your-work/security-harden-deployments/oidc-in-aws).
5. Migrate the existing SQLite content, configure domains and [ACM certificates](https://docs.aws.amazon.com/acm/latest/userguide/gs-acm-request-public.html), and set the App Runner CORS origin and frontend Strapi URL to the production domains.
6. Configure the listed CloudWatch alarms and snapshot retention, then merge a validated conventional-commit pull request and approve the first production deployment.

## Automated one-time setup

`scripts/bootstrap-aws.sh` provisions the ECR repository, private/versioned/encrypted media bucket, CloudFront Origin Access Control and distribution, private RDS PostgreSQL database, App Runner VPC connector and service, Amplify app and `main` branch, Strapi Secrets Manager values, and the GitHub Actions OIDC deployment role. It also builds and publishes the initial Strapi image, then prints the six values to add to the GitHub `production` environment.

Install and authenticate AWS CLI v2, Docker, and OpenSSL on a trusted machine. The GitHub personal access token used for Amplify must have access to this repository; the script does not write it to disk or print it. Provide an existing VPC and at least two **private** subnets. Those subnets need NAT access or suitable VPC endpoints for the running service to access AWS APIs. The script creates the App Runner and database security groups and permits PostgreSQL access only from App Runner.

```bash
export PROJECT_NAME=antoncmorgan
export AWS_REGION=eu-west-2
export GITHUB_REPOSITORY=antoncmorgan/antoncmorgan-website
export VPC_ID=vpc-0123456789abcdef0
export PRIVATE_SUBNET_IDS=subnet-0123456789abcdef0,subnet-0123456789abcdef1

./scripts/bootstrap-aws.sh
```

The script securely prompts for the PostgreSQL master password and Amplify GitHub access token. `PROJECT_NAME` must contain only lowercase letters, numbers, and hyphens. To use a different database size or name, set `DATABASE_INSTANCE_CLASS`, `DATABASE_NAME`, or `DATABASE_USERNAME` before running it. Re-running it preserves existing secrets and resources, but do not use it as a database migration tool.

After it completes, configure custom domains/certificates, CloudWatch alarms, snapshot-retention cleanup, and import existing SQLite content before enabling production traffic.

## Manual configuration after bootstrap

1. **Networking:** create the VPC and supply two or more private subnet IDs to the script. Confirm that those subnets span at least two Availability Zones and provide the required NAT gateway or VPC endpoints. Do not make RDS publicly accessible.
2. **Database:** import or migrate the existing local SQLite content before cutover. The workflow makes an additional *manual* RDS snapshot before every deployment; configure an EventBridge/Lambda retention policy to remove aged manual snapshots.
3. **Domains:** configure custom API, website, and media domains and their HTTPS certificates after the default App Runner, Amplify, and CloudFront endpoints have been verified.
4. **Observability:** retain App Runner logs in CloudWatch and create alarms for App Runner deployment failures, HTTP 5xx responses, RDS CPU/storage/connections, and Amplify deployment failures.

## App Runner environment

Store the secret values in Secrets Manager and reference them from the App Runner service:

- `DATABASE_URL` or `DATABASE_HOST`, `DATABASE_PORT`, `DATABASE_NAME`, `DATABASE_USERNAME`, `DATABASE_PASSWORD`
- `APP_KEYS` (a comma-separated set of at least four long random values)
- `ADMIN_JWT_SECRET`, `API_TOKEN_SALT`, `TRANSFER_TOKEN_SALT`, and `JWT_SECRET`

Set these non-secret values:

- `DATABASE_CLIENT=postgres`, `DATABASE_SSL=true`, and `DATABASE_SSL_REJECT_UNAUTHORIZED=true`
- `HOST=0.0.0.0`, `PORT=1337`, and `NODE_ENV=production`
- `AWS_REGION`, `AWS_S3_BUCKET`, and `AWS_S3_BASE_URL=https://<media-cloudfront-domain>`
- `CORS_ORIGIN=https://<frontend-domain>`

Use the RDS CA bundle with strict certificate validation where the deployment model requires it. Rotate every secret periodically and restart/redeploy App Runner after rotation.

## GitHub configuration

Create a GitHub **production environment** named `production`, protect it with the appropriate reviewers, and add these non-secret environment variables:

| Variable | Value |
| --- | --- |
| `AWS_ROLE_TO_ASSUME` | ARN of the GitHub Actions deployment role |
| `AWS_REGION` | Deployment region |
| `AWS_RDS_INSTANCE_IDENTIFIER` | RDS DB instance identifier |
| `AWS_ECR_REPOSITORY` | Private ECR repository name |
| `AWS_APP_RUNNER_SERVICE_ARN` | Strapi App Runner service ARN |
| `AWS_AMPLIFY_APP_ID` | Amplify application ID |

Do **not** add long-lived AWS access keys to GitHub secrets. Configure the IAM role's OIDC trust policy for `token.actions.githubusercontent.com`, restrict `sub` to this repository's `production` environment, and require the `sts.amazonaws.com` audience. Grant only:

- `rds:CreateDBSnapshot` and `rds:DescribeDBSnapshots` for the production database;
- ECR authorization and push permissions for the selected repository;
- `apprunner:StartDeployment` and `apprunner:ListOperations` for the selected service;
- `amplify:StartJob` and `amplify:GetJob` for the selected app and branch.

For releases, allow GitHub Actions read/write workflow `contents` permission and enable GitHub Actions to create pull requests/issues if required by the repository settings. Protect `main`, require the `Validate` checks, require pull requests, and allow only squash merges. The squash commit title must use Conventional Commits, for example `feat: add project filters` or `fix: correct image URL`.

## First deployment and recovery

1. Run the validation workflow on a conventional-commit pull request and merge it into `main`.
2. Approve the protected `production` deployment. Confirm the workflow reaches a completed RDS snapshot before it publishes the image.
3. Verify the App Runner API, S3/CloudFront media, Amplify site, CORS policy, and CloudWatch alarms.
4. If deployment fails after the snapshot, stop promotion, restore the named RDS snapshot to a new instance, validate it, and repoint the App Runner secret/configuration. Re-deploy the last known ECR image digest. Do not restore over the live database without a tested recovery procedure.
