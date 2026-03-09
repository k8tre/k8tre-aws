

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

resource "kubernetes_storage_class" "rwo-default" {
  metadata {
    name = "rwo-default"
    annotations = {
      "description" = "ReadWriteOnce - Single pod read-write access"
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

data "aws_efs_file_system" "lookup" {
  creation_token = var.efs_name
}

# https://github.com/kubernetes-sigs/aws-efs-csi-driver/blob/ada97c0de28ddea1b525595ed419292191c8601d/examples/kubernetes/dynamic_provisioning/README.md
resource "kubernetes_storage_class" "rwx-default" {
  metadata {
    name = "rwx-default"
    annotations = {
      "description" = "ReadWriteMany - Multi-pod shared read-write access"
    }
  }
  storage_provisioner = "efs.csi.aws.com"
  reclaim_policy      = "Delete"
  parameters = {
    provisioningMode = "efs-ap"
    fileSystemId     = data.aws_efs_file_system.lookup.id
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

