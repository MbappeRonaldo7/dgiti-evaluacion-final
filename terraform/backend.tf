# ---------------------------------------------------------------------------
# backend.tf - Estado remoto en S3 (compartido entre el PC y el pipeline)
# El nombre del bucket se pasa en "terraform init" con -backend-config,
# porque depende del ID de la cuenta del Learner Lab (ver scripts/init.sh).
# use_lockfile = true activa el bloqueo nativo de S3 (Terraform >= 1.10).
# ---------------------------------------------------------------------------
terraform {
  backend "s3" {
    key          = "dgiti/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
