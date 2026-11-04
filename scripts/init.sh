#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# init.sh - Crea (si no existe) el bucket S3 del estado y ejecuta terraform init.
# Lo usan tanto el PC local como el pipeline, para compartir el mismo estado.
# Uso:  ./scripts/init.sh        (desde la raíz del repositorio)
# ---------------------------------------------------------------------------
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
BUCKET="dgiti-tfstate-${ACCOUNT_ID}"

if ! aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  echo ">> Creando bucket de estado: $BUCKET"
  aws s3api create-bucket --bucket "$BUCKET" --region "$REGION"
  aws s3api put-bucket-versioning --bucket "$BUCKET" \
    --versioning-configuration Status=Enabled
  aws s3api put-public-access-block --bucket "$BUCKET" \
    --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
else
  echo ">> Bucket de estado ya existe: $BUCKET"
fi

cd "$(dirname "$0")/../terraform"
terraform init -reconfigure -backend-config="bucket=${BUCKET}"
