# K8TRE AWS base infrastructure

[![Lint](https://github.com/manics/k8tre-infrastructure-aws/actions/workflows/lint.yml/badge.svg)](https://github.com/manics/k8tre-infrastructure-aws/actions/workflows/lint.yml)

Deploy AWS infrastructure using Terraform to support [K8TRE](https://github.com/k8tre/k8tre).

## First time

You must first create a S3 bucket to store the [Terraform state file](https://developer.hashicorp.com/terraform/language/state).
Activate your AWS credentials in your shell environment, edit the `resource.aws_s3_bucket.bucket` `bucket` name in [`bootstrap/backend.tf`](bootstrap/backend.tf), then:

```sh
cd backend
terraform init
terraform apply
cd ..
```

## Deploy Amazon Elastic Kubernetes Service (EKS)

By default this 3will deploy two EKS clusters:

- `k8tre-dev-argocd` is where ArgoCD will run
- `k8tre-dev` is where K8TRE will be deployed

IAM roles and pod identities are setup to allow ArgoCD running in the `k8tre-dev-argocd` cluster to have admin access to the `k8tre-dev` cluster.

### Configuration

Edit [`main.tf`](main.tf).
You must modify `terraform.backend.s3` `bucket` to match the one in `bootstrap/backend.tf`, and you may want to modify the configuration of `module.k8tre-eks`.

If you want to deploy ArgoCD in the same cluster as K8TRE delete

- `module.k8tre-argocd-eks`
- `output.kubeconfig_command_k8tre-argocd-dev`

### Run Terraform

Activate your AWS credentials in your shell environment, then:

```sh
terraform init
terraform apply
```

If there's a timeout run

```sh
terraform apply
```

again.

### Kubernetes access

`terraform apply` should display the command to create a [kubeconfig file](https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/) for the `k8tre-dev` and `k8tre-dev-argocd` clusters.

### Install K8TRE prerequisites and ArgoCD

The `apps` directory will install some Kubernetes prerequisites for K8TRE, as well as setting up ArgoCD.
If you prefer you can set everything up manually following the [K8TRE documentation](https://github.com/k8tre/k8tre/blob/main/docs/development/k3s-dev.md#setup-argocd).

Edit [`apps/variables.tf`](apps/variables.tf):

- Modify `terraform.backend.s3` `bucket` to match the one in `bootstrap/backend.tf`.
- Change the `data.terraform_remote_state.k8tre` section to match the `backend.s3` section in `main.tf`.
  This allows the ArgoCD terraform to automatically lookup up the EKS details without needing to specify everything manually.
- By default this will also install the K8TRE ArgoCD root-app-of-apps.
  Set `install_k8tre = false` to disable this.

## Things to note

EKS is deployed in a private subnet, with NAT gateway to a public subnet
A [GitHub OIDC role](https://docs.github.com/en/actions/concepts/security/openid-connect) can optionally be created.

The cluster has a single EKS node group in a single subnet (single availability zone) to reduce costs, and to avoid multi-AZ storage.
If you require multi-AZ high-availability you will need to modify this.

A prefix list `${var.cluster_name}-service-access-cidrs` is provided for convenience
This is not used in any Terraform resource, but can be referenced in Application load balancers deployed in EKS

## Optional wildcard certificate (not currently automated)

To simplify certificate management in K8TRE you can optionally create a wildcard public certificate using [Amazon Certificate Manager](https://docs.aws.amazon.com/acm/latest/userguide/acm-public-certificates.html).
This certificate can then be used in AWS load balancers provisioned by K8TRE without further configuration.

## Developer notes

To debug Argocd inter-cluster auth:

```sh
kubectl -nargocd exec -it deploy/argocd-server -- bash

argocd-k8s-auth aws --cluster-name k8tre-dev --role-arn arn:aws:iam::${ACCOUNT_ID}:role/k8tre-dev-eks-access
```

### Linting

When making changes to this repository run:

```sh
terraform validate
terraform fmt -recursive
tflint --recursive
npx prettier@3.6.2 --write '**/*.{yaml,yml,md}'
```

### Configuring K8TRE

Set the required labels using `k8tre_cluster_label_overrides` in `apps/variables.tf`
