# Create the plugin config map first so that it can be referenced later in the helm release.
resource "kubernetes_config_map" "cmp_plugin" {
  metadata {
    name      = "cmp-plugin"
    namespace = "argocd"
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
            - |
              kustomize build --enable-helm --load-restrictor LoadRestrictionsNone . | \
              sed "s/\$${ENVIRONMENT}/$${ARGOCD_ENV_ENVIRONMENT}/g; s/\$${DOMAIN}/$${ARGOCD_ENV_DOMAIN}/g; s/\\.ENVIRONMENT\\./.$${ARGOCD_ENV_ENVIRONMENT}./g; s/\\.DOMAIN/.$${ARGOCD_ENV_DOMAIN}/g; s/^ENVIRONMENT$/$${ARGOCD_ENV_ENVIRONMENT}/g; s/^DOMAIN$/$${ARGOCD_ENV_DOMAIN}/g"
    EOT
  }

  provider = kubernetes.k8tre-dev-argocd
}

# https://github.com/argoproj/argo-helm/tree/argo-cd-9.0.5/charts/argo-cd
resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = "9.4.0"
  namespace  = "argocd"

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

resource "kubernetes_namespace" "argocd" {
  metadata {
    name = "argocd"
  }

  provider = kubernetes.k8tre-dev-argocd
}

# Add k8tre-dev cluster to ArgoCD
# https://argo-cd.readthedocs.io/en/release-3.1/operator-manual/declarative-setup/#eks
resource "kubernetes_secret" "argocd-cluster-k8tre-dev" {
  metadata {
    name      = "argocd-cluster-${data.aws_eks_cluster.deployment.id}"
    namespace = "argocd"
    labels = merge(
      { "argocd.argoproj.io/secret-type" = "cluster" },
      var.k8tre_cluster_labels
    )
  }
  data = {
    config = jsonencode({
      awsAuthConfig = {
        clusterName = data.aws_eks_cluster.deployment.id
        roleARN     = data.terraform_remote_state.k8tre.outputs.k8tre_eks_access_role
      }
      tlsClientConfig = {
        caData = data.aws_eks_cluster.deployment.certificate_authority[0].data
      }
    })
    name   = data.aws_eks_cluster.deployment.id
    server = data.aws_eks_cluster.deployment.endpoint
  }

  provider = kubernetes.k8tre-dev-argocd
}

# https://github.com/k8tre/k8tre/blob/75e550350427d38b637dffbe6f55124ed323ba70/app_of_apps/root-app-of-apps.yaml
resource "kubernetes_manifest" "argocd-root-app-of-apps" {
  count = var.install_k8tre ? 1 : 0

  manifest = yamldecode(
    replace(
      replace(
        file("root-app-of-apps.yaml"),
        "main", var.k8tre_github_ref
      ),
      "k8tre/k8tre", var.k8tre_github_repo
    )
  )

  # This is a CRD, so ArgoCD must be deployed first
  depends_on = [helm_release.argocd]

  provider = kubernetes.k8tre-dev-argocd
}
