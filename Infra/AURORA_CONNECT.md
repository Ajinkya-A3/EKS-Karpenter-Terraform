# Aurora Serverless v2 (PostgreSQL) — Connection Guide

## TL;DR — which auth method should you use?

| Workload | Method | Why |
|---|---|---|
| **App pods (SELECT/INSERT/UPDATE)** | **IRSA + IAM DB auth** | No password stored anywhere; 15-min auto-expiring tokens; CloudTrail audit trail |
| **Migration Jobs (CREATE TABLE, ALTER, etc.)** | Master user via Secrets Manager | Needs superuser DDL privileges that `app_user` doesn't have |
| **Local dev / DBA one-off** | Port-forward + IAM auth or master creds | DB is private-subnet-only; no public endpoint |

**Bottom line: do not store a password in a Kubernetes Secret or environment variable for your app pods.** Use IRSA — the pattern is already working in this cluster for ALB and EBS CSI. Aurora is just one more consumer of the same mechanism.

---

## 1. How the network path works

Three things wired by Terraform make pod → Aurora connectivity work:

**Subnets:** The `aws_db_subnet_group` uses `aws_subnet.private[*]` — the same private subnets the EKS nodes run in. Aurora has no public IP and no route to the internet gateway.

**Security group:** The Aurora SG accepts TCP/5432 only from `aws_security_group.node` (the EKS node SG). Every pod on every node inherits that node SG for outbound traffic, so pods can reach Aurora. No other source in the VPC can.

**DNS:** The writer endpoint (`<cluster>.cluster-<id>.<region>.rds.amazonaws.com`) resolves to a private IP inside the VPC. CoreDNS in the cluster forwards external names to the VPC resolver — pods resolve it without any extra config.

You do **not** need a VPC endpoint for RDS data-plane traffic; it is just TCP inside the VPC. IAM token generation (`GenerateAuthToken`) calls STS, for which a VPC endpoint already exists in this setup.

---

## 2. One-time DB setup — create the IAM-auth user

PostgreSQL IAM auth works differently from MySQL. Instead of a special plugin, you grant the built-in `rds_iam` role to a regular PostgreSQL user.

### Step 1 — get the master credentials

```bash
CLUSTER_NAME=demo        # match your var.cluster_name
REGION=ap-south-1

SECRET_ARN=$(terraform output -raw aurora_master_user_secret_arn)

CREDS=$(aws secretsmanager get-secret-value \
  --secret-id "$SECRET_ARN" \
  --region "$REGION" \
  --query SecretString \
  --output text)

MASTER_USER=$(echo "$CREDS" | jq -r .username)   # "postgres"
MASTER_PASS=$(echo "$CREDS" | jq -r .password)
AURORA_HOST=$(terraform output -raw aurora_cluster_endpoint)
DB_NAME=$(terraform output -raw aurora_database_name)   # "appdb"
```

### Step 2 — connect as the master user (from a pod or bastion)

Run a throwaway pod with psql inside the cluster:

```bash
kubectl run psql-setup --rm -it \
  --image=postgres:16 \
  --env="PGPASSWORD=$MASTER_PASS" \
  --restart=Never \
  -- psql "host=$AURORA_HOST port=5432 dbname=$DB_NAME user=$MASTER_USER sslmode=require"
```

### Step 3 — create the IAM-auth role inside PostgreSQL

```sql
-- Create the role your app pods will authenticate as.
-- No password — authentication happens via IAM token.
CREATE USER app_user;

-- This is the PostgreSQL equivalent of AWSAuthenticationPlugin in MySQL.
-- It tells Aurora: "when app_user connects, validate via IAM instead of password."
GRANT rds_iam TO app_user;

-- Grant only the permissions your app actually needs.
-- Never grant superuser to the app role.
GRANT CONNECT ON DATABASE appdb TO app_user;
\c appdb
GRANT USAGE ON SCHEMA public TO app_user;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO app_user;

-- Make future tables automatically accessible (so migrations don't break grants).
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app_user;

-- Verify:
SELECT rolname, rolcanlogin FROM pg_roles WHERE rolname = 'app_user';
-- Should show: app_user | t
```

---

## 3. Kubernetes ServiceAccount

The IRSA role's trust policy is locked to exactly `system:serviceaccount:<namespace>:<name>`.
Defaults are `default/app-db-access` — override with `aurora_app_service_account_namespace` and `aurora_app_service_account_name` variables.

