# Setup K8TRE and prerequisites


######################################################################
# Standard storage classes required by K8TRE

resource "kubernetes_storage_class" "rwo-default" {
  count = (var.deployment_stage >= 2) ? 1 : 0

  metadata {
    name = "rwo-default"
    annotations = {
      "description" = "ReadWriteOnce - Single pod read-write access"
      # "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }
  storage_provisioner = "kubernetes.io/aws-ebs"
  reclaim_policy      = "Delete"
  parameters = {
    type = "gp3"
  }
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true

  provider = kubernetes.k8tre-dev
}

# https://github.com/kubernetes-sigs/aws-efs-csi-driver/blob/ada97c0de28ddea1b525595ed419292191c8601d/examples/kubernetes/dynamic_provisioning/README.md
resource "kubernetes_storage_class" "rwx-default" {
  count = (var.deployment_stage >= 2) ? 1 : 0

  metadata {
    name = "rwx-default"
    annotations = {
      "description" = "ReadWriteMany - Multi-pod shared read-write access"
      # "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }
  storage_provisioner = "efs.csi.aws.com"
  reclaim_policy      = "Delete"
  parameters = {
    provisioningMode = "efs-ap"
    fileSystemId     = module.efs.file_system_id
    directoryPerms   = "750"

    # The rest of these are optional
    gidRangeStart         = "1000"
    gidRangeEnd           = "2000"
    basePath              = "/dynamic_provisioning"
    subPathPattern        = "$${.PVC.namespace}/$${.PVC.name}"
    ensureUniqueDirectory = "true"
    reuseAccessPoint      = "false"
  }
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true

  provider = kubernetes.k8tre-dev
}


######################################################################
# ArgoCD

resource "kubernetes_namespace" "argocd" {
  count = (var.deployment_stage >= 2) ? 1 : 0

  metadata {
    name = "argocd"
  }

  provider = kubernetes.k8tre-dev-argocd
}

# Create the plugin config map first so that it can be referenced later in the helm release.
resource "kubernetes_config_map" "cmp_plugin" {
  count = (var.deployment_stage >= 2) ? 1 : 0

  metadata {
    name      = "cmp-plugin"
    namespace = kubernetes_namespace.argocd[0].metadata[0].name
  }

  data = {
    "plugin.yaml" = <<-EOT
      apiVersion: argoproj.io/v1alpha1
      kind: ConfigManagementPlugin
      metadata:
        name: kustomize-with-envsubst
      spec:
        version: v1.0
        generate:
          command: [sh, -c]
          args:
            - >-
              kustomize build --enable-helm --load-restrictor LoadRestrictionsNone . |
                sed "
                  s/\$${ENVIRONMENT}/$${ARGOCD_ENV_ENVIRONMENT}/g;
                  s/\$${DOMAIN}/$${ARGOCD_ENV_DOMAIN}/g;
                  s/\\.ENVIRONMENT\\./.$${ARGOCD_ENV_ENVIRONMENT}./g;
                  s/\\.DOMAIN/.$${ARGOCD_ENV_DOMAIN}/g;
                  s/^ENVIRONMENT$/$${ARGOCD_ENV_ENVIRONMENT}/g;
                  s/^DOMAIN$/$${ARGOCD_ENV_DOMAIN}/g;

                  s/\$${CLUSTER_NAME}/$${ARGOCD_ENV_CLUSTER_NAME}/g;
                  s/\$${REGION}/$${ARGOCD_ENV_REGION}/g;
                "
    EOT
  }

  provider = kubernetes.k8tre-dev-argocd
}

# https://github.com/argoproj/argo-helm/tree/argo-cd-9.0.5/charts/argo-cd
resource "helm_release" "argocd" {
  count = (var.deployment_stage >= 2) ? 1 : 0

  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.argocd_version
  namespace  = kubernetes_namespace.argocd[0].metadata[0].name

  set = [
    {
      name  = "global.logging.level"
      value = "debug"
    },
    {
      name  = "configs.params.server.insecure"
      value = "true"
    },
    # https://github.com/argoproj/argo-helm/issues/1817
    {
      name  = "configs.cm.kustomize\\.buildOptions"
      value = "--enable-helm --load-restrictor LoadRestrictionsNone"
    },
  ]

  # Specify the custom plugin extra containers and volumes.
  values = [
    yamlencode({
      repoServer = {
        volumes = [
          {
            name = "cmp-plugin"
            configMap = {
              name = "cmp-plugin"
            }
          }
        ]
        extraContainers = [
          {
            name    = "cmp-kustomize-envsubst"
            command = ["/var/run/argocd/argocd-cmp-server"]
            image   = "quay.io/argoproj/argocd:{{ .Chart.AppVersion }}"
            securityContext = {
              runAsNonRoot             = true
              runAsUser                = 999
              allowPrivilegeEscalation = false
              readOnlyRootFilesystem   = true
              capabilities = {
                drop = ["ALL"]
              }
              seccompProfile = {
                type = "RuntimeDefault"
              }
            }
            volumeMounts = [
              {
                mountPath = "/var/run/argocd"
                name      = "var-files"
              },
              {
                mountPath = "/home/argocd/cmp-server/plugins"
                name      = "plugins"
              },
              {
                mountPath = "/tmp"
                name      = "tmp"
              },
              {
                mountPath = "/home/argocd/cmp-server/config/plugin.yaml"
                subPath   = "plugin.yaml"
                name      = "cmp-plugin"
              }
            ]
          }
        ]
      }
    })
  ]

  depends_on = [kubernetes_namespace.argocd, kubernetes_config_map.cmp_plugin]

  provider = helm.k8tre-dev-argocd
}


# Add k8tre-dev cluster to ArgoCD
# https://argo-cd.readthedocs.io/en/release-3.1/operator-manual/declarative-setup/#eks
resource "kubernetes_secret" "argocd-cluster-k8tre-dev" {
  count = (var.deployment_stage >= 2) ? 1 : 0

  metadata {
    name      = "argocd-cluster-${module.k8tre-eks.cluster_name}"
    namespace = kubernetes_namespace.argocd[0].metadata[0].name
    labels = merge(
      { "argocd.argoproj.io/secret-type" = "cluster" },
      var.k8tre_cluster_labels,
      {
        "cluster-name" : module.k8tre-eks.cluster_name,
        "external-domain" : var.dns_domain,
        "region" : var.region,
      },
      var.k8tre_cluster_label_overrides,
    )
  }
  data = {
    config = jsonencode({
      awsAuthConfig = {
        clusterName = module.k8tre-eks.cluster_name
        roleARN     = module.k8tre-eks.eks_access_role
      }
      tlsClientConfig = {
        caData = module.k8tre-eks.cluster_ca_certificate
      }
    })
    name   = module.k8tre-eks.cluster_name
    server = module.k8tre-eks.cluster_endpoint
  }

  provider = kubernetes.k8tre-dev-argocd
}

# https://github.com/k8tre/k8tre/blob/main/app_of_apps/root-app-of-apps.yaml
data "http" "k8tre-root-app" {
  count = (var.deployment_stage >= 3) && var.install_k8tre ? 1 : 0

  url = "https://github.com/${var.k8tre_github_repo}/raw/refs/heads/${var.k8tre_github_ref}/app_of_apps/root-app-of-apps.yaml"
}

resource "kubernetes_manifest" "argocd-root-app-of-apps" {
  count = (var.deployment_stage >= 3) && var.install_k8tre ? 1 : 0

  manifest = yamldecode(
    replace(
      replace(
        data.http.k8tre-root-app[0].response_body,
        "main", var.k8tre_github_ref
      ),
      "k8tre/k8tre", var.k8tre_github_repo
    )
  )

  # This is a CRD, so ArgoCD must be deployed first
  depends_on = [helm_release.argocd]

  provider = kubernetes.k8tre-dev-argocd
}
