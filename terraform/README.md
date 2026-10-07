# Target B — Terraform for AWS

**Arrives in milestone M2.** Same topology as the Compose kit on ECS Fargate (main, webhook processors, workers with runner sidecars), RDS Postgres 18 Multi-AZ, ElastiCache Valkey, ALB + ACM, EFS for binary data, S3 for encrypted backups, CloudWatch + the same Grafana dashboards.

Planned layout: `terraform/aws/{main,variables,outputs}.tf` + `modules/{network,ecs,rds-postgres,elasticache-valkey,efs,alb,s3,iam,monitoring}`; `plan` snapshot tests on PR, weekly sandbox `apply`/`destroy`, cost table in the docs.