```yaml
# k8s/service-account.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: app-db-access
  namespace: default
  annotations:
    # Get this value from: terraform output -raw aurora_app_irsa_role_arn
    eks.amazonaws.com/role-arn: arn:aws:iam::123456789012:role/demo-aurora-app-role
```

Apply it:
```bash
kubectl apply -f k8s/service-account.yaml
```

---

## 4. Kubernetes Deployment

No password env var, no Secret mount — the SA annotation is the entire auth story:

```yaml
# k8s/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: myapp
  namespace: default
spec:
  replicas: 2
  selector:
    matchLabels: { app: myapp }
  template:
    metadata:
      labels: { app: myapp }
    spec:
      serviceAccountName: app-db-access    # <— annotated SA → IRSA role → IAM token
      containers:
      - name: app
        image: 123456789012.dkr.ecr.ap-south-1.amazonaws.com/myapp:latest
        env:
        - name: DB_HOST
          # terraform output -raw aurora_cluster_endpoint
          value: "demo-aurora.cluster-xxxx.ap-south-1.rds.amazonaws.com"
        - name: DB_PORT
          value: "5432"
        - name: DB_USER
          value: "app_user"
        - name: DB_NAME
          value: "appdb"
        - name: DB_SSLMODE
          value: "require"
        - name: AWS_REGION
          value: "ap-south-1"
```

---

## 5. App code — generate a token and connect

### Important notes before reading the samples

- **Token lifetime:** 15 minutes. The token is only checked at *connect time*, not during an existing connection's lifetime. Connections held open > 15 min continue to work fine.
- **Pool recycling:** Set `pool_recycle` / `idleTimeout` to < 15 minutes so that stale connections are recycled and new ones get a fresh token.
- **TLS is mandatory:** IAM auth is refused on plaintext connections. Always pass `sslmode=require` (or `verify-full` in prod with the RDS CA bundle).
- **Scale-from-zero latency:** With `min_capacity = 0`, the first connection after idle takes ~15 seconds while the cluster resumes. Set `connect_timeout` to **30+ seconds** and implement at least 3 retries.

Download the RDS CA bundle once and bake it into your image or mount it as a ConfigMap:

```dockerfile
# In your Dockerfile
ADD https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem /etc/ssl/rds/global-bundle.pem
```

---

### Python — psycopg2 + SQLAlchemy

```python
import os, time, boto3
from sqlalchemy import create_engine, event, text
from sqlalchemy.pool import QueuePool

DB_HOST   = os.environ["DB_HOST"]
DB_PORT   = int(os.environ.get("DB_PORT", "5432"))
DB_USER   = os.environ["DB_USER"]
DB_NAME   = os.environ["DB_NAME"]
AWS_REGION = os.environ["AWS_REGION"]
RDS_CA    = "/etc/ssl/rds/global-bundle.pem"   # from Dockerfile or ConfigMap

rds_client = boto3.client("rds", region_name=AWS_REGION)

def generate_token() -> str:
    """Generate a fresh 15-minute IAM auth token."""
    return rds_client.generate_db_auth_token(
        DBHostname=DB_HOST,
        Port=DB_PORT,
        DBUsername=DB_USER,
        Region=AWS_REGION,
    )

def make_engine():
    import psycopg2

    def connect():
        token = generate_token()
        # sslmode=require is the minimum. Use verify-full + sslrootcert in prod.
        conn = psycopg2.connect(
            host=DB_HOST,
            port=DB_PORT,
            user=DB_USER,
            password=token,         # IAM token acts as the password
            dbname=DB_NAME,
            sslmode="require",
            sslrootcert=RDS_CA,
            connect_timeout=30,     # 30s to allow scale-from-zero resume
        )
        return conn

    return create_engine(
        "postgresql+psycopg2://",
        creator=connect,            # creator is called fresh per new connection
        poolclass=QueuePool,
        pool_size=5,
        max_overflow=10,
        pool_pre_ping=True,         # discard dead connections before use
        pool_recycle=600,           # recycle after 10 min (well under 15 min token TTL)
    )

engine = make_engine()

# Usage:
with engine.connect() as conn:
    result = conn.execute(text("SELECT version()"))
    print(result.fetchone())
```

---

### Python — asyncpg (async / FastAPI / Starlette)

