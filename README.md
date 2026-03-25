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

By default this will deploy two EKS clusters:

- `k8tre-dev-argocd` is where ArgoCD will run
- `k8tre-dev` is where K8TRE will be deployed

IAM roles and pod identities are setup to allow ArgoCD running in the `k8tre-dev-argocd` cluster to have admin access to the `k8tre-dev` cluster.

### Configuration

Edit [`provider.tf`](provider.tf).
You must modify `terraform.backend.s3` `bucket` to match the one in `bootstrap/backend.tf`.

You can install K8TRE AWS with no changes, but you will most likely want to set some variables.
Either modify [`variables.tf`](variables.tf), or copy [`overrides.tfvars-example`](overrides.tfvars-example) to `overrides.tfvars` and edit.

### Run Terraform

Activate your AWS credentials in your shell environment.
Terraform must be applied in several stages.
This is because Terraform needs to resolve some resources before running, but some of these resources don't initially exist.

Initialise Terraform providers and modules:

```sh
terraform init
```

Deploy the EKS cluster control plane, a Route 53 Private Zone, and EFS:

```sh
terraform apply -var-file=overrides.tfvars -var deployment_stage=0
```

Deploy EKS compute nodes, and Cilium:

```sh
terraform apply -var-file=overrides.tfvars -var deployment_stage=1
```

Deploy ArgoCD and some other prerequisites:

```sh
terraform apply -var-file=overrides.tfvars -var deployment_stage=2
```

Deploy K8TRE

```sh
terraform apply -var-file=overrides.tfvars -var deployment_stage=3
```

If any commands file or timeout try rerunning them.

### Kubernetes access

`terraform apply` should display the command to create a [kubeconfig file](https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/) for the `k8tre-dev` and `k8tre-dev-argocd` clusters.

### ArgoCD access

For convenience you can run the [`./argocd-portforward.sh`](`argocd-portforward.sh`) to start a port-forward to the ArgoCD web interface.
Open http://localhost:8080 in your browser and login with username `admin` nd the password displayed by the script.

If any Applications are not healthy check them, and if necessary try forcing a sync, or forcing broken resources to be recreated.

## Things to note

EKS is deployed in a private subnet, with NAT gateway to a public subnet
A [GitHub OIDC role](https://docs.github.com/en/actions/concepts/security/openid-connect) can optionally be created.

The cluster has a single EKS node group in a single subnet (single availability zone) to reduce costs, and to avoid multi-AZ storage.
If you require multi-AZ high-availability you will need to modify this.

A prefix list `${var.cluster_name}-service-access-cidrs` is provided for convenience
This is not used in any Terraform resource, but can be referenced in other resources such as Application load balancers deployed in EKS.

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

tflint --init
tflint --recursive

npx prettier@3.8.1 --write '**/*.{yaml,yml,md}'
```
