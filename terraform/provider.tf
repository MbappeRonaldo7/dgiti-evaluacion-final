# ---------------------------------------------------------------------------
# provider.tf - Versión de Terraform, proveedor AWS y etiquetas por defecto
# ---------------------------------------------------------------------------
terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
  }
}

provider "aws" {
  region = var.aws_region
  # Las credenciales NO van aquí: se toman del entorno
  # (AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_SESSION_TOKEN)
  # o de ~/.aws/credentials copiado desde "AWS Details" del Learner Lab.

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      Owner       = var.owner
      ManagedBy   = "Terraform"
      Course      = "DGITI-UPB"
    }
  }
}