```python
import os, asyncpg, boto3

DB_HOST    = os.environ["DB_HOST"]
DB_PORT    = int(os.environ.get("DB_PORT", "5432"))
DB_USER    = os.environ["DB_USER"]
DB_NAME    = os.environ["DB_NAME"]
AWS_REGION = os.environ["AWS_REGION"]
RDS_CA     = "/etc/ssl/rds/global-bundle.pem"

rds = boto3.client("rds", region_name=AWS_REGION)

import ssl
ssl_ctx = ssl.create_default_context(cafile=RDS_CA)
ssl_ctx.check_hostname = False   # Aurora endpoint CN doesn't match; CA validation is enough

async def create_pool() -> asyncpg.Pool:
    return await asyncpg.create_pool(
        host=DB_HOST,
        port=DB_PORT,
        user=DB_USER,
        database=DB_NAME,
        # asyncpg calls `password` as a coroutine/callable on each new connection
        password=lambda: rds.generate_db_auth_token(
            DBHostname=DB_HOST, Port=DB_PORT, DBUsername=DB_USER, Region=AWS_REGION
        ),
        ssl=ssl_ctx,
        timeout=30,              # scale-from-zero can take ~15s
        min_size=1,
        max_size=10,
        max_inactive_connection_lifetime=600,  # recycle before 15-min token expiry
    )

# In FastAPI lifespan:
# app.state.db = await create_pool()
```

---

### Node.js — node-postgres (`pg`)

```javascript
const { Pool } = require('pg');
const { Signer } = require('@aws-sdk/rds-signer');
const fs = require('fs');

const host   = process.env.DB_HOST;
const port   = Number(process.env.DB_PORT ?? '5432');
const user   = process.env.DB_USER;
const dbname = process.env.DB_NAME;
const region = process.env.AWS_REGION;
const ca     = fs.readFileSync('/etc/ssl/rds/global-bundle.pem');

const signer = new Signer({ hostname: host, port, region, username: user });

// node-postgres accepts `password` as an async function.
// It is called fresh each time a new client is created from the pool.
const pool = new Pool({
  host,
  port,
  user,
  database: dbname,
  password: () => signer.getAuthToken(),   // async fn → fresh token per connection
  ssl: { ca, rejectUnauthorized: true },
  connectionTimeoutMillis: 30_000,    // 30s — allows scale-from-zero resume
  idleTimeoutMillis: 600_000,         // 10 min — recycle before 15-min token expiry
  max: 10,
});

// Usage:
const { rows } = await pool.query('SELECT version()');
console.log(rows[0]);
```

---

### Go — `pgx` v5

```go
package db

import (
    "context"
    "crypto/tls"
    "crypto/x509"
    "fmt"
    "os"
    "time"

    "github.com/aws/aws-sdk-go-v2/config"
    "github.com/aws/aws-sdk-go-v2/feature/rds/auth"
    "github.com/jackc/pgx/v5/pgxpool"
)

func NewPool(ctx context.Context) (*pgxpool.Pool, error) {
    host   := os.Getenv("DB_HOST")
    port   := os.Getenv("DB_PORT")   // "5432"
    user   := os.Getenv("DB_USER")
    dbname := os.Getenv("DB_NAME")
    region := os.Getenv("AWS_REGION")

    awsCfg, err := config.LoadDefaultConfig(ctx, config.WithRegion(region))
    if err != nil {
        return nil, fmt.Errorf("load aws config: %w", err)
    }

    // Load RDS CA bundle for TLS verification.
    caPem, err := os.ReadFile("/etc/ssl/rds/global-bundle.pem")
    if err != nil {
        return nil, fmt.Errorf("read rds ca: %w", err)
    }
    pool := x509.NewCertPool()
    pool.AppendCertsFromPEM(caPem)
    tlsCfg := &tls.Config{RootCAs: pool}

    pgCfg, err := pgxpool.ParseConfig(fmt.Sprintf(
        "host=%s port=%s user=%s dbname=%s sslmode=require",
        host, port, user, dbname,
    ))
    if err != nil {
        return nil, fmt.Errorf("parse pgx config: %w", err)
    }

    pgCfg.ConnConfig.TLSConfig = tlsCfg
    pgCfg.ConnConfig.ConnectTimeout = 30 * time.Second   // scale-from-zero

    // BeforeConnect is called per new connection in the pool.
    // This is where we inject a fresh IAM token as the password.
    pgCfg.BeforeConnect = func(ctx context.Context, cc *pgx.ConnConfig) error {
        token, err := auth.BuildAuthToken(ctx,
            fmt.Sprintf("%s:%s", host, port), region, user, awsCfg.Credentials,
        )
        if err != nil {
            return fmt.Errorf("generate rds auth token: %w", err)
        }
        cc.Password = token
        return nil
    }

    pgCfg.MaxConns = 10
    pgCfg.MaxConnIdleTime = 10 * time.Minute   // recycle before 15-min token TTL

    return pgxpool.NewWithConfig(ctx, pgCfg)
}
```

