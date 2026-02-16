

resource "helm_release" "cilium" {
  name       = "cilium"
  repository = "https://helm.cilium.io/"
  chart      = "cilium"
  version    = "1.19.0"
  namespace  = "kube-system"

  set = [
    {
      name  = "cni.chainingMode"
      value = "aws-cni"
    },
    {
      name  = "cni.exclusive"
      value = "false"
    },
    {
      name  = "enableIPv4Masquerade"
      value = "false"
    },
    {
      name  = "routingMode"
      value = "native"
    },
  ]

  provider = helm.k8tre-dev
}


resource "kubernetes_storage_class" "ebs-gp3" {
  metadata {
    name = "gp3"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
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
