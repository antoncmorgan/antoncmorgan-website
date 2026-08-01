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

## One-time AWS setup

1. **Networking:** create a VPC across at least two Availability Zones. Put RDS in private subnets. Create an App Runner VPC connector with access to those subnets and allow its security group to reach RDS on PostgreSQL port 5432. Do not make RDS publicly accessible.
2. **Database:** create an encrypted RDS PostgreSQL instance, enable automated backups, deletion protection, and Performance Insights. Create the Strapi database and user. Import or migrate the existing local SQLite content before cutover. The workflow makes an additional *manual* RDS snapshot before every deployment; configure an EventBridge/Lambda retention policy to remove aged manual snapshots.
3. **Media:** create an encrypted S3 bucket with versioning enabled. Create a CloudFront distribution with Origin Access Control for the bucket and set its domain as `AWS_S3_BASE_URL`. Grant the App Runner instance role only `s3:GetObject`, `s3:PutObject`, and `s3:DeleteObject` on that bucket's objects. Keep the bucket private.
4. **Container registry:** create a private ECR repository for Strapi. Create an App Runner service from its `latest` image, configured for **manual** deployments, port `1337`, and the health endpoint appropriate for the service. Configure its ECR access role to pull that repository.
5. **App Runner configuration:** inject the values below from Secrets Manager or as non-secret environment variables. Use the App Runner VPC connector and attach the S3 instance role. Set a custom API domain and HTTPS certificate.
6. **Amplify:** create an Amplify Hosting app and its `main` branch. Set the app root to `client`, Node.js to 22, and use `npm ci` then `npm run build`. Set `STRAPI_URL` to the HTTPS App Runner API URL. Configure the public website domain and HTTPS certificate.
7. **Observability:** retain App Runner logs in CloudWatch and create alarms for App Runner deployment failures, HTTP 5xx responses, RDS CPU/storage/connections, and Amplify deployment failures.

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