---

## 6. Migration Jobs (using master credentials)

For schema migrations, you need a superuser. Use the master credentials from Secrets Manager — but fetch them at runtime in the Job, never store them in a Kubernetes Secret:

```yaml
# k8s/migration-job.yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: db-migrate
  namespace: default
spec:
  backoffLimit: 2
  template:
    spec:
      serviceAccountName: app-db-access   # needs aurora_app_read_master_secret = true
      restartPolicy: Never
      containers:
      - name: migrate
        image: 123456789012.dkr.ecr.ap-south-1.amazonaws.com/migrator:latest
        env:
        - name: AURORA_SECRET_ARN
          value: "arn:aws:secretsmanager:ap-south-1:123456789012:secret:rds!cluster-..."
        - name: DB_HOST
          value: "demo-aurora.cluster-xxxx.ap-south-1.rds.amazonaws.com"
        - name: DB_NAME
          value: "appdb"
        - name: AWS_REGION
          value: "ap-south-1"
        command: ["/bin/sh", "-c"]
        args:
        - |
          set -e
          CREDS=$(aws secretsmanager get-secret-value \
            --secret-id "$AURORA_SECRET_ARN" \
            --region "$AWS_REGION" \
            --query SecretString --output text)
          export PGUSER=$(echo "$CREDS" | jq -r .username)
          export PGPASSWORD=$(echo "$CREDS" | jq -r .password)
          export PGHOST=$DB_HOST
          export PGDATABASE=$DB_NAME
          export PGSSLMODE=require
          # Run alembic / flyway / django manage.py migrate / etc.
          alembic upgrade head
```

Enable the optional Secrets Manager read in Terraform:
```hcl
# terraform.tfvars
aurora_app_read_master_secret = true
```

---

## 7. Troubleshooting checklist

If a pod can't connect, check in this order:

**DNS:** Can the pod resolve the Aurora endpoint?
```bash
kubectl exec -it <pod> -- nslookup demo-aurora.cluster-xxxx.ap-south-1.rds.amazonaws.com
# Should return a 10.0.x.x private IP
```

**IAM identity:** Is the pod actually using the IRSA role?
```bash
kubectl exec -it <pod> -- aws sts get-caller-identity
# Should show the aurora-app-role ARN, NOT the node role ARN
# If it shows the node role → SA annotation is missing or wrong
```

**DB user:** Does `app_user` exist with `rds_iam`?
```sql
SELECT rolname, rolcanlogin
FROM pg_roles
WHERE rolname IN ('app_user');
-- If no row → run the CREATE USER / GRANT rds_iam steps in section 2

SELECT member::regrole, role::regrole
FROM pg_auth_members
WHERE role = 'rds_iam'::regrole;
-- app_user should appear here
```

**SSL:** Is the client passing sslmode=require?
Connections without TLS are rejected at the cluster level by `rds.force_ssl = 1`.

**Scale-from-zero:** First connection after idle takes ~15 seconds. If `connect_timeout` is less than 15s in your driver config, the connection will time out before the cluster finishes resuming. Set it to **30s minimum**.

**Token expiry in pool:** A connection token is only checked at connect time. If you see auth errors after 15 minutes, your pool is creating *new* connections with a cached (expired) token. Make sure the `password` parameter in your pool config is a *callable* (function/lambda) — not a pre-computed string captured at startup.

---

## 8. Quick-reference: outputs you'll use every day

```bash
terraform output aurora_cluster_endpoint         # DB_HOST
terraform output aurora_cluster_port             # 5432
terraform output aurora_database_name            # appdb
terraform output aurora_app_db_user              # app_user
terraform output -raw aurora_app_irsa_role_arn   # annotate the ServiceAccount with this
terraform output -raw aurora_master_user_secret_arn   # for migration Jobs only
```
