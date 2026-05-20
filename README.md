# K8TRE AWS base infrastructure

[![Lint](https://github.com/manics/k8tre-infrastructure-aws/actions/workflows/lint.yml/badge.svg)](https://github.com/manics/k8tre-infrastructure-aws/actions/workflows/lint.yml)

Deploy AWS infrastructure using Terraform to support [K8TRE](https://github.com/k8tre/k8tre).

## Prerequisites

- Administrator access to an AWS account.
- Ideally you should have access to a domain name to setup a wildcard host, e.g. `*.k8tre.example.org`.
- For production we strongly recommend you have an AWS Organisation with security policies and guardrails or equivalents.

## First time

You must first create a S3 bucket to store the [Terraform state file](https://developer.hashicorp.com/terraform/language/state).
Activate your AWS credentials in your shell environment, edit the `resource.aws_s3_bucket.bucket` `bucket` name in [`bootstrap/backend.tf`](bootstrap/backend.tf), then:

```sh
cd bootstrap
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

Particularly important variables include

- `dns_domain`: The domain for K8TRE, e.g. `k8tre.example.org`
- `request_certificate`: K8TRE requires a HTTPS certificate to be stored in AWS ACM, set this to `acm` to request a proper certificate instead of using a self-signed one.
- `number_availability_zones`: By default the deployed clusters run in a single availability zone to make it easier to deal with `ReadWriteOnce` persistent volumes which are backed by EBS volumes, which are tied to a single AZ.
  Increasing this provides more resilience to AWS outages, at the expense of needing more nodes in all AZs since once an EBS volume for a pod has been provisioned that pod can only ever be run in that AZ.

### Run Terraform

Activate your AWS credentials in your shell environment.
Terraform must be applied in several stages.
This is because Terraform needs to resolve some resources before running, but some of these resources don't initially exist.

Initialise Terraform providers and modules:

```sh
terraform init
```

Deploy the EKS cluster control plane, a Route 53 Private Zone, EFS, and HTTPS certificate:

```sh
terraform apply -var-file=overrides.tfvars -var deployment_stage=0
```

If you set `request_certificate = "acm"` then [create the DNS validation records](https://docs.aws.amazon.com/acm/latest/userguide/dns-validation.html) shown in the output.

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

On subsequent runs, for instance after updating your configuration, you can use the default

```sh
terraform apply -var-file=overrides.tfvars
```

Occasionally this may finish successfully, but some dependent resources will still be out of date, for example after upgrading the EKS cluster version
Rerun this command to be sure.

### K8TRE secrets

K8TRE requires several secrets in AWS SSM, such as credentials for applications.
You can use the `create-ci-secrets.py` script in the K8TRE repository to create them:

```sh
uv run create-ci-secrets.py --backend aws-ssm --region eu-west-2
```

### Kubernetes access

`terraform apply` should display the command to create a [kubeconfig file](https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/) for the `k8tre-dev` and `k8tre-dev-argocd` clusters.

### ArgoCD access

For convenience you can run the [`./argocd-portforward.sh`](`argocd-portforward.sh`) to start a port-forward to the ArgoCD web interface.
Open http://localhost:8080 in your browser and login with username `admin` and the password displayed by the script.

If any Applications are not healthy check them, and if necessary try forcing a sync, or forcing broken resources to be recreated.

### K8TRE access

K8TRE will setup a private Route53 DNS zone and configure the K8TRE VPC to use it.
Either

- Create an EC2 desktop instance or workspace attached to the VPC and connect to `https://portal.k8tre.example.org`
- Create an external application load balancer, see https://github.com/k8tre/k8tre-aws/issues/32

## K8TRE deployment overview

![K8TRE deployment overview](docs/k8tre-aws-infra-account.drawio.svg)

This deployment requires you to have administative access to an AWS Account, but assumes your AWS organisation and your DNS infrastructure are managed by a separate entity from the one deploying K8TRE.

It does not attempt to configure anything outside this single AWS account, nor does it configure any public DNS.
We recommend you use an [ACM managed public certificate](https://docs.aws.amazon.com/acm/latest/userguide/acm-public-certificates.html).
This deployment can request a certificate for you, but you must setup the DNS validation records yourself.
Once this is done you can proceed with deploying K8TRE, and the internal Application Load Balancer created by K8TRE should automatically use the certfiicate.

EKS is deployed in a private subnet, with NAT gateway to a public subnet.
By default the cluster has a single EKS node group in a single subnet (single availability zone) to reduce costs, and to avoid multi-AZ storage.
[EKS Pod Identities](https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html) allow specified Kubernetes service accounts to access AWS APIs.

A prefix list `${var.cluster_name}-service-access-cidrs` is provided for convenience
This is not used in any Terraform resource, but can be referenced in other resources such as Application load balancers deployed in EKS.

## AWS Organisation

This repository only manages the K8TRE infrastructure for a single AWS account.

We strongly recommend you setup a multi-account AWS Organisation, for example using [AWS Control Tower](https://aws.amazon.com/controltower/) or [Landing Zone Accelerator on AWS](https://aws.amazon.com/solutions/implementations/landing-zone-accelerator-on-aws/).
This organisation should include monitoring and security tools, either using AWS services or a third party alternative.

For example:
![Example K8TRE AWS organisation](docs/k8tre-aws-infra-organisation.drawio.svg)

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
prek run -a
```

prek (or pre-commit) will run some autoformatters, and TFlint.

## Autogenerated documentation

<!-- This section is automatically generated and updated by prek terraform-docs, do not modify! -->
<!-- prettier-ignore-start -->
<!-- BEGIN_TF_DOCS -->
### Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| <a name="module_certificate"></a> [certificate](#module\_certificate) | ./certificate | n/a |
| <a name="module_dnsresolver"></a> [dnsresolver](#module\_dnsresolver) | ./dnsresolver | n/a |
| <a name="module_efs"></a> [efs](#module\_efs) | ./efs | n/a |
| <a name="module_k8tre-argocd-eks"></a> [k8tre-argocd-eks](#module\_k8tre-argocd-eks) | ./k8tre-eks | n/a |
| <a name="module_k8tre-eks"></a> [k8tre-eks](#module\_k8tre-eks) | ./k8tre-eks | n/a |
| <a name="module_transparent-proxy"></a> [transparent-proxy](#module\_transparent-proxy) | ./transparent-proxy | n/a |
| <a name="module_vpc"></a> [vpc](#module\_vpc) | terraform-aws-modules/vpc/aws | 6.6.0 |

### Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_additional_admin_principals"></a> [additional\_admin\_principals](#input\_additional\_admin\_principals) | Additional EKS admin principals | `map(string)` | `{}` | no |
| <a name="input_additional_k8s_manifests"></a> [additional\_k8s\_manifests](#input\_additional\_k8s\_manifests) | List of paths to additional K8s manifests (one per file, multidoc YAML files are not supported) | `list(string)` | `[]` | no |
| <a name="input_additional_outbound_proxy_allowed_domains_re"></a> [additional\_outbound\_proxy\_allowed\_domains\_re](#input\_additional\_outbound\_proxy\_allowed\_domains\_re) | Allow outgoing http/https to these domains in addition to default\_outbound\_proxy\_allowed\_domains\_re | `list(string)` | `[]` | no |
| <a name="input_allowed_cidrs"></a> [allowed\_cidrs](#input\_allowed\_cidrs) | CIDRs allowed to access K8TRE ('myip' is dynamically replaced by your current IP) | `list(string)` | <pre>[<br/>  "myip"<br/>]</pre> | no |
| <a name="input_argocd_version"></a> [argocd\_version](#input\_argocd\_version) | ArgoCD Helm chart version | `string` | `"9.4.15"` | no |
| <a name="input_create_public_zone"></a> [create\_public\_zone](#input\_create\_public\_zone) | Create public DNS zone | `bool` | `false` | no |
| <a name="input_default_outbound_proxy_allowed_domains_re"></a> [default\_outbound\_proxy\_allowed\_domains\_re](#input\_default\_outbound\_proxy\_allowed\_domains\_re) | Allow outgoing http/https to these domains by default | `list(string)` | <pre>[<br/>  "amazonaws\\.com$",<br/>  "api\\.aws$",<br/>  "docker\\.com$",<br/>  "docker\\.io$",<br/>  "ghcr\\.io$",<br/>  "quay\\.io$",<br/>  "external-secrets\\.io$",<br/>  "charts\\.external-secrets\\.io$",<br/>  "aws\\.github\\.io$",<br/>  "codecentric\\.github\\.io$",<br/>  "jupyterhub\\.github\\.io$",<br/>  "kubernetes\\.github\\.io$",<br/>  "kubernetes-sigs\\.github\\.io$",<br/>  "lsc-sde\\.github\\.io$",<br/>  "github\\.com$",<br/>  "pkg-containers\\.githubusercontent\\.com$",<br/>  "raw\\.githubusercontent\\.com$",<br/>  "release-assets\\.githubusercontent\\.com$",<br/>  "dl\\.gitea\\.com$",<br/>  "charts\\.jetstack\\.io$",<br/>  "hub\\.jupyter\\.org$",<br/>  "www\\.manicstreetpreacher\\.co\\.uk$",<br/>  "dl-cdn\\.alpinelinux\\.org$"<br/>]</pre> | no |
| <a name="input_deployment_stage"></a> [deployment\_stage](#input\_deployment\_stage) | Multi-stage deployment step.<br/>  This is necessary because Terraform needs to resolve some resources before<br/>  running, but those resource amy not exist yet.<br/>  For the first deployment you must step through these starting at<br/>  '-var deployment\_stage=0', then '-var deployment\_stage=1'.<br/>  Future deployment can use the highest number (default). | `number` | `3` | no |
| <a name="input_dns_domain"></a> [dns\_domain](#input\_dns\_domain) | DNS domain | `string` | `"k8tre.internal"` | no |
| <a name="input_efs_token"></a> [efs\_token](#input\_efs\_token) | EFS name creation token, if null default to var.name | `string` | `null` | no |
| <a name="input_eks_autoupdate_addons"></a> [eks\_autoupdate\_addons](#input\_eks\_autoupdate\_addons) | Whether to autoupdate the versions of EKS addons when Terraform is run.<br/>If you plan to upgrade EKS you may need to set this to `true` before the<br/>upgrade since the current addon versions may not be compatible with the<br/>planned upgrade. | `bool` | `false` | no |
| <a name="input_enable_github_oidc"></a> [enable\_github\_oidc](#input\_enable\_github\_oidc) | Create GitHub OIDC role | `bool` | `false` | no |
| <a name="input_install_k8tre"></a> [install\_k8tre](#input\_install\_k8tre) | Install K8TRE root app-of-apps | `bool` | `true` | no |
| <a name="input_k8tre_cluster_label_overrides"></a> [k8tre\_cluster\_label\_overrides](#input\_k8tre\_cluster\_label\_overrides) | Additional labels merged with k8tre\_cluster\_labels and applied to K8TRE cluster | `map(string)` | `{}` | no |
| <a name="input_k8tre_cluster_labels"></a> [k8tre\_cluster\_labels](#input\_k8tre\_cluster\_labels) | Argocd labels applied to K8TRE cluster | `map(string)` | <pre>{<br/>  "environment": "dev",<br/>  "external-dns": "aws",<br/>  "secret-store": "aws",<br/>  "skip-metallb": "true",<br/>  "vendor": "aws"<br/>}</pre> | no |
| <a name="input_k8tre_github_ref"></a> [k8tre\_github\_ref](#input\_k8tre\_github\_ref) | K8TRE git ref (commit/branch/tag) | `string` | `"main"` | no |
| <a name="input_k8tre_github_repo"></a> [k8tre\_github\_repo](#input\_k8tre\_github\_repo) | K8TRE GitHub organisation and repository to install | `string` | `"k8tre/k8tre"` | no |
| <a name="input_name"></a> [name](#input\_name) | Name used for most resources | `string` | `"k8tre-dev"` | no |
| <a name="input_number_availability_zones"></a> [number\_availability\_zones](#input\_number\_availability\_zones) | Number of availability zones to use for EKS.<br/>EBS volumes are tied to a single AZ, so if you have multiple AZs you must<br/>ensure you always have sufficient nodes in all AZs to run all pods<br/>that use EBS. | `number` | `1` | no |
| <a name="input_outbound_proxy_cidrs"></a> [outbound\_proxy\_cidrs](#input\_outbound\_proxy\_cidrs) | Traffic for these CIDRs will be directed through the proxy | `list(string)` | <pre>[<br/>  "0.0.0.0/0"<br/>]</pre> | no |
| <a name="input_private_subnets"></a> [private\_subnets](#input\_private\_subnets) | Private subnet CIDRs to create. These IPs are used by EKS pods so make it large! | `list(string)` | <pre>[<br/>  "10.0.64.0/18",<br/>  "10.0.128.0/18"<br/>]</pre> | no |
| <a name="input_public_subnets"></a> [public\_subnets](#input\_public\_subnets) | Public subnet CIDRs to create | `list(string)` | <pre>[<br/>  "10.0.1.0/24",<br/>  "10.0.2.0/24"<br/>]</pre> | no |
| <a name="input_region"></a> [region](#input\_region) | AWS region | `string` | `"eu-west-2"` | no |
| <a name="input_request_certificate"></a> [request\_certificate](#input\_request\_certificate) | Request an ACM certificate (requires manual DNS validation),<br/>create a self-signed certificate,<br/>or none (fully manage certificate yourself) | `string` | `"selfsigned"` | no |
| <a name="input_require_outbound_proxy"></a> [require\_outbound\_proxy](#input\_require\_outbound\_proxy) | Block default egress at the VPC level, deploy Squid proxy | `bool` | `false` | no |
| <a name="input_vpc_cidr"></a> [vpc\_cidr](#input\_vpc\_cidr) | VPC CIDR to create | `string` | `"10.0.0.0/16"` | no |

### Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_dns_validation_records"></a> [dns\_validation\_records](#output\_dns\_validation\_records) | DNS validation records to be created for ACM certificate |
| <a name="output_efs_token"></a> [efs\_token](#output\_efs\_token) | EFS name creation token |
| <a name="output_k8tre_argocd_cluster_name"></a> [k8tre\_argocd\_cluster\_name](#output\_k8tre\_argocd\_cluster\_name) | K8TRE dev cluster name |
| <a name="output_k8tre_cluster_name"></a> [k8tre\_cluster\_name](#output\_k8tre\_cluster\_name) | K8TRE dev cluster name |
| <a name="output_k8tre_eks_access_role"></a> [k8tre\_eks\_access\_role](#output\_k8tre\_eks\_access\_role) | K8TRE EKS deployment role ARN |
| <a name="output_kubeconfig_command_k8tre-argocd-dev"></a> [kubeconfig\_command\_k8tre-argocd-dev](#output\_kubeconfig\_command\_k8tre-argocd-dev) | Create kubeconfig for k8tre-argocd-dev |
| <a name="output_kubeconfig_command_k8tre-dev"></a> [kubeconfig\_command\_k8tre-dev](#output\_kubeconfig\_command\_k8tre-dev) | Create kubeconfig for k8tre-dev |
| <a name="output_name"></a> [name](#output\_name) | Name used for most resources |
| <a name="output_proxy_ec2_instance_id"></a> [proxy\_ec2\_instance\_id](#output\_proxy\_ec2\_instance\_id) | Transparent proxy EC2 instance ID if enabled |
| <a name="output_s3_studydata_bucket_name"></a> [s3\_studydata\_bucket\_name](#output\_s3\_studydata\_bucket\_name) | Name of the S3 studydata bucket |
| <a name="output_service_access_prefix_list"></a> [service\_access\_prefix\_list](#output\_service\_access\_prefix\_list) | ID of the prefix list that can access services running on K8s |
| <a name="output_vpc_cidr"></a> [vpc\_cidr](#output\_vpc\_cidr) | VPC CIDR |
<!-- END_TF_DOCS -->
<!-- prettier-ignore-end -->
